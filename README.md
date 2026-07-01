# Codex Log Rotator for Windows

[简体中文](README.zh-CN.md)

**Safely move growing Codex diagnostic logs off your Windows system SSD — with allowlist protection, SHA-256 verification, and restore support.**

## Why this exists

Codex diagnostic log files may continue to grow during normal use. If those files stay on the system SSD, they can consume space and add repeated writes over time. This tool was created to make offloading them to a removable drive or another disk safer and reversible.

## What it does

- Checks four explicitly allowlisted Codex diagnostic log files.
- Moves existing logs to a destination you choose; there is no hidden fallback to the system drive.
- Writes a manifest with paths, sizes, SHA-256 hashes, and completion state.
- Restores a verified backup without overwriting newly created active logs.

## What it does not do

- It does not stop Codex from creating new diagnostic logs after restart.
- It does not claim to fix Codex or an underlying write issue.
- It does not touch sessions, authentication, configuration, plugins, skills, or project files.

> [!IMPORTANT]
> This is an unofficial community project and is not affiliated with or supported by OpenAI. Upgrade Codex before using this tool. This utility rotates existing diagnostic logs; it does not fix the underlying cause of repeated writes.

## Privacy boundary

The utility handles only these files under `%USERPROFILE%\.codex`:

- `logs_2.sqlite`
- `logs_2.sqlite-wal`
- `logs_2.sqlite-shm`
- `log\codex-tui.log`

It does **not** handle sessions, archived sessions, `state_5.sqlite`, authentication, configuration, skills, or plugins.

Diagnostic logs may contain prompts, tool output, local paths, project names, or other sensitive information. Never upload real logs, SQLite databases, manifests, or backup archives to GitHub issues.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- A destination folder, preferably on a separate drive
- Codex must be completely closed before backup or restore

Download `codex-log-rotator.ps1`, then open PowerShell in the download folder.

## Check without changing files

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" -Action Check
```

## Preview a backup

Always preview the operation first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Backup `
  -BackupRoot "E:\CodexLogBackups" `
  -WhatIf
```

## Back up and rotate logs

Close Codex completely, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Backup `
  -BackupRoot "E:\CodexLogBackups" `
  -Confirm:$false
```

The script creates a timestamped directory and moves only existing allowlisted files. It records file size, SHA-256, paths, and completion state in `manifest.json`.

If the destination drive is disconnected or unavailable, the operation stops before moving any source file. It never falls back to the system drive.

## Restore a backup

Close Codex completely. Replace the example timestamp with an actual backup directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Restore `
  -BackupPath "E:\CodexLogBackups\20260701-120000-000" `
  -Confirm:$false
```

Restore validates the allowlist, paths, file sizes, and SHA-256 hashes before moving the first file. It refuses to overwrite an existing active log.

## Limitations

- Codex may create new diagnostic logs after it restarts.
- This tool is not a drive-health, SSD-health, or full-backup solution.
- Backup and restore move files on the local filesystem; keep an independent backup if the records matter.
- If an operation is interrupted, inspect the timestamped directory and `manifest.json` before retrying.

## Testing

Tests use temporary synthetic text files only:

```powershell
Invoke-Pester ".\tests\codex-log-rotator.Tests.ps1"
```

## License

MIT
