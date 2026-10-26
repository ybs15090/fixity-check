# 通用文件归档 SHA-256 校验

本目录提供两份彼此独立、可直接运行的完整 PowerShell 7 脚本：

- Create-HashManifest.ps1：首次建立基准 CSV。
- Verify-HashManifest.ps1：只读检查原始基准并生成新报告。
- Create-HashManifest.bat、Verify-HashManifest.bat：双击交互运行，结束时显示运行结果。

默认扫描全部普通文件，SHA-256 针对原始字节计算，与文件格式或扩展名无关。MP3、ISO、PDF、源码、无扩展名、空文件、隐藏文件、只读文件、.lnk 文件本身均按同一方法处理。

## 1. 设计说明

- Manifest 只存相对路径、字节数、SHA-256 和辅助性的 UTC 修改时间，换盘符、UNC 根目录后可直接复用。
- Manifest 可在归档根目录内。扫描时按精确完整路径排除本次指定的 Manifest。
- 脚本同目录的 HASH 仍是保留管理目录；若它落在 -Path 内，整个目录会排除。不要把待归档的数据放进去（默认基准已不再写入这里）。
- Verify 生成的 CSV 报告带专用 ReportMarker 字段。后续扫描仅识别有该标识且表头符合预期的报告，不按文件名或扩展名排除所有 CSV。普通名为 Verification_*.csv 的文件仍被当作归档数据。排除项逐个输出，建立基准时应审阅。
- 当前写入的随机 .incomplete 文件按精确路径排除。以前失败留下的中间文件不会静默排除，在 Verify 中属于 NEW_FILE；先人工检查。
- 专用报告标识不是防恶意伪造的安全边界。若普通 CSV 恰好复制了完全相同的专用表头和标识，也会被排除。重要归档优先把 HASH 和报告目录放在 -Path 之外。
- 单个文件使用 1 MiB 缓冲区顺序流式读取，内存占用不随文件大小增长；文件索引和清单条目保存在内存，随文件数增长。
- 读取前后检查大小、当前修改时间和读取字节数。如果读取期间发生变化，Verify 记录 FILE_CHANGED_DURING_HASH，Create 不发布正式基准。历史文件时间与 Manifest 不同仍可为 OK。
- 符号链接、Junction 和其他 Reparse Point 不递归跟随；扫描不完整时不能显示通过。隐藏文件正常扫描。
- 路径索引按 Windows 大小写不敏感方式比较；仅大小写不同的重复条目报错，以免在 Windows/NAS 之间产生歧义。
- 创建基准和输出报告时先写随机 .incomplete 文件，刷新后以禁止覆盖的方式发布。原始 Manifest 在 Verify 中只读打开。
- SHA-256 证明读到的主文件字节与基准是否相同；不覆盖 ACL、备用数据流、目录属性或空目录，也不能证明初始归档本来就正确。

## 2. 完整脚本

- Create-HashManifest.ps1：本目录中的完整创建代码。
- Verify-HashManifest.ps1：本目录中的完整验证代码。

两个脚本没有第三方模块或共享脚本依赖，可分别复制、审阅和备份。

## 3. 参数说明

| 脚本 | 参数 | 必需 | 作用 |
| --- | --- | --- | --- |
| Create | -Path | CLI 必填；双击时输入 | 归档根目录 |
| Create | -Manifest | 否 | 新基准 CSV；省略时按默认规则命名并存到归档根父目录，也可指向目录或完整文件路径；已存在则拒绝覆盖 |
| Verify | -Path | CLI 必填；双击时输入 | 被验证副本的归档根目录 |
| Verify | -Manifest | 否 | 最初基准 CSV；省略时自动在归档根父目录查找；只读 |
| Verify | -Report | 否 | 新报告 CSV；省略时自动在清单目录命名 |
| 两者 | -Interactive | 否 | 显示参数含义并在缺少输入时提示；每轮结束后直接回车继续、输入 N 退出；BAT 自动指定 |

省略 -Manifest 时，Create 默认命名为“<归档根目录名>_SHA256_<创建日期 yyyyMMdd>.csv”，保存到归档根目录的父目录（与归档根并列）。例如 -Path 为 D:\Archive\Data，则默认 D:\Archive\Data_SHA256_20261026.csv。Create 的 -Manifest 也可指向目录：在该目录下按默认命名自动创建 CSV（目录不存在会自动创建）。Verify 省略 -Manifest 时，自动在归档根父目录查找“<归档根目录名>_SHA256_*.csv”，多个匹配取最新。原基准若是自定义名称，必须明确输入原路径。自定义文件路径的父目录需预先存在。支持盘符和普通 UNC 路径；拒绝设备路径前缀。脚本不删除文件，也不修改系统配置。

## 4. 使用示例

在 PowerShell 7 中从本目录执行；非交互调用可使用 pwsh.exe -NoProfile -NonInteractive -File。

双击本目录的 Create-HashManifest.bat 或 Verify-HashManifest.bat，会显示 Path、Manifest、Report 的含义并等待输入。Create 的 Manifest 直接回车使用默认命名；Verify 的 Manifest 直接回车自动查找、Report 留空自动命名。每轮执行结束后会提示“按回车继续……，输入 N 退出”：直接回车继续并重新输入下一轮的 Path、Manifest、Report；输入 N（或 no/否）退出循环。查看屏幕上的绿色/红色结果文字后按任意键关闭窗口。双击交互调用不会使用 -NonInteractive；无人值守命令仍应使用它，且只执行一轮。

建立基准（省略 -Manifest 时按默认规则命名，结果看输出文字）：

    .\Create-HashManifest.ps1 -Path 'D:\Archive\Data'
    .\Create-HashManifest.ps1 -Path 'D:\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv'

验证另一硬盘：

    .\Verify-HashManifest.ps1 -Path 'E:\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv' -Report 'D:\Archive\HASH\Verification\Backup_2026-10-03.csv'

验证 NAS：

    .\Verify-HashManifest.ps1 -Path '\\NAS\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv' -Report 'D:\Archive\HASH\Verification\NAS_2026-10-03.csv'

清单位于归档根内：

    .\Create-HashManifest.ps1 -Path 'D:\Archive\Data' -Manifest 'D:\Archive\Data\SHA256_manifest.csv'
    .\Verify-HashManifest.ps1 -Path 'E:\Archive\Data' -Manifest 'E:\Archive\Data\SHA256_manifest.csv'

最后一例假设原始清单也复制到了 E 盘。也可使用 \\192.168.1.10\Archive\Data 形式的 UNC 路径。建议将 NAS 验证报告写到本地独立目录。

## 5. 推荐目录结构

    Archive\
    ├─ Data\                         ← -Path
    │  ├─ Documents\
    │  ├─ Photos\
    │  ├─ Videos\
    │  ├─ Audio\
    │  ├─ Software\
    │  └─ Projects\
    ├─ Data_SHA256_20261026.csv  ← 省略 -Manifest 时的默认基准（与 Data 并列）
    ├─ HASH\  ← 可选：显式 -Manifest 指定的存放位置
    │  ├─ SHA256_Archive_2026.csv     ← 原始基准
    │  └─ Verification\
    ├─ Create-HashManifest.ps1
    ├─ Verify-HashManifest.ps1
    ├─ Create-HashManifest.bat
    └─ Verify-HashManifest.bat                  

省略 -Manifest 时，Create 在 Archive\（Data 的同级）生成 Data_SHA256_<日期>.csv；Verify 省略 -Manifest 时也在 Archive\ 下自动查找 Data_SHA256_*.csv。图中 Archive\HASH 是使用显式 -Manifest 的可选存放位置。脚本同目录的 HASH 仍是保留管理目录（若落在 -Path 内会整体排除），但默认基准已不再写入。若清单另放在 Data 内，脚本仍可按本次指定路径精确排除。

## 6. 首次建立归档

1. 整理 Data 及文件名，确认文件原本可打开。暂停同步、编辑、下载和重命名。
2. 使用默认 Manifest 时，Create 会在归档根父目录生成 <归档根名>_SHA256_<日期>.csv（无需预建目录）；若 -Manifest 指向目录会自动创建，自定义文件路径的父目录需预先存在。
3. 核对扫描文件数、总字节数、成功/失败数量、扫描错误、排除列表，并确认输出为绿色「基准清单已保存」。只有完整成功发布的正式 CSV 才可作为基准。
4. 立即运行 Verify 并保留首份报告。
5. 把原始清单保存到另一设备、只读共享、NAS 快照或离线介质。另存该 CSV 自身的 SHA-256 到独立位置：

    Get-FileHash -LiteralPath 'D:\Archive\HASH\SHA256_Archive_2026.csv' -Algorithm SHA256

不要把失败后的 .incomplete 文件改名为正式清单；脚本的防覆盖机制不能阻止其他软件或用户改写 CSV。

## 7. 复制到备份硬盘后的验证

1. 先验证主硬盘，确认复制来源符合原始基准。
2. 复制 Data，保留其内部相对路径及文件名；复制同一份原始清单。
3. 以备份硬盘的 Data 为 -Path，使用原始基准执行 Verify。
4. 核对全部 OK、无 NEW_FILE 和扫描错误，且输出为绿色「完整性校验通过」；保存报告。
5. 安全弹出并重新连接后可再验证一次。确认独立副本正常前保留旧盘数据。

迁移后历史时间戳变化不影响 OK。不要在新硬盘重新运行 Create 来代替迁移验证。

## 8. NAS / SMB 验证

1. 以运行脚本的同一账户确认 UNC 目录可列举、文件可读取。
2. 暂停 NAS 写入和同步，或在只读快照上验证。
3. 指定 UNC 数据根和原始 Manifest，报告写到本地。
4. 网络断开、权限失败、文件占用时核对报告中的 READ_ERROR / SCAN_ERROR，故障解除后重新完整运行。
5. 不根据一次不完整扫描得出“全部正常”。

校验数 TB NAS 文件会通过网络读取全部基准文件。映射盘符通常与登录会话绑定，计划任务更适合用 UNC 路径。

## 9. 半年或年度检查

1. 确认设备、路径层级和最初基准。如果保存了基准自身的独立哈希，先核对它。
2. 暂停写入；对每个副本分别 Verify，并分别保存报告。
3. 输出为绿色「完整性校验通过」时记录检查日期、设备和报告路径。
4. 有异常时保存现场，用同一原始基准交叉检查其他独立副本，再人工决定恢复办法。

## 10. 异常处理

| 状态 | 含义 | 处理 |
| --- | --- | --- |
| MISSING | 基准文件或其父目录不见了 | 查路径、盘符、共享状态；验证其他副本 |
| HASH_MISMATCH | 大小相同但 SHA-256 不同 | 保留现场，找匹配基准的独立副本 |
| SIZE_MISMATCH | 大小不同 | 仍完整计算实际 SHA-256，供交叉比对 |
| NEW_FILE | 当前目录出现基准中没有的普通文件 | 查来源；有意追加时建新批次，保留旧清单 |
| READ_ERROR | 无法读取、权限或网络错误 | 看 ErrorMessage，排除故障后重跑 |
| FILE_CHANGED_DURING_HASH | 文件在读取期间变化 | 停止写入或使用快照后重跑 |
| SCAN_ERROR | 目录列举不完整、重解析点等 | 修复后重跑，不能判定通过 |

LastWriteTimeUtc 仅供人工排查，不能独立构成内容损坏结论。NEW_FILE 因没有基准哈希，不额外读取内容计算哈希。

## 11. 运行结果判断

脚本运行结束后回到初始提示符，不再通过 exit 返回退出码（因此双击 BAT 时 %ERRORLEVEL% 恒为 0，自动化不应依赖退出码）。交互模式每轮结束（成功或失败）后都会提示继续；直接回车重新执行，输入 N 退出循环。非交互调用只执行一轮。请根据屏幕输出判断结果：

- 绿色文字「基准清单已保存」「完整性校验通过」= 成功/通过。
- 红色文字「建立基准失败」「完整性校验未通过」「校验任务失败」= 失败/未通过。
- Verify 未通过时还会用黄色提示「不要立即覆盖其他备份副本……」。

正式基准只有在 Create 完整成功（无计算失败、无扫描错误、复查无变化）后才会发布为正式 CSV；失败会保留 .incomplete 中间文件，绝不作为基准。

## 12. Manifest 的长期保存

- 原始 CSV 另存到独立设备并加只读权限或存储快照保护。
- 将该 CSV 自身的 SHA-256 单独保存，以便多年后判断拿到的基准是否被误改。若两者都可被同时修改，此哈希不能保证真实性。
- 为每一批归档记录数据来源、首次检查报告和基准版本。新增文件可以建新批次；不能通过重新生成基准掩盖旧副本异常。
- 查看 CSV 时按文本导入，避免表格软件改写数字、路径或公式样式的文件名。

## 13. 路径、时间与性能边界

- 使用 .NET 精确路径 API，中文、日文、空格、括号、#、&、单引号等按字面处理。CSV 是 UTF-8 BOM。Windows 不兼容的文件名会报错，不静默改名。
- 长路径支持仍受文件系统、NAS 与复制工具限制。遇到问题优先缩短归档根的绝对路径，保持根以下相对结构。脚本不改注册表。
- 脚本不显式设置录音或其他文件的时间戳，但操作系统/NAS 可能因读取自动更新访问时间。若需严格保存访问时间，应验证存储层只读快照方案。
- 默认单线程顺序读取，避免 HDD、USB HDD、NAS 的大量并发随机 I/O。没有自动重试或断点续传。
- 一次完整检查不能替代正确备份、可恢复性演练和基准保护。

## 14. 本次验证

已在 Windows PowerShell 7.6.6、隔离的临时目录中测试：

- 7 个不同名称、属性及扩展名的文件；8 MiB 文件的 SHA-256 与独立结果一致；
- 内置清单、旧报告排除；普通 Verification_*.csv 进入基准；
- 迁移到另一个根后复用清单；历史修改时间变化仍通过；
- MISSING、SIZE_MISMATCH、HASH_MISMATCH、NEW_FILE、READ_ERROR、SCAN_ERROR 等状态分类；
- 报告路径冲突拒绝创建，Create 失败不发布正式基准；
- 1,202 个文件的批量创建/校验、364 字符长路径、16 MiB 流式哈希与独立 SHA-256 对比；
- 非法相对路径、绝对路径、重复条目、无效哈希和无效大小均被拒绝；基准与报告禁止覆盖，验证后原始基准的 SHA-256 和修改时间未变化；
- 双击 BAT 的交互输入、默认命名清单、结果文字暂停窗口；归档根包含脚本目录时管理 HASH 被排除；再次 Create 拒绝覆盖；
- 交互模式连续两轮对两个不同归档执行 Create/Verify（直接回车继续，输入 N 退出），失败后回车也能进入下一轮；非交互调用只执行一轮；
- PowerShell 语法解析无错误。

未在真实 NAS/SMB、数 TB 数据或断电场景中测试。正式运行前先在自己的存储上做小样本演练，并核对数量、排除列表、报告和结果文字。
