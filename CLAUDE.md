# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

本目录是一套**离线文件归档 SHA-256 完整性校验工具**（非软件项目，无构建/测试框架）。核心是两份彼此独立、可直接运行的 PowerShell 7 脚本：

- `Create-HashManifest.ps1`：首次扫描归档根目录，为每个普通文件计算 SHA-256，生成基准 CSV（Manifest）。
- `Verify-HashManifest.ps1`：只读打开原始基准，重新计算当前副本的 SHA-256，生成差异报告 CSV。
- `Create-HashManifest.bat` / `Verify-HashManifest.bat`：双击交互运行；带 `-Interactive` 时每轮结束后直接回车继续、输入 N 退出，可循环处理多个目录，退出循环后 `pause` 显示退出码。

详细设计、参数表、异常状态表、退出码表都在 `README.md` 中，修改行为前先读它。

## 运行环境

- 仅限 **Windows + PowerShell 7**（`#requires -Version 7.0`，脚本内 `if (-not $IsWindows) throw`）。
- **零第三方依赖**，不加载任何模块或共享脚本。CSV 解析用 .NET 内置的 `Microsoft.VisualBasic.FileIO.TextFieldParser`。
- 脚本路径含中文，BAT 用 `chcp 65001` 切到 UTF-8 代码页后调 `pwsh.exe -NoProfile -File ... -Interactive`。

## 常用命令

在 PowerShell 7 中从本目录执行；无人值守用 `pwsh.exe -NoProfile -NonInteractive -File`，成功与否看 `$LASTEXITCODE` 而非输出。

建立基准：

```powershell
.\Create-HashManifest.ps1 -Path 'D:\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv'
$LASTEXITCODE   # 0=成功；非 0=失败且不发布正式基准
```

验证另一份副本（支持盘符或 `\\NAS\...` UNC 路径）：

```powershell
.\Verify-HashManifest.ps1 -Path 'E:\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv' -Report 'D:\Archive\HASH\Verification\Backup_2026.csv'
$LASTEXITCODE   # 0=全部通过；1=有异常文件；2=任务未完整完成
```

省略 `-Manifest` 时默认用 `脚本目录\HASH\SHA256_<归档根目录名>.csv`；省略 `-Report` 时在清单目录自动命名。

**没有正式测试套件。** 验证改动的方式是隔离临时目录内的小样本演练（README 第 14 节的方法）：造几个不同属性/扩展名的文件（含空文件、隐藏文件、长路径）→ 跑 Create → 跑 Verify → 检查各状态值、排除列表和退出码；并单独用 `Get-FileHash -Algorithm SHA256` 交叉比对结果。语法检查用 `pwsh.exe -NoProfile -NonInteractive -Command "$null = [scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '.\Create-HashManifest.ps1'))"`。

## 架构与数据流

两个脚本是**刻意近乎复制**的（约 80% 相同的 helper 函数，无共享模块），以便各自能被单独复制、审阅、备份。修改一处逻辑时通常要在两份脚本中同步改，并核对它们是否已悄然分歧。

数据流（Create）：

1. 路径校验：`Get-ArchiveRoot` 解析为完整文件系统路径，拒绝设备路径前缀 `\\?\` / `\\.\`，沿路径逐级 `Assert-NoReparsePoint`（不跟随符号链接/Junction）。
2. `Get-ArchiveInventory` 用 .NET `EnumerateFileSystemInfos` 手动栈式遍历，按精确路径排除本次 Manifest、`.incomplete` 中间文件、以及带 `ReportMarker` 的本工具报告；整目录排除 `脚本目录\HASH`（保留管理目录）。索引键用 `StringComparer.OrdinalIgnoreCase`（Windows 大小写不敏感）。
3. `Get-StreamingSHA256` 用 1 MiB 缓冲 + `IncrementalHash` 顺序流式读，内存不随文件大小增长；读取前后比对 size/LastWriteTimeUtc/readBytes，期间变化抛 `FILE_CHANGED_DURING_HASH`。
4. 全部算完后**再扫描一次**，检测运行期间新增/删除/修改，任一变化即放弃发布。
5. 先写随机命名 `.incomplete` 中间文件，Flush 后用 `[IO.File]::Move(..., $false)`（禁止覆盖）原子发布为正式 CSV；失败时保留 `.incomplete` 且绝不作为基准。

Verify 的差异：Manifest 以只读 `[IO.FileShare]::Read` 打开、全程不写；逐条比对基准与当前文件，`SIZE_MISMATCH` 文件仍完整计算实际 SHA-256 供交叉比对；`NEW_FILE`（当前有而基准无）只记大小/时间、**不额外读内容算哈希**。

## 关键设计约定（改代码前必读）

- **CSV 格式**：所有字段加引号、内部 `"` 转义为 `""`，文件为 UTF-8 BOM，换行 `\r\n`。Manifest 列 `RelativePath,Size,SHA256,LastWriteTimeUtc`；报告在其上追加 `Status,ExpectedSize,ActualSize,ExpectedSHA256,ActualSHA256,...` 并以 `ReportMarker` 收尾。
- **ReportMarker 机制**：`ReportMarker = 'PS7-SHA256-Verification-Report-v1'`。扫描时**只按“表头完全一致 + 首条记录以此标识结尾”识别**本工具生成的报告并排除，**不按 `.csv` 扩展名或文件名排除**——普通名为 `Verification_*.csv` 的文件仍当作归档数据。README 明确指出该标识不是防伪造的安全边界。
- **`LastWriteTimeUtc` 仅作人工排查辅助**，不能独立构成内容损坏结论；历史时间戳变化不影响 OK。内容一致性只看 SHA-256（及 Size 作为快速前置判断）。
- **退出码契约**：Create `0`=发布成功、`2`=任何失败；Verify `0`=通过、`1`=发现缺失/哈希变化/新文件、`2`=清单无效或任务未完整完成（含 `SCAN_ERROR`/`READ_ERROR`）。自动化必须把任何非零码视为未通过。
- `Get-SafeRelativePath` 拒绝绝对路径、空路径、`.`/`..`、以点/空格结尾、非法字符和 Windows 保留名（CON/PRN/AUX/NUL/COM/LPT）；`Read-ValidatedManifest` 逐行严格校验列数、Size（非负十进制）、SHA256（64 位十六进制），整份不合法即拒绝。
- 空归档目录拒绝建立基准；空清单拒绝通过校验（`Read-ValidatedManifest` 抛错）。

## 兄弟目录

父目录 `文件校验\` 下另有 `录音\`，文件名与本目录相同但脚本尺寸/日期不同，是针对长期录音归档的分叉变体（README 名为「长期录音归档校验」）。修改本目录逻辑时不要假设两处脚本同步——如需保持一致，先读 `录音\` 版本确认差异。
