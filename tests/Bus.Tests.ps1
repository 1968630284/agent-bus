# 协作总线 · 特征测试（Pester 3.4+，Windows PowerShell 5.1）
# 运行：Invoke-Pester .\tests\Bus.Tests.ps1

$Bus = Join-Path (Split-Path -Parent $PSScriptRoot) 'bus.ps1'
$Root = Join-Path $env:TEMP ('agent_bus_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Utf8 = New-Object Text.UTF8Encoding($false)

# ConvertFrom-Json 会把整个 JSON 数组当成单个对象输出，
# 所以先落变量再用 @() 包一层，单条 / 多条才能都得到真正的数组。
function Get-BoardRaw([string]$root, [int]$limit = 50) {
    return ((& $Bus board -Root $root -Json -Limit $limit) -join "`n")
}

Describe '协作总线 v1' {

    It 'init 生成目录与空板' {
        & $Bus init -Root $Root | Out-Null
        (Test-Path -LiteralPath (Join-Path $Root 'board.jsonl')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $Root 'agents.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $Root 'claims')) | Should Be $true
        (Get-Item -LiteralPath (Join-Path $Root 'board.jsonl')).Length | Should Be 0
    }

    It 'post 返回 posted + 8 位十六进制 id' {
        $out = & $Bus post -Root $Root -From 'A' -To 'all' -Kind task -Text 'hello' -Ref '48'
        ($out -join '') | Should Match '^posted [0-9a-f]{8}$'
    }

    It 'board -Json 字段完整且可解析' {
        $x = ConvertFrom-Json -InputObject (Get-BoardRaw $Root)
        $j = @($x)
        $j.Count | Should Be 1
        $j[0].from | Should Be 'A'
        $j[0].to | Should Be 'all'
        $j[0].kind | Should Be 'task'
        $j[0].text | Should Be 'hello'
        $j[0].ref | Should Be '48'
        $j[0].ts | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        $j[0].id.Length | Should Be 8
    }

    It 'agents.json 自动登记发言者' {
        $j = [IO.File]::ReadAllText((Join-Path $Root 'agents.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        ($j.PSObject.Properties.Name -contains 'A') | Should Be $true
    }

    It '无法解析的坏行被静默跳过' {
        [IO.File]::AppendAllText((Join-Path $Root 'board.jsonl'), "{broken-line`n", $Utf8)
        $x = ConvertFrom-Json -InputObject (Get-BoardRaw $Root)
        $j = @($x)
        $j.Count | Should Be 1
        $j[0].text | Should Be 'hello'
    }

    It 'tail -Since 只返回该 id 之后的新消息' {
        $x = ConvertFrom-Json -InputObject (Get-BoardRaw $Root)
        $first = @($x)[0].id
        & $Bus post -Root $Root -From 'B' -Text 'second' | Out-Null
        $y = ConvertFrom-Json -InputObject ((& $Bus tail -Root $Root -Since $first -Json) -join "`n")
        $j = @($y)
        $j.Count | Should Be 1
        $j[0].text | Should Be 'second'
    }

    It 'tail 的 id 不存在时退回最近 N 条' {
        $y = ConvertFrom-Json -InputObject ((& $Bus tail -Root $Root -Since 'deadbeef' -Json -Limit 5) -join "`n")
        @($y).Count | Should Be 2
    }

    It '4 个并发写入者 × 25 条，不丢不串行' {
        $cc = Join-Path $env:TEMP ('agent_bus_cc_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        & $Bus init -Root $cc | Out-Null
        $jobs = @()
        foreach ($n in 1..4) {
            $jobs += Start-Job -ScriptBlock {
                param($b, $r, $n)
                1..25 | ForEach-Object { & $b post -Root $r -From ("W$n") -Kind status -Text ("m" + $_) | Out-Null }
            } -ArgumentList $Bus, $cc, $n
        }
        $jobs | Wait-Job -Timeout 180 | Out-Null
        $jobs | Receive-Job | Out-Null
        $jobs | Remove-Job -Force

        $lines = @([IO.File]::ReadAllLines((Join-Path $cc 'board.jsonl'), [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
        $lines.Count | Should Be 100
        $bad = @($lines | Where-Object { try { $_ | ConvertFrom-Json | Out-Null; $false } catch { $true } })
        $bad.Count | Should Be 0
        $senders = @($lines | ForEach-Object { ($_ | ConvertFrom-Json).from } | Sort-Object -Unique)
        $senders.Count | Should Be 4
        Remove-Item -LiteralPath $cc -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
