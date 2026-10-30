# 小文件 / 文本走 contents API（web_fetch 被墙时）

`raw.githubusercontent.com` 实测 `curl: (35) Recv failure: Connection was reset`、落盘 0 字节，**同一 URL 重试无效**。改走 contents API：

```powershell
$repo = 'Tencent/BrowserSkill'; $path = 'README.md'; $ref = 'main'
$rawOut = Join-Path $env:TEMP ("raw_{0}.md" -f [guid]::NewGuid().ToString('N').Substring(0,6))
$hdrRaw = @('-H','User-Agent: dsh-agent','-H','Accept: application/vnd.github.raw')
$ua = $(if ($winProxy) { @('--proxy',$winProxy) } else { @() })
$code = (& $curlExe -sS -m 40 @ua @hdrRaw -o $rawOut -w '%{http_code}' "https://api.github.com/repos/$repo/contents/$path?ref=$ref" 2> "$rawOut.err")
$bytes = $(if (Test-Path $rawOut) { (Get-Item $rawOut).Length } else { 0 })
"contents api=$code bytes=$bytes"
if ($bytes -eq 0) { throw "RAW_UNVERIFIED: contents API 返回 $code 且 0 字节（$((Get-Content "$rawOut.err" -Raw -ErrorAction SilentlyContinue).Trim())）" }
$txt = Get-Content $rawOut -Raw -Encoding UTF8
if ($txt.Length -gt 0) { $txt.Substring(0, [math]::Min(1200, $txt.Length)) }
Remove-Item $rawOut,"$rawOut.err" -Force -ErrorAction SilentlyContinue
```

实测：`bytes: 35598`（README）、`bytes: 8094`（AGENT_INSTALL.md）。收尾照样走第 10 步。

