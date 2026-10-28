#requires -Version 5.1
<#
  github-release-download-acceleration 技能自检脚本（Windows PowerShell 5.1 可跑）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate.ps1 -SkillRoot <技能目录>

  校验内容：
    1. 必需文件：SKILL.md / README.md / agents/openai.yaml
    2. SKILL.md frontmatter：首尾 ---、必填 name+description、name 与目录名一致且为 kebab-case、
       未知字段告警、description 长度合理
    2b. frontmatter.metadata 里的两个门槛（min_size_for_ladder_mb / single_conn_fast_kbps）
       必须与正文代码里的 $ladderMinMB / $fastKB 一致
    3. 正文结构：Steps / Pitfalls / Verification 三节齐备
    4. 所有 ```powershell 代码块能被 PowerShell 解析器无错解析
    5. 5.1 兼容性红线：-Parallel / -ThrottleLimit / 含空格的 -w 参数
    6. agents/openai.yaml：interface 三要素齐备、default_prompt 用 $技能名 引用自己、字符串加引号

  退出码：0 = 全部通过（允许 WARN），1 = 有 FAIL
#>
[CmdletBinding()]
param(
  [string]$SkillRoot
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 在 param() 默认值求值时 $PSScriptRoot 还是空的，只能放到脚本体里兜底。
if (-not $SkillRoot) {
  $here = $PSScriptRoot
  if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $SkillRoot = Split-Path -Parent $here
}
$script:fail = 0
$script:warn = 0

function Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Bad([string]$m)  { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow; $script:warn++ }

function Read-Utf8([string]$path) {
  return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

Write-Host "skill root = $SkillRoot"
Write-Host ("-" * 72)

# ---------- 1. 必需文件 ----------
$skillPath = Join-Path $SkillRoot 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillPath)) {
  Bad "缺少 SKILL.md，无法继续"
  exit 1
}
$skillText = Read-Utf8 $skillPath
Ok ("SKILL.md 存在（{0} 字节，{1} 行）" -f (Get-Item $skillPath).Length, (($skillText -split "`n").Count))

foreach ($rel in @('README.md', 'agents\openai.yaml')) {
  if (Test-Path -LiteralPath (Join-Path $SkillRoot $rel)) { Ok "$rel 存在" }
  else { Bad "缺少 $rel" }
}

# ---------- 2. frontmatter ----------
$lines = $skillText -split "`r?`n"
if ($lines[0].Trim() -ne '---') {
  Bad "SKILL.md 第 1 行必须是 ---"
}
else {
  $end = 1
  while ($end -lt $lines.Count -and $lines[$end].Trim() -ne '---') { $end++ }
  if ($end -ge $lines.Count) {
    Bad "frontmatter 没有闭合的 ---"
  }
  else {
    $allowed = @('name', 'description', 'whenToUse', 'metadata', 'disable-model-invocation', 'user-invocable')
    $fm = @{}
    $meta = @{}
    for ($i = 1; $i -lt $end; $i++) {
      $line = $lines[$i]
      if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
      if ($line -match '^(?<k>[A-Za-z][A-Za-z0-9_-]*):\s*(?<v>.*)$') {
        $fm[$Matches['k']] = $Matches['v'].Trim()
      }
      elseif ($line -match '^\s+(?<k>[A-Za-z][A-Za-z0-9_-]*):\s*(?<v>.+)$') {
        # metadata 下的缩进子键（min_size_for_ladder_mb 之类），不是未知字段
        $meta[$Matches['k']] = $Matches['v'].Trim().Trim('"').Trim("'")
      }
      else {
        Warn ("frontmatter 第 {0} 行无法解析为 key: value —— {1}" -f ($i + 1), $line.Trim())
      }
    }
    if ($fm.ContainsKey('name') -and $fm['name']) { Ok "frontmatter.name = $($fm['name'])" } else { Bad "frontmatter 缺少必填字段 name" }
    if ($fm.ContainsKey('description') -and $fm['description']) {
      $dLen = $fm['description'].Length
      if ($dLen -lt 40) { Warn "description 偏短（$dLen 字符），路由效果可能不好" }
      elseif ($dLen -gt 1024) { Bad "description 过长（$dLen 字符 > 1024），宿主可能拒收" }
      else { Ok "frontmatter.description 长度 $dLen 字符" }
    }
    else { Bad "frontmatter 缺少必填字段 description" }

    $leaf = Split-Path -Leaf ($SkillRoot.TrimEnd('\'))
    if ($fm.ContainsKey('name') -and $fm['name']) {
      if ($fm['name'] -eq $leaf) { Ok "name 与目录名一致（$leaf）" }
      else { Bad "name=$($fm['name']) 与目录名 $leaf 不一致，技能可能加载不到" }
      if ($fm['name'] -match '^[a-z0-9]+(-[a-z0-9]+)*$') { Ok "name 是合法 kebab-case" }
      else { Bad "name 不是 kebab-case：$($fm['name'])" }
    }
    foreach ($k in $fm.Keys) {
      if ($k -notin $allowed) { Warn "frontmatter 有本宿主不认识的字段：$k（DSH 只认 $($allowed -join ', ')）" }
    }
    if ($fm.ContainsKey('whenToUse')) { Ok "whenToUse 已提供（$($fm['whenToUse'].Length) 字符）" }
    else { Warn "没有 whenToUse，模型路由只能靠 description" }

    # ---------- 2b. metadata 阈值 与 正文代码里的默认值一致 ----------
    # 5.1 没有 YAML 解析器，代码不可能直接读 frontmatter，所以两处各存一份，这里负责比对。
    $thresholdVars = [ordered]@{ 'min_size_for_ladder_mb' = 'ladderMinMB'; 'single_conn_fast_kbps' = 'fastKB' }
    foreach ($mk in $thresholdVars.Keys) {
      $var = $thresholdVars[$mk]
      if (-not $meta.ContainsKey($mk)) { Bad "frontmatter.metadata 缺少 $mk"; continue }
      if ($meta[$mk] -notmatch '^\d+$') { Bad "metadata.$mk 必须是纯数字（建议加引号写成字符串），当前 '$($meta[$mk])'"; continue }
      Ok "metadata.$mk = $($meta[$mk])"
      $hit = [regex]::Match($skillText, ('\$' + $var + '\s*=\s*(?<n>\d+)'))
      if (-not $hit.Success) { Bad "正文里找不到 `$$var = <数字>`，第 6/7 步的两个门槛变量必须保留这一行" }
      elseif ([int]$hit.Groups['n'].Value -ne [int]$meta[$mk]) {
        Bad "metadata.$mk=$($meta[$mk]) 与代码 `$$var = $($hit.Groups['n'].Value)` 不一致：改阈值要两处同步"
      }
      else { Ok "`$$var 与 metadata.$mk 一致" }
    }
  }
}

# ---------- 3. 正文结构 ----------
foreach ($sec in @('## Steps', '## Pitfalls', '## Verification')) {
  if ($skillText -match [regex]::Escape($sec)) { Ok "正文包含 $sec" }
  else { Warn "正文缺少 $sec 小节" }
}

# ---------- 4/5. powershell 代码块：语法 + 5.1 兼容性 ----------
$fence = [regex]'(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```'
$blocks = $fence.Matches($skillText)
if ($blocks.Count -eq 0) { Warn "没有找到 ```powershell 代码块" }

$totalErrors = 0
foreach ($b in $blocks) {
  $code  = $b.Groups['code'].Value
  $startLine = (($skillText.Substring(0, $b.Index)) -split "`n").Count
  $tokens = $null; $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    $totalErrors += $errs.Count
    foreach ($e in $errs) {
      Bad ("代码块（SKILL.md 第 {0} 行起）语法错误：{1} @{2}" -f $startLine, $e.Message, $e.Extent.StartLineNumber)
    }
  }
  if ($code -match 'ForEach-Object\s+-Parallel' -or $code -match '-ThrottleLimit') {
    Bad ("代码块（SKILL.md 第 {0} 行起）用了 7.x 才有的 -Parallel/-ThrottleLimit，5.1 会直接报 AmbiguousParameterSet" -f $startLine)
  }
  foreach ($m in [regex]::Matches($code, "'-w',\s*'(?<fmt>[^']*)'")) {
    if ($m.Groups['fmt'].Value -match ' ') {
      Bad ("代码块（SKILL.md 第 {0} 行起）-w 格式串含空格，5.1 的 Start-Process 会把参数拆坏" -f $startLine)
    }
  }
  # 5.1 表达式的三种经典写坏法；先去掉行尾注释，避免注释里的示例被误判
  foreach ($line in ($code -split "\r?\n")) {
    if ($line.TrimStart().StartsWith('#')) { continue }
    $c = ($line -replace '\s#.*$','').Trim()
    if ($c -match '(?<!\$)\(\s*if\s') {
      Bad ("代码块（SKILL.md 第 {0} 行起）用 ( if …) 包表达式：5.1 会报 The term if is not recognized，改成 `$(...) 包住 if" -f $startLine)
    }
    if ($c -match '\+=(?!\s*@)[^\r\n]*\|') {
      Warn ("代码块（SKILL.md 第 {0} 行起）'+= 管道' 右边要套 @(...)，否则运算符优先级会吞掉结果" -f $startLine)
    }
    if ($c -match '&\s*curl[^\r\n]*2>&1') {
      Bad ("代码块（SKILL.md 第 {0} 行起）'& curl … 2>&1'：5.1 会把 curl 的 stderr 变成终止错误，改用 Start-Process + 两个重定向文件" -f $startLine)
    }
  }
}
if ($totalErrors -eq 0) { Ok "$($blocks.Count) 个 powershell 代码块全部通过语法解析" }

# ---------- 6. agents/openai.yaml ----------
$oaPath = Join-Path $SkillRoot 'agents\openai.yaml'
if (Test-Path -LiteralPath $oaPath) {
  $oa = Read-Utf8 $oaPath
  foreach ($need in @('interface:', 'display_name:', 'short_description:', 'default_prompt:')) {
    if ($oa -match [regex]::Escape($need)) { Ok "openai.yaml 含 $need" } else { Bad "openai.yaml 缺少 $need" }
  }
  $m = [regex]::Match($oa, 'short_description:\s*"(?<v>[^"]*)"')
  if ($m.Success) {
    $len = $m.Groups['v'].Value.Length
    if ($len -lt 25 -or $len -gt 64) { Warn "short_description 建议 25–64 字符，当前 $len" } else { Ok "short_description 长度 $len（25–64）" }
  }
  if ($oa -match 'default_prompt:\s*"[^"]*') { Ok "default_prompt 已加引号" } else { Warn "default_prompt 建议用双引号包裹" }
  if ($oa -match '\$[a-z0-9-]+') {
    $ref = $Matches[0].TrimStart('$')
    if ($SkillRoot -and $ref -eq (Split-Path -Leaf ($SkillRoot.TrimEnd('\')))) { Ok "default_prompt 以 `$$ref 引用自身" }
    else { Warn "default_prompt 引用了 $ref，与目录名不一致" }
  }
  else { Warn "default_prompt 未用 `$技能名 形式引用自己" }
}

Write-Host ("-" * 72)
if ($script:fail -gt 0) {
  Write-Host "VALIDATE_FAILED: $($script:fail) 个错误 / $($script:warn) 个告警" -ForegroundColor Red
  exit 1
}
Write-Host "VALIDATE_OK: 0 个错误 / $($script:warn) 个告警" -ForegroundColor Green
exit 0
