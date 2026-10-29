<#
  ghdl.ps1 —— GitHub Release 大资产下载（一次性 runner）
  由 scripts/build-runner.ps1 从 SKILL.md 的 0-11 步代码块自动生成，请勿手改：
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
  [Parameter(Mandatory = $true, Position = 0)][string]$Url,
  [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'),
  [switch]$ForceLadder,
  [switch]$ForceClean,
  [switch]$KeepParts,
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
$direct = $false
if (-not $repo) {
  # 不是 github.com：当作任意直链（自建 CDN / GitLab / 内网制品库都能用），只做字节校验
  if ($u -match '^https?://') { $direct = $true; if (-not $asset) { $asset = ($u -split '[?#]')[0].Split('/')[-1] } }
  else { throw 'BAD_URL: 先把 release 直链或 tag 页地址确定下来' }
}
"repo=$repo tag=$tag asset=$asset direct=$direct"

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

$total = [int64]0; $want = ''; $api = 'skip'
if ($direct) {
  # 没有 GitHub API 可问：用 1 字节 range 的 Content-Range 反推总长，拿不到就按未知处理（后面走单流）
  $h = Invoke-Curl @('-sS','-L','-m','20','-A','dsh','-r','0-0','-D','-','-o','NUL',$u)
  if ($h.Out -match '(?im)content-range:\s*bytes\s+\d+-\d+/(\d+)') { $total = [int64]$Matches[1] }
  $api = 'direct'
} else {
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
$api = $code
}
"asset=$asset total=$total want=$want api=$api digest=$(if ($want) { 'sha256' } else { 'none' })"

if (-not $direct) { $u = "https://github.com/$repo/releases/download/$tag/$asset" }
# 直链模式没有 GitHub 域名可拼镜像，空数组让下面的镜像探测自然跳过
$mirrors = @()
if (-not $direct) { $mirrors = @('https://ghfast.top', 'https://ghproxy.net', 'https://gh-proxy.com', 'https://github.moeyy.xyz', 'https://gh.llkk.cc', 'https://ghproxy.cc') }
# 直链可能就是个小文件，不拿 512KB 卡它
$minBytes = $(if ($direct) { 1 } else { 524288 })
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
$cand2 = @($results | Where-Object { $_.Code -in @('200','206') -and $_.Bytes -ge $minBytes } | Sort-Object KBps -Descending)
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
  "SKIP_LADDER: total=$(if ($total -gt 0) { "$([math]::Round($total/1MB,1))MB" } else { 'unknown' }) singleKB=$singleKB (门槛 ${ladderMinMB}MB / ${fastKB}KB/s) -> 单流，省约 20-26s"
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

$ErrorActionPreference = 'Stop'
$parts = $winN
if (-not $parts) { $parts = 1 }
$vc = $(if ($curlVer -match '^(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" } else { [version]'0.0' })
$retry = @('--retry', '3', '--retry-delay', '2')
if ($vc -ge [version]'7.71') { $retry += '--retry-all-errors' } else { "RETRY_DEGRADED: curl $curlVer < 7.71，只用 --retry 3 --retry-delay 2" }
$base = $OutDir
$dir = Join-Path $base '_dl_parts'
$out = Join-Path $base $asset
New-Item -ItemType Directory $base -Force | Out-Null

# 0) 孤儿收尾：上次被强杀时留下的 curl 可能还在写同一目录，先清掉，绝不允许两个进程写同一分片
$orphans = @()
if ($onWin) {
  $orphans = @(Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($dir) -or $_.CommandLine.Contains($out)) } |
    ForEach-Object { [int]$_.ProcessId })
} else {
  $orphans = @(Get-Process curl -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}
if ($orphans.Count -gt 0) {
  $orphans | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
  "ORPHANS_KILLED: $($orphans.Count) 个残留 curl 正在写同一目录（pid=$($orphans -join ',')），已停掉再开工"
}

# 1) 幂等：目标已存在且字节/哈希都对 → 直接跳过（重跑不重复下载）
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
  "FORCE_CLEAN: 已删旧分片与旧输出，强制重下"
}

if ($Parts -gt 0 -and $winN -gt 1 -and ($total -le 0 -or $total -lt ($ladderMinMB * 1MB))) {
  "PARTS_IGNORED: 资产 $([math]::Round($total/1MB,1))MB（闸值 ${ladderMinMB}MB）或总字节数未知，分段只会更慢，走单流"
  $winN = 1; $parts = 1
}
$engine = 'single'; $workers = 0; $segCount = 0; $stolen = 0; $repairs = 0
if ($verifiedBefore) {
  $engine = 'cached'; $parts = 1
} elseif ($total -le 0 -or $total -lt ($ladderMinMB * 1MB) -or $parts -le 1) {
  # 单流也能续：有半截文件且服务器支持 Range 时用 -C - 接着下，而不是从头覆盖
  $singleResume = @()
  if ((Test-Path $out) -and $total -gt 0 -and (Get-Item $out).Length -lt $total) {
    $singleResume = @('-C','-'); "SINGLE_RESUME: 从 $((Get-Item $out).Length) 字节继续"
  }
  $a = @('-sS','-L','--fail','--connect-timeout','10','-A','Mozilla/5.0','-o',$out,'-D',"$out.headers",'-m','1800','-w','code=%{http_code}|got=%{size_download}|speed=%{speed_download}|t=%{time_total}') + $singleResume + $retry
  if ($winProxy) { $a += @('--proxy', $winProxy) }
  $a += $winUrl
  $st = (& $curlExe @a | Out-String).Trim()
  "SINGLE exit=$LASTEXITCODE $st"
  if ($LASTEXITCODE -ne 0) { throw "SINGLE_FAILED: exit=$LASTEXITCODE $st" }
  # 三方差一即失败：远端声明的 Content-Length 必须等于 total（续传时 Content-Length 只剩剩余字节，不参与比对）
  # 注意 -D 会把重定向链上每一跳的响应头都写进来，必须取「最后一个」Content-Length（302 那跳是 0）
  if (-not $singleResume -and (Test-Path "$out.headers")) {
    $cls = [regex]::Matches([IO.File]::ReadAllText("$out.headers"), '(?im)^content-length:\s*(\d+)\s*$')
    if ($cls.Count -gt 0 -and $total -gt 0) {
      $declared = [int64]$cls[$cls.Count - 1].Groups[1].Value
      if ($declared -gt 0 -and $declared -ne $total) { throw "SIZE_MISMATCH: Content-Length=$declared 与 total=$total 不一致（下载被截断或换过文件），文件留在 $out" }
      "content_length_ok=$declared"
    }
  }
  Remove-Item "$out.headers" -Force -ErrorAction SilentlyContinue
  if ($total -le 0) { $total = (Get-Item $out).Length; "total_from_download=$total" }
  $parts = 1
} else {
  if ($dir -match ' ') { throw "SPACE_IN_PATH: $dir 含空格，5.1 的 Start-Process 会拆坏 -o" }
  $root = ([IO.Path]::GetPathRoot($dir)).TrimEnd('\').TrimEnd(':')
  $freeGB = [math]::Round((Get-PSDrive $root).Free / 1GB, 1)
  $needGB = [math]::Round(($total * 2 / 1GB), 1)
  if ($freeGB -lt $needGB) { throw "SPACE_LOW: free=${freeGB}GB need=${needGB}GB" }

  # 路线池：第 4 步实测拿到完整 1MB 且 code=206 的前三条，多源并行从这里轮流取
  $poolAll = @($results | Where-Object { $_.Code -eq '206' -and $_.Bytes -ge 1048576 } | Sort-Object KBps -Descending)
  $poolMin = [math]::Max(200, [int](0.35 * [math]::Max([int]$poolAll[0].KBps, 1)))
  $pool = @($poolAll | Where-Object { $_.KBps -ge $poolMin } | Select-Object -First 3)
  if ($pool.Count -eq 0) { $pool = @($route) }
  $poolNames = ($pool | ForEach-Object { $_.Name }) -join ' + '

  # 自适应段大小：按单连接实测速度让每段约 4 秒的活，夹在 2MB..24MB。
  # 段数上限取 128：总长 ≤3GB 时段大小都不会被顶出 24MB（1GB 约 52–78 段，3GB 约 128 段）；
  # 超过 3GB 才会出现 >24MB 的段——宁可段变大，也不让分片数量失控。
  $perKB = [math]::Max([int]$singleKB, 512)
  $chunk = [int64]($perKB * 1024 * 4)
  if ($chunk -lt 2MB) { $chunk = 2MB } elseif ($chunk -gt 24MB) { $chunk = 24MB }
  $workers = [math]::Min([math]::Max([int]$parts, 2), 16)
  $nseg = [int][math]::Ceiling($total / [double]$chunk)
  if ($nseg -lt $workers) { $nseg = $workers }
  if ($nseg -gt 128) { $nseg = 128 }
  $chunk = [int64][math]::Ceiling($total / [double]$nseg)

  # 续传：manifest 记下一次的分段方案（total/chunk/nseg/url）。重跑时方案一致就沿用，已有分片自动跳过
  $manifest = Join-Path $dir 'manifest.json'
  $resumePlan = $false
  if ((Test-Path $manifest) -and -not $ForceClean) {
    try {
      $mf = Get-Content $manifest -Raw | ConvertFrom-Json
      if ([int64]$mf.total -eq $total -and $mf.url -eq $winUrl) {
        $chunk = [int64]$mf.chunk; $nseg = [int]$mf.nseg; $resumePlan = $true
        $had = @(Get-ChildItem $dir -Filter 'p*.bin' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        "RESUME_PLAN: 沿用上次分段 nseg=$nseg chunk=$([math]::Round($chunk/1MB,1))MB 已有 $([math]::Round($had/1MB,1))MB"
      }
    } catch { "RESUME_PLAN_IGNORED: manifest 读不懂（$($_.Exception.Message)），重新规划" }
  }
  if (-not $resumePlan) {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $dir -Force | Out-Null
    @{ total = $total; chunk = $chunk; nseg = $nseg; url = $winUrl; asset = $asset } | ConvertTo-Json -Compress | Set-Content -LiteralPath $manifest -Encoding ASCII
    "PLAN: nseg=$nseg chunk=$([math]::Round($chunk/1MB,1))MB"
  }
  $pids = New-Object System.Collections.ArrayList
  $swE = [Diagnostics.Stopwatch]::StartNew()
  $segFile = { param($i) Join-Path $dir ("p{0:000}.bin" -f $i) }
  $rangeOf = { param($i) $s = [int64]($i * $chunk); [pscustomobject]@{ S = $s; E = $(if ($i -eq $nseg - 1) { $total - 1 } else { $s + $chunk - 1 }) } }

  # fast path：curl >= 7.66 时单进程 --parallel 把所有段一次拉完（无窃取，但进程开销最低）
  # 注意：不能用 -K 配置文件分组（实测 cfg 里的 next 分隔只跑第一段），必须用 --next 命令行分组。
  $useParallel = ($env:GHDL_PARALLEL -eq '1') -and ($vc -ge [version]'7.66')
  if ($useParallel) {
    $pa = @('--parallel', '--parallel-max', "$workers", '--show-error', '--silent')
    for ($i = 0; $i -lt $nseg; $i++) {
      if ($i -gt 0) { $pa += '--next' }
      $rg = & $rangeOf $i
      $r = $pool[$i % $pool.Count]
      $pa += @('-L', '--fail', '--connect-timeout', '10', '-A', 'Mozilla/5.0', '--retry', '3', '--retry-delay', '2')
      $pa += @('-o', (& $segFile $i), '-r', "$($rg.S)-$($rg.E)")
      if ($r.Proxy) { $pa += @('--proxy', $r.Proxy) }
      $pa += $r.Url
    }
    $plog = Join-Path $dir 'parallel.log'
    $pp = Start-Process $curlExe -ArgumentList $pa -NoNewWindow -PassThru -RedirectStandardOutput $plog -RedirectStandardError (Join-Path $dir 'parallel.err')
    [void]$pids.Add($pp.Id)
    $pp | Wait-Process -Timeout 1800 -ErrorAction SilentlyContinue
    $full = 0
    for ($i = 0; $i -lt $nseg; $i++) {
      $rg = & $rangeOf $i
      $f = & $segFile $i
      if ((Test-Path $f) -and ((Get-Item $f).Length -eq ($rg.E - $rg.S + 1))) { $full++ }
    }
    if ($full -eq $nseg) { $engine = 'parallel' } else { "PARALLEL_FALLBACK: 只完成 $full/$nseg 段，改走窃取调度（已下好的段保留）" }
  }

  if ($engine -ne 'parallel') {
    # 窃取调度：段是可重入的「起点..终点」，卡住/断了就按已下载字节续传，换下一条路线重排队
    $queue = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $nseg; $i++) {
      $rg = & $rangeOf $i
      $f = & $segFile $i
      $have = $(if (Test-Path $f) { [int64](Get-Item $f).Length } else { [int64]0 })
      if ($have -lt ($rg.E - $rg.S + 1)) {
        [void]$queue.Add([pscustomobject]@{ Index = $i; Start = $rg.S; End = $rg.E; Route = ($i % $pool.Count); Tries = 0 })
      }
    }
    # 并发不是越大越好：先 4 条起步，吞吐涨就加、出现卡住就砍。实测同一节点 16 条并发会被直接重置。
    $wMax = [math]::Min([math]::Max([int]$parts, 4), 16)
    $wCur = [math]::Min(4, $wMax)
    "engine=steal segments=$nseg chunk=$([math]::Round($chunk/1MB,1))MB workers=start$wCur/$wMax pool=$poolNames"
    $running = @{}
    $jobId = 0
    $winKB = 0; $winBase = 0; $winStall = 0
    $swWin = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
      while ($running.Count -lt $wCur -and $queue.Count -gt 0) {
        $seg = $queue[0]; $queue.RemoveAt(0); $jobId++
        $f = & $segFile $seg.Index
        $have = $(if (Test-Path $f) { [int64](Get-Item $f).Length } else { [int64]0 })
        $rs = [int64]($seg.Start + $have)
        if ($rs -gt $seg.End) { continue }
        # 从 0 开始时直接写正式分片；只有续传才写 .resume 再追加——少一次文件合并就少一处句柄竞争
        $tgt = $(if ($have -eq 0) { $f } else { "$f.resume" })
        $r = $pool[$seg.Route % $pool.Count]
        $a = @('-sS', '-L', '--fail', '--connect-timeout', '10', '-A', 'Mozilla/5.0', '-r', "$rs-$($seg.End)", '-o', $tgt, '-m', '1800') + $retry
        if ($r.Proxy) { $a += @('--proxy', $r.Proxy) }
        $a += $r.Url
        $lg = Join-Path $dir ("p{0:000}.log" -f $seg.Index)
        $pr = Start-Process $curlExe -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardOutput $lg -RedirectStandardError ($lg -replace '\.log$', '.err')
        [void]$pids.Add($pr.Id)
        $running[$jobId] = [pscustomobject]@{ Id = $jobId; Seg = $seg; File = $f; Resume = $(if ($tgt -eq $f) { $null } else { $tgt }); Proc = $pr; Last = $have; Still = 0 }
      }
      Start-Sleep -Milliseconds 500
      foreach ($k in @($running.Keys)) {
        $job = $running[$k]
        $stalled = $false
        if (-not $job.Proc.HasExited) {
          $cur = $(if (Test-Path $job.File) { [int64](Get-Item $job.File).Length } else { [int64]0 }) + $(if ($job.Resume -and (Test-Path $job.Resume)) { [int64](Get-Item $job.Resume).Length } else { [int64]0 })
          if ($cur -le $job.Last) { $job.Still++ } else { $job.Still = 0 }
          $job.Last = $cur
          if ($job.Still -lt 12) { continue }   # 6 秒没长进才算卡住（4 秒会误杀慢启动的连接）
          Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue
          Wait-Process -Id $job.Proc.Id -Timeout 5 -ErrorAction SilentlyContinue   # 等句柄释放，否则下面合并会撞锁
          $stalled = $true
        }
        if ($job.Resume -and (Test-Path $job.Resume)) {
          $tries = 0
          while ($tries -lt 10) {
            try {
              $fs = [IO.File]::Open($job.File, [IO.FileMode]::Append, [IO.FileAccess]::Write)
              $ri = [IO.File]::OpenRead($job.Resume)
              $ri.CopyTo($fs); $ri.Dispose(); $fs.Dispose()
              break
            } catch {
              Start-Sleep -Milliseconds 300
              $tries++
              if ($tries -ge 10) { throw "RESUME_MERGE_FAILED: $($job.Resume) 一直被占用：$($_.Exception.Message)" }
            }
          }
          Remove-Item $job.Resume -Force -ErrorAction SilentlyContinue
        }
        $running.Remove($k)
        if ($stalled) { $stolen++; $winStall++ }
        $have = $(if (Test-Path $job.File) { [int64](Get-Item $job.File).Length } else { [int64]0 })
        $need = $job.Seg.End - $job.Seg.Start + 1
        if ($have -lt $need) {
          $repairs++
          if ($job.Seg.Tries -ge 5) { throw "SEGMENT_SHORT: p$($job.Seg.Index) have=$have need=$need（换 5 条路线仍不够）" }
          $job.Seg.Tries++
          $job.Seg.Route++
          [void]$queue.Add($job.Seg)
        }
      }
      if ($swWin.Elapsed.TotalSeconds -ge 3) {
        $done = 0
        for ($i = 0; $i -lt $nseg; $i++) {
          $f = & $segFile $i
          if (Test-Path $f) { $done += (Get-Item $f).Length }
        }
        $rate = [int](($done - $winBase) / 1KB / [math]::Max($swWin.Elapsed.TotalSeconds, 0.1))
        if ($winKB -gt 0 -and $rate -gt ($winKB * 1.15) -and $wCur -lt $wMax) {
          $wCur = [math]::Min($wMax, $wCur + 2)
          "RAMP_UP: $rate KB/s > $winKB KB/s -> workers=$wCur"
        } elseif ($winStall -ge 2 -and $wCur -gt 2) {
          $wCur = [math]::Max(2, [int][math]::Floor($wCur / 2))
          "BACKOFF: 3 秒内卡了 $winStall 段 -> workers=$wCur"
        }
        $winKB = $rate; $winBase = $done; $winStall = 0
        $swWin.Restart()
      }
    }
    $engine = 'steal'
  }

  $swE.Stop()
  $segCount = $nseg
  $parts = $nseg
  "engine_done=$engine segments=$nseg steals=$stolen repairs=$repairs elapsed=$([math]::Round($swE.Elapsed.TotalSeconds,1))s"
  "SEGMENTS_READY: $nseg 个分片在 $dir（拼装与逐段核对在第 9 步）"
}

if ($engine -in @('steal', 'parallel')) {
  $gotMB = [math]::Round((@(Get-ChildItem $dir -Filter 'p*.bin' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1)
  "progress=${gotMB}MB/$([math]::Round($total/1MB,1))MB segments=$nseg engine=$engine"
} else {
  "progress: engine=$engine 不走分段"
}

if ($parts -gt 1) {
  if (-not $nseg) { $nseg = $parts }
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
  if ($errs.Count -gt 0) { throw ("SEGMENT_SIZE_MISMATCH: " + ($errs -join '; ') + "（分片留在 $dir，可直接重跑续传）") }
  if ($sum -ne $total) { throw "PARTS_MISMATCH: sum=$sum total=$total（分片留在 $dir）" }
  "partsBytes=$sum total=$total ok=True"
  $fs = [IO.File]::Create($out)
  for ($i = 0; $i -lt $nseg; $i++) {
    $ri = [IO.File]::OpenRead((Join-Path $dir ("p{0:000}.bin" -f $i)))
    $ri.CopyTo($fs); $ri.Dispose()
  }
  $fs.Dispose()
  "assembled=$((Get-Item $out).Length)"
  $parts = 1
} else {
  "single=$((Get-Item $out).Length)（单流/命中缓存，无需拼装）"
}

$size = (Get-Item $out).Length
# total 未知（服务器不给 Content-Range / API 取不到）时，能下完整只能说明「字节数自身一致」，不能说和远端一致
$sizeOk = $(if ($total -gt 0) { $size -eq $total } else { $size -gt 0 })
$verifiedOk = $false
"size=$size expect=$(if ($total -gt 0) { "$total" } else { 'unknown（只能证明下完了，不能证明和远端一致）' }) sizeOk=$sizeOk"
if ($want) {
  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower()
  "sha256=$got expect=$want"
  if ($sizeOk -and $got -eq $want) { $verifiedOk = $true; 'DOWNLOAD_VERIFIED_OK' } else { 'DOWNLOAD_VERIFY_FAILED' }
} else {
  'NO_DIGEST: 该 release 未提供 sha256，只能保证字节数一致'
  if ($sizeOk) { $verifiedOk = $true; 'DOWNLOAD_SIZE_OK_NO_DIGEST' } else { 'DOWNLOAD_VERIFY_FAILED' }
}

if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }
$curlPids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
if ($verifiedOk -and -not $KeepParts) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
elseif (Test-Path $dir) { "PARTS_KEPT: 分片保留在 $dir（校验未通过或 -KeepParts；重跑会续传，-ForceClean 可清掉重下）" }
Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'cur_*' -or $_.Name -like 'raw_*' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
"7897=$([bool](Test-Port '127.0.0.1' 7897)) corePid=$corePid"
if ($onWin) { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable }

# ---- 退出码：给调用方（agent / CI）判断成败用，不要靠读文字猜
# 第 10 步算出的 $verifiedOk：digest 或字节数校验通过才是真
if ($verifiedOk) { exit 0 } else { exit 1 }