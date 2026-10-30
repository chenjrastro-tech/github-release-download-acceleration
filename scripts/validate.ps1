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
    2b. 正文「可调参数」表里的两个门槛（min_size_for_ladder_mb / single_conn_fast_kbps）
       必须与正文代码里的 $ladderMinMB / $fastKB 一致
    3. 正文结构：Steps / Pitfalls / Verification 三节齐备
    4. 所有 ```powershell 代码块能被 PowerShell 解析器无错解析
    5. 5.1 兼容性红线：-Parallel / -ThrottleLimit / 含空格的 -w 参数
    6. agents/openai.yaml：interface 三要素齐备、default_prompt 用 $技能名 引用自己、字符串加引号
    7. 插件包装：package.json / cordis.patch.yml / index.js 三者 id/name 一致
    8. 一次性 runner（scripts/ghdl.ps1 / ghdl.sh）存在、可解析、与 SKILL.md 同步、镜像清单两端一致

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
    $allowed = @('name', 'description', 'metadata')
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
    # frontmatter 只留 name + description + metadata（最小公共集）：严格宿主遇到不认识的键会整条丢弃技能，
    # 因此触发条件必须写进 description / 正文，而不是 whenToUse；阈值放 metadata 供宿主展示/转发。

    # ---------- 2b. 正文参数表 与 代码默认值一致 ----------
    # 阈值以正文「可调参数」表为文档侧真源，第 6 步代码里各有一份常量，两处必须同步。
    $thresholdVars = [ordered]@{ 'min_size_for_ladder_mb' = 'ladderMinMB'; 'single_conn_fast_kbps' = 'fastKB' }
    foreach ($mk in $thresholdVars.Keys) {
      $var = $thresholdVars[$mk]
      $rowM = [regex]::Match($skillText, ('(?m)^\|\s*`' + $mk + '`\s*\|\s*(?<v>\d+)\s*\|'))
      if (-not $rowM.Success) { Bad "正文「可调参数」表缺少 $mk 行"; continue }
      $declared = [int]$rowM.Groups['v'].Value
      Ok "参数表 $mk = $declared"
      $hit = [regex]::Match($skillText, ('\$' + $var + '\s*=\s*(?<n>\d+)'))
      if (-not $hit.Success) { Bad "正文里找不到 `$$var = <数字>`，第 6/7 步的两个门槛变量必须保留这一行" }
      elseif ([int]$hit.Groups['n'].Value -ne $declared) {
        Bad "参数表 $mk=$declared 与代码 `$$var = $($hit.Groups['n'].Value)` 不一致：改阈值要两处同步"
      }
      else { Ok "`$$var 与参数表 $mk 一致" }
    }

    # 2c. metadata 与 ghdl.sh 常量也要和参数表一致（跨平台共用同一套阈值）
    $metaVars = [ordered]@{ 'min_size_for_ladder_mb' = 'LADDER_MIN_MB'; 'single_conn_fast_kbps' = 'FAST_KBPS' }
    foreach ($mk in $metaVars.Keys) {
      $rowM = [regex]::Match($skillText, ('(?m)^\|\s*`' + $mk + '`\s*\|\s*(?<v>\d+)\s*\|'))
      if (-not $rowM.Success) { continue }
      $declared = [int]$rowM.Groups['v'].Value
      if ($meta.ContainsKey($mk)) {
        $mv = $meta[$mk]
        if ($mv -match '^\d+$' -and [int]$mv -eq $declared) { Ok "metadata.$mk = $declared（与参数表一致）" }
        else { Bad "metadata.$mk=$mv 与参数表 $declared 不一致：阈值要四处同步（metadata/参数表/ps1/sh）" }
      }
      else { Warn "frontmatter 的 metadata 缺少 $mk" }
      $shPath = Join-Path $SkillRoot 'scripts\ghdl.sh'
      if (Test-Path $shPath) {
        $shVar = $metaVars[$mk]
        $shM = [regex]::Match([IO.File]::ReadAllText($shPath), ('(?m)^' + $shVar + '=\$\{' + $shVar + ':-([0-9]+)\}'))
        if (-not $shM.Success) { Warn "ghdl.sh 里找不到 $shVar 的默认值" }
        elseif ([int]$shM.Groups[1].Value -ne $declared) { Bad "ghdl.sh 的 $shVar=$($shM.Groups[1].Value) 与参数表 $declared 不一致" }
        else { Ok "ghdl.sh $shVar 与参数表一致" }
      }
    }
  }
}

# ---------- 3. 正文结构 ----------
foreach ($sec in @('## Steps', '## Pitfalls', '## Verification')) {
  if ($skillText -match [regex]::Escape($sec)) { Ok "正文包含 $sec" }
  else { Warn "正文缺少 $sec 小节" }
}

# ---------- 4/5. powershell 代码块：语法 + 5.1 兼容性（SKILL.md 与 references 都扫） ----------
$fence = [regex]'(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```'
$runnerStepsPath = Join-Path $SkillRoot 'references\runner-steps.md'
$runnerStepsText = $(if (Test-Path -LiteralPath $runnerStepsPath) { Read-Utf8 $runnerStepsPath } else { '' })
$sources = @(
  @{ Label = 'SKILL.md'; Text = $skillText },
  @{ Label = 'references/runner-steps.md'; Text = $runnerStepsText }
)

$blockTotal = 0
$totalErrors = 0
foreach ($src in $sources) {
  if (-not $src.Text) { continue }
  $blocks = $fence.Matches($src.Text)
  $blockTotal += $blocks.Count
  foreach ($b in $blocks) {
    $code  = $b.Groups['code'].Value
    $startLine = (($src.Text.Substring(0, $b.Index)) -split "`n").Count
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
      $totalErrors += $errs.Count
      foreach ($e in $errs) {
        Bad ("代码块（{0} 第 {1} 行起）语法错误：{2} @{3}" -f $src.Label, $startLine, $e.Message, $e.Extent.StartLineNumber)
      }
    }
    if ($code -match 'ForEach-Object\s+-Parallel' -or $code -match '-ThrottleLimit') {
      Bad ("代码块（{0} 第 {1} 行起）用了 7.x 才有的 -Parallel/-ThrottleLimit，5.1 会直接报 AmbiguousParameterSet" -f $src.Label, $startLine)
    }
    foreach ($m in [regex]::Matches($code, "'-w',\s*'(?<fmt>[^']*)'")) {
      if ($m.Groups['fmt'].Value -match ' ') {
        Bad ("代码块（{0} 第 {1} 行起）-w 格式串含空格，5.1 的 Start-Process 会把参数拆坏" -f $src.Label, $startLine)
      }
    }
    # 5.1 表达式的三种经典写坏法；先去掉行尾注释，避免注释里的示例被误判
    foreach ($line in ($code -split "\r?\n")) {
      if ($line.TrimStart().StartsWith('#')) { continue }
      $c = ($line -replace '\s#.*$','').Trim()
      if ($c -match '(?<!\$)\(\s*if\s') {
        Bad ("代码块（{0} 第 {1} 行起）用 ( if …) 包表达式：5.1 会报 The term if is not recognized，改成 `$(...) 包住 if" -f $src.Label, $startLine)
      }
      if ($c -match '\+=(?!\s*@)[^\r\n]*\|') {
        Warn ("代码块（{0} 第 {1} 行起）'+= 管道' 右边要套 @(...)，否则运算符优先级会吞掉结果" -f $src.Label, $startLine)
      }
      if ($c -match '&\s*curl[^\r\n]*2>&1') {
        Bad ("代码块（{0} 第 {1} 行起）'& curl … 2>&1'：5.1 会把 curl 的 stderr 变成终止错误，改用 Start-Process + 两个重定向文件" -f $src.Label, $startLine)
      }
    }
  }
}
if ($blockTotal -eq 0) { Warn "没有找到 ```powershell 代码块" }
if ($totalErrors -eq 0 -and $blockTotal -gt 0) { Ok "$blockTotal 个 powershell 代码块全部通过语法解析" }

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

# ---------- 7. 插件包装（package.json / cordis.patch.yml / index.js） ----------
# 市场 CI 会读这三样：`dsh.bundle.patch` 必须指向真实文件，patch 里的 `id`/`name` 必须与
# package.json 的 `name` 和 index.js 的 `export const name` 一致，否则开机解析失败。
$pkgPath = Join-Path $SkillRoot 'package.json'
$patchPath = Join-Path $SkillRoot 'cordis.patch.yml'
$indexPath = Join-Path $SkillRoot 'index.js'
$dirName = Split-Path -Leaf ($SkillRoot.TrimEnd('\'))

if (-not (Test-Path -LiteralPath $pkgPath)) {
  Warn "没有 package.json：手动放技能的用法仍可用，但进不了插件市场"
} else {
  $pkgText = Read-Utf8 $pkgPath
  $pkg = $null
  try { $pkg = $pkgText | ConvertFrom-Json } catch { Bad "package.json 不是合法 JSON：$($_.Exception.Message)" }
  if ($pkg) {
    if ($pkg.name -eq $dirName) { Ok "package.json name 与目录名一致（$($pkg.name)）" }
    elseif ($pkg.name) {
      # 允许不一致：npm registry 会拒绝包名里的某些词（例如 download → 400 That word
      # is not allowed），发布名与仓库目录名不同是正常情况，不算错误。
      Ok "package.json name=$($pkg.name) 与目录名 $dirName 不同（npm 发布名，允许）"
    }
    else { Bad "package.json 缺少 name" }
    if ($pkg.name -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') { Ok "package.json name 是 kebab-case" }
    else { Bad "package.json name 不是 kebab-case：$($pkg.name)" }
    if ($pkg.version -match '^\d+\.\d+\.\d+') { Ok "package.json version = $($pkg.version)" }
    else { Bad "package.json version 不是 semver：$($pkg.version)" }
    if ($pkg.dsh.bundle.patch) { Ok "package.json 声明了 dsh.bundle.patch = $($pkg.dsh.bundle.patch)" }
    else { Bad "package.json 缺少 dsh.bundle.patch（市场只收声明了 dsh.bundle 的包）" }
    if ($pkg.main -and (Test-Path -LiteralPath (Join-Path $SkillRoot $pkg.main))) { Ok "package.json main 指向存在的文件（$($pkg.main)）" }
    else { Bad "package.json main 缺失或指向不存在的文件" }

    if ($pkg.dsh.bundle.patch) {
      $patched = Join-Path $SkillRoot $pkg.dsh.bundle.patch
      if (Test-Path -LiteralPath $patched) { Ok "bundle patch 文件存在" }
      else { Bad "dsh.bundle.patch 指向的 $($pkg.dsh.bundle.patch) 不存在" }
    }
  }
}

if (Test-Path -LiteralPath $patchPath) {
  $patch = Read-Utf8 $patchPath
  if ($patch -match '(?m)^- insert:') { Ok "cordis.patch.yml 有 insert 段" } else { Bad "cordis.patch.yml 缺少 insert 段" }
  # YAML 里 `- id: x` 与 `  id: x` 两种写法都合法，正则要同时吃下前导列表符号。
  $idM = [regex]::Match($patch, '(?m)^\s*(?:-\s+)?id:\s*(?<v>[^\s#]+)')
  $nameM = [regex]::Match($patch, '(?m)^\s*(?:-\s+)?name:\s*[''"]?(?<v>[^''"\r\n]+)')
  if (-not $idM.Success) { Bad "cordis.patch.yml 缺少 id" }
  if (-not $nameM.Success) { Bad "cordis.patch.yml 缺少 name" }
  if ($idM.Success -and $nameM.Success -and $pkg) {
    if ($nameM.Groups['v'].Value.Trim() -eq $pkg.name) { Ok "patch name 与 package.json name 一致" }
    else { Bad "patch name=$($nameM.Groups['v'].Value.Trim()) 与 package.json name=$($pkg.name) 不一致" }
    $idxText = if (Test-Path -LiteralPath $indexPath) { Read-Utf8 $indexPath } else { '' }
    $expM = [regex]::Match($idxText, "export\s+const\s+name\s*=\s*['""](?<v>[^'""]+)['""]")
    if (-not $expM.Success) { Bad "index.js 缺少 export const name" }
    elseif ($expM.Groups['v'].Value -eq $idM.Groups['v'].Value) { Ok "patch id 与 index.js 的 export const name 一致" }
    else { Bad "patch id=$($idM.Groups['v'].Value) 与 index.js name=$($expM.Groups['v'].Value) 不一致" }
    if ($idxText -match "inject\s*=\s*\[[^\]]*'skills'") { Ok "index.js 声明 inject = ['skills']" }
    else { Bad "index.js 没有声明 inject = ['skills']" }
    if ($idxText -match 'registerProvider\(') { Ok "index.js 调用了 ctx.skills.registerProvider" }
    else { Bad "index.js 没有调用 registerProvider" }
  }
} elseif ($pkg) {
  Bad "声明了 dsh.bundle 但缺少 cordis.patch.yml"
}

# ---------- 8. 一次性 runner ----------
$runnerPs1 = Join-Path $SkillRoot 'scripts\ghdl.ps1'
if (-not (Test-Path -LiteralPath $runnerPs1)) {
  Warn "没有 scripts/ghdl.ps1（一次性 runner 未生成，跑 scripts\build-runner.ps1）"
} else {
  $rErr = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($runnerPs1, [ref]$null, [ref]$rErr)
  if ($rErr -and $rErr.Count -gt 0) { Bad "ghdl.ps1 语法错误 $($rErr.Count) 处" }
  else { Ok "ghdl.ps1 语法解析通过（$((Get-Item $runnerPs1).Length) 字节）" }
  $builder = Join-Path $SkillRoot 'scripts\build-runner.ps1'
  if (Test-Path -LiteralPath $builder) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $builder -Check | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok "ghdl.ps1 与 references/runner-steps.md 同步（build-runner -Check）" }
    else { Bad "ghdl.ps1 与 references/runner-steps.md 不同步：重跑 scripts\build-runner.ps1" }
  } else { Warn "没有 scripts/build-runner.ps1，无法校验 runner 漂移" }
}
$runnerSh = Join-Path $SkillRoot 'scripts\ghdl.sh'
if (Test-Path -LiteralPath $runnerSh) {
  $shText = Read-Utf8 $runnerSh
  if ($shText -notmatch "`r") { Ok "ghdl.sh 是 LF 换行" } else { Bad "ghdl.sh 含 CRLF，POSIX 下会报 bad interpreter" }
  if ($shText -match 'set -[eu]') { Ok "ghdl.sh 设置了 set -e/-u" } else { Warn "ghdl.sh 建议加 set -eu" }

  # 镜像清单必须两端一致：runner 里 $mirrors 一份，ghdl.sh 的 for m in 是另一路。
  # 曾经漏掉 hk.gh-proxy.com（文档 7 条、脚本 6 条），只有真机上才发现少测了一条路线。
  # 注意：正文里有一句 `$mirrors = @()` 的初始化，必须挑「同时含 https://」的那一行才是真正的清单
  $mirrorSrc = $(if ($runnerStepsText) { $runnerStepsText } else { Read-Utf8 $skillPath })
  $mirrorLine = $mirrorSrc -split "`n" | Where-Object { $_ -match '\$mirrors = @\(' -and $_ -match 'https://' } | Select-Object -First 1
  $shLoop = $shText -split "`n" | Where-Object { $_ -match 'for m in https://' } | Select-Object -First 1
  if ($mirrorLine -and $shLoop) {
    $docHosts = [regex]::Matches($mirrorLine, 'https://[A-Za-z0-9.\-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
    $shHosts  = [regex]::Matches($shLoop,    'https://[A-Za-z0-9.\-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique
    $missing  = @($docHosts | Where-Object { $shHosts -notcontains $_ })
    $extra    = @($shHosts  | Where-Object { $docHosts -notcontains $_ })
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) { Ok "镜像清单两端一致（$($docHosts.Count) 条）" }
    elseif ($missing.Count -gt 0) { Bad "ghdl.sh 少了镜像：$($missing -join ', ')（SKILL.md 有、脚本没测）" }
    else { Bad "ghdl.sh 多了镜像：$($extra -join ', ')（脚本在测、文档没写）" }
  } else { Warn "找不到镜像清单（SKILL.md 的 `$mirrors 或 ghdl.sh 的 for m in），跳过一致性检查" }
} else { Warn "没有 scripts/ghdl.sh（macOS/Linux 路径）" }

$testsRunner = Join-Path $SkillRoot 'tests\run-tests.ps1'
$testsServer = Join-Path $SkillRoot 'tests\serve.ps1'
if ((Test-Path -LiteralPath $testsRunner) -and (Test-Path -LiteralPath $testsServer)) {
  Ok "离线回归测试存在（tests\run-tests.ps1 + tests\serve.ps1）"
  $tErr = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($testsRunner, [ref]$null, [ref]$tErr)
  if ($tErr -and $tErr.Count -gt 0) { Bad "tests\run-tests.ps1 语法错误 $($tErr.Count) 处" } else { Ok "tests\run-tests.ps1 语法解析通过" }
} else { Warn "没有 tests\run-tests.ps1（离线回归测试缺失）" }

# ---------- 9. 最小版自举 + 文档体积 + CI ----------
# 运行时代码在 references/runner-steps.md（progressive disclosure）：SKILL.md 只留索引，
# 否则 30KB+ 的脚本会把 65,536 字节的正文上限挤爆（宿主会直接拒收/截断技能）。
if (Test-Path -LiteralPath $runnerStepsPath) {
  $stepBlocks = $fence.Matches($runnerStepsText).Count
  $sepBytes = [Text.Encoding]::UTF8.GetByteCount($runnerStepsText)
  if ($stepBlocks -ge 11) { Ok "references/runner-steps.md 有 $stepBlocks 个 powershell 块（>= 11，build-runner 可用）" }
  else { Bad "references/runner-steps.md 只有 $stepBlocks 个 powershell 块，build-runner 需要 >= 11" }
  if ($runnerStepsText -match "`r") { Bad "references/runner-steps.md 含 CRLF（仓库统一 LF）" } else { Ok "references/runner-steps.md 是 LF（$sepBytes 字节）" }
} else { Bad "缺少 references/runner-steps.md（ghdl.ps1 的真源，build-runner 依赖它）" }

$skillText = Read-Utf8 $skillPath
$skillBytes = [Text.Encoding]::UTF8.GetByteCount($skillText)
if ($skillBytes -le 65536) {
  Ok "SKILL.md 体积 $skillBytes 字节（<= 64KB 上限）"
  # 目标形态是「索引 + references」：超过 48KB 说明又往正文塞了代码/长文案，提前提醒
  if ($skillBytes -gt 49152) {
    Write-Host ("[WARN] SKILL.md 已 $skillBytes 字节（> 48KB）：运行时代码请放 references/runner-steps.md，正文只留步骤说明与指针") -ForegroundColor Yellow
  }
} else { Bad "SKILL.md 已 $skillBytes 字节，超过 64KB 上限（代码放 references/，正文只留指针）" }

$miniSh = Join-Path $SkillRoot 'scripts\ghdl-min.sh'
if (-not (Test-Path -LiteralPath $miniSh)) {
  Bad "缺少 scripts/ghdl-min.sh（单文件自举用的最小下载器）"
} else {
  $miniText = Read-Utf8 $miniSh
  if ($miniText -match "`r") { Bad "ghdl-min.sh 含 CRLF，POSIX 下会报 bad interpreter" } else { Ok "ghdl-min.sh 是 LF 换行" }
  if ($miniText -notmatch '^#!/bin/sh') { Bad "ghdl-min.sh 缺少 #!/bin/sh" } else { Ok "ghdl-min.sh 解释器声明正确" }
  # SKILL.md 里的内联块必须与文件逐字一致，否则用户复制到的是过期版本
  $m = [regex]::Match($skillText, '(?ms)拿不到 scripts/ 时的最小版.*?```sh\r?\n(?<code>.*?)\r?\n```')
  if (-not $m.Success) { Bad "SKILL.md 缺少「最小版」章节或其 sh 代码块" }
  else {
    $inline = $m.Groups['code'].Value.Replace("`r`n", "`n").TrimEnd()
    $file = $miniText.Replace("`r`n", "`n").TrimEnd()
    if ($inline -eq $file) { Ok "SKILL.md 内联的最小版与 scripts/ghdl-min.sh 逐字一致" }
    else { Bad "SKILL.md 内联的最小版与 scripts/ghdl-min.sh 不一致（改一边要同步另一边）" }
  }
}

$ciPath = Join-Path $SkillRoot '.github\workflows\test.yml'
if (Test-Path -LiteralPath $ciPath) {
  $ci = Read-Utf8 $ciPath
  if ($ci -match '(?m)^\s*matrix:') { Ok "CI 工作流含 matrix" } else { Warn "CI 工作流没有 matrix" }
} else { Warn "没有 .github/workflows/test.yml（三平台 CI 未落地）" }

Write-Host ("-" * 72)
if ($script:fail -gt 0) {
  Write-Host "VALIDATE_FAILED: $($script:fail) 个错误 / $($script:warn) 个告警" -ForegroundColor Red
  exit 1
}
Write-Host "VALIDATE_OK: 0 个错误 / $($script:warn) 个告警" -ForegroundColor Green
exit 0
