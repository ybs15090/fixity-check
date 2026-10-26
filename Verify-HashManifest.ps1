#requires -Version 7.0
<#
.SYNOPSIS
只读校验通用文件归档的 SHA-256 基准，生成独立 CSV 报告。
.EXAMPLE
.\Verify-HashManifest.ps1 -Path '\\NAS\Archive\Data' -Manifest 'D:\Archive\HASH\SHA256_Archive_2026.csv'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Path,
    [ValidateNotNullOrEmpty()][string]$Manifest,
    [ValidateNotNullOrEmpty()][string]$Report,
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

function Read-ValidatedManifest {
    param([IO.Stream]$Stream)
    $parser = $null
    try {
        # 严格解析带引号的 CSV；列数、哈希、大小及相对路径不合法时整份拒绝。
        $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new(
            $Stream, [Text.UTF8Encoding]::new($false, $true), $true, $true)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        if ($parser.EndOfData) { throw 'Manifest 为空。' }
        $header = $parser.ReadFields()
        $columns = [Collections.Generic.Dictionary[string, int]]::new($script:Comparer)
        for ($columnIndex = 0; $columnIndex -lt $header.Length; $columnIndex++) {
            $name = $header[$columnIndex]
            if ([string]::IsNullOrWhiteSpace($name) -or $columns.ContainsKey($name)) {
                throw "Manifest 存在空列名或重复列名：$name"
            }
            $columns.Add($name, $columnIndex)
        }
        foreach ($required in 'RelativePath', 'Size', 'SHA256') {
            if (-not $columns.ContainsKey($required)) { throw "Manifest 缺少必需列：$required" }
        }
        $entries = [Collections.Generic.Dictionary[string, object]]::new($script:Comparer)
        while (-not $parser.EndOfData) {
            $lineNumber = $parser.LineNumber
            $fields = $parser.ReadFields()
            if ($fields.Length -ne $header.Length) { throw "Manifest 第 $lineNumber 行列数不匹配。" }
            $relative = Get-SafeRelativePath $fields[$columns['RelativePath']]
            $sizeText = $fields[$columns['Size']]
            [long]$size = 0
            if ($sizeText -notmatch '^(0|[1-9][0-9]*)$' -or
                -not [long]::TryParse($sizeText, [Globalization.NumberStyles]::None,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$size)) {
                throw "Manifest 第 $lineNumber 行 Size 无效：$sizeText"
            }
            $hash = $fields[$columns['SHA256']]
            if ($hash -notmatch '^[0-9a-fA-F]{64}$') { throw "Manifest 第 $lineNumber 行 SHA256 无效。" }
            if ($entries.ContainsKey($relative)) { throw "Manifest 相对路径重复或大小写冲突：$relative" }
            $expectedTime = if ($columns.ContainsKey('LastWriteTimeUtc')) {
                $fields[$columns['LastWriteTimeUtc']]
            }
            else { '' }
            $entries.Add($relative, [pscustomobject]@{
                Size = $size
                SHA256 = $hash.ToUpperInvariant()
                LastWriteTimeUtc = $expectedTime
            })
        }
        if ($entries.Count -eq 0) { throw 'Manifest 没有文件记录，拒绝空清单通过校验。' }
        # 使用包装对象，避免 PowerShell 自动枚举集合返回值。
        return [pscustomobject]@{ Entries = $entries }
    }
    finally {
        if ($parser) { $parser.Dispose() }
    }
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$manifestStream = $null
$outputStream = $null
$writer = $null
$stagingPath = $null
$published = $false
try {
    if (-not $IsWindows) { throw '本脚本面向 Windows + PowerShell 7。' }
    if ($Interactive) {
        Write-Host 'Path：当前要检查的归档副本根目录。'
        Write-Host 'Manifest：首次归档时建立的 SHA-256 基准 CSV；仅只读使用。'
        Write-Host 'Report：本次新报告的 CSV 完整路径；留空时自动生成。'
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
    if ($Interactive -and [string]::IsNullOrWhiteSpace($Report)) {
        $answer = Read-Host '请输入 Report（直接回车自动生成）'
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $Report = $answer }
    }
    Write-Host "Manifest：$manifestPath"
    if ($script:Comparer.Equals($root, $PSScriptRoot)) {
        Write-Warning 'Path 是脚本目录：脚本、BAT、说明文件及其他普通文件也会被检查；HASH 管理目录除外。'
    }
    if ([IO.Path]::GetExtension($manifestPath) -ine '.csv') {
        throw '只接受正式 .csv 清单，不接受 .incomplete 文件。'
    }
    Assert-NoReparsePoint $manifestPath
    # 整个验证过程保持清单只读打开；不赋予写入权限，不调用任何更新清单的接口。
    $manifestStream = [IO.FileStream]::new($manifestPath, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $baseline = (Read-ValidatedManifest $manifestStream).Entries
    if (Test-IsInsideArchive $manifestPath $root) {
        $manifestRelative = [IO.Path]::GetRelativePath($root, $manifestPath)
        if ($baseline.ContainsKey($manifestRelative)) {
            throw 'Manifest 把自身列为归档文件，拒绝循环校验。'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Report)) {
        $reportPath = Get-FullFileSystemPath $Report
    }
    else {
        $name = 'Verification_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $reportPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($manifestPath), $name)
    }
    if ($script:Comparer.Equals($reportPath, $manifestPath)) { throw '报告路径不能与原始 Manifest 相同。' }
    if (Test-IsInsideArchive $reportPath $root) {
        $reportRelative = [IO.Path]::GetRelativePath($root, $reportPath)
        if ($baseline.ContainsKey($reportRelative)) {
            throw "报告路径与基准文件条目冲突：$reportRelative"
        }
    }
    Assert-NewOutput $reportPath $root
    Write-Host "归档根目录：$root"
    Write-Host "只读基准清单：$manifestPath"
    Write-Host '请保持归档静止；大小不符的文件也将完整计算 SHA-256。'
    $inventory = Get-ArchiveInventory $root $manifestPath $null

    $stagingPath = $reportPath + '.' + [guid]::NewGuid().ToString('N') + '.incomplete'
    $outputStream = [IO.FileStream]::new($stagingPath, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($outputStream, [Text.UTF8Encoding]::new($true), 65536, $true)
    Write-CsvRecord $writer @('RelativePath', 'Status', 'ExpectedSize', 'ActualSize',
        'ExpectedSHA256', 'ActualSHA256', 'ExpectedLastWriteTimeUtc',
        'ActualLastWriteTimeUtc', 'ErrorMessage', 'ReportMarker')
    $counts = [ordered]@{
        OK = 0; MISSING = 0; SIZE_MISMATCH = 0; HASH_MISMATCH = 0
        NEW_FILE = 0; READ_ERROR = 0; FILE_CHANGED_DURING_HASH = 0; SCAN_ERROR = 0
    }
    [int]$processed = 0
    [long]$verifiedBytes = 0
    foreach ($relative in ($baseline.Keys | Sort-Object)) {
        $processed++
        $expected = $baseline[$relative]
        $fullPath = [IO.Path]::Combine($root, $relative)
        $actualSize = $null
        $actualHash = ''
        $writeTime = ''
        $message = ''
        $status = ''
        Write-Progress -Id 1 -Activity '验证 SHA-256 基准' -Status "$processed / $($baseline.Count)；$relative" -PercentComplete (100.0 * $processed / $baseline.Count)
        try {
            Assert-NoReparsePoint $fullPath
            if ([IO.File]::GetAttributes($fullPath) -band [IO.FileAttributes]::Directory) {
                throw '基准文件所在位置现在是目录。'
            }
            $actualSize = [IO.FileInfo]::new($fullPath).Length
            $result = Get-StreamingSHA256 $fullPath $relative
            $actualSize = $result.Size
            $actualHash = $result.SHA256
            $writeTime = $result.LastWriteTimeUtc
            $verifiedBytes += $result.Size
            # 大小不符优先标记 SIZE_MISMATCH，但保留实际 SHA-256 供跨副本比对。
            if ($actualSize -ne $expected.Size) {
                $status = 'SIZE_MISMATCH'
            }
            elseif ($actualHash -ne $expected.SHA256) {
                $status = 'HASH_MISMATCH'
            }
            else {
                $status = 'OK'
            }
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause.Message.StartsWith('FILE_CHANGED_DURING_HASH:', [StringComparison]::Ordinal)) {
                $status = 'FILE_CHANGED_DURING_HASH'
            }
            elseif ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) {
                $status = 'MISSING'
            }
            else {
                $status = 'READ_ERROR'
            }
            $message = $cause.Message
        }
        $counts[$status]++
        Write-CsvRecord $writer @($relative, $status, $expected.Size, $actualSize,
            $expected.SHA256, $actualHash, $expected.LastWriteTimeUtc,
            $writeTime, $message, $script:ReportMarker)
        if ($status -ne 'OK') { Write-Warning "[$status] $relative $message" }
    }
    Write-Progress -Id 1 -Activity '验证 SHA-256 基准' -Completed

    # NEW_FILE 没有基准可供比较，记录大小和时间，不额外读取内容计算哈希。
    foreach ($relative in ($inventory.Files.Keys | Sort-Object)) {
        if (-not $baseline.ContainsKey($relative)) {
            $item = $inventory.Files[$relative]
            $counts['NEW_FILE']++
            Write-CsvRecord $writer @($relative, 'NEW_FILE', $null, $item.Size, '', '',
                '', $item.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture),
                '', $script:ReportMarker)
            Write-Warning "[NEW_FILE] $relative"
        }
    }
    foreach ($issue in $inventory.Issues) {
        $counts['SCAN_ERROR']++
        Write-CsvRecord $writer @($issue.RelativePath, 'SCAN_ERROR', $null, $null, '', '',
            '', '', $issue.ErrorMessage, $script:ReportMarker)
    }

    $writer.Flush()
    $outputStream.Flush($true)
    $writer.Dispose()
    $writer = $null
    $outputStream.Dispose()
    $outputStream = $null
    Assert-NewOutput $reportPath $root
    [IO.File]::Move($stagingPath, $reportPath, $false)
    $published = $true
    $watch.Stop()
    $abnormalFiles = $baseline.Count - $counts['OK'] + $counts['NEW_FILE']
    $readErrors = $counts['READ_ERROR'] + $counts['FILE_CHANGED_DURING_HASH'] + $counts['SCAN_ERROR']
    $totalFiles = $baseline.Count + $counts['NEW_FILE']
    Write-Host ''
    Write-Host "总文件数（基准 + 新文件）：$totalFiles；基准文件：$($baseline.Count)；当前实际普通文件：$($inventory.Files.Count)"
    foreach ($statusName in $counts.Keys) { Write-Host ("{0}: {1}" -f $statusName, $counts[$statusName]) }
    Write-Host "读取/计算/扫描错误：$readErrors（SCAN_ERROR 是扫描错误事件，可能与文件错误重叠）"
    Write-Host "已校验数据总量：$verifiedBytes 字节（$([Math]::Round($verifiedBytes / 1GB, 3)) GiB）"
    Write-Host "排除的清单/报告：$($inventory.Skipped.Count)"
    Write-Host "校验耗时：$($watch.Elapsed)"
    Write-Host "报告保存位置：$reportPath"
    if ($abnormalFiles -eq 0 -and $readErrors -eq 0) {
        Write-Host '完整性校验通过：所有基准文件 SHA-256 均一致，且未发现缺失文件或异常文件。' -ForegroundColor Green
        exit 0
    }
    Write-Host '完整性校验未通过。' -ForegroundColor Red
    Write-Host "异常文件 $abnormalFiles 个，另有扫描错误事件 $($counts['SCAN_ERROR']) 个。" -ForegroundColor Red
    if ($counts['SCAN_ERROR'] -gt 0) { Write-Host '扫描不完整，异常文件总数可能更多。' }
    Write-Host '不要立即覆盖其他备份副本，应先使用其他独立副本进行交叉验证。' -ForegroundColor Yellow
    if ($readErrors -gt 0) { exit 2 }
    exit 1
}
catch {
    Write-Host "校验任务失败：$($_.Exception.GetBaseException().Message)" -ForegroundColor Red
    Write-Host '不要立即覆盖其他备份副本，应先使用其他独立副本进行交叉验证。' -ForegroundColor Yellow
    if ($stagingPath -and -not $published) {
        Write-Host "如已生成中间报告，将保留在：$stagingPath"
        Write-Host '该文件为未完成报告，不代表完整校验结果。'
    }
    exit 2
}
finally {
    if ($writer) { $writer.Dispose() }
    if ($outputStream) { $outputStream.Dispose() }
    if ($manifestStream) { $manifestStream.Dispose() }
    Write-Progress -Id 1 -Activity '验证 SHA-256 基准' -Completed
}
