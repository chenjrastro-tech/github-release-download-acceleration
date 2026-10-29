---
name: github-release-download-acceleration
description: 从 GitHub Releases 下载几十 MB 到几 GB 的资产时，先只读自检网络家底（已监听代理端口、环境变量/系统代理、curl 版本、可选的本机 Clash 内核），并行实测「现有代理 / 无头内核 / 公共镜像 / 直连」各路线速度，只在「资产大且单连接被限速」时跑 1 段与 16 段限时阶梯，再用 curl 多段 range 并发下载并以 release digest 做「字节数 + SHA256」闭环校验；零第三方运行时、不改系统代理、不向用户索要参数，资产名对不上报 ASSET_NOT_FOUND 并列出真实候选。当用户说 GitHub 下载太慢、镜像不通、没装加速工具、想多线程下大安装包、文件名可能记错、或只想「无脑下下来」时使用。
---

# GitHub Release 大资产下载加速（自检 → 并行选路 → 限时阶梯 → digest 校验）

目标：用户只说「帮我下这个 / 太慢了」，技能自己探清家底、实测选路、必要时并发，最后用 digest 闭环。前置条件为零：不假设装了 Clash Verge、aria2、7z，不假设系统代理可用，也不要求用户报端口/路径/仓库名。

围栏代码在 Windows PowerShell 5.1 上实跑过（fzf 1.86MB、写错资产名、obs-studio 223MB、rclone 31.6MB），**macOS/Linux 路径未实测**（见「支持矩阵」）。围栏内禁用 `Format-Table`/`Format-List`：抽块连跑时上一条 `format-*` 会污染下一条输出，统一用 `'{0,-28} ...' -f`。

## 什么时候用

- 用户要把 GitHub Release 大文件（几十 MB 以上）下到本机，并抱怨慢、镜像超时、网络受限。
- 不确定本机代理 / Clash 内核在不在跑。
- 用户说「别问我，自己看着办」「我电脑上什么都没装」。
- 资产名可能记错：先校验，对不上报 `ASSET_NOT_FOUND`，不猜文件名。
- 要做「单流 vs 多线程」干净对照。
- `web_fetch` 被墙，需要借本机代理取 raw.githubusercontent 文本。

### 可调参数（正文表与代码两处必须一致，`validate.ps1` 会拦）

| 参数 | 默认 | 作用 | 代码位置 |
| --- | --- | --- | --- |
| `min_size_for_ladder_mb` | 100 | 小于该值不做并发阶梯（阶梯成本 20–26s） | 第 6 步 `$ladderMinMB` |
| `single_conn_fast_kbps` | 3072 | 单连接探针 ≥ 该值直接单流（并发无收益） | 第 6 步 `$fastKB` |

## 环境自适应决策表（先读这张表再动手）

| 自检发现 | 走哪条路线 |
| --- | --- |
| 环境变量/系统代理或常见端口在监听 | A：现有代理，直接实测；能用就用，别再起第二个内核 |
| 无监听端口，但找到内核 exe 且有 `clash-verge.yaml` | B：无头拉起内核，只监听 `127.0.0.1:7897` |
| 没装内核，或配置/节点缺失 | 跳过 B，走 C（镜像实测）+ D（直连） |
| 镜像全灭或 <100 KB/s | D：直连多段，并发 8–16（32 段实测无收益） |
| 所有路线都慢但仍有字节 | 取最高的一条照下，先报预计耗时，别声明「无解」 |
| 资产 <100 MB（`min_size_for_ladder_mb`，默认 100） | 不测并发，单流一次拿完：阶梯要 20–26s，小包纯亏 |
| 资产 ≥100 MB 但单连接探针 ≥3 MB/s（`single_conn_fast_kbps`，默认 3072） | 单流：单连接没被限速，多开线程只是把同一条管子切碎（实测 0.72×） |
| 资产 ≥100 MB 且单连接 <3 MB/s 或探不到速度 | 跑 **1/16 两档**阶梯（每档三遍），多段须快 1.25 倍才分段 |
| 用户明确要「单流 vs 多段」对照 | 置 `$ForceLadder = $true`，测三段 1、4、16 段 |

### 错误路径（必须原样报出来，不许猜着继续）

| 判定 | 必须的动作 |
| --- | --- |
| tag 不存在（API 404） | 报 `RELEASE_NOT_FOUND` 并停，先确认 tag |
| API 200 但没有用户给的资产名 | 报 `ASSET_NOT_FOUND` + 全部候选（名字 + MB）+ 最接近一条，停在这里 |
| API 403 限流 | 报 `API_RATE_LIMITED` 但**不停**：用已知 total/digest 继续，缺 total 用 `Content-Range` 反推 |
| API 被墙/超时（code 000） | 报 `ASSET_UNVERIFIED`，按用户给的直链继续，只做字节数校验 |
| 所有路线 0 字节或非 2xx | 报 `NO_ROUTE` 并列出每条路线的 code/bytes/KBps |
| 拼装字节 ≠ total 或 SHA256 ≠ digest | 报 `DOWNLOAD_VERIFY_FAILED`，不许说「下好了」 |

**API 200 只说明 release/tag 存在**，既不说明资产名对，也不说明可下。资产名对不上是唯一必须回问用户的状态，其余自己探。

### 为什么先选路再谈线程（同机实测，2026-10）

| 路线 | 并发 | 实测吞吐 |
| --- | --- | --- |
| 直连 release-assets | 整包 / 8MB 探针 | ≈1.2 MB/s / ≈3.0 MB/s |
| 公共镜像 gh-proxy | 1 | ≈119 KB/s（其余 6 个镜像 TLS 超时 code 000） |
| 本机内核 7897 | 1 / 4 / 16 / 24 / 32 | 4.9 / 5.3 / **7.7** / 6.0 / 6.3 MB/s（223.7MB / 28.2s，SHA256 通过） |
| 本机内核 7897（节点好转后，31.6MB 整包） | 1 / 16 | **5.8 / 4.2 MB/s（0.72×）** |

路线决定量级（镜像 119 KB/s vs 代理 7.7 MB/s ≈ 65 倍），线程只在「单连接被限速」时再多 1.5–6 倍。顺序固定：**自检 → 校验资产名 → 测路线 → 限时阶梯 → 按 `$winN` 下载**。裸机上没有「装个工具再说」这一步。

### 宿主 shell 的硬约束

- 默认 shell 是 Windows PowerShell 5.1（`$PSVersionTable.PSEdition -eq 'Desktop'`）：**没有 `ForEach-Object -Parallel`**，并行一律 `Start-Process` 多条 + `Wait-Process -Timeout`。
- `Start-Process -ArgumentList` 传数组不会加引号：含空格的参数会被拆坏（`-o` 失效、二进制进 stdout、分片 0 字节）。**所有 curl 参数串不含空格**（`-w` 用 `|`、`-A dsh`、输出 `NUL`）。
- 写脚本文件必须 UTF-8 with BOM；写回 SKILL.md 用 `UTF8Encoding($false)`（SKILL.md 必须 BOM=False）。
- 不要 `& curl … 2>&1`：5.1 会把原生 stderr 变终止错误。统一 `Start-Process -RedirectStandardOutput/-RedirectStandardError` 两个文件。

## Steps

0. **把用户给的地址拆成 `repo/tag/asset`。** 只丢一个 release 页或直链也行，不要反问。

```powershell
$u = 'https://github.com/owner/repo/releases/download/v1.2.3/asset.zip'
$repo = ''; $tag = ''; $asset = ''
if ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/download/(?<t>[^/?#]+)/(?<a>[^/?#]+)') {
  $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t; $asset = $Matches.a
} elseif ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/tag/(?<t>[^/?#]+)') {
  $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t
} elseif ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/?#]+)/?$') {
  $repo = "$($Matches.o)/$($Matches.r)"    # 只给仓库：走 latest
}
if (-not $repo) { throw 'BAD_URL: 先把 release 直链或 tag 页地址确定下来' }
"repo=$repo tag=$tag asset=$asset"
```

1. **只读自检：探清家底，不装东西、不改系统、不问用户。** 端口真在监听才算数（`ProxyEnable` 残留值不算）；`Test-Port` 用 TcpClient 实现，5.1/7.x 和 POSIX 侧都能对上。

```powershell
$ProgressPreference = 'SilentlyContinue'
$onWin = ($env:OS -eq 'Windows_NT')
function Test-Port([string]$h,[int]$p,[int]$ms = 600) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $t = $c.BeginConnect($h,$p,$null,$null)
    if (-not $t.AsyncWaitHandle.WaitOne($ms)) { return $false }
    $c.EndConnect($t); return $true
  } catch { return $false } finally { $c.Close() }
}
$portList = 7890,7891,7897,7898,1080,10808,10809,2080,8889,20171,8080
$listen = @($portList | Where-Object { Test-Port '127.0.0.1' $_ })
$sysProxy = 'n/a'
if ($onWin) {
  $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $sysProxy = "ProxyEnable=$($reg.ProxyEnable) ProxyServer=$($reg.ProxyServer)"    # 只读
}
$curlExe = $(if ($onWin) { 'curl.exe' } else { 'curl' })
$curlOk  = [bool](Get-Command $curlExe -ErrorAction SilentlyContinue)
$curlVer = $(if ($curlOk) { [string](((& $curlExe -V) -split '\s+')[1]) } else { '(none)' })
$cores = @()
if ($onWin) { $cores = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'mihomo|clash|verge|sing-box|v2ray|xray' } | ForEach-Object { '{0}:{1}' -f $_.ProcessName, $_.Id }) }
"onWin=$onWin listen=$($listen -join ',') $sysProxy env=$env:HTTPS_PROXY|$env:HTTP_PROXY|$env:ALL_PROXY curl=$curlVer ok=$curlOk core=$($cores -join ',')"
if (-not $curlOk) { 'NO_CURL: 端口探测/镜像/分段不可用；Windows 用 Invoke-WebRequest 单流降级，POSIX 直接停' }

function Invoke-Curl([string[]]$a) {                      # 统一取 stdout/stderr，避免 2>&1 变终止错误
  $o = Join-Path $env:TEMP ("cur_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
  $p = Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError "$o.err"
  if (-not $p.WaitForExit(180000)) { $p.Kill() }
  $out = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + '').Trim()
  $err = ((Get-Content "$o.err" -Raw -ErrorAction SilentlyContinue) + '').Trim()
  Remove-Item $o,"$o.err" -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{ Out = $out; Err = $err; Exit = $p.ExitCode }
}
```

2. **定位本机 Clash 内核与配置（找不到就跳过 B 路线，不报错退出）。** 实测常装在非系统盘，候选必须覆盖「标准目录 + 每个固定盘根 × 常见子目录 + 开始菜单反查」，只遍历 `DriveType=Fixed`（网络盘/光驱上 `Test-Path` 会卡）。

```powershell
$coreDir = ''; $cfgDir = ''; $cand = @()
if ($onWin) {
  $base = @()
  if ($env:ProgramFiles) { $base += (Join-Path $env:ProgramFiles 'Clash Verge') }
  if (${env:ProgramFiles(x86)}) { $base += (Join-Path ${env:ProgramFiles(x86)} 'Clash Verge') }
  if ($env:LOCALAPPDATA) { $base += @((Join-Path $env:LOCALAPPDATA 'Programs\Clash Verge'), (Join-Path $env:LOCALAPPDATA 'Clash Verge')) }
  foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.Name })) {
    $base += @((Join-Path $d 'Clash Verge'), (Join-Path $d 'Apps\Clash Verge'), (Join-Path $d 'Tools\Clash Verge'))
  }
  $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  if (Test-Path $sm) {
    $sh = New-Object -ComObject WScript.Shell
    $base += @(Get-ChildItem $sm -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
      Where-Object Name -match 'Clash.*Verge' |
      ForEach-Object { Split-Path $sh.CreateShortcut($_.FullName).TargetPath -Parent })
  }
  # 多份安装取 exe 最新的那份：旧内核配新配置会读不懂字段
  $cand = @($base | Where-Object { $_ -and (Test-Path (Join-Path $_ 'verge-mihomo.exe')) } |
    Sort-Object { (Get-Item (Join-Path $_ 'verge-mihomo.exe')).LastWriteTime } -Descending)
  $coreDir = $cand | Select-Object -First 1
  $cfgDir = @("$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev", "$env:APPDATA\clash-verge",
              "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev") |
            Where-Object { Test-Path (Join-Path $_ 'clash-verge.yaml') } | Select-Object -First 1
} else { 'B 路线仅 Windows 实测：macOS/Linux 的内核路径未验证，先走镜像/直连' }
"core=$coreDir cfg=$cfgDir candidates=$($cand.Count)"
```

3. **取 release 元数据并校验资产名（测速前的硬闸门）。** 只给 tag 页就按 `size` 降序挑最大并说明理由；资产名对不上就到此为止，不测速、不下载、不拿「x64 换 amd64」去猜。

```powershell
$total = [int64]0; $want = ''
$apiUrl = $(if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" })
$metaF = Join-Path $env:TEMP ("meta_{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0,6))
$mr = Invoke-Curl @('-sS','-L','-m','20','-A','dsh','-o',$metaF,'-w','%{http_code}',$apiUrl)
$code = $mr.Out
$body = ((Get-Content $metaF -Raw -ErrorAction SilentlyContinue) + '')
Remove-Item $metaF -Force -ErrorAction SilentlyContinue
if ($code -eq '404') { throw "RELEASE_NOT_FOUND: $repo@$tag 不存在（API 404）——先确认 tag，别去猜资产名" }
if ($code -eq '200') {
  $meta = $body | ConvertFrom-Json
  $names = @($meta.assets | ForEach-Object { $_.name })
  if ($names.Count -eq 0) { throw 'ASSET_NOT_FOUND: 该 release 没有任何 asset' }
  if (-not $asset) { $asset = ($meta.assets | Sort-Object size -Descending | Select-Object -First 1).name }
  $a = $meta.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
  if (-not $a) {
    $at = $asset -split '[-_.]'
    $near = @($names | ForEach-Object { [pscustomobject]@{ Name = $_; Score = @(($_ -split '[-_.]') | Where-Object { $at -contains $_ }).Count } } | Sort-Object Score -Descending)[0].Name
    $list = ($meta.assets | Sort-Object name | ForEach-Object { '  - {0} ({1:N1} MB)' -f $_.name, ($_.size / 1MB) }) -join "`n"
    throw ("ASSET_NOT_FOUND: 你给的 '{0}' 不在 {1}@{2}。真实候选：`n{3}`n最接近 '{4}'；确认后给完整直链，我不会静默换名。" -f $asset, $repo, $tag, $list, $near)
  }
  $total = [int64]$a.size
  $want = $(if ($a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLower() } else { '' })
} else {
  if (-not $asset) { throw "ASSET_UNVERIFIED: API code=$code 且没给具体资产名，请给完整资产直链" }
  if ($code -eq '403') { 'API_RATE_LIMITED: 用已知 total/digest 继续，缺 total 用 Content-Range 反推' }
  else { 'ASSET_UNVERIFIED: API 取不到元数据（被墙/超时），按给定资产名继续，缺 digest 只校验字节数' }
  if ($total -le 0) {
    $h = Invoke-Curl @('-sS','-L','-m','20','-A','dsh','-r','0-0','-D','-','-o','NUL',"https://github.com/$repo/releases/download/$tag/$asset")
    if ($h.Out -match '(?im)content-range:\s*bytes\s+\d+-\d+/(\d+)') { $total = [int64]$Matches[1] }
    "range_probe curlExit=$($h.Exit) total=$total"
  }
}
"asset=$asset total=$total want=$want api=$code digest=$(if ($want) { 'sha256' } else { 'none' })"
```

4. **并行短测各条路线：每条都真跑一次 range GET。** 超时 8s、`--connect-timeout 5`、只取 1MB；B 路线留到第 5 步（内核还没起）。排序先看「拿到 ≥512KB」再看 KBps——镜像回一页 HTML 错误页也会「很快」。

```powershell
$u = "https://github.com/$repo/releases/download/$tag/$asset"
$mirrors = @('https://ghfast.top','https://ghproxy.net','https://gh-proxy.com','https://github.moeyy.xyz','https://gh.llkk.cc','https://ghproxy.cc')
$probes = @()
if ($listen.Count -gt 0) { $probes += [pscustomobject]@{ Name = "A 现有代理 :$($listen[0])"; Url = $u; Proxy = "http://127.0.0.1:$($listen[0])" } }
$probes += @($mirrors | ForEach-Object { [pscustomobject]@{ Name = "C 镜像 $_"; Url = "$_/$u"; Proxy = $null } })
$probes += [pscustomobject]@{ Name = 'D 直连'; Url = $u; Proxy = $null }
$pdir = Join-Path $env:TEMP ("probe_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory $pdir -Force | Out-Null
$jobs = @(foreach ($p in $probes) {
  $f = Join-Path $pdir (($p.Name -replace '[^\w]','_') + '.out')
  $a = @('-sS','-L','--connect-timeout','5','-m','8','-r','0-1048575','-A','Mozilla/5.0','-o','NUL','-w','%{http_code}|%{size_download}|%{speed_download}')
  if ($p.Proxy) { $a += @('--proxy',$p.Proxy) }
  $a += $p.Url
  [pscustomobject]@{ Name = $p.Name; Url = $p.Url; Proxy = $p.Proxy; Log = $f
    Proc = (Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $f -RedirectStandardError ($f -replace '\.out$','.err')) }
})
$jobs.Proc | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
$results = @(foreach ($j in $jobs) {
  $line = ((Get-Content $j.Log -Raw -ErrorAction SilentlyContinue) + '').Trim()
  $o = $(if ($line) { $line -split '\|' } else { @() })
  if ($o.Count -lt 3) { $o = @('000','0','0') }
  [pscustomobject]@{ Name = $j.Name; Url = $j.Url; Proxy = $j.Proxy; Code = $o[0]
    Bytes = $(if ($o[1] -match '^\d+$') { [int64]$o[1] } else { 0 })
    KBps  = $(if ($o[2] -match '^[\d.]+$') { [int][math]::Round([double]$o[2] / 1KB, 0) } else { 0 }) }
})
$results | Sort-Object @{Expression = { $_.Bytes -ge 524288 }; Descending = $true}, @{Expression = 'KBps'; Descending = $true} |
  ForEach-Object { '{0,-30} code={1} bytes={2,9} KBps={3,6} 206={4}' -f $_.Name, $_.Code, $_.Bytes, $_.KBps, ($_.Code -eq '206') }
"PROBE_206_OK=$(@($results | Where-Object { $_.Code -eq '206' -and $_.Bytes -ge 1048576 }).Count)"
$cand2 = @($results | Where-Object { $_.Code -in @('200','206') -and $_.Bytes -ge 524288 } | Sort-Object KBps -Descending)
if ($cand2.Count -eq 0) {
  throw ("NO_ROUTE: 所有路线都没拿到数据`n" + (($results | ForEach-Object { '{0} code={1} bytes={2} KBps={3}' -f $_.Name, $_.Code, $_.Bytes, $_.KBps }) -join "`n"))
}
$route = $cand2[0]; $winUrl = $route.Url; $winProxy = $route.Proxy
Remove-Item $pdir -Recurse -Force -ErrorAction SilentlyContinue
"route=$($route.Name) KBps=$($route.KBps) slow=$($route.KBps -lt 100)"
```

5. **没有可用代理时才无头拉起内核，只监听 127.0.0.1:7897，并只记自己起的 pid。** 用户原本在跑的 7897 不许停；起不来就立刻杀掉自己那一个，回 C/D。

```powershell
$corePid = $null; $curlPids = @()
$up = [bool](Test-Port '127.0.0.1' 7897)
if ($up) { 'PORT_7897_ALREADY_LISTENING: 用现成的，收尾不要停' }
elseif ($coreDir -and $cfgDir -and (Test-Path (Join-Path $coreDir 'verge-mihomo.exe'))) {
  (Get-Content (Join-Path $cfgDir 'config.yaml') -TotalCount 20 -ErrorAction SilentlyContinue | Select-String 'mixed-port').Line   # 只确认端口
  $core = Start-Process -FilePath (Join-Path $coreDir 'verge-mihomo.exe') -ArgumentList @('-d',$cfgDir,'-f',(Join-Path $cfgDir 'clash-verge.yaml')) -WindowStyle Hidden -PassThru
  $corePid = $core.Id
  for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Milliseconds 700; if (Test-Port '127.0.0.1' 7897) { break } }
} else { 'NO_CLASH_CORE: 没找到内核/配置，跳过 B 路线' }
$up = [bool](Test-Port '127.0.0.1' 7897)
$bKB = 0
if ($up) {
  $need = $(if ($total -gt 0) { [math]::Min([int64]8388608, $total) } else { [int64]8388608 })   # 资产 <8MB 时只能拿回整包
  $br = Invoke-Curl @('-sS','-L','--connect-timeout','8','-m','20','-r','0-8388607','--proxy','http://127.0.0.1:7897','-A','Mozilla/5.0','-o','NUL','-w','%{http_code}|%{size_download}|%{speed_download}',$u)
  $b = $br.Out -split '\|'
  $bCode = $(if ($b.Count -ge 3) { $b[0] } else { '000' })
  $bGot  = $(if ($b.Count -ge 3 -and $b[1] -match '^\d+$') { [int64]$b[1] } else { 0 })
  $bKB   = $(if ($b.Count -ge 3 -and $b[2] -match '^[\d.]+$') { [int][math]::Round([double]$b[2] / 1KB, 0) } else { 0 })
  "B 本机内核 code=$bCode got=$bGot KBps=$bKB 206=$($bCode -eq '206')"
  if ($bCode -notin @('200','206') -or $bGot -lt ($need * 0.5)) {
    "B 不可用 err=$($br.Err)"
    if ($corePid) { Stop-Process -Id $corePid -Force -ErrorAction SilentlyContinue; $corePid = $null }
    $bKB = 0
  }
}
if ($bKB -ge 100 -and $bKB -gt $route.KBps) { $winUrl = $u; $winProxy = 'http://127.0.0.1:7897'; 'B 胜出，改用本机内核' }
$singleKB = [int]$bKB
if ($singleKB -le 0) { $singleKB = [int]$route.KBps }
"singleKB=$singleKB (>=3072 视为单连接没被限速)"
```

6. **先判值不值得测，再在胜出路线上做限时阶梯。** 默认只在「资产 ≥100 MB 且 `$singleKB < 3072`」时跑 **1/16 两档**；用户要对照才置 `$ForceLadder = $true` 跑 1、4、16 三段。每档 n 条连接各从自己起点 open-range 读到文件尾，同一时间窗比聚合吞吐，三遍交错取中位数并报 min–max。

```powershell
function Test-Ladder([int]$n,[string]$url,[string]$proxy,[int64]$total = 0,[int]$sec = 4) {
  $per = $(if ($total -gt 0) { [int64][math]::Floor($total / $n) } else { [int64][math]::Floor(64MB / $n) })
  $dir = Join-Path $env:TEMP ("ladder_{0}_{1}" -f $n, [guid]::NewGuid().ToString('N').Substring(0,4))
  New-Item -ItemType Directory $dir -Force | Out-Null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ps = @(1..$n | ForEach-Object {
    $i = $_; $s = [int64](($i - 1) * $per)
    $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-r',"$s-",'-o','NUL','-m',"$sec",'-w','%{http_code}|%{size_download}|%{speed_download}')
    if ($proxy) { $a += @('--proxy',$proxy) }
    $a += $url
    Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $dir "p$i.out") -RedirectStandardError (Join-Path $dir "p$i.err")
  })
  $ps | Wait-Process -Timeout ($sec + 30) -ErrorAction SilentlyContinue
  $ps | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
  $sw.Stop()
  $bytes = 0; $ok = 0
  Get-ChildItem $dir -Filter 'p*.out' -ErrorAction SilentlyContinue | ForEach-Object {
    $o = ((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) + '').Trim() -split '\|'
    if ($o.Count -ge 3 -and $o[0] -match '^20[06]$') { $ok++; if ($o[1] -match '^\d+$') { $bytes += [int64]$o[1] } }
  }
  $kbps = [int](($bytes / 1KB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.1))
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{ N = $n; Full = $ok; KBps = $kbps
    Text = ('{0,2} 段: 完成 {1}/{0} {2,7:N1} MB / {3,4:N1}s = {4,6:N0} KB/s' -f $n, $ok, ($bytes / 1MB), $sw.Elapsed.TotalSeconds, $kbps) }
}
$ForceLadder = $false
$ladderMinMB = 100
$fastKB = 3072
$bigEnough = ($total -ge ($ladderMinMB * 1MB))
$throttled = ($singleKB -le 0) -or ($singleKB -lt $fastKB)
$rungs = $(if ($ForceLadder) { @(1,4,16) } else { @(1,16) })
$runs = @(); $ladderSec = 0; $sampleMB = 0
if ($ForceLadder -or ($bigEnough -and $throttled)) {
  $swL = [Diagnostics.Stopwatch]::StartNew()
  foreach ($rep in 1..3) { foreach ($n in $rungs) { $runs += @(Test-Ladder $n $winUrl $winProxy $total 4) } }
  $swL.Stop(); $ladderSec = [math]::Round($swL.Elapsed.TotalSeconds, 1)
  $sampleMB = [math]::Round(($runs | Measure-Object KBps -Sum).Sum * 4 / 1024, 0)
  $runs | ForEach-Object { $_.Text }
  "LADDER_DONE: rungs=$($rungs -join '/') passes=3 elapsed=${ladderSec}s sample=$sampleMB MB"
} else {
  "SKIP_LADDER: total=$([math]::Round($total/1MB,1))MB singleKB=$singleKB (门槛 ${ladderMinMB}MB / ${fastKB}KB/s) -> 单流，省约 20-26s"
}
$agg = @(foreach ($n in $rungs) {
  $s = @($runs | Where-Object { $_.N -eq $n })
  if ($s.Count -eq 0) { continue }
  $v = @($s | ForEach-Object { [int]$_.KBps } | Sort-Object)
  $mid = [int][math]::Floor($v.Count / 2)
  $med = $(if (($v.Count % 2) -eq 1) { $v[$mid] } else { [int](($v[$mid - 1] + $v[$mid]) / 2) })
  $spread = $(if ($v[0] -gt 0) { [math]::Round($v[$v.Count - 1] / $v[0], 2) } else { 0 })
  [pscustomobject]@{ N = $n; Full = ($s | Measure-Object Full -Minimum).Minimum; Med = $med; Min = $v[0]; Max = $v[$v.Count - 1]; Spread = $spread }
})
$agg | ForEach-Object { '{0,2} 段: 完成 {1}/{0} 中位 {2,6} KB/s min-max {3}-{4} 波动 {5}x' -f $_.N, $_.Full, $_.Med, $_.Min, $_.Max, $_.Spread }
$bestR = @($agg | Where-Object { $_.Full -ge $_.N -and $_.Spread -le 2 } | Sort-Object Med -Descending)
if ($bestR.Count -eq 0) { $bestR = @($agg | Where-Object { $_.Full -ge $_.N } | Sort-Object Med -Descending) }
$one = $agg | Where-Object { $_.N -eq 1 } | Select-Object -First 1
$winN = 1; $ratio = 1
if ($runs.Count -gt 0 -and $bestR.Count -gt 0 -and $bestR[0].N -gt 1) {
  if (-not $one -or $bestR[0].Med -ge (1.25 * $one.Med)) { $winN = $bestR[0].N; $ratio = [math]::Round($bestR[0].Med / [math]::Max($one.Med, 1), 2) }
}
"winN=$winN ratio=${ratio}x elapsed=${ladderSec}s"
if ($Parts -gt 0) {
  # 没有总字节数就算不出 range 边界：与其假装分段，不如说清原因后走单流
  if ($total -gt 0) { $winN = [int]$Parts; "PARTS_OVERRIDE: winN=$winN（手动指定并发段数）" }
  else { "PARTS_IGNORED: 总字节数未知（API 限流或不可达），无法切 range，改走单流"; $winN = 1 }
}
```

判定：只有「完成数 = n/n、三次波动 ≤2×」的档位能胜出；多段必须快过单段 1.25 倍才分段，否则 `$winN=1` 并把倍数写进报告。`$total` 未知时按 64MB 估起点。跳过阶梯是设计里的省时分支，不是漏测。

7. **按胜出组合下载：`$winN=1`、或小资产、或 total 未知时单流一次拿完，否则按 `$winN` 段并发。** 先查盘（分片+成品约 2 倍资产）、每段独立日志、带 `--retry`，`--retry-all-errors` 要 7.71+。

```powershell
$ErrorActionPreference = 'Stop'
$parts = $winN
if (-not $parts) { $parts = 1 }
$vc = $(if ($curlVer -match '^(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" } else { [version]'0.0' })
$retry = @('--retry','3','--retry-delay','2')
if ($vc -ge [version]'7.71') { $retry += '--retry-all-errors' } else { "RETRY_DEGRADED: curl $curlVer < 7.71，只用 --retry 3 --retry-delay 2" }
$base = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
$dir  = Join-Path $base '_dl_parts'
$out  = Join-Path $base $asset
New-Item -ItemType Directory $base -Force | Out-Null
# 小资产、单流足够快、或总字节数未知时都走单流；若是 -Parts 指定却被挡下，说清原因
if ($Parts -gt 0 -and $winN -gt 1 -and ($total -le 0 -or $total -lt ($ladderMinMB * 1MB))) {
  "PARTS_IGNORED: 资产 $([math]::Round($total/1MB,1))MB（闸值 ${ladderMinMB}MB）或总字节数未知，分段只会更慢，改走单流"
  $winN = 1
}
if ($total -le 0 -or $total -lt ($ladderMinMB * 1MB) -or $parts -le 1) {
  $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-o',$out,'-m','1800','-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}|t=%{time_total}') + $retry
  if ($winProxy) { $a += @('--proxy',$winProxy) }
  $a += $winUrl
  $st = (& $curlExe @a | Out-String).Trim()
  "SINGLE exit=$LASTEXITCODE $st"
  if ($LASTEXITCODE -ne 0) { throw "SINGLE_FAILED: exit=$LASTEXITCODE $st" }
  if ($total -le 0) { $total = (Get-Item $out).Length; "total_from_download=$total" }
  $parts = 1
} else {
  if ($dir -match ' ') { throw "SPACE_IN_PATH: $dir 含空格，5.1 的 Start-Process 会拆坏 -o" }
  $freeGB = [math]::Round((Get-PSDrive (([IO.Path]::GetPathRoot($dir)).TrimEnd('\').TrimEnd(':'))).Free / 1GB, 1)
  $needGB = [math]::Round(($total * 2 / 1GB), 1)
  if ($freeGB -lt $needGB) { throw "SPACE_LOW: free=${freeGB}GB need=${needGB}GB" }
  if ([math]::Floor($total / $parts) -lt 2MB) { $parts = [math]::Max(1, [int][math]::Floor($total / 2MB)) }
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $dir -Force | Out-Null
  $chunk = [int64][math]::Floor($total / $parts)
  for ($i = 0; $i -lt $parts; $i++) {
    $s = [int64]($i * $chunk)
    $e = $(if ($i -eq $parts - 1) { $total - 1 } else { $s + $chunk - 1 })
    $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-r',"$s-$e",'-o',(Join-Path $dir "p$i.bin"),'-m','1800','-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}') + $retry
    if ($winProxy) { $a += @('--proxy',$winProxy) }
    $a += $winUrl
    $curlPids += (Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $dir "p$i.log") -RedirectStandardError (Join-Path $dir "p$i.err")).Id
  }
  "parts=$parts chunk=$chunk pids=$($curlPids -join ',')"
}
```

8. **分段时 45 秒看一次增长；20–30s 仍 0 字节就自己降档。** 只停自己那批 `$curlPids`，清空分片，降并发（16→8→4）或换第二名路线重开。单流分支跳过本步。

```powershell
if ($parts -gt 1) {
  $before = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  Start-Sleep -Seconds 45
  $after = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  "delta=$([math]::Round(($after-$before)/1MB,1))MB/45s = $([math]::Round((($after-$before)/1KB)/45,0)) KB/s total=$([math]::Round($after/1MB,1))MB"
  Get-ChildItem $dir -Filter 'p*.bin' | Sort-Object Length | ForEach-Object { '{0,-8} {1,12} {2,7:N1} MB' -f $_.Name, $_.Length, ($_.Length / 1MB) }
  # 判定为 0 时才执行：$curlPids | Stop-Process -Force; 清分片; 改 $parts; 重跑第 7 步
}
```

9. **拼装前逐段核对字节数，再按 p0→pN 拼。** 总和对不上只重跑缺的那段；大小对内容错要靠第 10 步的 digest 发现。

```powershell
if ($parts -gt 1) {
  $sum = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  "partsBytes=$sum total=$total ok=$($sum -eq $total)"
  Get-ChildItem $dir -Filter 'p*.log' | ForEach-Object { "  $($_.Name): $(((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) + '').Trim())" }
  if ($sum -ne $total) { throw "PARTS_MISMATCH: sum=$sum total=$total，先修分片再拼" }
  $fs = [IO.File]::Create($out)
  for ($i = 0; $i -lt $parts; $i++) {
    $p = Join-Path $dir "p$i.bin"
    if (-not (Test-Path $p)) { $fs.Dispose(); throw "PARTS_MISSING: $p" }
    $in = [IO.File]::OpenRead($p); $in.CopyTo($fs); $in.Dispose()
  }
  $fs.Dispose()
  "assembled=$((Get-Item $out).Length)"
} else {
  "single=$((Get-Item $out).Length)（单流分支，无需拼装）"
}
```

10. **用 release digest 做「字节数 + SHA256」闭环，不通过就别说完成。** 无 digest 的老 release 如实报缺基准，不要伪造校验，也不要用 Authenticode 兜底（实测该安装包 `NotSigned`）。

```powershell
$size = (Get-Item $out).Length
$sizeOk = ($size -eq $total)
"size=$size expect=$total sizeOk=$sizeOk"
if ($want) {
  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower()
  "sha256=$got expect=$want"
  $(if ($sizeOk -and $got -eq $want) { 'DOWNLOAD_VERIFIED_OK' } else { 'DOWNLOAD_VERIFY_FAILED' })
} else {
  'NO_DIGEST: 该 release 未提供 sha256，只能保证字节数一致'
  $(if ($sizeOk) { 'DOWNLOAD_SIZE_OK_NO_DIGEST' } else { 'DOWNLOAD_VERIFY_FAILED' })
}
```

11. **收尾只还原自己动过的东西，然后一句话报结果。** 只按记下的 `$corePid`/`$curlPids` 以 Id 停进程；别 `Stop-Process -Name curl`（会杀用户自己的下载），别关用户原本就在跑的代理。清理用 `-like` 链，别用带括号的 `-match` 正则（少个右括号直接抛 ArgumentException）。

```powershell
if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }
$curlPids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'cur_*' -or $_.Name -like 'raw_*' -or $_.Name -like 'ghdl_*' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
"7897=$([bool](Test-Port '127.0.0.1' 7897)) corePid=$corePid"
if ($onWin) { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable }
```

报告三行（小白只看这三行，不贴探测过程）：

```powershell
"路线=<A/B/C/D>；阶梯 1/16 中位 X vs Y KB/s，min-max a-b / c-d，耗时 ${ladderSec}s、采样约 ${sampleMB}MB，winN=$winN（${ratio}x） 或 SKIP_LADDER：<100MB 或单连接 ≥3072KB/s，省约 20-26s"
"已下载并校验：<MB>，平均 <MB/s>，SHA256 与 release digest 一致（无 digest 写 NO_DIGEST 只校验字节数）"
"文件=<绝对路径>"
```

### 小文件/文本走同一条代理通道（web_fetch 被墙时）

抓 `raw.githubusercontent.com` 文本时别再反复 web_fetch，直接用第 1/2/5 步起的内核，读完**按 `Length` 做有保护截断**（无保护的 `Substring(0, N)` 会抛「索引和长度必须引用该字符串内的位置」）。

```powershell
$rawUrl = 'https://raw.githubusercontent.com/<owner>/<repo>/main/README.md'
$tmpTxt = Join-Path $env:TEMP ("raw_{0}.txt" -f [guid]::NewGuid().ToString('N').Substring(0,6))
$rr = Invoke-Curl @('-sS','-L','-m','30','-A','dsh','--proxy','http://127.0.0.1:7897','-o',$tmpTxt,'-w','%{http_code}|%{size_download}',$rawUrl)
$txt = ((Get-Content $tmpTxt -Raw -ErrorAction SilentlyContinue) + '')
"http=$($rr.Out) chars=$($txt.Length) bytes=$((Get-Item $tmpTxt -ErrorAction SilentlyContinue).Length)"
if ($txt.Length -gt 0) { $txt.Substring(0, [math]::Min(1200, $txt.Length)) }
Remove-Item $tmpTxt -Force -ErrorAction SilentlyContinue
```

收尾照样走第 11 步：停本次拉起的 `$corePid`、删临时文件、回读 `7897= False`。

### POSIX 兜底（`scripts/ghdl.sh`，macOS/Linux **未验证**）

`scripts/ghdl.sh` 是同一套流程的 POSIX 实现：探监听端口 → 探针选路 → 1/16 限时阶梯 → 单流或多段 range → sha256 校验。只用 `/bin/sh` + 系统 curl，不用 bash 数组、`/dev/tcp`、jq、python。

**状态：未验证。** 它只在 Windows 的 Git Bash 下过了 `sh -n` 语法检查；真实 macOS 12+ 与 Linux（dash/glibc）都没有跑过。跑通之前，对外只能说「Windows 已实测」，不许写「支持 macOS/Linux」。
## 支持矩阵

| 项 | 状态 | 依据 |
| --- | --- | --- |
| Windows 10/11 + PowerShell 5.1 + 自带 curl.exe | 已实测 | 本机真实下载 223.7MB / 31.6MB，字节与 SHA256 均对上 |
| Windows + PowerShell 7 | 理论可用 | 语法未用 7.x 专属特性，但未跑全流程 |
| macOS 12+（/bin/sh + 系统 curl） | 未验证 | 无 macOS 机器，POSIX 块只做过语法审读 |
| Linux glibc | 未验证 | 同上 |
| 宿主：DSH（读 SKILL.md + 执行 shell） | 已实测 | `skill` 工具实际加载成功并返回正文 |
| 宿主：其它能执行本地 shell 的 agent | 理论可用 | 逻辑只依赖 shell + curl，不含 DSH 专有 API；但本仓库只做过 DSH 加载证明 |
| 纯网页/手机/无 shell 的聊天宿主 | 不支持 | 无法执行 curl/PowerShell |
| 无代理直连 GitHub | 已实测 | 直连被限速约 1.2 MB/s，需镜像/代理 |
| 有代理时自动复用 | 已实测 | A 路线 range 实测后被选为胜出路线 |
| 管理员权限 | 不需要 | 只读 HKCU，不改注册表/系统代理 |
| Python / Node / aria2 / 7z / wget | 不需要 | 只用系统 curl + PowerShell/sha256 工具 || 一次性 runner `scripts/ghdl.ps1`（Windows） | 已实测 | 3 次真实下载全 `DOWNLOAD_VERIFIED_OK`：fzf 1.86MB（单流）、rclone 31.6MB（`-ForceLadder`）、OBS 223MB（`-Parts 16` 走拼装） |
| 一次性 runner `scripts/ghdl.sh`（POSIX） | 部分验证 | 在 Windows Git Bash（MSYS2，sh 5.x）跑通：单流下载 + `PARTS=16` 分段拼装 + SHA256 全对；真实 macOS/Linux、dash/BSD sh **未实测** |
| 「真零前置」：PATH 只剩系统目录 + 清空 HTTP(S)_PROXY/ALL_PROXY | 已实测（Windows） | 非管理员会话、`PATH=C:\Windows{;\system32;\System32\WindowsPowerShell\v1.0}`，靠端口探测找到 7897，全程 SHA256 校验通过 |
| frontmatter 最小公共集（只有 name + description） | 已实测 | 严格宿主遇到未知键会整条丢弃技能；触发条件写进 description，`validate.ps1` 只放行这两个键 |

其它未验证项：macOS 上的 Clash Verge 内核路径、Windows 上超出 6 个镜像的候选、1Gbps 以上链路下的阶梯采样偏差。

## Pitfalls

- **不要假设环境。** 裸机上可能没有 Clash Verge、没有 aria2/7z，也不一定有已启动的代理；缺了就换路线，绝不 `exit` 报错或让用户去装东西。
- **不要向用户要参数。** 端口、内核路径、配置目录都自己查；仓库名不能凭产品名猜（实测直接 404）。
- **资产名对不上必须 `ASSET_NOT_FOUND` + 候选清单，禁止静默换名。** 实测坏姿势：发现 `...-x64.zip` 不存在后只打印 name/size 就改用 `..._amd64.zip` 继续下，报告里连错误码都没有。
- **API 200 ≠ 资产名对，也 ≠ 资产可下；API 403 限流不是 NO_ROUTE**（有 total/digest 就继续，缺 total 用 `-r 0-0` 的 `Content-Range` 反推）。
- **并发不是越多越快。** 实测 16 段 7.7 MB/s 最优、24 段 6.0、32 段 6.3 回落；节点快时 16 段只有 0.72×。每轮现测，别背历史数字。
- **`Port open: False` 不等于代理已启用，`ProxyServer` 残留值也不等于。** 实测 `ProxyEnable: 0` 仍留着 `127.0.0.1:7897`，此时跑基线只会得到 `bytes=0 code=000`。
- **忘 `-L` 就只剩 302 和 0 字节**；别用 `-I`/HEAD 判断可下，用 `-r 0-1023` 的 GET；节点可用要 `206`（200 表示忽略 Range 回了整包）。
- **镜像必须实测，全灭很正常**（6 个里 5 个 TLS 超时）；**镜像「快」可能是回了错误页**：排序先看 `Bytes ≥ 512KB` 再看 KB/s。
- **内核要显式 `-d`/`-f` 且只绑本机**，不开 GUI、不写注册表、不开 `allow-lan`；多份安装按 exe `LastWriteTime` 取最新（数组第一个不算），候选为空是正常降级。
- **只杀自己的进程。** `Stop-Process -Name curl` 会杀用户自己的下载；收尾/降档只能用 `$curlPids` 与 `$corePid`。
- **`curl` 的 `-w` 串里不要有空格**（5.1 的 `Start-Process -ArgumentList` 不加引号，含空格的参数被拆开 → `-o` 失效、响应体进 stdout、分片 0 字节）。
- **围栏里不要混用 `Format-Table`/`Format-List`**：抽块连跑时 `FormatEntryData` 会污染下一条输出。
- **别写 `$x =(if …)` 形式**（5.1 里 `if` 是语句）：用 `$x =$(if (…) {…} else {…})`；`$array += 管道` 右边必须 `@()` 包住。
- **别用 `& curl … 2>&1` 收结果**（原生 stderr 变 ErrorRecord，撞上 `$ErrorActionPreference='Stop'` 就是终止错误）；统一两个重定向文件再 `Get-Content -Raw`。
- **`--retry-all-errors` 要 7.71+**，Win10 自带 7.55 会 `unknown option`；第 7 步先取版本，低于 7.71 只留 `--retry 3 --retry-delay 2` 并打 `RETRY_DEGRADED`。
- **阶梯结果必须喂给第 7 步。** 真缺陷：`Test-Ladder` 只打印不返回、第 7 步硬编码分段数，于是「测了但没用上」，节点不限速时反而更慢。函数要返回 `N/Full/KBps`，调用侧算出 `$winN`。
- **小段测速会把单流测冤枉**：固定 1MB/8MB 段被建连+慢启动吃掉（同节点 742 KB/s vs 整包 5829 KB/s）；必须每档 n 条同时 open-range 到文件尾、限同一时间窗。
- **`<100MB 走单流` 必须落成代码**，不能只在决策表写一句而代码里仍写死分段数。
- **Step 5 的 B 路线阈值要按资产大小算**：range `0-8388607` 对 <8MB 资产返回 200 + 整包（实测 `got=1863156`），硬阈值会误杀刚拉起来的内核。
- **写技能自己的 .ps1 必须带 BOM**（`UTF8Encoding($true)`）；写回 SKILL.md 相反用 `UTF8Encoding($false)`。
- **`Get-ChildItem -Filter` 只接受单个字符串**；多模式用 `Where-Object Name -like`。
- **`skill` 工具报 `unknown or no longer available` 是发现路径问题**：确认技能目录在发现根内（必要时建 junction），再用 `skill` 工具实加载验证，`Test-Path` 为真不算证明。
- **报告写实测平均速度，不要写峰值**（`speed_download` 瞬时值会被前段缓存拉高）。
- TODO：宿主已装 aria2c 时可用 `aria2c -x16 -s16 --all-proxy=...` 替代手写分段，本技能未实测该路线，暂不纳入默认流程。

## Verification

- 自检输出一句话说清走了哪条路线；第 3 步打印过 `asset=… total=… want=…`（API 403 是 `API_RATE_LIMITED`，被墙是 `ASSET_UNVERIFIED` + `range_probe` 反推 total）。
- **错误路径演练**：拿真实 release 的不存在资产名（例：`fzf-0.65.2-windows-x64.zip`，真实是 `..._amd64.zip`）跑一遍，输出必须含 `ASSET_NOT_FOUND`、全部候选（名字+MB）与最接近一条，且**没生成下载文件、没进第 4 步探测**。
- 探测表里胜出路线 KB/s 明显最高并打印 `PROBE_206_OK=1`；所有 `bytes=0 code=000` 都被标成「无代理」，没拿来当单流对照。
- **门槛可配且只改一处会被拦住**：正文「可调参数」表里 `min_size_for_ladder_mb` = 100、`single_conn_fast_kbps` = 3072，与代码 `$ladderMinMB = 100`/`$fastKB = 3072` 一致；只改参数表时 `validate.ps1` 必须输出「不一致：改阈值要两处同步」并 `exit=1`，已下行的旧阈值命数为 0：

```powershell
$d = '<技能目录>'
$old = @(('60' + 'MB'), ('<' + '20MB'), ('$parts = ' + '16'))
Select-String -Path "$d\SKILL.md","$d\README.md" -Pattern $old -SimpleMatch | ForEach-Object { "$($_.Filename):$($_.LineNumber): $($_.Line.Trim())" }
"old_hits=" + @(Select-String -Path "$d\SKILL.md","$d\README.md" -Pattern $old -SimpleMatch).Count
"SKILL_MD_BOM=" + ([IO.File]::ReadAllBytes("$d\SKILL.md")[0] -eq 0xEF)     # 必须 False
$t = [IO.File]::ReadAllText("$d\SKILL.md", [Text.Encoding]::UTF8)
$code = ([regex]::Matches($t, '(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```') | ForEach-Object { $_.Groups['code'].Value }) -join "`n"
"hardcoded_core_path_hits=" + ([regex]::Matches($code, 'D:\\Clash Verge')).Count   # 必须 0
```

- **小资产/快节点分支**：`$total < 100MB` 或 `$singleKB ≥ 3072` 时日志有 `SKIP_LADDER: …` 与 `SINGLE exit=0 code=200`（或 206），没有 `parts=` 分段行，最终 `DOWNLOAD_VERIFIED_OK`；报告只给路线/速度/校验三行并写明省约 20–26 秒。
- **限速节点分支**：只跑 1/16 两档、每档三遍，逐档输出「完成 n/n」、中位与实测 min–max、`波动 Nx`，最后 `LADDER_DONE: rungs=1/16 passes=3 elapsed=…s sample≈…MB` 与 `winN=…`；**不出现 4 段档**；`$parts` 等于 `winN`。
- **对照分支**：`$ForceLadder=$true` 时是三段（1、4、16），单流不慢于多段 1.25 倍就 `winN=1`，最终回答一句话写清倍数与「为何不分段」。
- **拼装与校验**：`p*.bin` 总字节等于 `$total`，拼装后 `Length` 等于 release `size`，`Get-FileHash` 与 digest 一致并输出 `DOWNLOAD_VERIFIED_OK`；无 digest 时 `DOWNLOAD_SIZE_OK_NO_DIGEST`。
- **离线夹具（网络全断时）**：抽出全部围栏块并报「块数与每块起始行号」，零真实流量下全 PASS——32MB 打印 `SKIP_LADDER` 且 `winN=1`、单连接 4200KB/s 同样跳过、99MB→小资产 / 200MB→非小资产；最后 `validate.ps1` exit=0、`%TEMP%` 无 `ladder_*`/`probe_*`/`meta_*`/`raw_*` 残留。夹具 PASS 只能报成离线验证。
- **收尾**：`7897` 不再监听、`Get-Process verge-mihomo` 无本次残留、`ProxyEnable` 与开始时一致（初始 0）；只按 `$corePid`/`$curlPids` 以 Id 停进程。
- **加载证明**：`skill` 工具能真正加载 `github-release-download-acceleration`（返回技能名/正文），不是只看目录存在；本技能只做本地验证，不 `git init`、不 push。

## 维护与自检（改完必跑）

三个非模型文件随文档同步维护：`agents/openai.yaml`（`short_description` 25–64 字符、`default_prompt` 含 `$github-release-download-acceleration`）、`README.md`（能力/限制/示例/支持矩阵与本文一致）、`scripts/validate.ps1`（可复跑自检，退出码非 0 就是文档有问题）。

两个门槛的唯一改动点是正文「可调参数」表；PS 5.1 没有 YAML 解析器，代码里各存一份，**改阈值要两处同步**，只改一边直接 FAIL。

```powershell
$root = '<技能目录>'
$b = [IO.File]::ReadAllBytes((Join-Path $root 'scripts\validate.ps1'))
"validateBOM=$($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)"
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\validate.ps1')
"exit=$LASTEXITCODE"
# 反向测试：只改正文参数表（100→80）必须 FAIL/exit=1，还原后 exit=0
$sk = Join-Path $root 'SKILL.md'; $v = Join-Path $root 'scripts\validate.ps1'
$enc = New-Object System.Text.UTF8Encoding($false)
$bak = [IO.File]::ReadAllText($sk, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($sk, ($bak -replace '\| min_size_for_ladder_mb \| 100 \|', '| min_size_for_ladder_mb | 80 |'), $enc)
'--- 只改参数表 ---'; powershell -NoProfile -ExecutionPolicy Bypass -File $v | Select-String 'VALIDATE|不一致'; "exit=$LASTEXITCODE"
[IO.File]::WriteAllText($sk, $bak, $enc)
'--- 还原 ---'; powershell -NoProfile -ExecutionPolicy Bypass -File $v | Select-String 'VALIDATE'; "exit=$LASTEXITCODE"
```

一次性 runner 是**生成**的，不要手改；改了 `SKILL.md` 就重生成：

```powershell
$root = '<技能目录>'
powershell -NoProfile -File (Join-Path $root 'scripts\build-runner.ps1')            # 重生成 scripts/ghdl.ps1
powershell -NoProfile -File (Join-Path $root 'scripts\build-runner.ps1') -Check     # 只比对，不同步就 exit=1
& 'D:\claude code配套\Git\bin\sh.exe' -n (Join-Path $root 'scripts\ghdl.sh')        # POSIX 侧只做语法检查
```
网络全断时用离线夹具（零下载流量），不要假装实测：

```powershell
$skill = Join-Path '<技能目录>' 'SKILL.md'
$t = [IO.File]::ReadAllText($skill, [Text.Encoding]::UTF8)
$ms = [regex]::Matches($t, '(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```')
"blocks=$($ms.Count)"
for ($i = 0; $i -lt $ms.Count; $i++) { 'block {0}: start_line={1}' -f $i, (($t.Substring(0, $ms[$i].Index)) -split "`n").Count }
$b6 = @($ms | Where-Object { $_.Groups['code'].Value -match 'SKIP_LADDER' })[0].Groups['code'].Value
function Check([bool]$c, [string]$m) { if ($c) { "[PASS] $m" } else { "[FAIL] $m" } }
$o1 = & ([scriptblock]::Create('$total=32MB;$singleKB=0;$winN=1;' + $b6)) | Out-String
Check ($o1 -match 'SKIP_LADDER') '32MB 打印 SKIP_LADDER'
Check ($o1 -match 'winN=1') '32MB 判 winN=1'
$o2 = & ([scriptblock]::Create('$total=200MB;$singleKB=4200;' + $b6)) | Out-String
Check ($o2 -match 'SKIP_LADDER') '单连接 4200KB/s 也跳过'
Check (((& ([scriptblock]::Create('$ladderMinMB=100;$total=99MB;$total -lt ($ladderMinMB * 1MB)')))) -eq $true)  '99MB 判为小资产'
Check (((& ([scriptblock]::Create('$ladderMinMB=100;$total=200MB;$total -lt ($ladderMinMB * 1MB)')))) -eq $false) '200MB 判为非小资产'
```

夹具脚本自己也要 UTF-8 with BOM 再执行；跑完删夹具目录并复跑 `validate.ps1` 到 exit=0。改完的回归闭环：抽全部围栏块按顺序点源执行（只替换占位行），第 2 步要打印实际命中的 `core`/`cfg`，输出不得出现 `FormatEntryData`/`out-lineoutput` 报错。
