#requires -Version 5.1
<#
  bench.ps1 —— 本地确定性基准（不碰外网）
  目的：把「Win / macOS 都把速度顶到最快、且不得劣化」落成可复跑的入库数据。

  做法：用 tests/serve.ps1 起本地 HTTP 服务（无代理、无节点抖动），
        对同一资产分别跑「强制单流」与「强制 16 段」，各 N 遍，取中位数，
        读每个 runner 输出的 RESULT_JSON 行取 elapsed_s / avg_mbps。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\bench.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\bench.ps1 -Runs 5 -Asset /huge.bin

  判据（与 SKILL.md「验收阈值」一致）：
    本机链路不限速（等价「单连接未被限速」）→ 多段聚合不得低于单流 95%；
    低于就说明并发只是多了开销，应当回退单流。
#>
[CmdletBinding()]
param(
  [int]$Port = 18791,
  [int]$Runs = 3,
  [string]$Asset = '/big.bin',
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ('ghdl_bench_' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Test-Serve {
  param([int]$p)
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$p/ok.bin")
    $req.AddRange(0, 0)
    $resp = $req.GetResponse()
    $code = [int]$resp.StatusCode
    $resp.Close()
    return ($code -eq 206)
  } catch { return $false }
}

$serveProc = $null
if (-not (Test-Serve $Port)) {
  $serveProc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'serve.ps1'), '-Port', "$Port"
  )
  $ok = $false
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; if (Test-Serve $Port) { $ok = $true; break } }
  if (-not $ok) { throw "BENCH_NO_SERVE: 127.0.0.1:$Port 起不来（端口被占且不是本夹具？）" }
}

function Invoke-Run {
  param([int]$parts)
  $dir = Join-Path $OutDir ("p{0}_{1}" -f $parts, [guid]::NewGuid().ToString('N').Substring(0, 4))
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\ghdl.ps1') `
    -Url "http://127.0.0.1:$Port$Asset" -OutDir $dir -Parts $parts -ForceClean 2>&1 | Out-String
  $code = $LASTEXITCODE
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  $json = $null
  foreach ($line in ($o -split "`r?`n")) {
    if ($line -match '^RESULT_JSON: (.+)$') {
      try { $json = $Matches[1] | ConvertFrom-Json } catch { $json = $null }
    }
  }
  [pscustomobject]@{ Exit = $code; Elapsed = $(if ($json) { [double]$json.elapsed_s } else { $null }); MBps = $(if ($json) { [double]$json.avg_mbps } else { $null }) }
}

function Get-Median {
  param([double[]]$v)
  if (-not $v -or $v.Count -eq 0) { return $null }
  $s = $v | Sort-Object
  $n = $s.Count
  if ($n % 2 -eq 1) { return [double]$s[($n - 1) / 2] }
  return [double](($s[$n / 2 - 1] + $s[$n / 2]) / 2)
}

$rows = @()
foreach ($mode in @(@{ Name = 'single'; Parts = 1 }, @{ Name = 'segments16'; Parts = 16 })) {
  $el = @(); $mb = @(); $fails = 0
  for ($r = 1; $r -le $Runs; $r++) {
    $res = Invoke-Run -parts $mode.Parts
    if ($res.Exit -ne 0 -or -not $res.Elapsed) { $fails++ ; continue }
    $el += $res.Elapsed; $mb += $res.MBps
  }
  $rows += [pscustomobject]@{
    Mode    = $mode.Name
    Runs    = $Runs
    Fails   = $fails
    MedianS = Get-Median $el
    MedianMBps = Get-Median $mb
    MinS    = $(if ($el.Count) { ($el | Measure-Object -Minimum).Minimum } else { $null })
    MaxS    = $(if ($el.Count) { ($el | Measure-Object -Maximum).Maximum } else { $null })
  }
}

if ($serveProc) { try { Stop-Process -Id $serveProc.Id -Force -ErrorAction SilentlyContinue } catch { } }
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue

$single = $rows | Where-Object Mode -eq 'single'
$seg = $rows | Where-Object Mode -eq 'segments16'
Write-Host ''
$rows | Format-Table Mode, Runs, Fails, MedianS, MedianMBps, MinS, MaxS -AutoSize | Out-String | Write-Host
if ($single.MedianMBps -and $seg.MedianMBps) {
  $ratio = [math]::Round($seg.MedianMBps / $single.MedianMBps, 2)
  Write-Host ("BENCH: asset={0} single={1} MB/s segments16={2} MB/s ratio={3}x" -f $Asset, $single.MedianMBps, $seg.MedianMBps, $ratio)
  if ($ratio -lt 0.95) {
    Write-Host 'BENCH_VERDICT: 本机不限速时多段低于单流 95% —— 符合「该回退单流」的预期（本地回环不模拟每连接限速）'
  } else {
    Write-Host 'BENCH_VERDICT: 多段不劣于单流 95%'
  }
}
