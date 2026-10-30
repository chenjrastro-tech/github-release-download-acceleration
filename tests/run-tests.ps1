#requires -Version 5.1
<#
  run-tests.ps1 —— 本地确定性回归测试（不需要外网、不需要 GitHub 账号）

  跑法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Keep   # 保留临时目录排查
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Port 19000  # 指定端口

  覆盖：单流 / 幂等 / 强制重下 / 16 段分段 / 续传（manifest）/ 坏分片 / 短包 / 不支持 Range / 全灭路线
        直链 404 / 死代理端口 / -Parts 64 并发夹取（共 12 组 34 条）
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
  Check (-not (Test-Path (Join-Path $d4 '_dl_parts'))) '校验通过后分片目录被清掉'

  # ---------- 5) 续传：预置 manifest + 1 个完整段 + 半个段
  "`n[5] 续传（manifest + 已有分片）"
  $d5 = Join-Path $Work 'resume'
  $p5 = Join-Path $d5 '_dl_parts'
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

  # ---------- 6) 坏分片：长度对不上必须报 SEGMENT_SIZE_MISMATCH，且保留分片
  "`n[6] 坏分片（长度不符）"
  $d6 = Join-Path $Work 'badseg'
  $p6 = Join-Path $d6 '_dl_parts'
  New-Item -ItemType Directory $p6 -Force | Out-Null
  '{"total":123456789,"chunk":8000000,"nseg":16,"url":"' + "$Base/big.bin" + '","asset":"big.bin"}' |
    Set-Content -LiteralPath (Join-Path $p6 'manifest.json') -Encoding ASCII
  # 造一个「比需要的还长」的分片：引擎会跳过它（长度不小于需要），第 9 步核对时必然对不上
  & curl.exe -sS -L -o (Join-Path $p6 'p000.bin') -r '0-8999999' "$Base/big.bin"
  Check ((Get-Item (Join-Path $p6 'p000.bin')).Length -eq 9000000) '预置超长分片 9000000 B'
  $r = Invoke-Ghdl @('-Url', "$Base/big.bin", '-OutDir', $d6, '-Parts', '16')
  Check ($r.Code -eq 1) '坏分片 exit=1' "exit=$($r.Code)"
  Check (Has $r.Out 'SEGMENT_SIZE_MISMATCH') '报 SEGMENT_SIZE_MISMATCH'
  Check (Test-Path (Join-Path $d6 '_dl_parts')) '失败时保留分片以便续传'

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
} finally {
  if ($ownServer) { Stop-Process -Id $ownServer.Id -Force -ErrorAction SilentlyContinue }
  if (-not $Keep) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

"`n----------------------------------------"
if ($script:Fail -eq 0) { "TESTS_OK: $script:Pass 项通过"; exit 0 }
else { "TESTS_FAILED: $script:Pass 通过 / $script:Fail 失败"; exit 1 }
