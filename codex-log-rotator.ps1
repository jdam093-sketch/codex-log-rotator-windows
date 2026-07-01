[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Check', 'Backup', 'Restore')]
    [string]$Action,

    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$BackupRoot,
    [string]$BackupPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-TargetLogs {
    param([Parameter(Mandatory = $true)][string]$Root)

    @(
        [pscustomobject]@{ Name = 'logs_2.sqlite'; RelativePath = 'logs_2.sqlite'; Path = Join-Path $Root 'logs_2.sqlite' }
        [pscustomobject]@{ Name = 'logs_2.sqlite-wal'; RelativePath = 'logs_2.sqlite-wal'; Path = Join-Path $Root 'logs_2.sqlite-wal' }
        [pscustomobject]@{ Name = 'logs_2.sqlite-shm'; RelativePath = 'logs_2.sqlite-shm'; Path = Join-Path $Root 'logs_2.sqlite-shm' }
        [pscustomobject]@{ Name = 'codex-tui.log'; RelativePath = 'log\codex-tui.log'; Path = Join-Path (Join-Path $Root 'log') 'codex-tui.log' }
    )
}

function Get-LogStatus {
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($target in Get-TargetLogs -Root $Root) {
        $item = Get-Item -LiteralPath $target.Path -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name = $target.Name
            RelativePath = $target.RelativePath
            Path = $target.Path
            Exists = $null -ne $item
            Length = if ($null -ne $item) { $item.Length } else { 0 }
            LastWriteTime = if ($null -ne $item) { $item.LastWriteTime } else { $null }
        }
    }
}

function Test-CodexProcessRunning {
    return $null -ne (
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like 'codex*' } |
            Select-Object -First 1
    )
}

function Assert-CodexStopped {
    param([scriptblock]$ProcessProbe = { Test-CodexProcessRunning })

    if (& $ProcessProbe) {
        throw 'Codex is running. Exit Codex completely before continuing.'
    }
}

function Resolve-BackupRoot {
    param([Parameter(Mandatory = $true)][string]$DestinationRoot)

    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        throw 'BackupRoot is required for Backup.'
    }

    $fullDestination = [IO.Path]::GetFullPath($DestinationRoot)
    $filesystemRoot = [IO.Path]::GetPathRoot($fullDestination)
    if ([string]::IsNullOrWhiteSpace($filesystemRoot) -or
        -not (Test-Path -LiteralPath $filesystemRoot -PathType Container)) {
        throw "Backup drive is unavailable: $filesystemRoot"
    }

    return $fullDestination.TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Write-Manifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Test-PathEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        [IO.Path]::GetFullPath($Left).TrimEnd('\'),
        [IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Invoke-LogBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [scriptblock]$ProcessProbe = { Test-CodexProcessRunning }
    )

    Assert-CodexStopped -ProcessProbe $ProcessProbe
    $existing = @(Get-LogStatus -Root $SourceRoot | Where-Object Exists)
    if ($existing.Count -eq 0) {
        throw 'No supported Codex diagnostic logs were found.'
    }

    $resolvedRoot = Resolve-BackupRoot -DestinationRoot $DestinationRoot
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $destination = Join-Path $resolvedRoot $timestamp

    if (-not $PSCmdlet.ShouldProcess($destination, "Move $($existing.Count) allowlisted Codex diagnostic log file(s)")) {
        return [pscustomobject]@{ Action = 'Backup'; BackupPath = $destination; FileCount = 0; WhatIf = $true }
    }

    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedRoot -Force:$false | Out-Null
    }
    New-Item -ItemType Directory -Path $destination -Force:$false | Out-Null

    $records = @()
    foreach ($source in $existing) {
        $destinationPath = Join-Path $destination $source.Name
        $records += [pscustomobject]@{
            Name = $source.Name
            RelativePath = $source.RelativePath
            SourcePath = [IO.Path]::GetFullPath($source.Path)
            BackupPath = [IO.Path]::GetFullPath($destinationPath)
            Length = [long]$source.Length
            SHA256 = (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash
            Status = 'Planned'
        }
    }

    $manifest = [pscustomobject]@{
        Version = 1
        CreatedAt = (Get-Date).ToString('o')
        CodexHome = [IO.Path]::GetFullPath($SourceRoot)
        Files = @($records)
    }
    $manifestPath = Join-Path $destination 'manifest.json'
    Write-Manifest -Manifest $manifest -Path $manifestPath

    foreach ($record in $manifest.Files) {
        Move-Item -LiteralPath $record.SourcePath -Destination $record.BackupPath
        $moved = Get-Item -LiteralPath $record.BackupPath
        $movedHash = (Get-FileHash -LiteralPath $record.BackupPath -Algorithm SHA256).Hash
        if ((Test-Path -LiteralPath $record.SourcePath) -or
            $moved.Length -ne [long]$record.Length -or
            $movedHash -ne $record.SHA256) {
            throw "Backup verification failed: $($record.Name)"
        }
        $record.Status = 'Completed'
        Write-Manifest -Manifest $manifest -Path $manifestPath
    }

    return [pscustomobject]@{
        Action = 'Backup'
        BackupPath = $destination
        FileCount = @($manifest.Files).Count
        WhatIf = $false
    }
}

function Invoke-LogRestore {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$SourceBackupPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCodexHome,
        [scriptblock]$ProcessProbe = { Test-CodexProcessRunning }
    )

    Assert-CodexStopped -ProcessProbe $ProcessProbe
    $resolvedBackup = [IO.Path]::GetFullPath($SourceBackupPath).TrimEnd('\')
    $manifestPath = Join-Path $resolvedBackup 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Version -ne 1 -or
        [string]::IsNullOrWhiteSpace($manifest.CodexHome) -or
        $null -eq $manifest.Files -or
        @($manifest.Files).Count -eq 0) {
        throw 'Manifest is invalid or unsupported.'
    }
    if (-not (Test-PathEquals -Left $manifest.CodexHome -Right $ExpectedCodexHome)) {
        throw 'Manifest CodexHome does not match the requested restore target.'
    }

    $allowed = @{}
    foreach ($target in Get-TargetLogs -Root $manifest.CodexHome) {
        $allowed[$target.Name] = $target
    }
    $seen = @{}

    foreach ($record in @($manifest.Files)) {
        if (-not $allowed.ContainsKey($record.Name) -or $seen.ContainsKey($record.Name)) {
            throw "Manifest contains a disallowed or duplicate log name: $($record.Name)"
        }
        $seen[$record.Name] = $true
        $target = $allowed[$record.Name]
        $expectedBackup = Join-Path $resolvedBackup $record.Name

        if ($record.Status -ne 'Completed' -or
            $record.RelativePath -ne $target.RelativePath -or
            -not (Test-PathEquals -Left $record.SourcePath -Right $target.Path) -or
            -not (Test-PathEquals -Left $record.BackupPath -Right $expectedBackup)) {
            throw "Manifest path is outside the diagnostic log allowlist: $($record.Name)"
        }
        if (-not (Test-Path -LiteralPath $record.BackupPath -PathType Leaf)) {
            throw "Backup file not found: $($record.Name)"
        }
        if (Test-Path -LiteralPath $record.SourcePath) {
            throw "Restore refused because source already exists: $($record.SourcePath)"
        }

        $backupItem = Get-Item -LiteralPath $record.BackupPath
        $backupHash = (Get-FileHash -LiteralPath $record.BackupPath -Algorithm SHA256).Hash
        if ($backupItem.Length -ne [long]$record.Length -or $backupHash -ne $record.SHA256) {
            throw "Backup integrity check failed: $($record.Name)"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($manifest.CodexHome, "Restore $(@($manifest.Files).Count) verified Codex diagnostic log file(s)")) {
        return [pscustomobject]@{ Action = 'Restore'; BackupPath = $resolvedBackup; FileCount = 0; WhatIf = $true }
    }

    foreach ($record in @($manifest.Files)) {
        $sourceDirectory = Split-Path -Parent $record.SourcePath
        if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
        }
        Move-Item -LiteralPath $record.BackupPath -Destination $record.SourcePath
        $restored = Get-Item -LiteralPath $record.SourcePath
        $restoredHash = (Get-FileHash -LiteralPath $record.SourcePath -Algorithm SHA256).Hash
        if ($restored.Length -ne [long]$record.Length -or $restoredHash -ne $record.SHA256) {
            throw "Restore verification failed: $($record.Name)"
        }
    }

    return [pscustomobject]@{
        Action = 'Restore'
        BackupPath = $resolvedBackup
        FileCount = @($manifest.Files).Count
        WhatIf = $false
    }
}

if ($Action -eq 'Check') {
    Get-LogStatus -Root $CodexHome
    return
}

if ($Action -eq 'Backup') {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        throw 'BackupRoot is required for Backup.'
    }
    Invoke-LogBackup -SourceRoot $CodexHome -DestinationRoot $BackupRoot
    return
}

if ($Action -eq 'Restore') {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw 'BackupPath is required for Restore.'
    }
    Invoke-LogRestore -SourceBackupPath $BackupPath -ExpectedCodexHome $CodexHome
    return
}
