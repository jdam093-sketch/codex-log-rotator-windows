# Codex Windows 日志安全迁移工具

[English](README.md)

**将持续增长的 Codex 诊断日志安全移出 Windows 系统 SSD，并保留白名单保护、SHA-256 校验和恢复能力。**

## 为什么做

Codex 的诊断日志在日常使用中可能持续增长。如果这些文件一直留在系统 SSD，会逐渐占用空间，并可能带来反复写入。这个工具的初衷，是把日志迁移到移动硬盘或其他磁盘，同时让整个过程可检查、可验证、可恢复。

## 它具体做什么

- 只检查四种明确列入白名单的 Codex 诊断日志。
- 把现有日志移动到用户指定的磁盘，不会暗中回退到系统盘。
- 用 manifest 记录路径、大小、SHA-256 和完成状态。
- 对备份校验后再恢复，并拒绝覆盖 Codex 新生成的活动日志。

## 它不会做什么

- 不会阻止 Codex 重启后继续生成新的诊断日志。
- 不宣称修复 Codex 或底层写入问题。
- 不触碰会话、认证信息、配置、plugins、skills 或项目文件。

> [!IMPORTANT]
> 这是非官方社区项目，与 OpenAI 无隶属关系，也不由 OpenAI 提供支持。使用前请先升级 Codex。本工具只轮转已经生成的诊断日志，不能根治反复写入的原因。

## 隐私边界

本工具只处理 `%USERPROFILE%\.codex` 下的以下文件：

- `logs_2.sqlite`
- `logs_2.sqlite-wal`
- `logs_2.sqlite-shm`
- `log\codex-tui.log`

它**不会**处理会话、归档会话、`state_5.sqlite`、认证信息、配置、skills 或 plugins。

诊断日志可能包含提示词、工具输出、本地路径、项目名称或其他敏感信息。切勿把真实日志、SQLite 数据库、manifest 或备份压缩包上传到 GitHub issue。

## 使用条件

- Windows PowerShell 5.1 或 PowerShell 7
- 一个备份目标目录，最好位于另一块磁盘
- 执行备份或恢复前必须彻底退出 Codex

下载 `codex-log-rotator.ps1`，然后在下载目录打开 PowerShell。

## 只读检查

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" -Action Check
```

## 预演备份

建议始终先预演：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Backup `
  -BackupRoot "E:\CodexLogBackups" `
  -WhatIf
```

## 备份并轮转日志

彻底退出 Codex 后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Backup `
  -BackupRoot "E:\CodexLogBackups" `
  -Confirm:$false
```

脚本会创建带时间戳的目录，只移动实际存在的白名单文件，并在 `manifest.json` 中记录文件大小、SHA-256、路径和完成状态。

如果目标磁盘断开或不可用，操作会在移动任何源文件前停止，并且绝不会回退到系统盘。

## 恢复备份

彻底退出 Codex。把示例时间戳替换为真实备份目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex-log-rotator.ps1" `
  -Action Restore `
  -BackupPath "E:\CodexLogBackups\20260701-120000-000" `
  -Confirm:$false
```

恢复前会统一验证白名单、路径、文件大小和 SHA-256。只要活动日志中已有同名文件，脚本就会拒绝覆盖。

## 局限

- Codex 重启后仍可能生成新的诊断日志。
- 本工具不是磁盘健康、SSD 健康或完整备份方案。
- 备份和恢复会在本地文件系统中移动文件；重要记录仍应保留独立备份。
- 如果操作被中断，请先检查时间戳目录和 `manifest.json`，不要直接重复执行。

## 测试

测试只使用临时生成的虚拟文本文件：

```powershell
Invoke-Pester ".\tests\codex-log-rotator.Tests.ps1"
```

## 许可证

MIT
