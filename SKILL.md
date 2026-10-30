---
name: github-release-download-acceleration
description: 从 GitHub Releases 下载几十 MB 到几 GB 的资产，或 Invoke-RestMethod / raw.githubusercontent.com 被「连接被意外关闭」「Connection was reset」挡住时：先只读自检网络家底（并发端口探测、环境变量/系统代理、curl 版本、可选本机内核），再对现有代理 / 本机内核 / 公共镜像 / 直连逐条用 HTTP Range 实测 KB/s 选路（不盲试同一域名、不只凭 200 判可下），按实测结论用 curl 多段 range 并行下载并逐段核对 .part 字节数、某段 0 字节或停滞只补该段，拼装前比总字节数、拼装后核 release digest 的 SHA256，最后跑 exe --version 或解压校验做冒烟；API 只走 curl.exe 落盘再 ConvertFrom-Json，raw 文件改走 contents API；零第三方运行时、不改系统代理、不向用户索要参数，资产名对不上报 ASSET_NOT_FOUND 并列出真实候选。当用户说 GitHub 下载太慢、45MB 下到一半超时、镜像不通、没装加速工具、想多线程下大安装包、文件名可能记错、下载完担心文件残缺、Invoke-RestMethod 报「基础连接已经关闭」、raw.githubusercontent 连接被重置时使用。
whenToUse: 维护本技能包自身时也用：SKILL.md 逼近 65,536 字节要按施工法拆到 references/、改 ghdl.sh 后要与 ghdl.ps1 逐项对齐验收、核对某个版本是否 tag/Release/npm/CI 全发齐。
metadata:
  min_size_for_ladder_mb: 100
  single_conn_fast_kbps: 3072
---

# GitHub Release 大资产下载加速（自检 → Range 选路 → 分片续传 → 三重校验）

目标：用户只说「帮我下这个 / 太慢了 / 下到一半就断」，技能自己探清家底、按实测 KB/s 选路、必要时分段并行，卡住的段单独补，最后用「总字节 + SHA256 + 冒烟」闭环。前置条件为零：不假设装了 Clash Verge、aria2、7z，不假设系统代理可用，也不要求用户报端口/路径/仓库名。

围栏代码在 Windows PowerShell 5.1 上实跑过（fzf 1.86MB、写错资产名、obs-studio 223MB、rclone 31.6MB、Godot 1.2GB、auto-editor 45.5MB 八段续传）；macOS/Linux 侧只在 CI 的 `macos-latest` / `ubuntu-latest` 跑通 23 条离线套件，**真机速度未实测**（口径见支持矩阵）。围栏内禁用 `Format-Table`/`Format-List`：抽块连跑时会污染下一条输出，统一用 `'{0,-28} ...' -f`。

## 环境分发：两个 runner，一套阈值

| 平台 | 入口 | 依赖 |
| --- | --- | --- |
| Windows（PowerShell 5.1+） | `scripts/ghdl.ps1 -Url '<url>' [-OutDir <目录>] [-Parts 16] [-ForceClean] [-KeepParts] [-ForceLadder] [-Sha256 <hex>]` | 系统自带 `curl.exe`（Win10 1803+） |
| macOS / Linux（bash 3.2+） | `bash scripts/ghdl.sh '<url>'`（参数走环境变量，见下） | 系统自带 `curl`；SHA256 用 `openssl` / `shasum` / `sha256sum` 降级链 |
| 任意平台，只想让 agent 照做 | 读本文件 0–10 步围栏 | 无 |

- Windows 版由 `scripts/build-runner.ps1` 从 `references/runner-steps.md` 的围栏块生成，**不要手改 `ghdl.ps1`**：改逻辑就改那个文件，再重跑生成器。
- macOS/Linux 版 `scripts/ghdl.sh` 是手写脚本，行为对齐：选路 → 阶梯 → 分段/单流 → 自愈 → 三重校验。**macOS 真机未验证**（见 Verification 与文末支持矩阵）。
- 「任意 agent」指**有本地命令执行权的 agent**：网页版/手机端没有 CLI，只能读步骤人工核对，不能承诺通用。
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
| `SHA256_EXPECT` | 空 | release 页上的 sha256；API 被限流拿不到 digest 时手动给，照样做 SHA256 闭环 |
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
| `--sha256 HEX` | `-Sha256` | 手动给期望 digest（API 403 时用） |
| `-h, --help` | — | 打印用法 |

未知选项报 `UNKNOWN_FLAG` 并 exit 2（不会静默当 URL 用）。

macOS 侧实现要点（`scripts/ghdl.sh` 顶部注释同步维护）：

- 端口探测顺序：`nc -z -w 1`（BSD nc 支持 `-w`）→ bash `/dev/tcp`（Git Bash 没 `nc`）→ `curl -x` 当代理试连；只 `curl http://端口` 会误判未开。
- 开头 `ulimit -n 4096`，抬不上去就打印 `ULIMIT_SKIP` 继续跑，不中断。
- SHA256 降级链：`openssl dgst -sha256 -r` → `shasum -a 256` → `sha256sum`，结果必须是 64 位十六进制，否则 `NO_HASH_TOOL`。
- 并发引擎用「命名队列文件 + `mkdir` 原子锁」，不用 `xargs -P`：`xargs` 做不了「单段 6 秒卡死 → 杀掉 → 续传 → 换源」这套自愈。
- 每段下完先核 `end-start+1` 字节，拼装前逐段强校验；缺一字节就 `SEGMENT_SIZE_MISMATCH` 并保留分片，重跑自动续传。
- `--http2` / `--buffer-size` / `--proxy-http2` 全部先用 `curl --help all` 探测再用（Git Bash 自带的 curl 8.22 既没有 `--buffer-size` 也没编 HTTP/2，硬写参数会直接 exit 2）；**探测不到就整段不加，绝不因选项不支持退出**。
- 服务器忽略 Range（`code=200`）时立刻 `RANGE_UNSUPPORTED` 降级单流，不死磕分段。
- 阶梯与 ps1 同口径：1/16 两档各跑三遍、交错执行，取**中位数**再比 1.25 倍（单次 1MB 探针噪声可达 3–10 倍，一遍定胜负会来回翻结论）；只有 `16/16` 完成的那一档才算数。
- 并发与 ps1 同策略：阶梯证明「多段快 ≥2 倍」或单连接被限速时直接拉满；单连接已经够快就先起 4 条，按 1 秒窗口逐级 8→16，出现 2 段卡住就停手（`RAMP_UP` / `BACKOFF`）。
- 进度：每 4 秒一行 `progress=…MB/…MB (…%) running=… rate=…KB/s`，静默超过 15 秒说明卡死。
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

## 文件布局（为什么正文里没有代码）

- `SKILL.md`（本文）= 索引：决策表、步骤说明、参数、Pitfalls、校验口径。**不放运行时代码**。
- `references/runner-steps.md` = 0–10 步的 powershell 真源；`scripts/build-runner.ps1` 用它生成 `scripts/ghdl.ps1`。
- `scripts/ghdl.ps1` / `scripts/ghdl.sh` = 两平台可直接执行的 runner；`scripts/ghdl-min.sh` = 单文件最小版（本文末尾内联同一份）。
- 这么拆是因为宿主对 `SKILL.md` 有 65,536 字节硬上限，30KB+ 代码留在正文会被拒收。要读代码：打开 `references/runner-steps.md`，按块号对应下面的步骤。
- 要再拆一次、或核对 sh 与 ps1 是否对齐，按文末「施工法 A / B」逐条跑，不要凭记忆。

## Steps

0. **把用户给的地址拆成 `repo/tag/asset`。** 只丢一个 release 页或直链也行，不要反问。

（运行时代码：`references/runner-steps.md` 块 0。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

1. **只读自检：探清家底，不装东西、不改系统、不问用户。** 端口真在监听才算数（`ProxyEnable` 残留值不算）。多端口用并发 TcpClient 探测（实测 11 口 0.4s，串行逐口 600ms 要 6.2s）；只对最终候选口用 `Test-NetConnection` 复核一次。

（运行时代码：`references/runner-steps.md` 块 0。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

2. **定位本机 Clash 内核与配置（找不到就跳过 B 路线）。** 已有代理在监听就整段跳过（实测省 5–6 秒），日志必须出现 `KERNEL_SCAN_SKIPPED`。

（运行时代码：`references/runner-steps.md` 块 1。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

3. **取 release 元数据并校验资产名（测速前的硬闸门）。只用 curl.exe，不要对这个 URL 用 `Invoke-RestMethod`。** 实测 `Invoke-RestMethod -Uri 'https://api.github.com/repos/.../releases?per_page=15'` 直接抛「基础连接已经关闭: 连接被意外关闭」，同一 cmdlet 重试无效。

（运行时代码：`references/runner-steps.md` 块 2。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

> 总字节数未知时不要猜着切段：分段需要 total 才能算每段区间。

4. **并行短测各条路线：每条都真跑一次 Range GET。** 超时 8s、`--connect-timeout 5`、只取 1MB；B 路线留到第 5 步。排序先看「拿到 ≥512KB」再看 KBps——镜像回一页 HTML 错误页也会「很快」。

（运行时代码：`references/runner-steps.md` 块 3。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

> 实测：`proxy7897=False`（端口没监听）时 `skip proxy`，`direct -> 200`；反过来直连被打回时先 `Test-NetConnection 127.0.0.1:<port>` 再决定加不加 `--proxy`，别硬编码代理。

5. **没有可用代理时才无头拉起内核，只监听 127.0.0.1:7897，并只记自己起的 pid。** 用户原本在跑的 7897 不许停；起不来就立刻杀掉自己那一个，回 C/D。顺带量一次 8MB 单连接速度（小资产跳过）。

（运行时代码：`references/runner-steps.md` 块 4。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

6. **先判值不值得测，再做限时阶梯。** 默认只在「资产 ≥100 MB 且 `$singleKB < 3072`」时跑 **1/16 两档**；用户要对照才置 `$ForceLadder = $true` 跑 1、4、16。每档 n 条连接各从自己起点 open-range 读到文件尾，同一时间窗比聚合吞吐，三遍交错取中位数并报 min–max。

（运行时代码：`references/runner-steps.md` 块 5。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

判定：只有「完成数 = n/n」的档位能胜出；多段必须快过单段 1.25 倍才分段，否则 `$winN=1` 并把倍数写进报告。`$total` 未知时按 64MB 估起点。

7. **按胜出组合下载。** 单流优先用 **asset id URL + `Accept: application/octet-stream`**（避免 302 到过期签名链）；分段仍用 `browser_download_url`（range 实测稳定）。分段时**起始并发 = `$winN`**、按队列波次推进，每 500ms 轮询 `.part` 增长，单段 6 秒无增长就杀那一条 curl、只把该段塞回队列。

（运行时代码：`references/runner-steps.md` 块 6。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

> 实测：8 段并行跑到 87.5% 时 `02.part` 长时间 0 字节、其余 7 段早已打满，整体停滞；此时**不要从头来**——停掉该段进程、只对 `02` 那一段再发一次 `-r <start>-<end>`（实测 5,684,160 字节、246 KB/s），再进入拼装。

8. **拼装前逐段强校验，再按 p000→pN 拼。** 每段长度必须精确等于 `end-start+1`；缺段或多出字节都报 `SEGMENT_SIZE_MISMATCH` 并列出段号/期望/实际。

（运行时代码：`references/runner-steps.md` 块 7。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

9. **用 asset digest 做「字节数 + SHA256」闭环，再跑一次冒烟。** 无 digest 的老 release 如实报缺基准，不伪造校验，也不用 Authenticode 兜底（实测该安装包 `NotSigned`）。

（运行时代码：`references/runner-steps.md` 块 8。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

10. **收尾只还原自己动过的东西。** 只按 `$corePid`/`$pids` 以 Id 停进程；别 `Stop-Process -Name curl`（会杀用户自己的下载），别关用户原本在跑的代理。

（运行时代码：`references/runner-steps.md` 块 9。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

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
- **验收阈值（把「最快」落成数字）**：单连接已 ≥ `single_conn_fast_kbps` 时，分段聚合不得低于单流的 95%，否则判回归、回单流；单连接明显被限速时，分段聚合要 ≥3× 单流；任何场景劣化不得超过 5%，超了就回单流并如实报负收益。

### 小文件/文本走同一条代理通道（web_fetch 被墙时）

`raw.githubusercontent.com` 被墙时别重试同一 URL，改走 contents API（`Accept: application/vnd.github.raw`）。
可直接复制的命令与实测字节数见 `references/fetch-raw-via-api.md`。

### 其他分发渠道（不是 GitHub Release 时）

- 镜像/厂商分发站（`registry.npmmirror.com` 的 `ffmpeg-static` 目录、官方 CDN 等）常比 GitHub Release 稳，但 **本技能没有覆盖这些站点的目录结构与校验方式**：用之前先按第 4 步同样手法做 Range 实测，不要照抄 URL 猜文件名。
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
- **POSIX 侧关 fd 用子 shell**：`( … ) 3>&- 2>/dev/null` 只影响子 shell；写裸 `exec 3>&- 2>/dev/null` 会改当前 shell 并把后续所有 stderr 一起吞掉，之后报错再也看不见。
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
- **直链总长只信 206/200**：只有 206 的 `Content-Range` 与 200 的 `Content-Length` 能当 total；403/404 干净失败，408/425/429/5xx 退避重试 3 次。以前只抓最后一个 `Content-Length`，503 的 11 字节响应体被当成资产总大小，后面整条链路按错值算，最后报 `SIZE_MISMATCH: total=11`。
- **小文件不能用 256KB 当探针门槛**（直链常是小文本，会误判 `NO_ROUTE`）；已知 total 降到 total，未知直链降到 1KB。
- **报告写实测平均速度，不要写峰值**；收益必须同时给时间降幅与速度升幅，并说明两者不等价。
- **写技能自己的 .ps1 必须带 BOM**（`UTF8Encoding($true)`）；写回 SKILL.md 相反用 `UTF8Encoding($false)`。`Get-ChildItem -Filter` 只接受单个字符串，多模式用 `Where-Object Name -like`。
- **SKILL.md 体积有硬上限 65536 字节**（宿主超限会截断/拒收）：运行时代码已外置到 `references/runner-steps.md`，正文只留步骤说明与指针。改完必须 `(Get-Item SKILL.md).Length` 自检；再加长先拆 `references/`，别删校验步骤。
- **续传 manifest 必须先校验 `total` 与 `url`**；`.resume` 合并前要 `Wait-Process` 再 10×300ms 重试（实测直接 `OpenRead` 撞「文件被另一进程占用」）。
- **收尾清理只删自己建的东西**：别用 `-like 'ghdl_*'` 扫 `%TEMP%`（实测删掉别人的 `%TEMP%\ghdl_tests`，表现为「下载成功但文件不见了」）。
- **本机假服务器是单线程的**：`tests/serve.ps1` 串行处理连接，探针会全 `000` → `NO_ROUTE`；这是夹具限制。
- **直链模式没有 digest**，报告必须写「只校验了字节数」。
- **版本对比先取证再下结论**：`git tag --list` 核实真实 tag（本项目是 `v0.1.0` / `v0.2.0` / `v0.2.1`，**没有** 1.0），再 `git diff --stat <base>..HEAD` 给文件数与增删行数；不许自设「里程碑」当基准，也不许用分条清单代替按维度标新增/重写/沿用的对比表。
- **aria2c 不在覆盖范围**：宿主已装时可用 `aria2c -x16 -s16 --all-proxy=...`，但它不做逐条路线实测、不核 release digest，也没有本技能的补段与续传日志；要用它得自己补校验，默认流程仍走自带 curl。

- `curl --parallel`（单进程内并发）**实现过、实测过、又撤了**：P2 阶段 16 段同资产对照 `--parallel` 31.6s vs 多进程自适应 32.3s（噪声内），但 `--parallel -K cfg` 只能整批跑完，单段卡死时无法只杀那一段、换源、续传重排队——等于拿可靠性换 0.7 秒。P3 重写引擎时移除；若要加回，作为可选快路径，不当默认。
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
- **macOS 的 BSD 工具与 GNU 不同**：`date +%s%N` 在 BSD 上不支持（ghdl.sh 因此改用各 curl 自报的 `speed_download` 累加计时）；`sed -i` 需要备份后缀；`pgrep -f` 行为与 Linux 有差异（Git Bash 干脆没有 `pgrep`）。写 sh 版一律按 POSIX + BSD 可用子集，别用 GNU 扩展。`set -u` 下空数组展开要写 `${arr[@]+"${arr[@]}"}`（bash 3.2 才炸）；`wc -c` 输出可能有前导空格，比较前先 `tr -d ' '`。
- **单流 Content-Length**：输出 `content_length_ok=<total>（取重定向链最后一个）`，并说明 302 那跳的 `Content-Length: 0` 不能当判据。
- **小资产/快节点分支**：`$total < 100MB` 或 `$singleKB ≥ 3072` 时日志有 `SKIP_LADDER` 与 `SINGLE_KB_SKIPPED`、`SINGLE exit=0`，无分段行。
- **限速节点分支**：只跑 1/16 两档、每档三遍，逐档输出「完成 n/n」、中位与 min–max，最后 `LADDER_DONE: … winN=…`；不出现 4 段档。
- **P3 断言**：直链走 `direct=True`；重跑命中 `ALREADY_DONE` 或 `RESUME_PLAN`；逐段不符必须 `SEGMENT_SIZE_MISMATCH` + 退出码 1 + `PARTS_KEPT`（且不能打印 `DOWNLOAD_VERIFIED_OK`）。
- **跨平台分发**：Windows 跑 `scripts/ghdl.ps1`，macOS/Linux 跑 `scripts/ghdl.sh`；两边日志都应有 `skip_ladder`/`SKIP_LADDER` 与同一组阈值（100MB / 3072KB/s）。
- **macOS 侧回归（离线）**：`bash tests/run-tests-sh.sh` 用 `tests/serve.py` 起本地假服务器，覆盖单流/8 段/续传/不支持 Range/404/截断包/死代理/P2SP 双源/P2SP 死源/坏分片/幂等/KEEP_TMP/后缀冒烟/故障注入；Windows 上要 `PYTHON=<真实 python3>`（商店版是空壳）。2026-10-30 实测 `TESTS_SH_OK: 23 项通过`，`tests/run-tests-min-shells.sh` 另证 dash/busybox/ksh 跑通 `ghdl-min.sh`。
- **故障注入（离线、确定性）**：`tests/serve.py` 提供 403 / 503+`Retry-After` / 429 / 谎报 416 / 302→404 五类端点，`tests/run-tests-sh.sh` 每类一条断言：403/404 非零退出且目标文件不残留，503/429 退避重试后成功，谎报 416 按 `RANGE_UNSUPPORTED` 降级。首跑就抓到真 bug：503 的 11 字节响应体被当成资产 total（`SIZE_MISMATCH: total=11`）；复跑必须 `TESTS_SH_OK` 且日志不再出现 `SIZE_MISMATCH`。
- **同一个下载目录里并发两个资产**：分片目录按资产名隔离（`<asset>.parts`），两个资产互不覆盖；孤儿清理也只按该资产的分片目录匹配。
- **curl 部分成功会把探针行搞乱**：`out=$(curl … || echo '000|0|0')` 在「收到 700KB 后超时」时会把两行拼在一起，六列格式错位，实测直接把 route 选成错的那条、代理字段串成 `0.0.0.0`。正确写法是 `out=$(curl …) || true` 再取第一行。
- **串行探测关闭端口在 Windows 上很贵**：`/dev/tcp` 连接失败的握手要 ~2 秒，20 个端口就是 40 秒（本地 64MB 用例从 9.4s 涨到 23.9s 的元凶）。现在改成「全部并行发起，最多等 3 秒，再按优先级挑一个」，macOS 有 `nc -z -w 1` 时几乎是瞬间。
- **进度采样别用 `wc -c` 逐文件**：分段下载时 16 个文件逐个 `wc` 会被正在写的文件拖住（Windows 共享冲突时还会让 `set -e` 把进度线程直接杀掉），改用一次 `du -sk` 遍历整个分片目录。
- **机器上没有 curl.exe**：Windows 走 `Invoke-WebRequest` 单流降级（不选路/不分段/不续传，打印 `IWR_FALLBACK`），POSIX 直接报 `NO_CURL` 停下——`ghdl.sh` 依赖 curl。
- **收尾**：`7897` 不再监听、无本次 `verge-mihomo` 残留、`ProxyEnable` 与开始时一致。
- **文件体积**：`(Get-Item SKILL.md).Length` ≤ 65536（上限硬约束）。
- **声明 macOS/Linux 支持前的静态初筛**：对 `scripts/ghdl.sh` 统计 shebang、`[[`、`local`、`function`、数组赋值、`+=`、`echo -e` 的用量；静态过只算「未发现阻断」，必须 CI 或真机跑通才写进支持矩阵。

### 支持矩阵（实测到哪一步就写哪一步）

| 能力 | Windows | macOS | Linux |
| --- | --- | --- | --- |
| `scripts/ghdl.ps1`（生成物） | 已实测：fzf 1.86MB / OBS 213MB / rclone 31.6MB / Godot 1.2GB，含 `-Parts`、`-ForceClean`、续传、截断、无 Range、404 | 不适用（PowerShell 5.1 专属） | 不适用 |
| `scripts/ghdl.sh`（手写） | 已实测：Git Bash 上 sh 套件 23 条全过 | CI 已实测：GitHub Actions `macos-latest`（bash 3.2 + BSD 工具）sh 套件 23 条全过；真机速度未测 | CI 已实测：GitHub Actions `ubuntu-latest` sh 套件 23 条全过 |
| 环境探测（端口/代理/内核） | 已实测 | 已实测（CI，`nc` 分支） | 已实测（CI） |
| 三重校验（字节 + SHA256 + 冒烟） | 已实测 | 部分：字节校验已实测，`openssl`/`shasum` 分支仅 CI 未覆盖 digest | 同上 |

## 维护与自检（改完必跑）

三个非模型文件随文档同步：`agents/openai.yaml`（`short_description` 25–64 字符、含 `$github-release-download-acceleration`）、`README.md`（与本文一致）、`scripts/validate.ps1`（退出码非 0 就是文档有问题）。改 `references/runner-steps.md` 后 `scripts/ghdl.ps1` 由 `scripts/build-runner.ps1` 重新生成；`tests/` 是离线回归套件。

（运行时代码：`references/runner-steps.md` 块 10。要执行直接用 `scripts\ghdl.ps1`，不必手工复制这段脚本。）

- **门槛可配且只改一处会被拦住**：frontmatter `metadata.min_size_for_ladder_mb` = 100 / `single_conn_fast_kbps` = 3072，与正文参数表、代码 `$ladderMinMB = 100` / `$fastKB = 3072` 三处一致；只改一处时 `validate.ps1` 输出「不一致：改阈值要两处同步」并 `exit=1`，一致时 `VALIDATE_OK` + `exit=0`。
- **离线回归**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1` 必须 `TESTS_OK`；网络全断时用离线夹具，夹具 PASS 只能报成离线验证。
- **`.gitattributes` 是 CRLF 的根治**：仓库根必须存在 `.gitattributes` 且含 `*.sh text eol=lf`；CI 里的 `sed -i 's/\r$//'` 只是兜底。本地 checkout 报 `bad interpreter: /bin/bash^M` 时先查这个文件，别只改 CI。
- **BOM 只给 .ps1**：任何被 edit/write 动过的 `scripts/*.ps1` / `tests/*.ps1`，回读首 3 字节必须是 `EF BB BF`；`SKILL.md`、`references/*.md`、`*.sh` 必须无 BOM 且 LF。无 BOM 时 PS 5.1 会按 GBK 读中文，报 `Missing closing ')'` 这种看起来像语法错误的假象。
- **体积余量提醒**：`validate.ps1` 在 SKILL.md 距 65,536 上限不足 2 KB 时打 `[INFO]`，不计入告警（仍是 `VALIDATE_OK: 0 个错误 / 0 个告警`）；看到 `[INFO]` 就按施工法 A 拆。
- **CI 三道闸**：`windows-latest` / `ubuntu-latest` / `macos-latest` 三个 job + 独立 job「自举最小版 / 多 shell 回归」（装 dash/busybox/ksh 后跑 `tests/run-tests-min-shells.sh`，本机缺 shell 打 SKIP 且 exit 0）；三个平台都绿才更新支持矩阵，macOS runner 长期 `queued` 时保留「真机未验证」。
- **加载证明**：`skill` 工具能真正加载 `github-release-download-acceleration`。

### 施工法 A：SKILL.md 逼近 65,536 字节时怎么拆（逐字可复跑）

以 2026-10 这次拆分为样本：65,383 → 35,980 字节，11 个 `powershell` 块搬到 `references/runner-steps.md`，`ghdl.ps1` 只有头部注释变化。

1. **先量字节与行数，再按体积排序**，确认唯一超标的是 SKILL.md：

    ```powershell
    (Get-Item SKILL.md).Length
    (Get-Content SKILL.md).Count
    Get-ChildItem -Recurse -File |
      Where-Object { $_.Extension -in '.md','.ps1','.sh','.json','.yml','.py' } |
      Sort-Object Length -Descending |
      Select-Object -First 12 Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}}
    ```

    实测拆前 65,383 字节 / 862 行，余量 153 字节；另一次 65,482 → 65,522 只剩 14 字节。**余量小于 2 KB 就先拆再加字**，不要靠删校验步骤腾地方。

2. **数围栏块再动手**：用多行正则（`(?ms)`，捕获语言与代码组）逐块打印「语言 / 字节 / 所在小节」。实测 SKILL.md 里 0–10 步是 11 个 `powershell` 块（31,591 字节），`sh` 最小版 1 块（3,386 字节）留在正文。**只搬 powershell 运行时代码，步骤说明、判定和错误表留在原位。**

3. **搬进 references/ 并在原位留指针**：每块前加 `## 块 N · <小节标题>`；SKILL.md 原位留一行 `（运行时代码：references/runner-steps.md 块 N。要执行直接用 scripts\ghdl.ps1，不必手工复制这段脚本。）`。搬移脚本的坑：Python 命名组写 `(?P<code>...)`，照抄 .NET 的 `(?<code>...)` 会直接 `re.error`。
    - 搬完 `git diff SKILL.md` 只核两件事：删掉的是代码块、保留的是说明与指针；指针行数 = 搬走块数（实测 11 行）。

4. **生成器跟着新真源走，GENERATE_MISS 不能丢**：`scripts/build-runner.ps1` 的输入改为 `references/runner-steps.md`，三处替换点匹配不到就 `throw "GENERATE_MISS: …"`。改完先用旧结构试一次，必须看到 `GENERATE_MISS`——本窗口正是靠它发现切片写成 `blocks[1:12]`（应为 `blocks[0:11]`）。
    - 正确生成时日志是 `GENERATED: …ghdl.ps1 (31,899 bytes, 514 lines, 12 blocks)`；后来加功能变 33,163 bytes / 535 lines，但块数恒为 12。与提交版比只有头部两行注释（「从 SKILL.md 生成」→「从 references/runner-steps.md 生成」）不同，`git diff scripts/ghdl.ps1` 里没有逻辑行。

5. **validate 双处扫 + 同步断言**：围栏的语法与 5.1 兼容检查同时遍历 `SKILL.md` 与 `references/runner-steps.md`；新增 `build-runner.ps1 -Check`（非 0 就 FAIL）、`references/runner-steps.md` 块数 ≥ 11、SKILL.md 体积余量。期望输出里有「ghdl.ps1 与 references/runner-steps.md 同步」「references/runner-steps.md 有 11 个 powershell 块」「VALIDATE_OK: 0 个错误 / 0 个告警」。

6. **全仓扫旧引用再改文案**：

    ```powershell
    Select-String -Path SKILL.md,README.md,scripts\*.ps1 -Pattern 'build-runner|references/|65,536|65536|64 ?KB'
    ```

    「从本文件的围栏块生成」、README 目录树缺 `references/`、「18 条」这类旧话要一起改；断言条数以实测为准（sh 23 条 / ps1 46 条）。

7. **收尾闸（缺一不算完）**：

    ```powershell
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-runner.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\validate.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    bash tests/run-tests-sh.sh        # Windows 上先设 PYTHON=<真实 python3>
    ```

    期望顺序：`GENERATED` → `VALIDATE_OK` → `TESTS_OK: 46 项通过` → `TESTS_SH_OK: 23 项通过`；再跑 `build-runner.ps1 -Check` 拿 `GENERATE_OK: runner 与 references/runner-steps.md 同步`。拆分不改下载逻辑，套件失败先查环境（`PYTHON` 未设、`bash` 不在 PATH），别急着改代码——本窗口 sh 套件唯一一次失败就是没设 `PYTHON`。

8. **BOM 与 LF 是两条独立红线**：`scripts/*.ps1`、`tests/*.ps1` 必须带 BOM；`SKILL.md`、`references/*.md`、`*.sh` 不能带 BOM 且全文 LF。用字节回读验证（前 3 字节是否 `EF BB BF`、`\r\n` 计数是否为 0），不要只看编辑器显示。

### 施工法 B：ghdl.sh 与 ghdl.ps1 对齐验收（逐项可复跑）

对齐不是把 ps1 逐行翻译成 sh，而是下面五项在两侧日志里都能被看见：

| 能力 | 验收判据（两侧都要有日志证据） |
| --- | --- |
| 阶梯 | 1/16 两档各 3 遍、**交错**执行取中位数；必须 `16/16` 完成且 16 段 ≥ 1.25× 单段才分段，否则单流 |
| 并发 | 单连接被限速直接拉满；否则 4→8→16，打印 `RAMP_UP: workers=…`，出现 2 段卡住打印 `BACKOFF` |
| 进度 | 每 3–4 秒一行 `progress=…MB/…MB (…%) running=… rate=…KB/s`（ps1 3 秒、sh 4 秒）；sh 静默 >15 秒视为卡死 |
| 端口 | 20 个候选端口并行发起、最多等 3 秒再按优先级挑；串行每口约 2 秒（xtrace 实测 20 口 48.4s → 并行 9.4s） |
| 自愈/校验 | 坏段只重下该段；`SEGMENT_SIZE_MISMATCH` 保留分片；SHA256 降级链输出纯 hex；按后缀冒烟 |

改 `ghdl.sh` 的施工方式（sh 没有安全的手工编辑余量）：

1. **一律用 Python 锚点补丁脚本，不手改**：`io.open(p, encoding='utf-8', newline='')` 读入，先 `assert '\r\n' not in s`；每处替换写 `old = '''…'''`，`if old not in s: print('MISS <名字>'); sys.exit(1)`；写回后再回读断言新片段存在。MISS 就是「代码没改」，不是「也许改了」。
2. **MISS 后先停套件再重切片**：补丁 MISS 时正在跑的套件用的还是旧代码——先 kill 后台任务，再按前后两个稳定标记重新切片（不要按行号）。本窗口 `MISS ramp block` 后白跑 10 分钟才被发现；示例切片：从 `started=0\n  limit=4` 到 `# 进度：每 3 秒一行`。
3. **每次改完先 `bash -n scripts/ghdl.sh`**（`syntax_exit=0` 才继续）；Windows 上 `bash` 不在 PATH，要写全路径（如 `D:\...\Git\bin\bash.exe`），别直接调 `bash`。
4. **裸 `wait` 必须改成只等 worker pid**：分段 worker 之外还有进度报告器，裸 `wait` 等全部子进程 → 报告器等 busy 文件消失、主流程等 wait，实测挂死 >10 分钟被 kill。改成 `for p in $wpids; do wait "$p"; done`（只在 `$wpids` 非空时执行）。
5. **进度采样用一次 `du`，不要 16 次 `wc -c`**：逐个 `wc` 会被正在写的分片拖住（Windows 共享冲突时还能让进度线程被 `set -e` 杀掉），短下载（<5 秒）几乎采不到点；改成 `du -sk "$TMPD"` 一次遍历。
6. **curl 部分成功（rc=28）先取第一行再解析六列**：`out=$(curl … || echo '000|0|0')` 在「收到一部分后超时」会追加第二行，六列错位（实测选错路线、代理字段变 `0.0.0.0`）。正确写法 `out=$(curl …) || true`，再取第一行解析。
7. **测试夹具 TcpListener 要设 SendTimeout/ReceiveTimeout**：`tests/serve.ps1` 只设 `ReceiveTimeout` 不够，半开连接会卡死串行夹具，表现为「同一 OutDir 并发两个资产」两项都没有 exit code；给每个连接补 `SendTimeout` 后 ps1 套件 46/46。
8. **收尾判据**：日志里要有 `RAMP_UP`/`BACKOFF`/`progress=` 行、`engine_done=… elapsed=…`、`TESTS_SH_OK: 23 项通过`、`TESTS_OK: 46 项通过`；光 exit=0 不算对齐。sh 套件有时序，改完连跑 5 次都绿再收工。

### 发布自查：一个版本「发全」要四份证据

1. **tag 在远端**：`git ls-remote --tags origin` 与本地 `git tag --list` 对比 commit；或 `curl.exe -sS -H 'Accept: application/vnd.github+json' https://api.github.com/repos/<owner>/<repo>/git/refs/tags/<tag>`，确认指向 HEAD 同一提交。
2. **GitHub Release 本体**：`…/releases/tags/<tag>` 里 `draft=false`、`prerelease=false`、`published_at` 非空；「发布页能打开」不算证据。
3. **npm（若该版本也发布到 npm）**：从仓库 `package.json` 读 `name`，再 `npm view <name> dist-tags --json` 核 `latest`、`npm view <name> time --json` 核发布时间；命令与包名以仓库实际为准，别拿技能名硬套。
4. **CI 可追溯**：`gh run list --limit 3 --json databaseId,headSha,status,conclusion` 找到 `headSha` 等于该 tag 提交的 run，`conclusion=success`；插件市场目录（awesome-dsh-plugin / dsh-market）滞后一天属正常，不作为未发布证据。
