param(
    [Parameter(Position = 0)][string]$Cmd = 'board',
    [Parameter(Position = 1)][string]$Arg1,
    [string]$From = '',
    [string]$To = 'all',
    [string]$Kind = 'note',
    [string]$Text = '',
    [string]$Ref = '',
    [string]$Since = '',
    [string]$Root = '',
    [int]$Limit = 20,
    [int]$Interval = 2,
    [switch]$Json
)

# 协作总线：一个目录就是一块共享白板。
#
# 布局：
#   board.jsonl   留言板，append-only，每行一条完整 JSON
#   agents.json   成员登记（首次出现 / 最后发言）
#   claims\       预留：文件占用声明（当前版本不使用）
#
# 与消费端的约定：
#   * 每行一条完整 JSON，UTF-8 无 BOM，行尾 LF
#   * 只追加，不原地改写；读取端可按字节偏移增量消费
#   * 半行（进程被杀）不参与解析，下次追加自成一行
#   * stdout 只输出结果，便于脚本管道；错误一律抛异常

$ErrorActionPreference = 'Stop'
$BusRoot = if ($Root) { $Root } else { $PSScriptRoot }
if (-not $BusRoot) { $BusRoot = (Get-Location).Path }
$BusRoot = [IO.Path]::GetFullPath($BusRoot)
$Utf8 = New-Object Text.UTF8Encoding($false)

function Initialize-Bus {
    foreach ($d in @($BusRoot, (Join-Path $BusRoot 'claims'))) {
        try { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch { }
    }
    foreach ($f in @('board.jsonl', 'agents.json')) {
        $p = Join-Path $BusRoot $f
        try {
            if (-not (Test-Path -LiteralPath $p)) {
                # CreateNew 保证只有一个进程真正创建；抢输的一方拿到异常，忽略即可
                $fs = New-Object IO.FileStream($p, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                if ($f -eq 'agents.json') {
                    $bytes = $Utf8.GetBytes("{`n}")
                    $fs.Write($bytes, 0, $bytes.Length)
                }
                $fs.Dispose()
            }
        } catch { }
    }
}

function Get-BusFile([string]$name) { return (Join-Path $BusRoot $name) }

# 并发追加：用 FileShare.None 取得独占写权，等价于文件级互斥。
# 抢不到写权的进程短抖动重试；这样既不会丢行，也不会两个进程写在同一偏移上互相覆盖。
function Add-BusLine([string]$file, $obj) {
    Initialize-Bus
    $line = ($obj | ConvertTo-Json -Compress -Depth 5) + "`n"
    $path = Get-BusFile $file
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $fs = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $sw = New-Object IO.StreamWriter($fs, $Utf8)
            $sw.Write($line)
            $sw.Flush()
            $sw.Dispose()
            $fs.Dispose()
            return
        } catch {
            [Threading.Thread]::Sleep(20 + (Get-Random -Maximum 60))
        }
    }
    throw "写总线失败: $path"
}

# 无法解析的行静默跳过：崩溃留下的半行、人工编辑的脏行都不该让整块白板不可用。
function Read-BusLines([string]$file) {
    $path = Get-BusFile $file
    $items = @()
    if (-not (Test-Path -LiteralPath $path)) { return $items }
    foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        if (-not $l.Trim()) { continue }
        try { $items += ($l | ConvertFrom-Json) } catch { }
    }
    return $items
}

function Register-Agent([string]$name, [string]$note) {
    if (-not $name) { return }
    # 成员表是派生数据：并发写冲突时重试，仍失败就放弃，绝不因此丢掉留言。
    try {
        $path = Get-BusFile 'agents.json'
        $map = @{}
        if (Test-Path -LiteralPath $path) {
            try {
                $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { $map[$p.Name] = $p.Value }
            } catch { }
        }
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        if ($map.ContainsKey($name)) {
            $map[$name].last_seen = $now
            if ($note) { $map[$name].note = $note }
        } else {
            $map[$name] = [ordered]@{ first_seen = $now; last_seen = $now; note = $note }
        }
        $text = $map | ConvertTo-Json -Depth 5
        for ($i = 0; $i -lt 12; $i++) {
            try {
                [IO.File]::WriteAllText($path, $text, $Utf8)
                return
            } catch {
                [Threading.Thread]::Sleep(60 + (Get-Random -Maximum 80))
            }
        }
    } catch { }
}

function Format-Message($m) {
    return ('[{0}] {1} → {2} ({3}) {4}' -f $m.ts, $m.from, $m.to, $m.kind, $m.text)
}

function Write-Json($items) {
    $arr = @($items)
    if ($arr.Count -eq 0) { return '[]' }
    # -InputObject 保证单条时仍输出 JSON 数组，而不是被管道拆成标量
    return (ConvertTo-Json -InputObject $arr -Depth 6)
}

# ---------------- 命令 ----------------
switch ($Cmd.ToLower()) {
    'init' {
        Initialize-Bus
        "bus root : $BusRoot"
    }
    'post' {
        Initialize-Bus
        $msg = [ordered]@{
            ts   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            from = $(if ($From) { $From } else { 'unknown' })
            to   = $To
            kind = $Kind
            text = $Text
            ref  = $Ref
            id   = [guid]::NewGuid().ToString('N').Substring(0, 8)
        }
        Register-Agent $From '发布留言'
        Add-BusLine 'board.jsonl' $msg
        Write-Output ('posted ' + $msg.id)
    }
    'board' {
        $items = Read-BusLines 'board.jsonl' | Select-Object -Last $Limit
        if ($Json) { Write-Json $items; break }
        foreach ($m in $items) { Format-Message $m }
    }
    'tail' {
        # 游标消费：Since 为上次看到的消息 id，只返回它之后的新消息。
        # id 找不到（板子被重写 / 传错）时退回最近 Limit 条，避免调用方永远追不上。
        $all = @(Read-BusLines 'board.jsonl')
        $start = -1
        if ($Since) { for ($i = $all.Count - 1; $i -ge 0; $i--) { if ($all[$i].id -eq $Since) { $start = $i; break } } }
        $items = if ($start -ge 0) { @($all | Select-Object -Skip ($start + 1)) } else { @($all | Select-Object -Last $Limit) }
        if ($Json) { Write-Json $items; break }
        foreach ($m in $items) { Format-Message $m }
    }
    'watch' {
        # 常驻轮询：先把最近 5 条作为上下文打出来，之后只输出新增消息。
        # Ctrl+C 退出；断线重开时用 -Since <id> 接着上次的位置。
        $seen = $Since
        if (-not $seen) {
            $recent = @(Read-BusLines 'board.jsonl' | Select-Object -Last 5)
            foreach ($m in $recent) { Format-Message $m }
            if ($recent.Count -gt 0) { $seen = $recent[$recent.Count - 1].id }
        }
        while ($true) {
            $all = @(Read-BusLines 'board.jsonl')
            $new = @()
            if ($seen) {
                $start = -1
                for ($i = $all.Count - 1; $i -ge 0; $i--) { if ($all[$i].id -eq $seen) { $start = $i; break } }
                # 板子被整体重写时找不到游标，退回最近 Limit 条，保证不会永远卡住
                $new = if ($start -ge 0) { @($all | Select-Object -Skip ($start + 1)) } else { @($all | Select-Object -Last $Limit) }
            } else {
                $new = $all
            }
            foreach ($m in $new) { Format-Message $m; $seen = $m.id }
            Start-Sleep -Seconds ([Math]::Max(1, $Interval))
        }
    }
    'agents' {
        $path = Get-BusFile 'agents.json'
        if (-not (Test-Path -LiteralPath $path)) { return }
        if ($Json) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8); break }
        $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            '{0,-16} 首次 {1}  最近 {2}  {3}' -f $p.Name, $p.Value.first_seen, $p.Value.last_seen, $p.Value.note
        }
    }
    'whoami' {
        'bus root : ' + $BusRoot
        'user     : ' + $env:USERNAME
    }
    default {
        @'
用法：bus.ps1 <命令> [参数]

  init                                          初始化目录与空板
  post -From 名字 [-To all] [-Kind note] -Text 内容 [-Ref 引用]
                                                发一条留言，stdout 返回 posted <id>
  board [-Limit 20] [-Json]                     看最近 N 条
  tail  -Since <id> [-Limit 20] [-Json]         只取该 id 之后的新消息（游标消费）
  watch [-Since <id>] [-Interval 2]              常驻轮询，只打新增消息（Ctrl+C 退出）
  agents [-Json]                                成员登记
  whoami                                        当前总线目录与系统用户

可选参数：-Root <目录>  指定总线目录（默认 = 脚本所在目录）

kind 约定：note / status / task / question / decision / result / discuss / verdict
'@
    }
}
