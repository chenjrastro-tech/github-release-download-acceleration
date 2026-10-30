# Runner 源步骤（对应 SKILL.md 的 Steps 0–10）

> 本文件是 `scripts/ghdl.ps1` 的唯一真源：`scripts/build-runner.ps1` 按顺序取下面 11 个
> powershell 代码块拼出 runner。改逻辑改这里，改完重跑 build-runner。
> SKILL.md 只保留步骤说明与指针——6.5 万字节是正文硬上限，30KB+ 的运行时代码必须外置。

## 块 0 · 0

```powershell
$u = 'https://github.com/owner/repo/releases/download/v1.2.3/asset.zip'
$repo = ''; $tag = ''; $asset = ''
if ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/download/(?<t>[^/?#]+)/(?<a>[^/?#]+)') {
  $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t; $asset = $Matches.a
} elseif ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/]+)/releases/tag/(?<t>[^/?#]+)') {
  $repo = "$($Matches.o)/$($Matches.r)"; $tag = $Matches.t
} elseif ($u -match '^https?://github\.com/(?<o>[^/]+)/(?<r>[^/?#]+)/?$') {
  $repo = "$($Matches.o)/$($Matches.r)"
}
$direct = $false
if (-not $repo) {
  if ($u -match '^https?://') { $direct = $true; if (-not $asset) { $asset = ($u -split '[?#]')[0].Split('/')[-1] } }
  else { throw 'BAD_URL: 先把 release 直链或 tag 页地址确定下来' }
}
"repo=$repo tag=$tag asset=$asset direct=$direct"
```

## 块 1 · 1

```powershell
$ProgressPreference = 'SilentlyContinue'
$onWin = ($env:OS -eq 'Windows_NT')
$curlExe = $(if ($onWin) { 'curl.exe' } else { 'curl' })
function Test-Port([string]$h,[int]$p,[int]$ms = 600) {
  $c = New-Object Net.Sockets.TcpClient
  try { $t = $c.BeginConnect($h,$p,$null,$null); if (-not $t.AsyncWaitHandle.WaitOne($ms)) { return $false }; $c.EndConnect($t); return $true }
  catch { return $false } finally { $c.Close() }
}
$portList = 7890,7891,7897,7898,1080,10808,10809,2080,8889,20171,8080
$swP = [Diagnostics.Stopwatch]::StartNew()
$probe = @()
foreach ($p in $portList) {
  $c = New-Object Net.Sockets.TcpClient
  $probe += [pscustomobject]@{ Port = $p; Client = $c; H = $c.BeginConnect('127.0.0.1', $p, $null, $null).AsyncWaitHandle }
}
try { [void][Threading.WaitHandle]::WaitAll([Threading.WaitHandle[]]@($probe | ForEach-Object { $_.H }), 400) } catch { }
$listen = @($probe | Where-Object { $_.Client.Connected } | ForEach-Object { $_.Port })
$probe | ForEach-Object { try { $_.Client.Close() } catch { } }
$swP.Stop()
$proxyOk = $false
if ($listen.Count -gt 0) { $proxyOk = [bool](Test-NetConnection 127.0.0.1 -Port $listen[0] -InformationLevel Quiet -WarningAction SilentlyContinue) }
$sysProxy = 'n/a'
if ($onWin) {
  $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $sysProxy = "ProxyEnable=$($reg.ProxyEnable) ProxyServer=$($reg.ProxyServer)"
}
$curlOk = [bool](Get-Command $curlExe -ErrorAction SilentlyContinue)
$curlVer = $(if ($curlOk) { [string](((& $curlExe -V) -split '\s+')[1]) } else { '(none)' })
"onWin=$onWin listen=$($listen -join ',') proxyOk=$proxyOk probeSec=$([math]::Round($swP.Elapsed.TotalSeconds,2)) sysProxy=$sysProxy env=$env:HTTPS_PROXY|$env:HTTP_PROXY curl=$curlVer ok=$curlOk"
if (-not $curlOk -and -not $onWin) { throw 'NO_CURL: POSIX 没有 curl（ghdl.sh 依赖 curl），不降级' }
if (-not $curlOk) {
  # 没有 curl.exe 的 Windows（Win7 / Server 2016 / 精简镜像）：退化成 Invoke-WebRequest 单流。
  # 明确降级：不选路、不分段、不续传、拿不到 digest —— 但至少能下完并落盘。
  "IWR_FALLBACK: 没有 curl.exe，改用 Invoke-WebRequest 单流（不选路/不分段/不续传）"
  $base = $(if ($OutDir) { $OutDir } else { Join-Path $env:USERPROFILE 'Downloads' })
  if (-not $asset) { throw 'IWR_NO_ASSET: 直链里取不到文件名，请给 release 资产直链' }
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $out = Join-Path $base $asset
  $u2 = $(if ($direct) { $u } else { "https://github.com/$repo/releases/download/$tag/$asset" })
  $iw = @{ Uri = $u2; OutFile = $out; UseBasicParsing = $true; TimeoutSec = 900 }
  if ($listen.Count -gt 0) { $iw.Proxy = "http://127.0.0.1:$($listen[0])"; "IWR_PROXY: $($iw.Proxy)" }
  try { Invoke-WebRequest @iw -ErrorAction Stop | Out-Null } catch { throw "IWR_FAILED: $($_.Exception.Message)" }
  $size = (Get-Item $out).Length
  $sha = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
  "IWR_GOT: $size 字节 sha256=$sha"
  "IWR_OK: $out（没有 curl 就取不到 release digest，只保证字节落盘）"
  return
}
function Invoke-Curl([string[]]$a) {
  $o = Join-Path $env:TEMP ("cur_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
  $p = Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError "$o.err"
  if (-not $p.WaitForExit(180000)) { $p.Kill() }
  $out = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + '').Trim()
  $err = ((Get-Content "$o.err" -Raw -ErrorAction SilentlyContinue) + '').Trim()
  Remove-Item $o,"$o.err" -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{ Out = $out; Err = $err; Exit = $p.ExitCode }
}
```

## 块 2 · 2

```powershell
$coreDir = ''; $cfgDir = ''; $cand = @()
if ($onWin -and $listen.Count -eq 0) {
  $base = @()
  foreach ($d in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if ($d) { $base += @((Join-Path $d 'Clash Verge'), (Join-Path $d 'Programs\Clash Verge')) }
  }
  foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' } | ForEach-Object { $_.Name })) {
    $base += @((Join-Path $d 'Clash Verge'), (Join-Path $d 'Apps\Clash Verge'), (Join-Path $d 'Tools\Clash Verge'))
  }
  $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  if (Test-Path $sm) {
    $sh = New-Object -ComObject WScript.Shell
    $base += @(Get-ChildItem $sm -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'Clash.*Verge' } | ForEach-Object { Split-Path $sh.CreateShortcut($_.FullName).TargetPath -Parent })
  }
  $cand = @($base | Where-Object { $_ -and (Test-Path (Join-Path $_ 'verge-mihomo.exe')) } |
    Sort-Object { (Get-Item (Join-Path $_ 'verge-mihomo.exe')).LastWriteTime } -Descending)
  $coreDir = $cand | Select-Object -First 1
  $cfgDir = @("$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev", "$env:APPDATA\clash-verge",
              "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev") |
            Where-Object { Test-Path (Join-Path $_ 'clash-verge.yaml') } | Select-Object -First 1
} elseif ($listen.Count -gt 0) { 'KERNEL_SCAN_SKIPPED: 已有代理在监听，跳过全盘/开始菜单扫描' }
"core=$coreDir cfg=$cfgDir candidates=$($cand.Count)"
```

## 块 3 · 3

```powershell
$total = [int64]0; $want = ''; $aid = [int64]0; $api = 'skip'
$hdr = @('-H','User-Agent: dsh-agent','-H','Accept: application/vnd.github+json')
if ($env:GITHUB_TOKEN) { $hdr += @('-H', "Authorization: Bearer $($env:GITHUB_TOKEN)") }
if ($direct) {
  $h = Invoke-Curl @('-sS','-L','-m','20','-A','dsh','-r','0-0','-D','-','-o','NUL',$u)
  if ($h.Out -match '(?im)content-range:\s*bytes\s+\d+-\d+/(\d+)') { $total = [int64]$Matches[1] }
  $api = 'direct'
} else {
  $metaF = Join-Path $env:TEMP ("meta_{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0,6))
  $apiUrl = $(if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" })
  $code = (& $curlExe -sS -m 40 @hdr -o $metaF -w '%{http_code}' $apiUrl 2> "$metaF.err")
  $body = ((Get-Content $metaF -Raw -ErrorAction SilentlyContinue) + '')
  $apiErr = ((Get-Content "$metaF.err" -Raw -ErrorAction SilentlyContinue) + '').Trim()
  Remove-Item $metaF,"$metaF.err" -Force -ErrorAction SilentlyContinue
  "api=$code err=$apiErr bytes=$($body.Length)"
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
      throw ("ASSET_NOT_FOUND: '{0}' 不在 {1}@{2}。真实候选：`n{3}`n最接近 '{4}'；确认后给完整直链，我不会静默换名。" -f $asset, $repo, $tag, $list, $near)
    }
    $total = [int64]$a.size; $aid = [int64]$a.id
    $want = $(if ($a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLower() } else { '' })
    "picked asset=$($a.name) size=$total assetId=$aid digest=$(if ($want) { 'sha256' } else { 'none' })"
  } else {
    if (-not $asset) { throw "ASSET_UNVERIFIED: API code=$code 且没给具体资产名，请给完整资产直链" }
    if ($code -eq '403') { 'API_RATE_LIMITED: 可设 GITHUB_TOKEN 把限额从 60/h 提到 5000/h；本轮用已知 total/digest 继续，缺 total 用 Content-Range 反推' }
    else { 'ASSET_UNVERIFIED: API 取不到元数据（被墙/超时），按给定资产名继续，缺 digest 只校验字节数' }
    if ($total -le 0 -and $tag) {
      $h = Invoke-Curl @('-sS','-L','-m','20','-A','dsh','-r','0-0','-D','-','-o','NUL',"https://github.com/$repo/releases/download/$tag/$asset")
      if ($h.Out -match '(?im)content-range:\s*bytes\s+\d+-\d+/(\d+)') { $total = [int64]$Matches[1] }
      "range_probe curlExit=$($h.Exit) total=$total"
    }
  }
  $api = $code
}
"asset=$asset total=$total want=$want api=$api assetId=$aid"
```

## 块 4 · 4

```powershell
if (-not $direct) { $u = "https://github.com/$repo/releases/download/$tag/$asset" }
$mirrors = @()
if (-not $direct) { $mirrors = @('https://ghfast.top','https://ghproxy.net','https://gh-proxy.com','https://hk.gh-proxy.com','https://github.moeyy.xyz','https://gh.llkk.cc','https://ghproxy.cc') }
$minBytes = $(if ($direct) { 1 } else { 524288 })
$hostName = ''; try { $hostName = ([uri]$u).Host } catch { }
$isLocal = ($hostName -match '^(?i)(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
if ($isLocal) { "LOCAL_TARGET: 目标是本机/内网地址（$hostName），跳过代理与公共镜像——它们只会把请求绕远，还可能在中途断掉；直接走原地址" }
$probes = @()
if (-not $isLocal -and $listen.Count -gt 0) { $probes += [pscustomobject]@{ Name = "A 代理 :$($listen[0])"; Url = $u; Proxy = "http://127.0.0.1:$($listen[0])" } }
if (-not $isLocal) { $probes += @($mirrors | ForEach-Object { [pscustomobject]@{ Name = "C 镜像 $_"; Url = "$_/$u"; Proxy = $null } }) }
$probes += [pscustomobject]@{ Name = 'D 直连'; Url = $u; Proxy = $null }
$pdir = Join-Path $env:TEMP ("probe_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory $pdir -Force | Out-Null
$jobs = @(foreach ($p in $probes) {
  $f = Join-Path $pdir (($p.Name -replace '[^\w]','_') + '.out')
  $a = @('-sS','-L','--connect-timeout','5','-m','8','-r','0-1048575','-A','Mozilla/5.0','-o','NUL','-w','%{http_code}|%{size_download}|%{speed_download}')
  if ($p.Proxy) { $a += @('--proxy', $p.Proxy) } else { $a += @('--noproxy', '*') }
  $a += $p.Url
  [pscustomobject]@{ Name = $p.Name; Url = $p.Url; Proxy = $p.Proxy; Log = $f
    Proc = (Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $f -RedirectStandardError ($f -replace '\.out$','.err')) }
})
$jobs.Proc | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
$results = @(foreach ($j in $jobs) {
  $o = (((Get-Content $j.Log -Raw -ErrorAction SilentlyContinue) + '').Trim()) -split '\|'
  if ($o.Count -lt 3) { $o = @('000','0','0') }
  [pscustomobject]@{ Name = $j.Name; Url = $j.Url; Proxy = $j.Proxy; Code = $o[0]
    Bytes = $(if ($o[1] -match '^\d+$') { [int64]$o[1] } else { 0 })
    KBps  = $(if ($o[2] -match '^[\d.]+$') { [int][math]::Round([double]$o[2] / 1KB, 0) } else { 0 }) }
})
$results | Sort-Object @{Expression = { $_.Bytes -ge 524288 }; Descending = $true}, @{Expression = 'KBps'; Descending = $true} |
  ForEach-Object { '{0,-30} code={1} bytes={2,9} KBps={3,6}' -f $_.Name, $_.Code, $_.Bytes, $_.KBps }
$cand2 = @($results | Where-Object { $_.Code -in @('200','206') -and $_.Bytes -ge $minBytes } | Sort-Object KBps -Descending)
if ($cand2.Count -eq 0) {
  throw ("NO_ROUTE: 所有路线都没拿到数据`n" + (($results | ForEach-Object { '{0} code={1} bytes={2} KBps={3}' -f $_.Name, $_.Code, $_.Bytes, $_.KBps }) -join "`n"))
}
$route = $cand2[0]; $winUrl = $route.Url; $winProxy = $route.Proxy
Remove-Item $pdir -Recurse -Force -ErrorAction SilentlyContinue
"route=$($route.Name) KBps=$($route.KBps) slow=$($route.KBps -lt 100)"
```

## 块 5 · 5

```powershell
$corePid = $null
$up = [bool](Test-Port '127.0.0.1' 7897)
if ($up -and -not $isLocal) { 'PORT_7897_ALREADY_LISTENING: 用现成的，收尾不要停' }
elseif ($up -and $isLocal) { 'LOCAL_TARGET: 现有代理对本地地址无用，本轮单流/分段都走直连' }
elseif ($coreDir -and $cfgDir -and (Test-Path (Join-Path $coreDir 'verge-mihomo.exe'))) {
  $core = Start-Process -FilePath (Join-Path $coreDir 'verge-mihomo.exe') -ArgumentList @('-d',$cfgDir,'-f',(Join-Path $cfgDir 'clash-verge.yaml')) -WindowStyle Hidden -PassThru
  $corePid = $core.Id
  for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Milliseconds 700; if (Test-Port '127.0.0.1' 7897) { break } }
} else { 'NO_CLASH_CORE: 没找到内核/配置，跳过 B 路线' }
$up = [bool](Test-Port '127.0.0.1' 7897)
$bKB = 0
if ($total -gt 0 -and $total -lt 100MB) {
  'SINGLE_KB_SKIPPED: 资产 <100MB，跳过 8MB 单连接测速（反正走单流）'
} elseif ($up) {
  $need = $(if ($total -gt 0) { [math]::Min([int64]8388608, $total) } else { [int64]8388608 })
  $br = Invoke-Curl @('-sS','-L','--connect-timeout','8','-m','20','-r','0-8388607','--proxy','http://127.0.0.1:7897','-A','Mozilla/5.0','-o','NUL','-w','%{http_code}|%{size_download}|%{speed_download}',$u)
  $b = $br.Out -split '\|'
  $bCode = $(if ($b.Count -ge 3) { $b[0] } else { '000' })
  $bGot  = $(if ($b.Count -ge 3 -and $b[1] -match '^\d+$') { [int64]$b[1] } else { 0 })
  $bKB   = $(if ($b.Count -ge 3 -and $b[2] -match '^[\d.]+$') { [int][math]::Round([double]$b[2] / 1KB, 0) } else { 0 })
  "B 本机内核 code=$bCode got=$bGot KBps=$bKB"
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

## 块 6 · 6

```powershell
function Test-Ladder([int]$n,[string]$url,[string]$proxy,[int64]$total = 0,[int]$sec = 4) {
  $per = $(if ($total -gt 0) { [int64][math]::Floor($total / $n) } else { [int64][math]::Floor(64MB / $n) })
  $dir = Join-Path $env:TEMP ("ladder_{0}_{1}" -f $n, [guid]::NewGuid().ToString('N').Substring(0,4))
  New-Item -ItemType Directory $dir -Force | Out-Null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ps = @(1..$n | ForEach-Object {
    $i = $_; $s = [int64](($i - 1) * $per)
    $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-r',"$s-",'-o','NUL','-m',"$sec",'-w','%{http_code}|%{size_download}|%{speed_download}')
    if ($proxy) { $a += @('--proxy',$proxy) } else { $a += @('--noproxy','*') }
    $a += $url
    Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $dir "p$i.out") -RedirectStandardError (Join-Path $dir "p$i.err")
  })
  $ps | Wait-Process -Timeout ($sec + 30) -ErrorAction SilentlyContinue
  $ps | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue
  $sw.Stop(); $bytes = 0; $ok = 0
  Get-ChildItem $dir -Filter 'p*.out' -ErrorAction SilentlyContinue | ForEach-Object {
    $o = (((Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) + '').Trim()) -split '\|'
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
$runs = @()
if ($ForceLadder -or ($bigEnough -and $throttled)) {
  foreach ($rep in 1..3) { foreach ($n in $rungs) { $runs += @(Test-Ladder $n $winUrl $winProxy $total 4) } }
} else {
  "SKIP_LADDER: total=$([math]::Round($total/1MB,1))MB singleKB=$singleKB（门槛 ${ladderMinMB}MB/${fastKB}KB/s）-> 单流，省约 20-26s"
}
$winN = 1; $ratio = 1
if ($runs.Count -gt 0) {
  $agg = @(foreach ($n in $rungs) {
    $s = @($runs | Where-Object { $_.N -eq $n }); if ($s.Count -eq 0) { continue }
    $v = @($s | ForEach-Object { [int]$_.KBps } | Sort-Object); $mid = [int][math]::Floor($v.Count / 2)
    $med = $(if (($v.Count % 2) -eq 1) { $v[$mid] } else { [int](($v[$mid - 1] + $v[$mid]) / 2) })
    [pscustomobject]@{ N = $n; Full = ($s | Measure-Object Full -Minimum).Minimum; Med = $med; Min = $v[0]; Max = $v[$v.Count - 1] }
  })
  $agg | ForEach-Object { '{0,2} 段: 完成 {1}/{0} 中位 {2,6} KB/s min-max {3}-{4}' -f $_.N, $_.Full, $_.Med, $_.Min, $_.Max }
  $one = $agg | Where-Object { $_.N -eq 1 } | Select-Object -First 1
  $best = @($agg | Where-Object { $_.Full -ge $_.N -and $_.N -gt 1 } | Sort-Object Med -Descending)[0]
  if ($best -and (-not $one -or $best.Med -ge (1.25 * $one.Med))) { $winN = $best.N; $ratio = [math]::Round($best.Med / [math]::Max($one.Med, 1), 2) }
  "LADDER_DONE: rungs=$($rungs -join '/') passes=3 winN=$winN ratio=${ratio}x"
}
if ($Parts -gt 0) {
  if ($total -gt 0) { $winN = [int]$Parts }   # -Parts 的含义是「段数」，第 7 步据此切分并回显 PARTS_OVERRIDE
  else { "PARTS_IGNORED: 总字节数未知（API 限流或不可达），无法切 range，改走单流"; $winN = 1 }
}
```

## 块 7 · 7

```powershell
$ErrorActionPreference = 'Stop'
$vc = $(if ($curlVer -match '^(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" } else { [version]'0.0' })
$retry = @('--retry','3','--retry-delay','2')
if ($vc -ge [version]'7.71') { $retry += '--retry-all-errors' } else { "RETRY_DEGRADED: curl $curlVer < 7.71，只用 --retry 3 --retry-delay 2" }
$base = $(if ($OutDir) { $OutDir } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' })
$safe = ($asset -replace '[\\/:*?"<>|]', '_')
if (-not $safe) { $safe = 'download' }
# 分片目录按资产隔离：同一 -OutDir 并发两个文件时，分片不会互相覆盖，孤儿清理也只扫自己那份
$dir = Join-Path $base ($safe + '.parts')
$out = Join-Path $base $asset
New-Item -ItemType Directory $base -Force | Out-Null
if ($dir -match ' ') { throw "SPACE_IN_PATH: $dir 含空格，5.1 的 Start-Process 会拆坏 -o" }
$assetUrl = $(if ($aid -gt 0) { "https://api.github.com/repos/$repo/releases/assets/$aid" } else { $winUrl })

# 孤儿收尾：上次被强杀留下的 curl 可能还在写同一目录（只认本目录）
if ($onWin) {
  @(Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($dir) } | ForEach-Object { [int]$_.ProcessId }) |
    ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
}
# 幂等：目标已存在且字节/哈希都对 → 直接跳过
$verifiedBefore = $false
if ((Test-Path $out) -and -not $ForceClean) {
  $osz = (Get-Item $out).Length
  if ($total -gt 0 -and $osz -eq $total) {
    $verifiedBefore = $(if ($want) { (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower() -eq $want } else { $true })
  }
  if ($verifiedBefore) { "ALREADY_DONE: $out 已是完整文件（$osz 字节），跳过下载" }
}
if ($ForceClean) {
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $out -Force -ErrorAction SilentlyContinue
  'FORCE_CLEAN: 已删旧分片与旧输出，强制重下'
}
$engine = 'single'; $nseg = 1; $chunk = [int64]0; $repairs = 0; $stalls = 0; $swE = $null
if ($verifiedBefore) { $engine = 'cached' }
elseif ($total -le 0 -or $total -lt ($ladderMinMB * 1MB) -or $winN -le 1) {
  $singleResume = @()
  if ((Test-Path $out) -and $total -gt 0 -and (Get-Item $out).Length -lt $total) {
    $singleResume = @('-C','-'); "SINGLE_RESUME: 从 $((Get-Item $out).Length) 字节继续"
  }
  $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-H','Accept: application/octet-stream','-o',$out,'-D',"$out.headers",'-m','1800','-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}') + $singleResume + $retry
  if ($winProxy) { $a += @('--proxy', $winProxy) } else { $a += @('--noproxy', '*') }
  $a += $assetUrl
  $st = (& $curlExe @a 2> "$out.err" | Out-String).Trim()
  "SINGLE exit=$LASTEXITCODE $st"
  if ($LASTEXITCODE -ne 0) { throw "SINGLE_FAILED: exit=$LASTEXITCODE $st $((Get-Content "$out.err" -Raw -ErrorAction SilentlyContinue))" }
  Remove-Item "$out.err" -Force -ErrorAction SilentlyContinue
  # -D 会把重定向链每一跳的响应头都写进来，302 那跳是 Content-Length: 0，必须取最后一个
  if (-not $singleResume -and (Test-Path "$out.headers")) {
    $cls = [regex]::Matches([IO.File]::ReadAllText("$out.headers"), '(?im)^content-length:\s*(\d+)\s*$')
    if ($cls.Count -gt 0 -and $total -gt 0) {
      $declared = [int64]$cls[$cls.Count - 1].Groups[1].Value
      if ($declared -gt 0 -and $declared -ne $total) { throw "SIZE_MISMATCH: Content-Length=$declared 与 total=$total 不一致（下载被截断或换过文件），文件留在 $out" }
      "content_length_ok=$declared（取重定向链最后一个）"
    }
  }
  Remove-Item "$out.headers" -Force -ErrorAction SilentlyContinue
  if ($total -le 0) { $total = (Get-Item $out).Length; "total_from_download=$total" }
} else {
  $root = ([IO.Path]::GetPathRoot($dir)).TrimEnd('\').TrimEnd(':')
  $freeGB = [math]::Round((Get-PSDrive $root).Free / 1GB, 1); $needGB = [math]::Round(($total * 2 / 1GB), 1)
  if ($freeGB -lt $needGB) { throw "SPACE_LOW: free=${freeGB}GB need=${needGB}GB" }
  $poolAll = @($results | Where-Object { $_.Code -eq '206' -and $_.Bytes -ge 1048576 } | Sort-Object KBps -Descending)
  $pool = $(if ($poolAll.Count -gt 0) { @($poolAll | Select-Object -First 3) } else { @($route) })
  $pool = @($pool)
  if ($pool.Count -eq 0) { throw "POOL_EMPTY: 没有可用路线（route=$($route.Name) code=$($route.Code)），先看第 4 步的 route 表" }
  $poolN = [math]::Max(1, $pool.Count)
  $perKB = [math]::Max([int]$singleKB, 512)
  $chunk = [int64]($perKB * 1024 * 4)                    # 每段约 4 秒的活
  if ($chunk -lt 2MB) { $chunk = 2MB } elseif ($chunk -gt 24MB) { $chunk = 24MB }
  $nseg = [int][math]::Ceiling($total / [double]$chunk)
  if ($nseg -gt 128) { $nseg = 128 }
  $chunk = [int64][math]::Ceiling($total / [double]$nseg)
  $workers = [math]::Min([math]::Max([int]$winN, 2), 16)
  if ($Parts -gt 0) {
    # -Parts 是「段数」：显式切分，别让「每段 4 秒的活」把段数压回个位数（诊断/复现场景要可复现）
    $nseg = [math]::Min([int]$Parts, 128)
    $chunk = [int64][math]::Ceiling($total / [double]$nseg)
    $workers = [math]::Min([math]::Max([int]$Parts, 2), 16)
    "PARTS_OVERRIDE: nseg=$nseg chunk=$([math]::Round($chunk/1MB,1))MB workers=$workers（手动指定段数）"
  }
  $manifest = Join-Path $dir 'manifest.json'; $resumePlan = $false
  if ((Test-Path $manifest) -and -not $ForceClean) {
    try {
      $mf = Get-Content $manifest -Raw | ConvertFrom-Json
      if ([int64]$mf.total -eq $total -and $mf.url -eq $winUrl) {
        $chunk = [int64]$mf.chunk; $nseg = [int]$mf.nseg; $resumePlan = $true
        $had = @(Get-ChildItem $dir -Filter 'p*.bin' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        "RESUME_PLAN: 沿用 nseg=$nseg chunk=$([math]::Round($chunk/1MB,1))MB 已有 $([math]::Round($had/1MB,1))MB"
      }
    } catch { 'RESUME_PLAN_IGNORED: manifest 读不懂，重新规划' }
  }
  if (-not $resumePlan) {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $dir -Force | Out-Null
    @{ total = $total; chunk = $chunk; nseg = $nseg; url = $winUrl; asset = $asset } | ConvertTo-Json -Compress | Set-Content -LiteralPath $manifest -Encoding ASCII
  }
  $poolNames = ($pool | ForEach-Object { $_.Name }) -join '+'
  "PLAN: nseg=$nseg chunk=$([math]::Round($chunk/1MB,1))MB workers=$workers pool=$poolNames"
  $segFile = { param($i) Join-Path $dir ("p{0:000}.bin" -f $i) }
  $queue = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $nseg; $i++) {
    $s = [int64]($i * $chunk); $e = $(if ($i -eq $nseg - 1) { $total - 1 } else { $s + $chunk - 1 })
    $f = & $segFile $i
    $have = $(if (Test-Path $f) { [int64](Get-Item $f).Length } else { [int64]0 })
    if ($have -lt ($e - $s + 1)) { [void]$queue.Add([pscustomobject]@{ Index = $i; Start = $s; End = $e; Route = ($i % $poolN); Tries = 0 }) }
  }
  $running = @{}; $jid = 0; $swE = [Diagnostics.Stopwatch]::StartNew()
  $tick = 0; $lastDone = [int64]0; $lastT = 0.0
  while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $workers -and $queue.Count -gt 0) {
      $seg = $queue[0]; $queue.RemoveAt(0); $jid++
      $f = & $segFile $seg.Index
      $have = $(if (Test-Path $f) { [int64](Get-Item $f).Length } else { [int64]0 })
      $rs = [int64]($seg.Start + $have)
      if ($rs -gt $seg.End) { continue }
      $tgt = $(if ($have -eq 0) { $f } else { "$f.resume" })     # 续写只写 .resume，完成后合并
      $rt = $pool[$seg.Route % $poolN]
      $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-r',"$rs-$($seg.End)",'-o',$tgt,'-m','1800') + $retry
      if ($rt.Proxy) { $a += @('--proxy', $rt.Proxy) } else { $a += @('--noproxy', '*') }
      $a += $rt.Url
      $lg = Join-Path $dir ("p{0:000}.log" -f $seg.Index)
      $pr = Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $lg -RedirectStandardError ($lg -replace '\.log$', '.err')
      $running[$jid] = [pscustomobject]@{ Seg = $seg; File = $f; Resume = $(if ($tgt -eq $f) { $null } else { $tgt }); Proc = $pr; Last = $have; Still = 0 }
    }
    Start-Sleep -Milliseconds 500
    $tick++
    if ($tick % 6 -eq 0) {
      $done = [int64]0
      Get-ChildItem $dir -Filter 'p*.bin' -ErrorAction SilentlyContinue | ForEach-Object { $done += $_.Length }
      $now = $swE.Elapsed.TotalSeconds; $kbps = 0
      if ($now -gt $lastT) { $kbps = [math]::Round((($done - $lastDone) / 1024) / ($now - $lastT)) }
      $lastDone = $done; $lastT = $now
      "progress=$([math]::Round($done/1MB,1))MB/$([math]::Round($total/1MB,1))MB ($([math]::Round(100.0*$done/$total))%) running=$($running.Count) rate=${kbps}KB/s"
    }
    foreach ($k in @($running.Keys)) {
      $job = $running[$k]; $stalled = $false
      if (-not $job.Proc.HasExited) {
        $cur = $(if (Test-Path $job.File) { [int64](Get-Item $job.File).Length } else { [int64]0 }) + $(if ($job.Resume -and (Test-Path $job.Resume)) { [int64](Get-Item $job.Resume).Length } else { [int64]0 })
        if ($cur -le $job.Last) { $job.Still++ } else { $job.Still = 0 }
        $job.Last = $cur
        if ($job.Still -lt 12) { continue }        # 6 秒没长进才算卡住（4 秒会误杀慢启动的连接）
        Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $job.Proc.Id -Timeout 5 -ErrorAction SilentlyContinue
        $stalled = $true
      }
      if ($job.Resume -and (Test-Path $job.Resume)) {
        $tries = 0
        while ($tries -lt 10) {
          try {
            $fs = [IO.File]::Open($job.File, [IO.FileMode]::Append, [IO.FileAccess]::Write)
            $ri = [IO.File]::OpenRead($job.Resume); $ri.CopyTo($fs); $ri.Dispose(); $fs.Dispose(); break
          } catch { Start-Sleep -Milliseconds 300; $tries++; if ($tries -ge 10) { throw "RESUME_MERGE_FAILED: $($job.Resume) 一直被占用" } }
        }
        Remove-Item $job.Resume -Force -ErrorAction SilentlyContinue
      }
      $running.Remove($k)
      if ($stalled) { $stalls++ }
      $have = $(if (Test-Path $job.File) { [int64](Get-Item $job.File).Length } else { [int64]0 })
      $need = $job.Seg.End - $job.Seg.Start + 1
      if ($have -lt $need) {                     # 0 字节/短缺：只补这一段，不整包重来
        $repairs++
        if ($job.Seg.Tries -ge 5) { throw "SEGMENT_SHORT: p$($job.Seg.Index) have=$have need=$need（换 5 条路线仍不够）" }
        $job.Seg.Tries++; $job.Seg.Route++; [void]$queue.Add($job.Seg)
      }
    }
  }
  $swE.Stop(); $engine = 'segments'
  "engine_done=segments nseg=$nseg stalls=$stalls repairs=$repairs elapsed=$([math]::Round($swE.Elapsed.TotalSeconds,1))s"
}
```

## 块 8 · 8

```powershell
if ($engine -eq 'segments' -and $nseg -gt 1) {
  $errs = @(); $sum = 0
  for ($i = 0; $i -lt $nseg; $i++) {
    $s = [int64]($i * $chunk)
    $e = $(if ($i -eq $nseg - 1) { $total - 1 } else { $s + $chunk - 1 })
    $need = $e - $s + 1
    $p = Join-Path $dir ("p{0:000}.bin" -f $i)
    if (-not (Test-Path $p)) { $errs += "p$i 缺失(期望 $need)"; continue }
    $len = (Get-Item $p).Length
    if ($len -ne $need) { $errs += ("p{0} 期望 {1} 实际 {2}" -f $i, $need, $len); continue }
    $sum += $len
  }
  if ($errs.Count -gt 0) { throw ("SEGMENT_SIZE_MISMATCH: " + ($errs -join '; ') + "（分片留在 $dir，重跑会续传）") }
  if ($sum -ne $total) { throw "PARTS_MISMATCH: sum=$sum total=$total（分片留在 $dir）" }
  "partsBytes=$sum total=$total ok=True"
  $fs = [IO.File]::Create($out)
  for ($i = 0; $i -lt $nseg; $i++) { $ri = [IO.File]::OpenRead((Join-Path $dir ("p{0:000}.bin" -f $i))); $ri.CopyTo($fs); $ri.Dispose() }
  $fs.Dispose()
  "assembled=$((Get-Item $out).Length)"
} else { "single=$((Get-Item $out).Length)（单流/命中缓存，无需拼装）" }
```

## 块 9 · 9

```powershell
$size = (Get-Item $out).Length
$sizeOk = $(if ($total -gt 0) { $size -eq $total } else { $size -gt 0 })
$verifiedOk = $false
"size=$size expect=$(if ($total -gt 0) { "$total" } else { 'unknown（只能证明下完了，不能证明和远端一致）' }) sizeOk=$sizeOk"
if ($want) {
  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower()
  "sha256=$got"
  "digest=sha256:$want"
  if ($sizeOk -and $got -eq $want) { $verifiedOk = $true; 'DOWNLOAD_VERIFIED_OK' } else { 'DOWNLOAD_VERIFY_FAILED' }
} else {
  'NO_DIGEST: 该 release 未提供 sha256，只能保证字节数一致'
  if ($sizeOk) { $verifiedOk = $true; 'DOWNLOAD_SIZE_OK_NO_DIGEST' } else { 'DOWNLOAD_VERIFY_FAILED' }
}
# 冒烟："文件在" ≠ "文件能用"；原生 stderr 一律 *> 文件，不要 2>&1
$smoke = 'SKIP'
if ($verifiedOk -and $asset -match '\.exe$') {
  $verF = Join-Path $env:TEMP ("ver_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
  $null = & $out --version *> $verF
  $smoke = ((((Get-Content $verF -Raw -ErrorAction SilentlyContinue) + '').Trim()) -split "`n")[0].Trim()
  Remove-Item $verF -Force -ErrorAction SilentlyContinue
} elseif ($verifiedOk -and $asset -match '\.zip$') {
  $tmp = Join-Path $env:TEMP ("smoke_{0}" -f [guid]::NewGuid().ToString('N').Substring(0,6))
  try { Expand-Archive -LiteralPath $out -DestinationPath $tmp -Force; $smoke = "unzip_ok files=$(@(Get-ChildItem $tmp -Recurse -File).Count)" }
  catch { $smoke = "SMOKE_FAILED: $($_.Exception.Message)" }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
} elseif ($verifiedOk -and $asset -match '\.(tar\.gz|tgz)$') {
  try { & tar.exe -tf $out | Out-Null; $smoke = 'tar_list_ok' } catch { $smoke = "SMOKE_FAILED: $($_.Exception.Message)" }
}
"smoke=$smoke"
$elapsedSec = $(if ($swE) { [math]::Round($swE.Elapsed.TotalSeconds, 1) } else { 0 })
$avgMBs = $(if ($elapsedSec -gt 0) { [math]::Round(($size / 1MB) / $elapsedSec, 2) } else { 0 })
```

## 块 10 · 10

```powershell
if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }
if ($verifiedOk -and -not $KeepParts) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
elseif (Test-Path $dir) { "PARTS_KEPT: 分片保留在 $dir（校验未通过或 -KeepParts；重跑会续传，-ForceClean 可清掉重下）" }
Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'cur_*' -or $_.Name -like 'raw_*' -or $_.Name -like 'ver_*' -or $_.Name -like 'smoke_*' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
"7897=$([bool](Test-Port '127.0.0.1' 7897)) corePid=$corePid"
if ($onWin) { $null = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable }
```
