---
name: github-release-download-acceleration
description: 从 GitHub Releases 下载几十 MB 到几 GB 的资产，或 Invoke-RestMethod / raw.githubusercontent.com 被「连接被意外关闭」「Connection was reset」挡住时：先只读自检网络家底（并发端口探测、环境变量/系统代理、curl 版本、可选本机内核），再对现有代理 / 本机内核 / 公共镜像 / 直连逐条用 HTTP Range 实测 KB/s 选路（不盲试同一域名、不只凭 200 判可下），按实测结论用 curl 多段 range 并行下载并逐段核对 .part 字节数、某段 0 字节或停滞只补该段，拼装前比总字节数、拼装后核 release digest 的 SHA256，最后跑 exe --version 或解压校验做冒烟；API 只走 curl.exe 落盘再 ConvertFrom-Json，raw 文件改走 contents API；零第三方运行时、不改系统代理、不向用户索要参数，资产名对不上报 ASSET_NOT_FOUND 并列出真实候选。当用户说 GitHub 下载太慢、45MB 下到一半超时、镜像不通、没装加速工具、想多线程下大安装包、文件名可能记错、下载完担心文件残缺、Invoke-RestMethod 报「基础连接已经关闭」、raw.githubusercontent 连接被重置时使用。
metadata:
  min_size_for_ladder_mb: 100
  single_conn_fast_kbps: 3072
---

# GitHub Release 大资产下载加速（自检 → Range 选路 → 分片续传 → 三重校验）

目标：用户只说「帮我下这个 / 太慢了 / 下到一半就断」，技能自己探清家底、按实测 KB/s 选路、必要时分段并行，卡住的段单独补，最后用「总字节 + SHA256 + 冒烟」闭环。前置条件为零：不假设装了 Clash Verge、aria2、7z，不假设系统代理可用，也不要求用户报端口/路径/仓库名。

围栏代码在 Windows PowerShell 5.1 上实跑过（fzf 1.86MB、写错资产名、obs-studio 223MB、rclone 31.6MB、Godot 1.2GB、auto-editor 45.5MB 八段续传），**macOS/Linux 路径未实测**。围栏内禁用 `Format-Table`/`Format-List`：抽块连跑时会污染下一条输出，统一用 `'{0,-28} ...' -f`。

## 环境分发：两个 runner，一套阈值

| 平台 | 入口 | 依赖 |
| --- | --- | --- |
| Windows（PowerShell 5.1+） | `scripts/ghdl.ps1 -Url '<url>' [-OutDir <目录>] [-Parts 16] [-ForceClean] [-KeepParts] [-ForceLadder]` | 系统自带 `curl.exe`（Win10 1803+） |
| macOS / Linux（bash 3.2+） | `bash scripts/ghdl.sh '<url>'`（参数走环境变量，见下） | 系统自带 `curl`；SHA256 用 `openssl` / `shasum` / `sha256sum` 降级链 |
| 任意平台，只想让 agent 照做 | 读本文件 0–10 步围栏 | 无 |

- Windows 版由 `scripts/build-runner.ps1` 从本文件的围栏块生成，**不要手改 `ghdl.ps1`**：改逻辑就改围栏，再重跑生成器。
- macOS/Linux 版 `scripts/ghdl.sh` 是手写脚本，行为对齐：选路 → 阶梯 → 分段/单流 → 自愈 → 三重校验。**macOS 真机未验证**（见 Verification 与文末支持矩阵）。
- 两个 runner 共用同一组阈值：frontmatter `metadata` + 下面「可调参数」表 + 各自代码里的常量，三处必须一致。

## 可调参数

| 参数 | 默认 | 改哪里 | 作用 |
| --- | --- | --- | --- |
| `min_size_for_ladder_mb` | 100 | frontmatter `metadata` + 第 6 步 `$ladderMinMB`（sh: `LADDER_MIN_MB`） | 资产小于该体积就不测并发阶梯（阶梯本身要 20–26 秒，小包纯亏） |
| `single_conn_fast_kbps` | 3072 | frontmatter `metadata` + 第 6 步 `$fastKB`（sh: `FAST_KBPS`） | 单连接达到该速度即判定「没被限速」，直接单流（实测此时多开线程是 0.72×） |

`scripts/validate.ps1` 会把「metadata / 参数表 / 代码常量 / ghdl.sh 环境变量」四处逐项比对，不一致直接 FAIL。

macOS runner 的参数全部走环境变量：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `OUTDIR` | `$HOME/Downloads` | 落盘目录 |
| `PARTS` | 0 | >0 强制定段数（诊断/复现用），0=按阶梯结果 |
| `WORKERS` | 16 | 并发上限（受 `ulimit -n` 制约） |
| `MIN_KBPS` | 100 | 某段 3 秒内低于该速度就掐断换源；0=关闭 |
| `P2SP_URLS` | 空 | 空格分隔的同一文件备源 URL，与代理/镜像混拨；显式备源不做相对速度淘汰 |
| `FORCE_CLEAN` | 0 | 1=删旧分片与旧输出 |
| `FORCE_LADDER` | 0 | 1=强制跑 1 段 vs 16 段对照 |
| `SMOKE` | 1 | 0=关掉后缀冒烟 |
| `KEEP_TMP` | 0 | 1=保留临时目录（排障） |

sh 侧同时接受与 ps1 对齐的命令行选项（优先于同名环境变量），用法 `bash ghdl.sh <url> [选项]`：

| 选项 | 等价的 ps1 参数 | 说明 |
| --- | --- | --- |
| `-o, --outdir DIR` | `-OutDir` | 落盘目录 |
| `-p, --parts N` | `-Parts` | 强制定段数 |
| `--force-clean` | `-ForceClean` | 清旧分片与半成品 |
| `--force-ladder` | `-ForceLadder` | 强制测 1 段 vs 16 段 |
| `--smoke 0\|1` | — | 关/开后缀冒烟 |
| `--keep-tmp` | `-KeepParts` | 保留下载现场 |
| `-h, --help` | — | 打印用法 |

未知选项报 `UNKNOWN_FLAG` 并 exit 2（不会静默当 URL 用）。

macOS 侧实现要点（`scripts/ghdl.sh` 顶部注释同步维护）：

- 端口探测用 `nc -z -w 1 127.0.0.1 <port>`，没有 `nc` 回退 `curl --connect-timeout 1`；不用 `/dev/tcp`（dash/老 bash 下不可用）。
- 开头 `ulimit -n 4096`，抬不上去就打印 `ULIMIT_SKIP` 继续跑，不中断。
- SHA256 降级链：`openssl dgst -sha256 -r` → `shasum -a 256` → `sha256sum`，结果必须是 64 位十六进制，否则 `NO_HASH_TOOL`。
- 并发引擎用「命名队列文件 + `mkdir` 原子锁」，不用 `xargs -P`：`xargs` 做不了「单段 6 秒卡死 → 杀掉 → 续传 → 换源」这套自愈。
- 每段下完先核 `end-start+1` 字节，拼装前逐段强校验；缺一字节就 `SEGMENT_SIZE_MISMATCH` 并保留分片，重跑自动续传。
- `--http2` / `--buffer-size` / `--proxy-http2` 全部先用 `curl --help all` 探测再用（Git Bash 自带的 curl 8.22 既没有 `--buffer-size` 也没编 HTTP/2，硬写参数会直接 exit 2）。
- 服务器忽略 Range（`code=200`）时立刻 `RANGE_UNSUPPORTED` 降级单流，不死磕分段。
- 冒烟按后缀分派：`.zip` → `unzip -tqq`、`.tar.gz/.tgz/.tar` → `tar -tf`、`.exe` 在 macOS 上一律 `smoke=SKIP`（不能执行 Windows 二进制，完整性靠 SHA256）。

## 拿不到 scripts/ 时的最小版（可整段复制）

只有 SKILL.md、且 `raw.githubusercontent` 被墙时用它：只依赖 `curl`，不做选路和多源，
但会分段、续传、强校验。正式场景仍用 `scripts/ghdl.sh`（选路 + 自愈 + digest 闭环）。

```sh
#!/bin/sh
# ghdl-min.sh —— 最小下载器（单文件，可整段复制）。用法: sh ghdl-min.sh <url> [outdir]
# 环境变量: SHA256=<hex>  PROXY=http://127.0.0.1:7897；只依赖 curl，哈希三级降级。
set -u
url=${1:-}; [ -n "$url" ] || { echo "MIN_USAGE: sh ghdl-min.sh <url> [outdir]"; exit 2; }
out=${2:-"$HOME/Downloads"}
mkdir -p "$out" 2>/dev/null || { echo "MIN_NO_OUTDIR: $out"; exit 2; }
name=${url##*/}; name=${name%%\?*}
[ -n "$name" ] || { echo "MIN_BAD_URL: $url"; exit 2; }
dst=$out/$name
proxy=${PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}
fetch() {  # 有代理就带上，没有就不带（不用数组，POSIX sh 没有）
  if [ -n "$proxy" ]; then
    curl -sS -L --connect-timeout 10 --retry 2 -A 'Mozilla/5.0' --proxy "$proxy" "$@"
  else
    curl -sS -L --connect-timeout 10 --retry 2 -A 'Mozilla/5.0' "$@"
  fi
}
# 总长：先 1 字节 Range 的 Content-Range，再退回 HEAD 的 Content-Length
total=$(fetch -r 0-0 -D - -o /dev/null "$url" 2>/dev/null | tr -d '\r' \
  | awk 'tolower($0) ~ /^content-range:/ { split($0,a,"/"); print a[2]; exit }')
[ -n "${total:-}" ] || total=$(fetch -sSI -o /dev/null -D - "$url" 2>/dev/null | tr -d '\r' \
  | awk 'tolower($0) ~ /^content-length:/ { print $2; exit }')
case ${total:-} in ''|*[!0-9]*) total=0 ;; esac
echo "MIN_TOTAL=$total"

if [ "$total" -ge 33554432 ]; then  # >=32MB 才分段，小文件单流更稳
  echo "MIN_SEG=8"
  tmpd=$out/.ghdl_min_$$; rm -rf "$tmpd"; mkdir -p "$tmpd"
  chunk=$(( (total + 7) / 8 )); i=0
  while [ $i -lt 8 ]; do
    s=$((i * chunk)); e=$((s + chunk - 1)); [ $e -ge "$total" ] && e=$((total - 1))
    [ $s -le $e ] && fetch -r "$s-$e" -o "$tmpd/p$i.bin" "$url" &
    i=$((i + 1))
  done
  wait
  i=0; sum=0; bad=0
  while [ $i -lt 8 ]; do
    s=$((i * chunk)); e=$((s + chunk - 1)); [ $e -ge "$total" ] && e=$((total - 1))
    need=$((e - s + 1)); have=$(wc -c < "$tmpd/p$i.bin" 2>/dev/null || echo 0)
    [ "$have" -eq "$need" ] || bad=1
    sum=$((sum + have)); i=$((i + 1))
  done
  if [ "$bad" -eq 0 ] && [ "$sum" -eq "$total" ]; then
    : > "$dst"; i=0
    while [ $i -lt 8 ]; do cat "$tmpd/p$i.bin" >> "$dst"; i=$((i + 1)); done
    rm -rf "$tmpd"; echo "MIN_SEG_OK"
  else
    echo "MIN_SEG_FALLBACK: 分片不齐（$sum/${total}），改单流重下"; rm -rf "$tmpd"
  fi
fi

if [ ! -s "$dst" ]; then
  echo "MIN_SINGLE"
  fetch -C - -o "$dst.part" "$url"; rc=$?
  got=$(wc -c < "$dst.part" 2>/dev/null || echo 0)
  if [ "$total" -gt 0 ] && [ "$got" -ne "$total" ]; then
    echo "MIN_SIZE_MISMATCH: got=$got want=$total (curl rc=$rc)（半截文件保留在 $dst.part）"; exit 1
  fi
  [ "$rc" -ne 0 ] && { echo "MIN_FAILED: curl rc=$rc"; exit 1; }
  mv -f "$dst.part" "$dst"
fi

got=$(wc -c < "$dst" 2>/dev/null || echo 0)
[ "$total" -gt 0 ] && [ "$got" -ne "$total" ] && { echo "MIN_SIZE_MISMATCH: got=$got want=$total"; exit 1; }
if [ -n "${SHA256:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then h=$(openssl dgst -sha256 "$dst" | awk '{print $NF}')
  elif command -v shasum >/dev/null 2>&1; then h=$(shasum -a 256 "$dst" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$dst" | awk '{print $1}')
  else h=""; echo "MIN_SHA_SKIP: 没有可用的 sha256 工具"; fi
  [ -n "$h" ] && [ "$h" != "$SHA256" ] && { echo "MIN_SHA_MISMATCH: got=$h want=$SHA256"; exit 1; }
fi
echo "MIN_OK: $dst ($got 字节)"
```

用法：`sh ghdl-min.sh '<url>' [outdir]`；可选 `SHA256=<hex>`、`PROXY=http://127.0.0.1:7897`。

## 环境自适应决策表

| 自检发现 | 走哪条路线 |
| --- | --- |
| 环境变量/系统代理或常见端口在监听 | A：现有代理，直接 Range 实测；能用就用，别再起第二个内核 |
| 无监听端口，但找到内核 exe 且有 `clash-verge.yaml` | B：无头拉起内核，只监听 `127.0.0.1:7897` |
| 没装内核，或配置/节点缺失 | 跳过 B，走 C（镜像实测）+ D（直连） |
| 直连被 (28) 超时、镜像中途断流 | 换镜像前缀重测（`ghproxy.net` / `gh-proxy.com` / `hk.gh-proxy.com` / `ghfast.top` / `gh.llkk.cc`），取 KB/s 最高一条 |
| 所有路线 0 字节 | 报 `NO_ROUTE` 立即停，列每条 code/bytes/KBps |
| 资产 <100 MB | 不测并发阶梯，单流一次拿完：阶梯要 20–26s，小包纯亏 |
| 资产 ≥100 MB 但单连接 ≥3 MB/s | 单流：单连接没被限速，多开线程只是把同一条管子切碎（实测 0.72×） |
| 资产 ≥100 MB 且单连接 <3 MB/s 或探不到 | 跑 **1/16 两档**阶梯（每档三遍），多段须快 1.25 倍才分段 |
| 用户明确要「单流 vs 多段」对照 | 置 `$ForceLadder = $true`，测 1、4、16 三段 |

### 实测样本：45.5 MB 资产在代理链路上的真实表现（2026-10）

| 路线 | 结果 |
| --- | --- |
| D 直连 github.com | `curl (28)` 10s 内 0 字节 |
| `gh-proxy.com` | 收到 4,012,736 / 45,473,280 字节后 `(28)` 超时；换单流只有 5 KB/s（预计 147 分钟） |
| `ghfast.top` / 直连 `ghproxy.net` | `code=000` 连不上 |
| `hk.gh-proxy.com` | 8 段 Range 全 206，单段 246 KB/s，拼装 45,473,280 字节 = 期望值，sha256 一致，`--version` 输出 31.8.0 |

结论：**路线决定量级，线程只在单连接被限速时再赚 1.5–6 倍**；而「能连上」≠「能下完」，必须边下边看字节增长。

### 错误路径（必须原样报出来，不许猜着继续）

| 判定 | 必须的动作 |
| --- | --- |
| tag 不存在（API 404） | 报 `RELEASE_NOT_FOUND` 并停，先确认 tag |
| API 200 但没有用户给的资产名 | 报 `ASSET_NOT_FOUND` + 全部候选（名字 + MB）+ 最接近一条，停在这里 |
| API 403 限流 | 报 `API_RATE_LIMITED` 但**不停**：提示可设 `GITHUB_TOKEN`（60/h → 5000/h），用已知 total/digest 继续，缺 total 用 `Content-Range` 反推 |
| API 被墙/超时（code 000） | 报 `ASSET_UNVERIFIED`，按用户给的直链继续，只做字节数校验 |
| 所有路线 0 字节或非 2xx | 报 `NO_ROUTE` 并立即停，列出每条路线的 code/bytes/KBps |
| 某分片 0 字节或 6s 无增长 | 只重下该段（不从头），连续 5 次仍短缺才 `SEGMENT_SHORT` |
| 分片字节 ≠ 段长 / sum ≠ total | 报 `SEGMENT_SIZE_MISMATCH` / `PARTS_MISMATCH`，保留分片供续传，禁止拼装 |
| 拼装字节 ≠ total 或 SHA256 ≠ digest | 报 `DOWNLOAD_VERIFY_FAILED`，不许说「下好了」 |
| 字节/哈希都对但冒烟失败 | 报 `SMOKE_FAILED`，说明文件完整但不可用（架构/权限/包损坏另查） |

**API 200 只说明 release/tag 存在**，既不说明资产名对，也不说明可下。资产名对不上是唯一必须回问用户的状态，其余自己探。

### 宿主 shell 硬约束

- PowerShell 5.1 没有 `ForEach-Object -Parallel`，并行一律 `Start-Process` + `Wait-Process -Timeout`。
- `Start-Process -ArgumentList` 传数组不加引号：含空格的参数会被拆坏（`-o` 失效、分片 0 字节）。**并行 curl 参数串里不许有空格**；带空格的请求头只在 `& curl.exe` 直调时用。
- 写脚本文件用 UTF-8 with BOM；写回 SKILL.md 用 `UTF8Encoding($false)`。
- 不要 `& curl … 2>&1`（5.1 会把原生 stderr 变终止错误）：直调用 `2> $errF`，并行用 `-RedirectStandardOutput/-RedirectStandardError`。

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
  $repo = "$($Matches.o)/$($Matches.r)"
}
$direct = $false
if (-not $repo) {
  if ($u -match '^https?://') { $direct = $true; if (-not $asset) { $asset = ($u -split '[?#]')[0].Split('/')[-1] } }
  else { throw 'BAD_URL: 先把 release 直链或 tag 页地址确定下来' }
}
"repo=$repo tag=$tag asset=$asset direct=$direct"
```

1. **只读自检：探清家底，不装东西、不改系统、不问用户。** 端口真在监听才算数（`ProxyEnable` 残留值不算）。多端口用并发 TcpClient 探测（实测 11 口 0.4s，串行逐口 600ms 要 6.2s）；只对最终候选口用 `Test-NetConnection` 复核一次。

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
if (-not $curlOk) { throw 'NO_CURL: 端口探测/镜像/分段全部不可用；Windows 用 Invoke-WebRequest 单流降级，POSIX 直接停' }
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

2. **定位本机 Clash 内核与配置（找不到就跳过 B 路线）。** 已有代理在监听就整段跳过（实测省 5–6 秒），日志必须出现 `KERNEL_SCAN_SKIPPED`。

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

3. **取 release 元数据并校验资产名（测速前的硬闸门）。只用 curl.exe，不要对这个 URL 用 `Invoke-RestMethod`。** 实测 `Invoke-RestMethod -Uri 'https://api.github.com/repos/.../releases?per_page=15'` 直接抛「基础连接已经关闭: 连接被意外关闭」，同一 cmdlet 重试无效。

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

> 总字节数未知时不要猜着切段：分段需要 total 才能算每段区间。

4. **并行短测各条路线：每条都真跑一次 Range GET。** 超时 8s、`--connect-timeout 5`、只取 1MB；B 路线留到第 5 步。排序先看「拿到 ≥512KB」再看 KBps——镜像回一页 HTML 错误页也会「很快」。

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

> 实测：`proxy7897=False`（端口没监听）时 `skip proxy`，`direct -> 200`；反过来直连被打回时先 `Test-NetConnection 127.0.0.1:<port>` 再决定加不加 `--proxy`，别硬编码代理。

5. **没有可用代理时才无头拉起内核，只监听 127.0.0.1:7897，并只记自己起的 pid。** 用户原本在跑的 7897 不许停；起不来就立刻杀掉自己那一个，回 C/D。顺带量一次 8MB 单连接速度（小资产跳过）。

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

6. **先判值不值得测，再做限时阶梯。** 默认只在「资产 ≥100 MB 且 `$singleKB < 3072`」时跑 **1/16 两档**；用户要对照才置 `$ForceLadder = $true` 跑 1、4、16。每档 n 条连接各从自己起点 open-range 读到文件尾，同一时间窗比聚合吞吐，三遍交错取中位数并报 min–max。

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

判定：只有「完成数 = n/n」的档位能胜出；多段必须快过单段 1.25 倍才分段，否则 `$winN=1` 并把倍数写进报告。`$total` 未知时按 64MB 估起点。

7. **按胜出组合下载。** 单流优先用 **asset id URL + `Accept: application/octet-stream`**（避免 302 到过期签名链）；分段仍用 `browser_download_url`（range 实测稳定）。分段时**起始并发 = `$winN`**、按队列波次推进，每 500ms 轮询 `.part` 增长，单段 6 秒无增长就杀那一条 curl、只把该段塞回队列。

```powershell
$ErrorActionPreference = 'Stop'
$vc = $(if ($curlVer -match '^(\d+)\.(\d+)') { [version]"$($Matches[1]).$($Matches[2])" } else { [version]'0.0' })
$retry = @('--retry','3','--retry-delay','2')
if ($vc -ge [version]'7.71') { $retry += '--retry-all-errors' } else { "RETRY_DEGRADED: curl $curlVer < 7.71，只用 --retry 3 --retry-delay 2" }
$base = $(if ($OutDir) { $OutDir } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' })
$dir = Join-Path $base '_dl_parts'
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

> 实测：8 段并行跑到 87.5% 时 `02.part` 长时间 0 字节、其余 7 段早已打满，整体停滞；此时**不要从头来**——停掉该段进程、只对 `02` 那一段再发一次 `-r <start>-<end>`（实测 5,684,160 字节、246 KB/s），再进入拼装。

8. **拼装前逐段强校验，再按 p000→pN 拼。** 每段长度必须精确等于 `end-start+1`；缺段或多出字节都报 `SEGMENT_SIZE_MISMATCH` 并列出段号/期望/实际。

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

9. **用 asset digest 做「字节数 + SHA256」闭环，再跑一次冒烟。** 无 digest 的老 release 如实报缺基准，不伪造校验，也不用 Authenticode 兜底（实测该安装包 `NotSigned`）。

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

10. **收尾只还原自己动过的东西。** 只按 `$corePid`/`$pids` 以 Id 停进程；别 `Stop-Process -Name curl`（会杀用户自己的下载），别关用户原本在跑的代理。

```powershell
if ($corePid) { Stop-Process -Id $corePid -ErrorAction SilentlyContinue }
if ($verifiedOk -and -not $KeepParts) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
elseif (Test-Path $dir) { "PARTS_KEPT: 分片保留在 $dir（校验未通过或 -KeepParts；重跑会续传，-ForceClean 可清掉重下）" }
Get-ChildItem $env:TEMP -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like 'ladder_*' -or $_.Name -like 'probe_*' -or $_.Name -like 'meta_*' -or $_.Name -like 'cur_*' -or $_.Name -like 'raw_*' -or $_.Name -like 'ver_*' -or $_.Name -like 'smoke_*' } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
"7897=$([bool](Test-Port '127.0.0.1' 7897)) corePid=$corePid"
if ($onWin) { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable }
```

### 报告模板（小白只看这四行）

- `路线=A/B/C/D；探针 KBps: 直连 0 / gh-proxy 22110 中途断 / hk.gh-proxy 成功；分片 nseg=8 chunk=…MB workers=…，补段 repairs=N，stalls=N`
- `已下载并校验：<MB>，平均 <MB/s>，sha256=<64 位十六进制> 与 release digest 一致（无 digest 写 NO_DIGEST 只校验字节数）`
- `冒烟：--version -> 31.8.0` 或 `unzip_ok files=N`
- `文件=<绝对路径>`

### 收益汇报：时间降幅与速度升幅不是一回事

`speed% = (v2/v1 - 1) * 100`；`time% = (t2/t1 - 1) * 100 = (v1/v2 - 1) * 100`。同样的 6.28× 速度写着 **+528% 速度** 对应 **−84.1% 时间**——两个数字不能混用，也不能只给其中一个。

| 场景 | 单流 | 16 段 | 速度 | 耗时 |
| --- | --- | --- | --- | --- |
| 节点限单连接（223.7MB / 28.2s） | 4.9 MB/s | 7.7 MB/s | +57.1% | −36.4% |
| 节点不限速（31.6MB，同机同日） | 5.8 MB/s | 4.2 MB/s | −27.6% | +38.1% |

- **分场景给结论**；不限速场景如实报回落（实测 −27.6%），**不许四舍五入成 0%**；若实测回落 ≤5%，写「0% 收益 / 5% 容差内无回归」并注明容差。
- 写清同一资产字节数、实测次数（每档 3 遍取中位）与日期，并给出复跑方式（第 6 步 `$ForceLadder=$true`）。
- 报告写实测平均速度（size/elapsed），不写 `speed_download` 峰值。

### 小文件/文本走同一条代理通道（web_fetch 被墙时）

`raw.githubusercontent.com` 被墙时别重试同一 URL，改走 contents API（`Accept: application/vnd.github.raw`）。
可直接复制的命令与实测字节数见 `references/fetch-raw-via-api.md`。

### 其他分发渠道（不是 GitHub Release 时）

- 镜像/厂商分发站（`registry.npmmirror.com` 的 `ffmpeg-static` 目录、官方 CDN 等）常比 GitHub Release 稳，但 **TODO：本技能未实测这些路径的目录结构与校验方式**，用之前先按第 4 步同样手法做 Range 实测，不要照抄 URL 猜文件名。
- 装完必须实跑 `ffmpeg -version` 之类冒烟并核 libx264/aac 等编码器，别只看文件存在（与第 9 步同一原则）。

## Pitfalls

- **不要假设环境，也不要向用户要参数。** 端口、内核路径、配置目录自己查；仓库名不能凭产品名猜。
- **「能连上」≠「能下完」**：直连 10s 就 `(28)` 0 字节；`gh-proxy.com` 下到 4,012,736/45,473,280 字节才 `(28)`。所以选路必须用 Range 实测 KB/s，下载过程必须看 `.part` 字节增长，而不是发一次 GET 成功就算通。
- **不要反复重试同一个域名**：`ghfast.top`、直连 `ghproxy.net` 实测 `code=000`，重试只会烧时间；换前缀（`hk.gh-proxy.com` 实测可用）重测一次即可。
- **单流 5 KB/s 就是该换路了**：实测 gh-proxy 单流 5 KB/s（45MB 要 147 分钟），此时立刻 kill 换镜像前缀/分段，不要干等。
- **某片 0 字节不要整包重来**：8 段跑到 87.5% 时 `02.part` 卡 0 字节，正确做法是停掉该段、只对那段 `-r start-end` 补一次；整包重下等于把 39.8MB 白扔。
- **`.part` 字节数是唯一真相**：拼装前必须逐段 `Length == end-start+1` 且 `sum == total`，任何一项不符就 `SEGMENT_SIZE_MISMATCH`/`PARTS_MISMATCH` 并保留分片。
- **拼装后还要 SHA256 + 冒烟**：`final bytes=45,473,280 match=True` 只是必要条件，还要 `sha256` 对 digest、`--version` 输出 31.8.0 才算「没坏」。
- **冒烟命令别用 `2>&1`**：原生程序把 ANSI 进度写 stderr，5.1 会变成终止错误；用 `& $out --version *> $verF` 再读文件。
- **`Invoke-RestMethod` 打 api.github.com 可能直接失败，别在同一 cmdlet 上重试**：换 `curl.exe -sS -m 40 -H 'User-Agent: dsh-agent' -H 'Accept: application/vnd.github+json' -o <临时文件>`，再 `Get-Content -Raw | ConvertFrom-Json`。
- **无代理路线必须 `--noproxy *`**：curl 默认吃 `HTTP_PROXY` 等环境变量，残留的死代理会把「直连」一起打成 000。本机/内网目标（`localhost`、`127.*`、`10.*`、`192.168.*`、`172.16-31.*`）不打代理、不试镜像，只印 `LOCAL_TARGET:` 走原地址；ps1/sh 两侧同规则。
- **决定代理前先判端口**：`Test-NetConnection -ComputerName 127.0.0.1 -Port 7897 -InformationLevel Quiet`（或并发 TcpClient 批量探）返回 False 就别加 `--proxy`——实测 `proxy7897=False` 时直连 200，加代理只会 000。
- **`Port open: False` 不等于代理已启用，`ProxyServer` 残留值也不等于**（`ProxyEnable: 0` 仍留着 `127.0.0.1:7897`）。
- **资产名对不上必须 `ASSET_NOT_FOUND` + 候选清单，禁止静默换名**；API 200 ≠ 资产名对，API 403 也不是 NO_ROUTE。
- **403 要提示 `GITHUB_TOKEN`**（60/h → 5000/h），同时不停：用已知 total/digest 继续，缺 total 用 `-r 0-0` 的 `Content-Range` 反推；**total 未知时明确 `PARTS_IGNORED` 走单流**。
- **下载走 asset id**（`/releases/assets/<id>` + `Accept: application/octet-stream`），下完必须同时比 size 与 digest sha256。
- **`raw.githubusercontent.com` 被 reset 就别重试同一 URL**：改 contents API + `Accept: application/vnd.github.raw`，落盘后报字节数（实测 35598 / 8094），0 字节报 `RAW_UNVERIFIED`。
- **并发不是越多越快。** 实测 16 段 7.7 MB/s 最优、24 段 6.0、32 段 6.3 回落；节点快时 16 段只有 0.72×。每轮现测，别背历史数字。
- **卡住判定别设 4 秒**（慢启动会被误杀）；6 秒（12 × 500ms）才稳。
- **忘 `-L` 就只剩 302 和 0 字节**；判断可下用 `-r 0-1023` 的 GET（要 206），别用 `-I`/HEAD。
- **镜像必须实测，全灭很正常**；镜像「快」可能是回了错误页：排序先看 `Bytes ≥ 512KB` 再看 KB/s。
- **只杀自己的进程。** `Stop-Process -Name curl` 会杀用户自己的下载；收尾/降档只能用 `$corePid`、按目录匹配到的孤儿 pid。
- **`Start-Process -ArgumentList` 不加引号**：并行 curl 参数串不许有空格；带空格的请求头只在 `& curl.exe` 直调时用。
- **别用 `& curl … 2>&1` 收结果**（原生 stderr 变 ErrorRecord，撞 `$ErrorActionPreference='Stop'` 即终止错误）；直调用 `2> $errF`。
- **`--retry-all-errors` 要 7.71+**，Win10 自带 7.55 会 `unknown option`：先取版本，低版本打 `RETRY_DEGRADED`。
- **`curl -K cfg` 里的 `next` 分组不可靠**（实测只跑第一段就 exit 0），多段并行必须命令行 `--next`。
- **小段测速会把单流测冤枉**：必须每档 n 条同时 open-range 到文件尾、限同一时间窗，别用固定 1MB 段。
- **`<100MB 走单流` 必须落成代码**（`$ladderMinMB`）；第 5 步 B 路线阈值要按资产大小算（range `0-8388607` 对 <8MB 资产返回 200 + 整包）。
- **重定向链的响应头有多份**：`-D` 会把 302 那跳的 `Content-Length: 0` 写在开头，必须取最后一个。
- **直链的总长探测也得走代理**：本机 `raw.githubusercontent.com` 不加 `--proxy` 时 `Content-Range` 探测静默失败，`total` 退化成 0。
- **小文件不能用 256KB 当探针门槛**（直链常是小文本，会误判 `NO_ROUTE`）；已知 total 降到 total，未知直链降到 1KB。
- **报告写实测平均速度，不要写峰值**；收益必须同时给时间降幅与速度升幅，并说明两者不等价。
- **写技能自己的 .ps1 必须带 BOM**（`UTF8Encoding($true)`）；写回 SKILL.md 相反用 `UTF8Encoding($false)`。`Get-ChildItem -Filter` 只接受单个字符串，多模式用 `Where-Object Name -like`。
- **SKILL.md 体积有硬上限 65536 字节**：本轮就因超限被拒过一次。改完必须 `(Get-Item SKILL.md).Length` 自检，超了先删重复段落（同一事实只写一次），别删校验步骤。
- **续传 manifest 必须先校验 `total` 与 `url`**；`.resume` 合并前要 `Wait-Process` 再 10×300ms 重试（实测直接 `OpenRead` 撞「文件被另一进程占用」）。
- **收尾清理只删自己建的东西**：别用 `-like 'ghdl_*'` 扫 `%TEMP%`（实测删掉别人的 `%TEMP%\ghdl_tests`，表现为「下载成功但文件不见了」）。
- **本机假服务器是单线程的**：`tests/serve.ps1` 串行处理连接，探针会全 `000` → `NO_ROUTE`；这是夹具限制。
- **直链模式没有 digest**，报告必须写「只校验了字节数」。
- **版本对比先取证再下结论**：`git tag --list` 核实真实 tag（本项目是 `v0.1.0` / `v0.2.0` / `v0.2.1`，**没有** 1.0），再 `git diff --stat <base>..HEAD` 给文件数与增删行数；不许自设「里程碑」当基准，也不许用分条清单代替按维度标新增/重写/沿用的对比表。
- TODO：宿主已装 aria2c 时可用 `aria2c -x16 -s16 --all-proxy=...` 替代手写分段，未实测，暂不纳入默认流程。

- `curl --parallel`（单进程内并发）**实现过、实测过、又撤了**：P2 阶段 16 段同资产对照 `--parallel` 31.6s vs 多进程自适应 32.3s（噪声内），但 `--parallel -K cfg` 只能整批跑完，单段卡死时无法只杀那一段、换源、续传重排队——等于拿可靠性换 0.7 秒。P3 重写引擎时移除；若要加回，作为可选快路径，不当默认。
- `SKILL.md` 有 64KB 硬上限（部分宿主把超大 SKILL.md 截断）：新增内容先看 `validate.ps1` 的体积行，逼近上限就把长表拆到 `references/`。

## Verification

- 自检输出说清路线，并打印 `probeSec`（亚秒级 ~0.4s，非 6s）；已有代理时出现 `KERNEL_SCAN_SKIPPED`、没有全盘扫描阶段。
- **选路证据**：探针表逐条打印 `code/bytes/KBps`，被拒绝的路线（`000`、中途 `(28)`）也在表里；`route=… KBps=…` 与最终 `pool=` 一致，说明没有盲试同一域名。
- **API 替代取法的证明**：日志有 `api=200` + `bytes=<非零>`，且无 `Invoke-RestMethod` 报错行；403 是 `API_RATE_LIMITED` + GITHUB_TOKEN 提示，被墙是 `ASSET_UNVERIFIED` + `range_probe` 反推 total。
- 第 3 步打印 `asset=… total=… want=… assetId=…`；资产名对不上必须输出 `ASSET_NOT_FOUND`、全部候选（名字+MB）与最接近一条，且没生成下载文件、没进第 4 步探测。
- **进度证据**：>100MB 资产下载途中每 3 秒应有 `progress=<已下>MB/<总>MB (<pct>%) running=<n> rate=<KBps>`，静默超过 10 秒说明引擎没在动（或已卡死）。
- **分片证据**：`PLAN: nseg=… chunk=…MB workers=…`（chunk 落在 2–24MB、nseg ≤ 128），随后 `engine_done=segments nseg=… stalls=… repairs=…`；出现 0 字节段时日志必须是 `repairs ≥ 1` 且只补该段，不是从头重下。
- **完整性三重证据**：`partsBytes=<sum> total=<total> ok=True` → `size=<size> sizeOk=True` → `sha256=<64 位十六进制>` 与 `digest=sha256:…` 一致 → `DOWNLOAD_VERIFIED_OK`；无 digest 时 `DOWNLOAD_SIZE_OK_NO_DIGEST`。
- **冒烟证据**：exe 打印 `smoke=31.8.0`（或实际版本号）；zip 打印 `smoke=unzip_ok files=N`。只打印路径不算通过。
- **curl 能力不能只看 `--help`**：本机 curl 8.22 的 `--help all` 里明明列出 `--proxy-http2`，真用就报 `the installed libcurl version does not support this`（`--http2`、`--buffer-size` 同样）。探测方式必须是「跑一次 `curl <option> --version`，看 stderr 有没有 `does not support` / `is unknown`」，ps1 侧同一原则。
- **POSIX 的 `xargs -P` 不够用**：它没法对「单段卡死 → 杀掉 → 续传 → 换源」做决策。ghdl.sh 用「队列文件 + `mkdir` 原子锁」的 worker 池，`xargs` 只适合一次性的纯并发。
- **macOS 的 BSD 工具与 GNU 不同**：`date +%s%N` 在 BSD 上不支持（ghdl.sh 因此改用各 curl 自报的 `speed_download` 累加计时）；`sed -i` 需要备份后缀；`pgrep -f` 行为与 Linux 有差异（Git Bash 干脆没有 `pgrep`）。写 sh 版一律按 POSIX + BSD 可用子集，别用 GNU 扩展。
- **单流 Content-Length**：输出 `content_length_ok=<total>（取重定向链最后一个）`，并说明 302 那跳的 `Content-Length: 0` 不能当判据。
- **小资产/快节点分支**：`$total < 100MB` 或 `$singleKB ≥ 3072` 时日志有 `SKIP_LADDER` 与 `SINGLE_KB_SKIPPED`、`SINGLE exit=0`，无分段行。
- **限速节点分支**：只跑 1/16 两档、每档三遍，逐档输出「完成 n/n」、中位与 min–max，最后 `LADDER_DONE: … winN=…`；不出现 4 段档。
- **P3 断言**：直链走 `direct=True`；重跑命中 `ALREADY_DONE` 或 `RESUME_PLAN`；逐段不符必须 `SEGMENT_SIZE_MISMATCH` + 退出码 1 + `PARTS_KEPT`（且不能打印 `DOWNLOAD_VERIFIED_OK`）。
- **跨平台分发**：Windows 跑 `scripts/ghdl.ps1`，macOS/Linux 跑 `scripts/ghdl.sh`；两边日志都应有 `skip_ladder`/`SKIP_LADDER` 与同一组阈值（100MB / 3072KB/s）。
- **macOS 侧回归（离线）**：`bash tests/run-tests-sh.sh` 用 `tests/serve.py` 起本地假服务器，覆盖单流/8 段/续传/不支持 Range/404/截断包/P2SP 双源/P2SP 死源/坏分片/幂等/KEEP_TMP/后缀冒烟；Windows 上跑要给 `PYTHON=<真实 python3>`（应用商店的 `python3` 是空壳）。2026-10-30 在 Git Bash 上实测 `TESTS_SH_OK: 17 项通过`。
- **收尾**：`7897` 不再监听、无本次 `verge-mihomo` 残留、`ProxyEnable` 与开始时一致。
- **文件体积**：`(Get-Item SKILL.md).Length` ≤ 65536（上限硬约束）。

### 支持矩阵（实测到哪一步就写哪一步）

| 能力 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| `scripts/ghdl.ps1`（生成物） | 已实测：fzf 1.86MB / OBS 213MB / rclone 31.6MB / Godot 1.2GB，含 `-Parts`、`-ForceClean`、续传、截断、无 Range、404 | 不适用（PowerShell 5.1 专属） | 不适用 |
| `scripts/ghdl.sh`（手写） | 部分验证：Git Bash 上单流/8 段/续传/无 Range/404/截断/P2SP 全过（`tests/run-tests-sh.sh`） | **未实测**：脚本按 macOS 自带 bash 3.2 + BSD 工具写，`nc -z`/`openssl -r`/`unzip -tqq` 的 BSD 行为未在真机跑过 | **未实测**，同上 |
| 环境探测（端口/代理/内核） | 已实测 | 部分（`nc` 分支未在真机跑） | 部分 |
| 三重校验（字节 + SHA256 + 冒烟） | 已实测 | 部分（`openssl`/`shasum` 分支未在真机跑） | 部分 |

## 维护与自检（改完必跑）

三个非模型文件随文档同步：`agents/openai.yaml`（`short_description` 25–64 字符、含 `$github-release-download-acceleration`）、`README.md`（与本文一致）、`scripts/validate.ps1`（退出码非 0 就是文档有问题）。改第 0–9 步代码后 `scripts/ghdl.ps1` 由 `scripts/build-runner.ps1` 重新生成；`tests/` 是离线回归套件。

```powershell
$root = '<技能目录>'
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\validate.ps1'); "exit=$LASTEXITCODE"
"SKILL_MD_bytes=" + (Get-Item (Join-Path $root 'SKILL.md')).Length        # 必须 ≤ 65536
"SKILL_MD_BOM=" + ([IO.File]::ReadAllBytes((Join-Path $root 'SKILL.md'))[0] -eq 0xEF)   # 必须 False
$t = [IO.File]::ReadAllText((Join-Path $root 'SKILL.md'), [Text.Encoding]::UTF8)
$code = ([regex]::Matches($t, '(?ms)^[ \t]*```(?:powershell|pwsh|ps1)[ \t]*\r?\n(?<code>.*?)^[ \t]*```') | ForEach-Object { $_.Groups['code'].Value }) -join "`n"
"hardcoded_core_path_hits=" + ([regex]::Matches($code, 'D:\\Clash Verge')).Count                     # 必须 0
```

- **门槛可配且只改一处会被拦住**：frontmatter `metadata.min_size_for_ladder_mb` = 100 / `single_conn_fast_kbps` = 3072，与正文参数表、代码 `$ladderMinMB = 100` / `$fastKB = 3072` 三处一致；只改一处时 `validate.ps1` 输出「不一致：改阈值要两处同步」并 `exit=1`，一致时 `VALIDATE_OK` + `exit=0`。
- **离线回归**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1` 必须 `TESTS_OK`；网络全断时用离线夹具，夹具 PASS 只能报成离线验证。
- **加载证明**：`skill` 工具能真正加载 `github-release-download-acceleration`。
