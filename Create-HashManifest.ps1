#requires -Version 7.0
<#
.SYNOPSIS
为静止的通用文件归档建立 SHA-256 基准 CSV；不覆盖任何已有清单。
.EXAMPLE
.\Create-HashManifest.ps1 -Path 'D:\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Path,
    [ValidateNotNullOrEmpty()][string]$Manifest,
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Buffer = [byte[]]::new(1MB)
$script:Comparer = [StringComparer]::OrdinalIgnoreCase
$script:ManagedHashDirectory = [IO.Path]::Combine($PSScriptRoot, 'HASH')
$script:ReportMarker = 'PS7-SHA256-Verification-Report-v1'
$script:ReportHeader = '"RelativePath","Status","ExpectedSize","ActualSize","ExpectedSHA256","ActualSHA256","ExpectedLastWriteTimeUtc","ActualLastWriteTimeUtc","ErrorMessage","ReportMarker"'

function Get-FullFileSystemPath {
    param([string]$Value)
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Value, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "只接受文件系统路径：$Value" }
    $full = [IO.Path]::GetFullPath($resolved)
    if ($full.StartsWith('\\?\') -or $full.StartsWith('\\.\')) {
        throw '请使用普通盘符路径或 UNC 路径，不使用设备路径前缀。'
    }
    return $full
}

function Assert-NoReparsePoint {
    param([string]$FullPath)
    # 不跟随符号链接、Junction 或其他重解析点，避免越过归档边界。
    $current = $FullPath
    while ($current) {
        $attributes = [IO.File]::GetAttributes($current)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "不支持重解析点，请使用真实目录或已落地的普通文件：$current"
        }
        $current = [IO.Path]::GetDirectoryName([IO.Path]::TrimEndingDirectorySeparator($current))
    }
}

function Get-ArchiveRoot {
    param([string]$Value)
    $full = Get-FullFileSystemPath $Value
    Assert-NoReparsePoint $full
    if (-not ([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::Directory)) {
        throw "归档根路径不是目录：$full"
    }
    return [IO.Path]::TrimEndingDirectorySeparator($full)
}

function Get-DefaultManifestPath {
    param([string]$Root)
    $archiveName = [IO.Path]::GetFileName($Root)
    if ([string]::IsNullOrWhiteSpace($archiveName)) { $archiveName = 'Archive' }
    $archiveName = [regex]::Replace($archiveName, '[<>:"/\\|?*\x00-\x1F]', '_')
    $archiveName = $archiveName.TrimEnd([char[]]@(' ', '.'))
    if ([string]::IsNullOrWhiteSpace($archiveName)) { $archiveName = 'Archive' }
    if ($archiveName.Length -gt 180) { $archiveName = $archiveName.Substring(0, 180) }
    return [IO.Path]::Combine($script:ManagedHashDirectory, "SHA256_$archiveName.csv")
}

function Assert-ArchiveRootOutsideManagement {
    param([string]$Root)
    $prefix = $script:ManagedHashDirectory + '\'
    if ($script:Comparer.Equals($Root, $script:ManagedHashDirectory) -or
        $Root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "归档根不能位于脚本的 HASH 管理目录内：$Root"
    }
}

function Test-IsInsideArchive {
    param([string]$FullPath, [string]$Root)
    $prefix = $Root
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return ($FullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
}

function Assert-NewOutput {
    param([string]$FullPath, [string]$Root)
    if ($script:Comparer.Equals($FullPath, $Root)) { throw '输出路径不能是归档根目录。' }
    if ([IO.Path]::GetExtension($FullPath) -ine '.csv') { throw '输出文件必须使用 .csv 扩展名。' }
    $parent = [IO.Path]::GetDirectoryName($FullPath)
    Assert-NoReparsePoint $parent
    if (-not ([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::Directory)) {
        throw "输出父路径不是目录：$parent"
    }
    # 预检查只用于给出明确提示；最终发布仍使用禁止覆盖的 Move。
    try {
        $null = [IO.File]::GetAttributes($FullPath)
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [IO.FileNotFoundException]) { return }
        throw
    }
    throw "拒绝覆盖：目标已经存在，请保留旧文件并指定新的文件名：$FullPath"
}

function Test-GeneratedReport {
    param([string]$FullPath)
    if ([IO.Path]::GetExtension($FullPath) -ine '.csv') { return $false }
    $stream = $null
    $reader = $null
    try {
        # 只识别本工具带专用标识的报告，不按 .csv 扩展名一概排除。
        $stream = [IO.FileStream]::new($FullPath, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        if ($reader.ReadLine() -cne $script:ReportHeader) { return $false }
        $firstRecord = $reader.ReadLine()
        return ($null -ne $firstRecord -and
            $firstRecord.EndsWith(',"' + $script:ReportMarker + '"', [StringComparison]::Ordinal))
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-SafeRelativePath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value)) {
        throw "清单包含空路径或绝对路径：$Value"
    }
    $normalized = $Value.Replace('/', '\')
    foreach ($component in $normalized.Split('\')) {
        if ($component -eq '' -or $component -in '.', '..' -or
            $component.EndsWith('.') -or $component.EndsWith(' ') -or
            $component.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') {
            throw "不安全或不兼容 Windows 的相对路径：$Value"
        }
    }
    return $normalized
}

function Get-ArchiveInventory {
    param([string]$Root, [string]$ManifestPath, [string]$StagingPath)
    $files = [Collections.Generic.Dictionary[string, object]]::new($script:Comparer)
    $issues = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = 0
    $options.IgnoreInaccessible = $false
    $options.RecurseSubdirectories = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    [long]$totalBytes = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            Assert-NoReparsePoint $directory
            foreach ($entry in [IO.DirectoryInfo]::new($directory).EnumerateFileSystemInfos('*', $options)) {
                $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName)
                try {
                    $relative = Get-SafeRelativePath $relative
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw "发现重解析点，不跟随：$($entry.FullName)"
                    }
                    if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
                        # HASH 是本套脚本的保留管理目录；若归档根包含脚本目录，整体排除。
                        if ($script:Comparer.Equals($entry.FullName, $script:ManagedHashDirectory)) {
                            Write-Host "排除管理目录：$relative"
                            continue
                        }
                        $pending.Push($entry.FullName)
                    }
                    else {
                        $skipReason = ''
                        if ($script:Comparer.Equals($entry.FullName, $ManifestPath)) {
                            $skipReason = '本次基准清单'
                        }
                        elseif ($StagingPath -and $script:Comparer.Equals($entry.FullName, $StagingPath)) {
                            $skipReason = '本次未完成输出'
                        }
                        elseif (Test-GeneratedReport $entry.FullName) {
                            $skipReason = '本工具生成的验证报告'
                        }
                        if ($skipReason) {
                            $skipped.Add([pscustomobject]@{
                                RelativePath = $relative
                                Reason = $skipReason
                            })
                            Write-Host "排除管理文件 [$skipReason]：$relative"
                            continue
                        }
                        if ($files.ContainsKey($relative)) { throw "路径存在大小写冲突：$relative" }
                        $size = $entry.Length
                        $files.Add($relative, [pscustomobject]@{
                            FullPath = $entry.FullName
                            Size = $size
                            LastWriteTimeUtc = $entry.LastWriteTimeUtc
                        })
                        $totalBytes += $size
                    }
                }
                catch {
                    $message = $_.Exception.GetBaseException().Message
                    $issues.Add([pscustomobject]@{ RelativePath = $relative; ErrorMessage = $message })
                    Write-Warning "扫描错误 [$relative]：$message"
                }
                if ($timer.ElapsedMilliseconds -ge 250) {
                    Write-Progress -Id 1 -Activity '扫描归档目录（包含隐藏文件）' -Status "已发现 $($files.Count) 个文件；$relative"
                    $timer.Restart()
                }
            }
        }
        catch {
            $relative = [IO.Path]::GetRelativePath($Root, $directory)
            $message = $_.Exception.GetBaseException().Message
            $issues.Add([pscustomobject]@{ RelativePath = $relative; ErrorMessage = $message })
            Write-Warning "目录扫描错误 [$relative]：$message"
        }
    }
    Write-Progress -Id 1 -Activity '扫描归档目录' -Completed
    return [pscustomobject]@{
        Files = $files
        Issues = $issues
        Skipped = $skipped
        TotalBytes = $totalBytes
    }
}

function Get-StreamingSHA256 {
    param([string]$FullPath, [string]$RelativePath)
    $stream = $null
    $hasher = $null
    try {
        Assert-NoReparsePoint $FullPath
        # 只读打开；在支持 Windows 共享语义的文件系统上，读期间拒绝写入/删除。
        $stream = [IO.FileStream]::new($FullPath, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
        $size = $stream.Length
        $before = [IO.FileInfo]::new($FullPath)
        $writeTime = $before.LastWriteTimeUtc
        $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
            [Security.Cryptography.HashAlgorithmName]::SHA256)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        [long]$readBytes = 0
        while (($readCount = $stream.Read($script:Buffer, 0, $script:Buffer.Length)) -gt 0) {
            $hasher.AppendData($script:Buffer, 0, $readCount)
            $readBytes += $readCount
            if ($timer.ElapsedMilliseconds -ge 250) {
                $percent = if ($size -eq 0) { 100 } else { [Math]::Min(100, 100.0 * $readBytes / $size) }
                Write-Progress -Id 2 -ParentId 1 -Activity 'SHA-256 流式读取' -Status $RelativePath -PercentComplete $percent
                $timer.Restart()
            }
        }
        $after = [IO.FileInfo]::new($FullPath)
        # 这里只比较同一次读取前后是否变化，不把历史时间戳作为内容判断依据。
        if (-not $after.Exists -or $readBytes -ne $size -or $stream.Length -ne $size -or
            $after.Length -ne $size -or $after.LastWriteTimeUtc -ne $writeTime) {
            throw [IO.IOException]::new("FILE_CHANGED_DURING_HASH: $RelativePath")
        }
        $hash = [BitConverter]::ToString($hasher.GetHashAndReset()).Replace('-', '')
        return [pscustomobject]@{
            Size = $size
            SHA256 = $hash
            LastWriteTimeUtc = $writeTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    finally {
        if ($hasher) { $hasher.Dispose() }
        if ($stream) { $stream.Dispose() }
        Write-Progress -Id 2 -Activity 'SHA-256 流式读取' -Completed
    }
}

function Write-CsvRecord {
    param([IO.StreamWriter]$Writer, [AllowEmptyCollection()][object[]]$Values)
    # 所有字段加引号，并转义字段内双引号，支持中文、逗号和括号等字符。
    $escaped = foreach ($value in $Values) {
        '"' + ([string]$value).Replace('"', '""') + '"'
    }
    $Writer.WriteLine($escaped -join ',')
}

$writer = $null
$outputStream = $null
$stagingPath = $null
$published = $false
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $IsWindows) { throw '本脚本面向 Windows + PowerShell 7。' }
    if ($Interactive) {
        Write-Host 'Path：要建立基准的归档根目录；递归扫描其中所有普通文件。'
        Write-Host 'Manifest：新建的 SHA-256 基准 CSV 完整路径；已存在时拒绝覆盖。'
        Write-Host '路径不要加引号'
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Path = Read-Host '请输入 Path'
        }
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '缺少 Path：请指定归档根目录。' }
    $root = Get-ArchiveRoot $Path
    Assert-ArchiveRootOutsideManagement $root
    $defaultManifest = Get-DefaultManifestPath $root
    if ([string]::IsNullOrWhiteSpace($Manifest)) {
        if ($Interactive) {
            $answer = Read-Host "请输入 Manifest（直接回车使用 $defaultManifest）"
            $Manifest = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultManifest } else { $answer }
        }
        else {
            $Manifest = $defaultManifest
        }
    }
    $manifestPath = Get-FullFileSystemPath $Manifest
    $manifestParent = [IO.Path]::GetDirectoryName($manifestPath)
    if ($script:Comparer.Equals($manifestParent, $script:ManagedHashDirectory) -and
        -not [IO.Directory]::Exists($script:ManagedHashDirectory)) {
        $null = [IO.Directory]::CreateDirectory($script:ManagedHashDirectory)
    }
    Assert-NewOutput $manifestPath $root
    Write-Host "Manifest：$manifestPath"
    if ($script:Comparer.Equals($root, $PSScriptRoot)) {
        Write-Warning 'Path 是脚本目录：脚本、BAT、说明文件及其他普通文件也会进入基准；HASH 管理目录除外。'
    }
    Write-Host "归档根目录：$root"
    Write-Host '请保持归档静止，暂停文件写入、同步和重命名。'
    $inventory = Get-ArchiveInventory $root $manifestPath $null
    $fileCount = $inventory.Files.Count
    if ($fileCount -eq 0 -and $inventory.Issues.Count -eq 0) {
        throw '归档目录为空，拒绝建立空基准，请检查路径。'
    }

    # 中间文件与最终清单位于同一目录；失败时保留 .incomplete，绝不作为正式基准。
    $stagingPath = $manifestPath + '.' + [guid]::NewGuid().ToString('N') + '.incomplete'
    $outputStream = [IO.FileStream]::new($stagingPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($outputStream, [Text.UTF8Encoding]::new($true), 65536, $true)
    Write-CsvRecord $writer @('RelativePath', 'Size', 'SHA256', 'LastWriteTimeUtc')
    [int]$successCount = 0
    [int]$failureCount = 0
    [int]$processed = 0
    foreach ($relative in ($inventory.Files.Keys | Sort-Object)) {
        $processed++
        Write-Progress -Id 1 -Activity '建立 SHA-256 基准' -Status "$processed / $fileCount；$relative" -PercentComplete (100.0 * $processed / $fileCount)
        try {
            $item = $inventory.Files[$relative]
            $result = Get-StreamingSHA256 $item.FullPath $relative
            if ($result.Size -ne $item.Size -or
                $result.LastWriteTimeUtc -ne $item.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)) {
                throw "文件在扫描后发生变化：$relative"
            }
        }
        catch {
            $failureCount++
            Write-Warning "计算失败 [$relative]：$($_.Exception.GetBaseException().Message)"
            continue
        }
        # 输出失败是整个任务失败，不作为单个归档文件的读取错误处理。
        Write-CsvRecord $writer @($relative, $result.Size, $result.SHA256, $result.LastWriteTimeUtc)
        $successCount++
    }
    Write-Progress -Id 1 -Activity '建立 SHA-256 基准' -Completed

    # 再扫描一次，检测运行期间增加、移除或修改的文件。
    Write-Host '复查目录是否在运行期间变化……'
    $afterScan = Get-ArchiveInventory $root $manifestPath $stagingPath
    [int]$changeCount = 0
    foreach ($relative in $inventory.Files.Keys) {
        $oldItem = $inventory.Files[$relative]
        if (-not $afterScan.Files.ContainsKey($relative) -or
            $afterScan.Files[$relative].Size -ne $oldItem.Size -or
            $afterScan.Files[$relative].LastWriteTimeUtc -ne $oldItem.LastWriteTimeUtc) {
            $changeCount++
            Write-Warning "目录复查发现变化或无法访问：$relative"
        }
    }
    foreach ($relative in $afterScan.Files.Keys) {
        if (-not $inventory.Files.ContainsKey($relative)) {
            $changeCount++
            Write-Warning "目录复查发现新增文件：$relative"
        }
    }
    $scanErrors = $inventory.Issues.Count + $afterScan.Issues.Count
    Write-Host ("文件总数（已扫描）：{0}；数据总大小：{1} 字节（{2:N3} GiB）" -f $fileCount, $inventory.TotalBytes, ($inventory.TotalBytes / 1GB))
    Write-Host "成功计算：$successCount；计算失败：$failureCount；扫描错误事件：$scanErrors；复查变化：$changeCount"
    Write-Host "排除的清单/报告：$($inventory.Skipped.Count)；总耗时：$($watch.Elapsed)"
    $writer.Flush()
    $outputStream.Flush($true)
    $writer.Dispose()
    $writer = $null
    $outputStream.Dispose()
    $outputStream = $null
    if ($failureCount -gt 0 -or $scanErrors -gt 0 -or $changeCount -gt 0) {
        throw '存在失败、扫描不完整或运行期间变化，未发布正式 Manifest。扫描不完整时文件总数/大小仅代表已发现部分。'
    }
    Assert-NewOutput $manifestPath $root
    [IO.File]::Move($stagingPath, $manifestPath, $false)
    $published = $true
    Write-Host "基准清单已保存：$manifestPath" -ForegroundColor Green
    Write-Host "总耗时：$($watch.Elapsed)"
    Write-Host '请立即独立校验，并将这份基准清单备份到不同设备。'
    exit 0
}
catch {
    Write-Host "建立基准失败：$($_.Exception.GetBaseException().Message)" -ForegroundColor Red
    if ($stagingPath -and -not $published) {
        Write-Host "如已生成中间文件，将保留在：$stagingPath"
        Write-Host '该 .incomplete 文件不可用于验证，也不要手动改名为正式清单。'
    }
    exit 2
}
finally {
    if ($writer) { $writer.Dispose() }
    if ($outputStream) { $outputStream.Dispose() }
    Write-Progress -Id 1 -Activity '建立 SHA-256 基准' -Completed
}
