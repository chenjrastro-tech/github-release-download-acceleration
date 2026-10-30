#requires -Version 5.1
<#
  build-runner.ps1 —— 由 SKILL.md 生成「一次性 runner」scripts/ghdl.ps1

  为什么生成而不是手写：SKILL.md 里的 12 个代码块就是这套流程的唯一真源。
  手写第二份实现必然会和正文漂移（历史上已经吃过一次亏），所以 runner 用
  同一批代码块拼出来，改 SKILL.md 后重跑本脚本即可。
  生成时会替换 3 处只有交互式执行才需要的东西：
    1. 第 0 块的示例 URL → 改成 -Url 参数
    2. 第 6 块的 $ForceLadder = $false → 改成 -ForceLadder 开关
    3. 第 7 块的 ~/Downloads → 改成 -OutDir 参数
  其余开关（-ForceClean / -KeepParts / -Parts）由下面的 head 模板直接注入，正文块按变量名读取。

  用法：
    powershell -NoProfile -File scripts\build-runner.ps1            # 生成/覆盖
    powershell -NoProfile -File scripts\build-runner.ps1 -Check     # 只校验是否同步（CI 用）
#>
[CmdletBinding()]
param(
  [string]$SkillMd,
  [string]$OutFile,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

# 5.1 里 param() 默认值求值时 $PSScriptRoot 还是空的，必须在脚本体里算
$here = $MyInvocation.MyCommand.Path
if (-not $here) { $here = $PSCommandPath }
$here = Split-Path -Parent $here
if (-not $SkillMd) { $SkillMd = Join-Path (Split-Path -Parent $here) 'SKILL.md' }
if (-not $OutFile) { $OutFile = Join-Path $here 'ghdl.ps1' }

$md = [IO.File]::ReadAllText($SkillMd)
$rx = [regex]'(?ms)^[ \t]*```powershell[ \t]*\r?\n(?<code>.*?)^[ \t]*```'
$blocks = @($rx.Matches($md) | ForEach-Object { $_.Groups['code'].Value -replace "`r`n", "`n" })
if ($blocks.Count -lt 11) { throw "SKILL.md 只找到 $($blocks.Count) 个 powershell 块，至少要 11 个（0–10 步）" }

# 只取 0–10 步；11 起是 raw/contents 取数片段与维护自检片段，不属于 runner
$flow = $blocks[0..10]

# --- 三处替换（匹配不到就报错，避免 SKILL.md 改结构后静默生成坏文件）
function Replace-Once([string]$text, [string]$pattern, [string]$replacement, [string]$what) {
  $rx2 = [regex]$pattern
  if (-not $rx2.IsMatch($text)) { throw "GENERATE_MISS: 找不到要替换的 $what（SKILL.md 结构变了？）" }
  # 用 MatchEvaluator 而不是字符串替换：替换文本里的 $ 会被 .NET 当成分组引用
  $rx2.Replace($text, { param($m) $replacement }, 1)
}

$flow[0] = Replace-Once $flow[0] '(?m)^[ \t]*\$u[ \t]*=[^\n]*\n' '' '第 0 块的示例 URL 赋值（$u = ...）'
$flow[6] = Replace-Once $flow[6] '(?m)^[ \t]*\$ForceLadder[ \t]*=[ \t]*\$false[ \t]*$' '$ForceLadder = [bool]$ForceLadderSwitch' '第 6 块的 $ForceLadder = $false'
$flow[7] = Replace-Once $flow[7] '(?m)^[ \t]*\$base[ \t]*=.*\$OutDir.*$' '$base = $OutDir' '第 7 块的 $base 输出目录默认值（含 $OutDir 判断）'

$head = @"
<#
  ghdl.ps1 —— GitHub Release 大资产下载（一次性 runner）
  由 scripts/build-runner.ps1 从 SKILL.md 的 0-10 步代码块自动生成，请勿手改：
  想改逻辑就改 SKILL.md，然后重跑  powershell -NoProfile -File scripts\build-runner.ps1

  用法：
    powershell -NoProfile -File scripts\ghdl.ps1 -Url 'https://github.com/owner/repo/releases/download/v1.2.3/a.zip'
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<release 页地址>' -OutDir 'D:\Downloads'
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -ForceLadder     # 强制做单流 vs 多段对照
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -Parts 16          # 手动指定并发段数（诊断/复现用）
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -ForceClean        # 删旧分片/旧输出，强制重下
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -KeepParts         # 校验通过也保留分片（排查用）

  幂等：目标已存在且字节/SHA256 都对 → 直接 ALREADY_DONE 跳过；中断后重跑 → 按 manifest 沿用分段续传。
  退出码：0=成功；1=流程内失败（看输出里的 CODE: 前缀）；2=参数错误
  输出约定：关键结论行以 DOWNLOAD_ / NO_ROUTE / ASSET_ / SKIP_LADDER / route= / parts= 开头，便于 agent 解析。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = `$true, Position = 0)][string]`$Url,
  [string]`$OutDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
  [switch]`$ForceLadder,
  [switch]`$ForceClean,
  [switch]`$KeepParts,
  [int]`$Parts = 0
)

`$ErrorActionPreference = 'Stop'
`$u = `$Url
`$ForceLadderSwitch = `$ForceLadder.IsPresent

"@

$tail = @"

# ---- 退出码：给调用方（agent / CI）判断成败用，不要靠读文字猜
# 第 10 步算出的 `$verifiedOk：digest 或字节数校验通过才是真
if (`$verifiedOk) { exit 0 } else { exit 1 }
"@

$body = ($flow -join "`n")
$text = ($head -replace "`r`n", "`n") + $body.TrimEnd() + "`n" + ($tail -replace "`r`n", "`n")
$text = $text -replace "`n", "`r`n"

if ($Check) {
  if (-not (Test-Path $OutFile)) { "GENERATE_STALE: $OutFile 不存在"; exit 1 }
  $cur = [IO.File]::ReadAllText($OutFile)
  if ($cur -ne $text) { "GENERATE_STALE: $OutFile 与 SKILL.md 不同步，重跑 build-runner.ps1"; exit 1 }
  'GENERATE_OK: runner 与 SKILL.md 同步'
  exit 0
}

# PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码，必须写 BOM
[IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($true)))
$lines = ($text -split "`r`n").Count
"GENERATED: $OutFile ($([IO.File]::ReadAllText($OutFile).Length) bytes, $lines lines, 12 blocks)"
