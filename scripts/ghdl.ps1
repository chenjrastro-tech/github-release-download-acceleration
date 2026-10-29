<#
  ghdl.ps1 —— GitHub Release 大资产下载（一次性 runner）
  由 scripts/build-runner.ps1 从 SKILL.md 的 0-11 步代码块自动生成，请勿手改：
  想改逻辑就改 SKILL.md，然后重跑  powershell -NoProfile -File scripts\build-runner.ps1

  用法：
    powershell -NoProfile -File scripts\ghdl.ps1 -Url 'https://github.com/owner/repo/releases/download/v1.2.3/a.zip'
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<release 页地址>' -OutDir 'D:\Downloads'
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -ForceLadder     # 强制做单流 vs 多段对照
    powershell -NoProfile -File scripts\ghdl.ps1 -Url '<...>' -Parts 16          # 手动指定并发段数（诊断/复现用）

  退出码：0=成功；1=流程内失败（看输出里的 CODE: 前缀）；2=参数错误
  输出约定：关键结论行以 DOWNLOAD_ / NO_ROUTE / ASSET_ / SKIP_LADDER / route= / parts= 开头，便于 agent 解析。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Url,
  [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
  [switch]$ForceLadder,
  [int]$Parts = 0
)

$ErrorActionPreference = 'Stop'
$u = $Url
$ForceLadderSwitch = $ForceLadder.IsPresent
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
$ForceLadder = [bool]$ForceLadderSwitch
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
if ($Parts -gt 0) { $winN = [int]$Parts; "PARTS_OVERRIDE: winN=$winN（手动指定并发段数）" }

$ErrorActionPreference = 'Stop'
$parts = $winN
if (-not $parts) { $parts = 1 }
$vc = $(if ($curlVer -match '^(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" } else { [version]'0.0' })
$retry = @('--retry','3','--retry-delay','2')
if ($vc -ge [version]'7.71') { $retry += '--retry-all-errors' } else { "RETRY_DEGRADED: curl $curlVer < 7.71，只用 --retry 3 --retry-delay 2" }
$base = $OutDir
$dir  = Join-Path $base '_dl_parts'
$out  = Join-Path $base $asset
New-Item -ItemType Directory $base -Force | Out-Null
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

if ($parts -gt 1) {
  $before = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  Start-Sleep -Seconds 45
  $after = (Get-ChildItem $dir -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  "delta=$([math]::Round(($after-$before)/1MB,1))MB/45s = $([math]::Round((($after-$before)/1KB)/45,0)) KB/s total=$([math]::Round($after/1MB,1))MB"
  Get-ChildItem $dir -Filter 'p*.bin' | Sort-Object Length | ForEach-Object { '{0,-8} {1,12} {2,7:N1} MB' -f $_.Name, $_.Length, ($_.Length / 1MB) }
  # 判定为 0 时才执行：$curlPids | Stop-Process -Force; 清分片; 改 $parts; 重跑第 7 步
}

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

if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }
$curlPids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'cur_*' -or $_.Name -like 'raw_*' -or $_.Name -like 'ghdl_*' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
"7897=$([bool](Test-Port '127.0.0.1' 7897)) corePid=$corePid"
if ($onWin) { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable }
