#requires -Version 5.1
<#
  fake-proxy.ps1 —— 测试夹具：一个只服务「单流回退」用例的假 HTTP 代理。

  行为：
    - 带 Range 的探测请求：快速返回 206 + 1MB 数据，让这条 A 路线在测速中胜出；
    - 完整 GET：返回 200 响应头后立即断开，不发送任何 body。
      这样 curl 以非 0 退出且落盘 0 字节，runner 应触发 SINGLE_ROUTE_FALLBACK，
      改走 D 直连（真实的 /fallback.bin）并成功。

  只用于 tests/run-tests.ps1，不属于技能运行时。
#>
[CmdletBinding()]
param(
  [int]$Port = 7890,
  [int64]$Total = 3145728
)

$ErrorActionPreference = 'Stop'
$rangeBytes = 1048576
$body = New-Object byte[] $rangeBytes
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
"LISTEN 127.0.0.1:$Port"
[Console]::Out.Flush()

while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000
    $client.NoDelay = $true

    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 4096
    while ($sb.ToString() -notmatch "`r`n`r`n") {
      $n = $stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
    }
    $head = $sb.ToString()
    $lines = $head -split "`r`n"
    if (-not $lines[0]) { continue }

    $method = ($lines[0] -split ' ')[0]
    $hasRange = $false
    $rs = [int64]0
    $re = [int64]($rangeBytes - 1)
    foreach ($l in $lines) {
      if ($l -match '^(?i)Range:\s*bytes=(\d+)-(\d*)\s*$') {
        $hasRange = $true
        $rs = [int64]$Matches[1]
        if ($Matches[2]) { $re = [int64]$Matches[2] }
      }
    }

    if ($hasRange) {
      $re = [math]::Min($re, $Total - 1)
      $len = $re - $rs + 1
      $h = ("HTTP/1.1 206 Partial Content`r`nContent-Type: application/octet-stream`r`n" +
            "Accept-Ranges: bytes`r`nContent-Range: bytes {0}-{1}/{2}`r`nContent-Length: {3}`r`nConnection: close`r`n`r`n") -f $rs, $re, $Total, $len
      $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
      $stream.Write($hb, 0, $hb.Length)
      if ($method -ne 'HEAD') {
        $sent = [int64]0
        while ($sent -lt $len) {
          $n = [int][math]::Min([int64]$body.Length, $len - $sent)
          $stream.Write($body, 0, $n)
          $sent += $n
        }
      }
      $stream.Flush()
    } else {
      # 关键：只发响应头，不发 body 就断开，模拟「探测快、完整下载失败」。
      $h = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $Total`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
      $stream.Write($hb, 0, $hb.Length)
      $stream.Flush()
    }
  } catch {
    # 客户端断开是预期场景
  } finally {
    if ($client) { try { $client.Close() } catch { } }
  }
}
