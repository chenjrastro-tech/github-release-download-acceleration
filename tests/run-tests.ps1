#requires -Version 5.1
<#
  run-tests.ps1 —— 本地确定性回归测试（不需要外网、不需要 GitHub 账号）

  跑法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Keep   # 保留临时目录排查
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Port 19000  # 指定端口

  覆盖：单流 / 幂等 / 强制重下 / 16 段分段 / 续传（旧+新 manifest）/ 坏分片 / 短包 / 不支持 Range / 全灭路线
        直链 404 / 死代理端口 / -Parts 64 并发夹取 / 小资产 / OutDir 含空格 / Parts 门控 / 无 digest exe
        / 单流首候选 0 字节回退（共 22 组）
  不覆盖（需要真实网络或真实磁盘故障）：digest 不匹配、ASSET_NOT_FOUND、磁盘不足、镜像超时
#>
[CmdletBinding()]
param(
  [int]$Port = 0,   # 0 = 自动挑一个空闲端口，避免和上一次残留的 serve.ps1 撞车
  [switch]$Keep
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $Root 'scripts\ghdl.ps1'
$Server = Join-Path $Root 'tests\serve.ps1'
$Work = Join-Path $env:TEMP 'ghdl_tests'

if (-not (Test-Path $Runner)) { throw "缺少 runner：$Runner" }

if ($Port -eq 0) {
  $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $Port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
  $probe.Stop()
}
$Base = "http://127.0.0.1:$Port"

$script:Pass = 0
$script:Fail = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') {
  if ($ok) { $script:Pass++; "  [PASS] $what" }
  else { $script:Fail++; "  [FAIL] $what $detail" }
}

function Invoke-Ghdl([string[]]$argv) {
  # 子进程的 stderr（NO_ROUTE 这类）在 $ErrorActionPreference=Stop 下会升级成终止错误，
  # 这里临时放宽：只要退出码和输出
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $Runner @argv 2>&1 | Out-String }
  finally { $ErrorActionPreference = $prev }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}

function Has($out, [string]$pat) { $out -match [regex]::Escape($pat) }

# 期望字节：pattern[i % 1MB] = (i*7+3) & 0xFF，与 serve.ps1 完全一致
$MB = 1MB
$pattern = New-Object byte[] $MB
for ($i = 0; $i -lt $MB; $i++) { $pattern[$i] = [byte](($i * 7 + 3) -band 0xFF) }
function Get-ExpectedHash([int64]$total) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $left = $total
  while ($left -gt 0) {
    $n = [int][math]::Min([int64]$pattern.Length, $left)
    if ($n -eq $pattern.Length) { [void]$sha.TransformBlock($pattern, 0, $n, $null, 0) }
    else { [void]$sha.TransformBlock($pattern, 0, $n, $pattern, 0) }
    $left -= $n
  }
  [void]$sha.TransformFinalBlock($pattern, 0, 0)
  (($sha.Hash | ForEach-Object { '{0:x2}' -f $_ }) -join '')
}

# ---- 起本地服务器（端口已被占用就复用，结束时只关自己起的那个）
$ownServer = $null
if ($Port -gt 0) {
  $stale = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains('serve.ps1') -and $_.CommandLine.Contains("-Port $Port") })
  if ($stale.Count -gt 0) {
    foreach ($s in $stale) { Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue }
    "SERVER_REAP: 清掉 $($stale.Count) 个残留 serve.ps1（端口 $Port）"
    Start-Sleep -Milliseconds 400
  }
}
function Test-Port([int]$p) {
  try { $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $p); $c.Close(); $true } catch { $false }
}
if (-not (Test-Port $Port)) {
  $ownServer = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Server, '-Port', "$Port" -WindowStyle Hidden -PassThru
  $n = 0
  while (-not (Test-Port $Port) -and $n -lt 50) { Start-Sleep -Milliseconds 200; $n++ }
  if (-not (Test-Port $Port)) { throw "本地测试服务器起不来（端口 $Port）" }
}

# 端口活着不等于「活的是本测试的 serve.ps1」：旧实例/别的服务占着同一端口会让用例莫名其妙地 404。
# 用一个 1 字节 range 请求验明正身（serve.ps1 对 /ok.bin 应回 206）。
function Test-Serve {
  try {
    $req = [System.Net.HttpWebRequest]::Create("$Base/ok.bin")
    $req.Method = 'GET'; [void]$req.AddRange(0, 0); $req.Timeout = 5000
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return ($code -eq 206)
  } catch { return $false }
}
if (-not (Test-Serve)) {
  throw "端口 $Port 上监听的不是本测试的 serve.ps1（可能是上一次残留的旧实例）——先结束它，或换 -Port 重跑"
}

try {
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory $Work -Force | Out-Null

  # ---------- 1) 单流 + 哈希
  "`n[1] 单流 3MB"
  $d1 = Join-Path $Work 'single'
  $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d1)
  Check ($r.Code -eq 0) '单流 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'DOWNLOAD_SIZE_OK_NO_DIGEST') '单流输出完整结论'
  $f1 = Join-Path $d1 'ok.bin'
  Check ((Test-Path $f1) -and (Get-Item $f1).Length -eq 3145728) '单流字节数=3145728'
  Check ((Get-FileHash $f1 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 3145728)) '单流内容 SHA256 正确'

  # ---------- 2) 幂等：重跑不再下载
  "`n[2] 幂等重跑"
  $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d1)
  Check ($r.Code -eq 0 -and (Has $r.Out 'ALREADY_DONE')) '重复执行命中 ALREADY_DONE'

  # ---------- 3) 强制重下
  "`n[3] -ForceClean"
  $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d1, '-ForceClean')
  Check ($r.Code -eq 0 -and (Has $r.Out 'FORCE_CLEAN')) '-ForceClean 真的删掉重下'

  # ---------- 4) 16 段分段（123456789 B，非段长整数倍）
  "`n[4] 16 段分段"
  $d4 = Join-Path $Work 'seg'
  $r = Invoke-Ghdl @('-Url', "$Base/big.bin", '-OutDir', $d4, '-Parts', '16')
  Check ($r.Code -eq 0) '分段 exit=0' "exit=$($r.Code)"
  Check ((Has $r.Out 'PLAN: nseg=16') -or (Has $r.Out 'nseg=16')) '分成 16 段'
  Check (Has $r.Out 'partsBytes=123456789') '逐段核对总字节=123456789'
  $f4 = Join-Path $d4 'big.bin'
  Check ((Get-Item $f4).Length -eq 123456789) '拼装后字节=123456789'
  Check ((Get-FileHash $f4 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 123456789)) '拼装后 SHA256 正确（跨段无错位）'
  Check (-not (Test-Path (Join-Path $d4 'big.bin.parts'))) '校验通过后分片目录被清掉'
  $rj4 = [regex]::Match($r.Out, '(?m)^RESULT_JSON:\s*(\{.*\})\s*$')
  Check ($rj4.Success) '输出 RESULT_JSON'
  if ($rj4.Success) {
    $j4 = $rj4.Groups[1].Value | ConvertFrom-Json
    Check ($j4.engine -eq 'segments' -and [int]$j4.parts -eq 16) 'RESULT_JSON engine=segments/parts=16' "engine=$($j4.engine) parts=$($j4.parts)"
  }

  # ---------- 5) 续传：预置 manifest + 1 个完整段 + 半个段
  "`n[5] 续传（manifest + 已有分片）"
  $d5 = Join-Path $Work 'resume'
  $p5 = Join-Path $d5 'big.bin.parts'
  New-Item -ItemType Directory $p5 -Force | Out-Null
  '{"total":123456789,"chunk":8000000,"nseg":16,"url":"' + "$Base/big.bin" + '","asset":"big.bin"}' |
    Set-Content -LiteralPath (Join-Path $p5 'manifest.json') -Encoding ASCII
  & curl.exe -sS -L -o (Join-Path $p5 'p000.bin') -r '0-7999999' "$Base/big.bin"
  & curl.exe -sS -L -o (Join-Path $p5 'p001.bin') -r '8000000-10999999' "$Base/big.bin"
  $seed = (Get-ChildItem $p5 -Filter 'p*.bin' | Measure-Object Length -Sum).Sum
  Check ($seed -eq 11000000) "预置分片 $seed B" "seed=$seed"
  $r = Invoke-Ghdl @('-Url', "$Base/big.bin", '-OutDir', $d5, '-Parts', '16')
  Check ($r.Code -eq 0) '续传 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'RESUME_PLAN') '识别到上次分段方案'
  Check (Has $r.Out 'assembled=123456789') '续传后拼装完整'
  $f5 = Join-Path $d5 'big.bin'
  Check ((Get-FileHash $f5 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 123456789)) '续传结果 SHA256 正确'

  # ---------- 5b) 新 manifest（source）：同样应识别续传
  "`n[5b] 新 manifest（source）续传"
  $d5b = Join-Path $Work 'resume-source'
  $p5b = Join-Path $d5b 'nodash.bin.parts'
  New-Item -ItemType Directory $p5b -Force | Out-Null
  '{"schema":2,"total":4194304,"chunk":1048576,"nseg":4,"source":"' + "$Base/nodash.bin" + '","asset":"nodash.bin"}' |
    Set-Content -LiteralPath (Join-Path $p5b 'manifest.json') -Encoding ASCII
  & curl.exe -sS -L -o (Join-Path $p5b 'p000.bin') -r '0-1048575' "$Base/nodash.bin"
  $r = Invoke-Ghdl @('-Url', "$Base/nodash.bin", '-OutDir', $d5b, '-Parts', '4')
  Check ($r.Code -eq 0) '新 manifest 续传 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'RESUME_PLAN') '新 manifest 识别 RESUME_PLAN'
  Check (Has $r.Out 'assembled=4194304') '新 manifest 续传后拼装完整'
  $f5b = Join-Path $d5b 'nodash.bin'
  Check ((Get-FileHash $f5b -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 4194304)) '新 manifest 续传 SHA256 正确'

  # ---------- 6) 坏分片：长度对不上必须报 SEGMENT_SIZE_MISMATCH，且保留分片
  "`n[6] 坏分片（长度不符）"
  $d6 = Join-Path $Work 'badseg'
  $p6 = Join-Path $d6 'big.bin.parts'
  New-Item -ItemType Directory $p6 -Force | Out-Null
  '{"schema":2,"total":123456789,"chunk":8000000,"nseg":16,"source":"' + "$Base/big.bin" + '","asset":"big.bin"}' |
    Set-Content -LiteralPath (Join-Path $p6 'manifest.json') -Encoding ASCII
  # 造一个「比需要的还长」的分片：引擎会跳过它（长度不小于需要），第 9 步核对时必然对不上
  & curl.exe -sS -L -o (Join-Path $p6 'p000.bin') -r '0-8999999' "$Base/big.bin"
  Check ((Get-Item (Join-Path $p6 'p000.bin')).Length -eq 9000000) '预置超长分片 9000000 B'
  $r = Invoke-Ghdl @('-Url', "$Base/big.bin", '-OutDir', $d6, '-Parts', '16')
  Check ($r.Code -eq 1) '坏分片 exit=1' "exit=$($r.Code)"
  Check (Has $r.Out 'SEGMENT_SIZE_MISMATCH') '报 SEGMENT_SIZE_MISMATCH'
  Check (Test-Path (Join-Path $d6 'big.bin.parts')) '失败时保留分片以便续传'
  $mf6 = Get-Content (Join-Path $p6 'manifest.json') -Raw | ConvertFrom-Json
  Check ([string]$mf6.source -eq "$Base/big.bin") '新 manifest 记录 source' "source=$($mf6.source)"

  # ---------- 7) 短包：服务器声明 2MB 只发 700KB，必须由「三方差一」拦下
  "`n[7] 短包"
  $d7 = Join-Path $Work 'short'
  $r = Invoke-Ghdl @('-Url', "$Base/short.bin", '-OutDir', $d7)
  Check ($r.Code -eq 1) '短包 exit=1' "exit=$($r.Code)"
  Check (Has $r.Out 'SIZE_MISMATCH') '短包报 SIZE_MISMATCH（Content-Length 与 total 不一致）'

  # ---------- 8) 不支持 Range：退回单流，但话要说清
  "`n[8] 服务器不支持 Range"
  $d8 = Join-Path $Work 'norange'
  $r = Invoke-Ghdl @('-Url', "$Base/norange.bin", '-OutDir', $d8)
  Check ($r.Code -eq 0) '无 Range 也能下完 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'DOWNLOAD_SIZE_OK_NO_DIGEST') '输出「只校验字节数」的结论'

  # ---------- 9) 全灭路线：不该假装成功
  "`n[9] 所有路线都不通"
  $d9 = Join-Path $Work 'noroute'
  $r = Invoke-Ghdl @('-Url', "http://127.0.0.1:18999/x.bin", '-OutDir', $d9)
  Check ($r.Code -eq 1) 'NO_ROUTE exit=1' "exit=$($r.Code)"
  Check (Has $r.Out 'NO_ROUTE') '报 NO_ROUTE'

  # ---------- 10) 直链 404（文件名不存在）：直链没有 API 可查，只能靠探测发现
  "`n[10] 直链 404"
  $d10 = Join-Path $Work 'notfound'
  $r = Invoke-Ghdl @('-Url', "$Base/missing.bin", '-OutDir', $d10)
  Check ($r.Code -eq 1) '404 exit=1' "exit=$($r.Code)"
  Check (Has $r.Out 'NO_ROUTE') '404 报 NO_ROUTE'

  # ---------- 11) 死代理端口：环境变量指向没人监听的端口，仍应自动走直连
  "`n[11] 死代理端口"
  $d11 = Join-Path $Work 'deadproxy'
  $o1 = $env:HTTP_PROXY; $o2 = $env:HTTPS_PROXY
  try {
    $env:HTTP_PROXY = 'http://127.0.0.1:1'
    $env:HTTPS_PROXY = 'http://127.0.0.1:1'
    $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d11)
  } finally {
    $env:HTTP_PROXY = $o1
    $env:HTTPS_PROXY = $o2
  }
  Check ($r.Code -eq 0) '死代理下仍能完成 exit=0' "exit=$($r.Code)"
  Check ((Test-Path (Join-Path $d11 'ok.bin')) -and (Get-Item (Join-Path $d11 'ok.bin')).Length -eq 3145728) '死代理下落盘字节正确'

  # ---------- 12) 并发过大：-Parts 64 必须被夹到 16，且不能失败
  "`n[12] 并发过大（-Parts 64）"
  $d12 = Join-Path $Work 'toomany'
  $r = Invoke-Ghdl @('-Url', "$Base/big.bin", '-OutDir', $d12, '-Parts', '64')
  $tail12 = (($r.Out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' / ')
  Check ($r.Code -eq 0) '-Parts 64 仍能完成 exit=0' "exit=$($r.Code) tail=$tail12"
  $m = [regex]::Match($r.Out, 'workers=(\d+)')
  Check ($m.Success -and [int]$m.Groups[1].Value -le 16) '并发被夹到 ≤16' "workers=$($m.Groups[1].Value)"
  Check ((Get-Item (Join-Path $d12 'big.bin')).Length -eq 123456789) '字节仍精确'
  # ---------- 13) 本机目标 + 死代理：必须走直连、印 LOCAL_TARGET，且字节正确
  "`n[13] 本机目标跳过代理（死代理环境）"
  $d13 = Join-Path $Work 'localdirect'
  $o1 = $env:HTTP_PROXY; $o2 = $env:HTTPS_PROXY
  try {
    $env:HTTP_PROXY = 'http://127.0.0.1:1'
    $env:HTTPS_PROXY = 'http://127.0.0.1:1'
    $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d13)
  } finally {
    $env:HTTP_PROXY = $o1
    $env:HTTPS_PROXY = $o2
  }
  Check ($r.Code -eq 0) 'LOCAL_TARGET 场景 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'LOCAL_TARGET') '印出 LOCAL_TARGET'
  Check ((Test-Path (Join-Path $d13 'ok.bin')) -and (Get-Item (Join-Path $d13 'ok.bin')).Length -eq 3145728) '本机目标落盘字节正确'

  # ---------- 14) 同一 OutDir 并发两个资产：分片目录必须按资产隔离（P0 回归）
  "`n[14] 同一 OutDir 并发两个资产"
  $d14 = Join-Path $Work 'concurrent'
  New-Item -ItemType Directory $d14 -Force | Out-Null
  function Start-Runner($url, $outDir) {
    # Start-Process 在 5.1 里配合 -RedirectStandardOutput 时 ExitCode 取不到（实测为空），
    # 这里直接用 Diagnostics.Process 并显式重定向。
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Url "{1}" -OutDir "{2}" -Parts 4' -f $Runner, $url, $outDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [Diagnostics.Process]::Start($psi)
  }
  $pa = Start-Runner "$Base/big.bin" $d14
  $pb = Start-Runner "$Base/big2.bin" $d14
  $o14a = $pa.StandardOutput.ReadToEnd() + $pa.StandardError.ReadToEnd()
  $o14b = $pb.StandardOutput.ReadToEnd() + $pb.StandardError.ReadToEnd()
  [void]$pa.WaitForExit(300000); [void]$pb.WaitForExit(300000)
  Check ($pa.ExitCode -eq 0 -and $pb.ExitCode -eq 0) '两个并发下载都 exit=0' "e1=$($pa.ExitCode) e2=$($pb.ExitCode)"
  $f14a = Join-Path $d14 'big.bin'; $f14b = Join-Path $d14 'big2.bin'
  $l14a = $(if (Test-Path $f14a) { (Get-Item $f14a).Length } else { -1 })
  $l14b = $(if (Test-Path $f14b) { (Get-Item $f14b).Length } else { -1 })
  Check ($l14a -eq 123456789) '并发下 big.bin 字节=123456789' "got=$l14a"
  Check ($l14b -eq 67108864) '并发下 big2.bin 字节=67108864' "got=$l14b"
  if ($l14a -eq 123456789) { Check ((Get-FileHash $f14a -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 123456789)) '并发下 big.bin SHA256 正确' }
  if ($l14b -eq 67108864) { Check ((Get-FileHash $f14b -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 67108864)) '并发下 big2.bin SHA256 正确' }
  Check ((Test-Path (Join-Path $d14 'big.bin.parts')) -eq $false -and (Test-Path (Join-Path $d14 'big2.bin.parts')) -eq $false) '两个资产的分片目录都已清掉'

  # ---------- 15) 没有 curl.exe：必须降级 Invoke-WebRequest 单流，而不是抛 NO_CURL
  "`n[15] 无 curl.exe 降级 Invoke-WebRequest"
  $d15 = Join-Path $Work 'nowcurl'
  $cmd = "`$env:Path='C:\Windows\System32\WindowsPowerShell\v1.0'; & '$Runner' -Url '$Base/ok.bin' -OutDir '$d15'"
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o15 = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | Out-String }
  finally { $ErrorActionPreference = $prevEap }
  $c15 = $LASTEXITCODE
  Check ($c15 -eq 0) 'IWR 降级 exit=0' "exit=$c15"
  Check (Has $o15 'IWR_FALLBACK') '印出 IWR_FALLBACK'
  $f15 = Join-Path $d15 'ok.bin'
  Check ((Test-Path $f15) -and (Get-Item $f15).Length -eq 3145728) 'IWR 落盘字节=3145728'

  # ---------- 16) 服务端确定性故障：403 / 503(+Retry-After) / 429 必须干净失败、不落半成品
  "`n[16] 服务端故障码（403 / 503+Retry-After / 429）"
  foreach ($code in 403, 503, 429) {
    $d16 = Join-Path $Work ("fault$code")
    $sw16 = [Diagnostics.Stopwatch]::StartNew()
    $o16 = Invoke-Ghdl "$Base/e$code.bin" $d16
    $c16 = $LASTEXITCODE
    $sw16.Stop()
    $f16 = Join-Path $d16 "e$code.bin"
    Check ($c16 -ne 0) "$code 必须非 0 退出" "exit=$c16"
    Check (Has $o16 "$code") "$code 的状态码要出现在输出里（可解释失败）" ''
    Check ((Test-Path $f16) -eq $false) "$code 失败后不留半成品文件" ('left=' + (Test-Path $f16))
    # 5xx 在「探测」阶段就判定不可用：这里要的是一次干净的快速失败（不让用户等重试），
    # 而不是伪装成已做退避。真正的重试发生在下载过程中（curl --retry），见 Pitfalls。
    Check ($sw16.Elapsed.TotalSeconds -lt 30) "$code 快速失败（<30s，不空转重试）" ("elapsed=$([math]::Round($sw16.Elapsed.TotalSeconds,1))s")
    if ($code -eq 503) {
      Check (Has $o16 'NO_ROUTE') '503 报 NO_ROUTE（说明探测阶段无可用路线）' ''
    }
    if (-not (Test-Path $d16)) { New-Item -ItemType Directory -Path $d16 -Force | Out-Null }
  }

  # ---------- 17) 小资产：旧逻辑的 512KB 探测门槛会把它判 NO_ROUTE
  "`n[17] 小资产 300KB"
  $d17 = Join-Path $Work 'small'
  $r = Invoke-Ghdl @('-Url', "$Base/small.bin", '-OutDir', $d17)
  Check ($r.Code -eq 0) '小资产 exit=0' "exit=$($r.Code)"
  $f17 = Join-Path $d17 'small.bin'
  Check ((Test-Path $f17) -and (Get-Item $f17).Length -eq 300000) '小资产字节=300000'
  Check ((Get-FileHash $f17 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 300000)) '小资产 SHA256 正确'

  # ---------- 18) OutDir 含空格 + 显式 -Parts 4（<100MB 也要尊重显式段数）
  "`n[18] OutDir 含空格 + -Parts 4"
  $d18 = Join-Path $Work 'space dir'
  $r = Invoke-Ghdl @('-Url', "$Base/ok.bin", '-OutDir', $d18, '-Parts', '4')
  Check ($r.Code -eq 0) '空格路径分段 exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'PARTS_OVERRIDE') '印出 PARTS_OVERRIDE'
  Check (Has $r.Out 'nseg=4') '<100MB 显式 -Parts 4 生效'
  $f18 = Join-Path $d18 'ok.bin'
  Check ((Test-Path $f18) -and (Get-Item $f18).Length -eq 3145728) '空格路径落盘字节=3145728'
  Check ((Get-FileHash $f18 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 3145728)) '空格路径 SHA256 正确'

  # ---------- 19) 服务器不支持 Range 时显式 -Parts 必须被忽略，而不是拿整包当分片
  "`n[19] 无 Range + -Parts 4"
  $d19 = Join-Path $Work 'norange-parts'
  $r = Invoke-Ghdl @('-Url', "$Base/norange.bin", '-OutDir', $d19, '-Parts', '4')
  Check ($r.Code -eq 0) '无 Range + Parts 仍单流成功' "exit=$($r.Code)"
  Check (Has $r.Out 'PARTS_IGNORED') '印出 PARTS_IGNORED'
  $f19 = Join-Path $d19 'norange.bin'
  Check ((Test-Path $f19) -and (Get-Item $f19).Length -eq 1048576) '无 Range 单流字节=1048576'

  # ---------- 20) 无 digest 的 exe 只能校验字节，绝不执行
  "`n[20] 无 digest 的 exe"
  $d20 = Join-Path $Work 'fakeexe'
  $r = Invoke-Ghdl @('-Url', "$Base/fake.exe", '-OutDir', $d20)
  Check ($r.Code -eq 0) '无 digest exe exit=0' "exit=$($r.Code)"
  Check (Has $r.Out 'smoke=SKIP_UNVERIFIED_EXE') '印出 smoke=SKIP_UNVERIFIED_EXE（不执行）'
  Check ((Test-Path (Join-Path $d20 'fake.exe')) -and (Get-Item (Join-Path $d20 'fake.exe')).Length -eq 1024) 'exe 字节=1024'

  # ---------- 21) 单流首选路线 200 后断流（0 字节）必须自动回退
  # 用 fallback.test 让 runner 不走 LOCAL_TARGET；CURL_HOME 的 resolve 规则只给测试内的
  # curl 用，把该主机名指到本地服务。fake proxy 占 7890 成为 A 路线，探测快、完整 GET
  # 只回头不发 body；D 直连 /fallback.bin 的 Range 探测故意慢 300ms。
  "`n[21] 单流回退（首候选 0 字节）"
  $proxyPort = 7890
  if (Test-Port $proxyPort) { throw "PORT_${proxyPort}_BUSY: 单流回退测试需要 127.0.0.1:$proxyPort 空闲" }
  $home21 = Join-Path $Work 'curlhome'
  New-Item -ItemType Directory $home21 -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $home21 '_curlrc') -Value ('resolve = "fallback.test:' + $Port + ':127.0.0.1"') -Encoding ASCII
  $oldCurlHome = $env:CURL_HOME
  $env:CURL_HOME = $home21
  $fakeProxy = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'tests\fake-proxy.ps1'), '-Port', "$proxyPort" -WindowStyle Hidden -PassThru
  try {
    $n = 0
    while (-not (Test-Port $proxyPort) -and $n -lt 50) { Start-Sleep -Milliseconds 100; $n++ }
    if (-not (Test-Port $proxyPort)) { throw "FAKE_PROXY_START_FAILED: 127.0.0.1:$proxyPort" }
    $d21 = Join-Path $Work 'singlefallback'
    $r = Invoke-Ghdl @('-Url', "http://fallback.test:$Port/fallback.bin", '-OutDir', $d21)
    Check ($r.Code -eq 0) '单流回退后 exit=0' "exit=$($r.Code)"
    Check (Has $r.Out 'SINGLE_ROUTE_FALLBACK') '印出 SINGLE_ROUTE_FALLBACK'
    $f21 = Join-Path $d21 'fallback.bin'
    Check ((Test-Path $f21) -and (Get-Item $f21).Length -eq 3145728) '回退后落盘字节=3145728'
    Check ((Get-FileHash $f21 -Algorithm SHA256).Hash.ToLower() -eq (Get-ExpectedHash 3145728)) '回退后 SHA256 正确'
  } finally {
    if ($fakeProxy) { Stop-Process -Id $fakeProxy.Id -Force -ErrorAction SilentlyContinue }
    $env:CURL_HOME = $oldCurlHome
  }
} finally {
  if ($ownServer) { Stop-Process -Id $ownServer.Id -Force -ErrorAction SilentlyContinue }
  if (-not $Keep) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

"`n----------------------------------------"
if ($script:Fail -eq 0) { "TESTS_OK: $script:Pass 项通过"; exit 0 }
else { "TESTS_FAILED: $script:Pass 通过 / $script:Fail 失败"; exit 1 }
