$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'codex-log-rotator.ps1'

Describe 'Public command contract' {
    It 'exposes only the approved public parameters' {
        $command = Get-Command -Name $scriptPath
        $publicParameters = @(
            $command.ScriptBlock.Ast.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath }
        )

        $publicParameters -join ',' | Should Be 'Action,CodexHome,BackupRoot,BackupPath'
        $command.Parameters.ContainsKey('WhatIf') | Should Be $true
        $command.Parameters.ContainsKey('Confirm') | Should Be $true
        $command.Parameters.ContainsKey('SkipProcessCheck') | Should Be $false
        $command.Parameters.ContainsKey('ProcessCheckOverride') | Should Be $false
    }

    It 'requires an explicit backup root' {
        $command = Get-Command -Name $scriptPath
        $parameter = $command.ScriptBlock.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'BackupRoot' }

        $parameter.DefaultValue | Should Be $null
    }
}

Describe 'Check action safety' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $codexHome = Join-Path $caseRoot '.codex'
        $logDirectory = Join-Path $codexHome 'log'
        $sessionDirectory = Join-Path $codexHome 'sessions'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') -Value 'db'
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite-wal') -Value 'wal'
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite-shm') -Value 'shm'
        Set-Content -LiteralPath (Join-Path $logDirectory 'codex-tui.log') -Value 'tui'
        Set-Content -LiteralPath (Join-Path $codexHome 'state_5.sqlite') -Value 'protected-state'
        Set-Content -LiteralPath (Join-Path $codexHome 'auth.json') -Value 'protected-auth'
        Set-Content -LiteralPath (Join-Path $sessionDirectory 'example.jsonl') -Value 'protected-session'

        $protectedBefore = @{
            State = (Get-FileHash -LiteralPath (Join-Path $codexHome 'state_5.sqlite') -Algorithm SHA256).Hash
            Auth = (Get-FileHash -LiteralPath (Join-Path $codexHome 'auth.json') -Algorithm SHA256).Hash
            Session = (Get-FileHash -LiteralPath (Join-Path $sessionDirectory 'example.jsonl') -Algorithm SHA256).Hash
        }
    }

    It 'reports exactly the four allowlisted diagnostic logs' {
        $result = & $scriptPath -Action Check -CodexHome $codexHome

        @($result.Name) -join ',' | Should Be 'logs_2.sqlite,logs_2.sqlite-wal,logs_2.sqlite-shm,codex-tui.log'
    }

    It 'does not modify protected Codex data' {
        & $scriptPath -Action Check -CodexHome $codexHome | Out-Null

        (Get-FileHash -LiteralPath (Join-Path $codexHome 'state_5.sqlite') -Algorithm SHA256).Hash | Should Be $protectedBefore.State
        (Get-FileHash -LiteralPath (Join-Path $codexHome 'auth.json') -Algorithm SHA256).Hash | Should Be $protectedBefore.Auth
        (Get-FileHash -LiteralPath (Join-Path $sessionDirectory 'example.jsonl') -Algorithm SHA256).Hash | Should Be $protectedBefore.Session
    }
}

Describe 'Backup safety and integrity' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $codexHome = Join-Path $caseRoot '.codex'
        $backupRoot = Join-Path $caseRoot 'backups'
        $logDirectory = Join-Path $codexHome 'log'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') -Value 'database-content'
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite-wal') -Value 'wal-content'
        Set-Content -LiteralPath (Join-Path $logDirectory 'codex-tui.log') -Value 'tui-content'
        Set-Content -LiteralPath (Join-Path $codexHome 'state_5.sqlite') -Value 'protected-state'

        . $scriptPath -Action Check -CodexHome $codexHome -BackupRoot $backupRoot | Out-Null
    }

    It 'refuses before creating a backup directory when Codex is running' {
        $caught = $null
        try { Invoke-LogBackup -SourceRoot $codexHome -DestinationRoot $backupRoot -ProcessProbe { $true } -Confirm:$false }
        catch { $caught = $_ }

        $caught.Exception.Message | Should Match '^Codex is running\.'
        Test-Path -LiteralPath $backupRoot | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $true
    }

    It 'changes nothing during WhatIf' {
        Invoke-LogBackup -SourceRoot $codexHome -DestinationRoot $backupRoot -ProcessProbe { $false } -WhatIf

        Test-Path -LiteralPath $backupRoot | Should Be $false
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $true
    }

    It 'moves only allowlisted files and records completed SHA256 entries' {
        $result = Invoke-LogBackup -SourceRoot $codexHome -DestinationRoot $backupRoot -ProcessProbe { $false } -Confirm:$false
        $manifestPath = Join-Path $result.BackupPath 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $manifest.Version | Should Be 1
        @($manifest.Files).Count | Should Be 3
        @($manifest.Files | Where-Object { $_.Status -ne 'Completed' }).Count | Should Be 0
        @($manifest.Files | Where-Object { $_.SHA256 -notmatch '^[A-F0-9]{64}$' }).Count | Should Be 0
        @($manifest.Files | Where-Object { [string]::IsNullOrWhiteSpace($_.RelativePath) }).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $codexHome 'state_5.sqlite') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $false
    }

    It 'leaves all sources unchanged when the destination drive is unavailable' {
        $usedDrives = @(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)
        $missingDrive = @('Z','Y','X','W','V','U','T','S','R','Q') |
            Where-Object { $usedDrives -notcontains $_ } |
            Select-Object -First 1
        if ($null -eq $missingDrive) { throw 'No unused drive letter is available for this test.' }

        $caught = $null
        try { Invoke-LogBackup -SourceRoot $codexHome -DestinationRoot "$missingDrive`:\backups" -ProcessProbe { $false } -Confirm:$false }
        catch { $caught = $_ }

        $caught.Exception.Message | Should Match '^Backup drive is unavailable:'
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $true
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite-wal') | Should Be $true
        Test-Path -LiteralPath (Join-Path $logDirectory 'codex-tui.log') | Should Be $true
    }
}

Describe 'Restore safety and integrity' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $codexHome = Join-Path $caseRoot '.codex'
        $backupRoot = Join-Path $caseRoot 'backups'
        New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') -Value 'database-content'

        . $scriptPath -Action Check -CodexHome $codexHome -BackupRoot $backupRoot | Out-Null
        $backupResult = Invoke-LogBackup -SourceRoot $codexHome -DestinationRoot $backupRoot -ProcessProbe { $false } -Confirm:$false
        $backupPath = $backupResult.BackupPath
    }

    It 'restores a verified allowlisted backup' {
        $result = Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false

        $result.FileCount | Should Be 1
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $true
        Test-Path -LiteralPath (Join-Path $backupPath 'manifest.json') | Should Be $true
    }

    It 'refuses a hash mismatch without restoring a file' {
        Set-Content -LiteralPath (Join-Path $backupPath 'logs_2.sqlite') -Value 'tampered-content'

        { Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $false
    }

    It 'refuses to overwrite an existing source' {
        Set-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') -Value 'new-active-log'

        { Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false } | Should Throw
        (Get-Content -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') -Raw).Trim() | Should Be 'new-active-log'
    }

    It 'rejects a manifest path outside the selected backup directory' {
        $manifestPath = Join-Path $backupPath 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.Files[0].BackupPath = Join-Path $caseRoot 'outside.sqlite'
        Set-Content -LiteralPath $manifest.Files[0].BackupPath -Value 'database-content'
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        { Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $false
    }

    It 'rejects an unknown or duplicate log name' {
        $manifestPath = Join-Path $backupPath 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.Files[0].Name = 'state_5.sqlite'
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        { Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $codexHome 'logs_2.sqlite') | Should Be $false
    }

    It 'rejects a manifest for a different Codex home' {
        $manifestPath = Join-Path $backupPath 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $otherCodexHome = Join-Path $caseRoot 'other-codex-home'
        $manifest.CodexHome = $otherCodexHome
        $manifest.Files[0].SourcePath = Join-Path $otherCodexHome 'logs_2.sqlite'
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

        { Invoke-LogRestore -SourceBackupPath $backupPath -ExpectedCodexHome $codexHome -ProcessProbe { $false } -Confirm:$false } | Should Throw
        Test-Path -LiteralPath (Join-Path $otherCodexHome 'logs_2.sqlite') | Should Be $false
    }
}
