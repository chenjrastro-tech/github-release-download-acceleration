#requires -Version 5.1
<#
  serve.ps1 —— 本地测试用 HTTP 服务（只给 tests/run-tests.ps1 用，不属于技能运行时）

  为什么手写 TcpListener 而不是 HttpListener：HttpListener 在非管理员下需要 URL ACL，
  而这台机器上所有真实用户都是非管理员（这正是技能「真零前置」要覆盖的场景）。

  路由：
    /ok.bin        3 MB，支持 Range
    /big.bin       123456789 B（非 2 的幂、非段长整数倍），支持 Range
    /big2.bin      67108864 B（64MB），给「同一 OutDir 并发两个资产」用例
    /nodash.bin    4 MB，Support Range
    /short.bin     声明 2 MB，实际只发 700 KB 就断开（模拟「短包」）
    /norange.bin   1 MB，故意忽略 Range（永远 200 + 全量），模拟不支持分段的服务器
    /huge.bin      1,880,743,936 B（1.75GB，非 2 的幂），给「≥1GB 段粒度」手动验收用，不参与 run-tests
#>
[CmdletBinding()]
param(
  [int]$Port = 18765
)

$ErrorActionPreference = 'Stop'

$MB = 1MB
$pattern = New-Object byte[] $MB
for ($i = 0; $i -lt $MB; $i++) { $pattern[$i] = [byte](($i * 7 + 3) -band 0xFF) }

$specs = @{
  '/ok.bin'      = @{ Total = 3145728;   Mode = 'ok' }
  '/big.bin'     = @{ Total = 123456789; Mode = 'ok' }
  '/big2.bin'    = @{ Total = 67108864;  Mode = 'ok' }
  '/nodash.bin'  = @{ Total = 4194304;   Mode = 'ok' }
  '/short.bin'   = @{ Total = 2097152;   Mode = 'short'; Send = 716800 }
  '/norange.bin' = @{ Total = 1048576;   Mode = 'norange' }
  '/huge.bin'    = @{ Total = 1880743936; Mode = 'ok' }
  # 故障端点：永远返回同一个状态码，用来验证「失败要干净、可解释、不落半成品」
  '/e403.bin'    = @{ Total = 0; Mode = 'status'; Code = 403; Reason = 'Forbidden' }
  '/e503.bin'    = @{ Total = 0; Mode = 'status'; Code = 503; Reason = 'Service Unavailable'; RetryAfter = 1 }
  '/e429.bin'    = @{ Total = 0; Mode = 'status'; Code = 429; Reason = 'Too Many Requests' }
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
"LISTEN 127.0.0.1:$Port"
[Console]::Out.Flush()

function Send-Pattern {
  param($stream, [int64]$start, [int64]$len)
  $buf = New-Object byte[] 262144
  $sent = 0
  while ($sent -lt $len) {
    $off = $start + $sent
    $n = [int][math]::Min([int64]$buf.Length, $len - $sent)
    $pos = [int]($off % $MB)
    $first = [math]::Min($n, $MB - $pos)
    [Array]::Copy($pattern, $pos, $buf, 0, $first)
    if ($first -lt $n) { [Array]::Copy($pattern, 0, $buf, $first, $n - $first) }
    $stream.Write($buf, 0, $n)
    $sent += $n
  }
}

while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()
    $client.ReceiveTimeout = 15000
    # 对端静默消失时，write 默认会无限阻塞 -> 整个单线程夹具卡死，后续用例全 000。
    # 这里给写操作设超时，卡住就丢掉这条连接继续 accept。
    $client.SendTimeout = 15000
    $client.NoDelay = $true

    # --- 读请求头（直到空行）
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
    $path = (($lines[0] -split ' ')[1] -split '\?')[0]

    if (-not $specs.ContainsKey($path)) {
      $msg = [System.Text.Encoding]::ASCII.GetBytes('not found')
      $h = "HTTP/1.1 404 Not Found`r`nContent-Length: $($msg.Length)`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
      $stream.Write($hb, 0, $hb.Length); $stream.Write($msg, 0, $msg.Length)
      continue
    }

    $spec = $specs[$path]
    $total = [int64]$spec.Total

    # --- 故障端点：直接回状态码，不返回任何字节内容
    if ($spec.Mode -eq 'status') {
      $msg = [System.Text.Encoding]::ASCII.GetBytes("status $($spec.Code)")
      $extra = $(if ($spec.ContainsKey('RetryAfter')) { "Retry-After: $($spec.RetryAfter)`r`n" } else { '' })
      $h = "HTTP/1.1 $($spec.Code) $($spec.Reason)`r`nContent-Type: text/plain`r`nContent-Length: $($msg.Length)`r`n${extra}Connection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
      $stream.Write($hb, 0, $hb.Length); $stream.Write($msg, 0, $msg.Length); $stream.Flush()
      continue
    }


    # --- Range 解析
    $rs = [int64]0; $re = $total - 1; $hasRange = $false
    foreach ($l in $lines) {
      if ($l -match '^(?i)Range:\s*bytes=(\d+)-(\d*)\s*$') {
        $hasRange = $true
        $rs = [int64]$Matches[1]
        if ($Matches[2]) { $re = [math]::Min([int64]$Matches[2], $total - 1) }
      }
    }

    if ($spec.Mode -eq 'norange') {
      $len = $total
      $h = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $len`r`nConnection: close`r`n`r`n"
    } elseif ($spec.Mode -eq 'short') {
      $len = [int64]$spec.Send
      $h = ("HTTP/1.1 206 Partial Content`r`nContent-Type: application/octet-stream`r`n" +
            "Accept-Ranges: bytes`r`nContent-Range: bytes {0}-{1}/{2}`r`nContent-Length: {3}`r`nConnection: close`r`n`r`n") -f $rs, ($rs + $len - 1), $total, $len
    } elseif ($hasRange) {
      $len = $re - $rs + 1
      $h = ("HTTP/1.1 206 Partial Content`r`nContent-Type: application/octet-stream`r`n" +
            "Accept-Ranges: bytes`r`nContent-Range: bytes {0}-{1}/{2}`r`nContent-Length: {3}`r`nConnection: close`r`n`r`n") -f $rs, $re, $total, $len
    } else {
      $len = $total; $rs = 0
      $h = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nAccept-Ranges: bytes`r`nContent-Length: $len`r`nConnection: close`r`n`r`n"
    }

    $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
    $stream.Write($hb, 0, $hb.Length)
    Send-Pattern -stream $stream -start $rs -len $len
    $stream.Flush()
  } catch {
    # 客户端被杀/断开是预期场景（续传测试会故意 kill），这里只保证服务循环不死
  } finally {
    if ($client) { try { $client.Close() } catch { } }
  }
}
