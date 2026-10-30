#!/bin/bash
# ghdl.sh —— GitHub Release / 任意 https 直链 大资产下载器（macOS / Linux / Git Bash）
#
# 与 scripts/ghdl.ps1 是同一套契约的两个实现：自检 → 选路 → 限时阶梯 → 分段并发
# → 逐段强校验 → SHA256 闭环 → 按后缀冒烟。两端不共享代码，但共享同一套阈值：
#   LADDER_MIN_MB=100  FAST_KBPS=3072（与 SKILL.md 的「可调参数」表一致）
#
# 平台要求：bash（macOS 自带 /bin/bash 3.2 足够）、系统 curl、以下之一：
#   openssl / shasum / sha256sum（只用于校验；都没有就只做字节校验并明说）。
# 不依赖：jq、python、node、aria2、GNU coreutils、flock、/dev/tcp。
#
# 用法：
#   bash scripts/ghdl.sh <release-url 或 任意 https 直链>
#   OUTDIR=~/Downloads PARTS=16 bash scripts/ghdl.sh <url>
#   WORKERS=8 FORCE_CLEAN=1 bash scripts/ghdl.sh <url>
#   FORCE_LADDER=1 bash scripts/ghdl.sh <url>     # 强制 1 段 vs 16 段对照
#   MIN_KBPS=0 bash scripts/ghdl.sh <url>         # 关掉「低于 100KB/s 就掐断」的保护
#   P2SP_URLS="https://cdn.example.com/f.bin" bash scripts/ghdl.sh <url>   # 双源混拨
#
# 环境变量：OUTDIR / WORKERS(16) / PARTS(0=自动) / FORCE_LADDER / FORCE_CLEAN /
#           LADDER_MIN_MB(100) / FAST_KBPS(3072) / MIN_KBPS(100) / SMOKE(1) /
#           GITHUB_TOKEN / HTTPS_PROXY 等标准代理变量
#
# 退出码：0 成功并校验通过 | 1 任一步失败 | 2 用法/参数错误
#
# 实测边界（照实写）：macOS 上的 `nc -z`、`openssl dgst -sha256 -r`、`unzip -t` 按
# BSD/系统自带行为实现，但本仓库只在 Windows 的 Git Bash 里跑过端到端；macOS 真机
# 仍未实测。Windows 请优先用 ghdl.ps1（WMI 抓孤儿、并行端口探测都更准）。

set -eu
T_START=$(date +%s)

# 高并发先抬文件句柄上限：macOS 默认 soft limit 只有 256，16 路并发很容易 EMFILE。

usage() {
  cat >&2 <<'USAGE'
用法: bash ghdl.sh <github release url | https 直链> [选项]
  -o, --outdir DIR     下载目录（默认 ~/Downloads，等价 OUTDIR）
  -p, --parts N        指定并发段数（默认 0 = 按单连接速度自适应，等价 PARTS）
      --force-clean    清掉上次的分片与半截文件重下（等价 FORCE_CLEAN=1）
      --force-ladder   跳过「单连接够快就单流」的判断，强制测阶梯（等价 FORCE_LADDER=1）
      --smoke 0|1      下完是否做冒烟（默认 1，等价 SMOKE）
      --keep-tmp       留着临时目录排错（等价 KEEP_TMP=1）
  -h, --help           显示本帮助
环境变量与选项等价：OUTDIR PARTS FORCE_CLEAN FORCE_LADDER SMOKE KEEP_TMP
                 LADDER_MIN_MB FAST_KBPS MIN_KBPS WORKERS P2SP_URLS PROXY
USAGE
}

_url=""
KEEP_TMP=${KEEP_TMP:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--outdir) [ $# -ge 2 ] || { echo "MISSING_VALUE: $1" >&2; exit 2; }; OUTDIR=$2; shift 2 ;;
    --outdir=*) OUTDIR=${1#*=}; shift ;;
    -p|--parts) [ $# -ge 2 ] || { echo "MISSING_VALUE: $1" >&2; exit 2; }; PARTS=$2; shift 2 ;;
    --parts=*) PARTS=${1#*=}; shift ;;
    --force-clean) FORCE_CLEAN=1; shift ;;
    --force-ladder) FORCE_LADDER=1; shift ;;
    --smoke) [ $# -ge 2 ] || { echo "MISSING_VALUE: $1" >&2; exit 2; }; SMOKE=$2; shift 2 ;;
    --smoke=*) SMOKE=${1#*=}; shift ;;
    --keep-tmp) KEEP_TMP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "UNKNOWN_FLAG: $1（--help 看用法）" >&2; exit 2 ;;
    *) if [ -z "$_url" ]; then _url=$1; else echo "EXTRA_ARG: $1" >&2; exit 2; fi; shift ;;
  esac
done
URL=${_url:-}
[ -n "$URL" ] || { usage; exit 2; }
ulimit -n 4096 2>/dev/null || echo "ULIMIT_SKIP: 当前环境不允许把 nofile 抬到 4096（继续，但并发高时可能 EMFILE）"

OUTDIR=${OUTDIR:-$HOME/Downloads}
PARTS=${PARTS:-0}
WORKERS=${WORKERS:-16}
PARTS_OVERRIDE=${PARTS:-0}
FORCE_LADDER=${FORCE_LADDER:-0}
FORCE_CLEAN=${FORCE_CLEAN:-0}
LADDER_MIN_MB=${LADDER_MIN_MB:-100}
FAST_KBPS=${FAST_KBPS:-3072}
MIN_KBPS=${MIN_KBPS:-100}
SMOKE=${SMOKE:-1}
STALL_SEC=6          # 单段连续 6 秒字节数不动 → 杀掉换源（与 ps1 版一致）
MAX_TRIES=5

command -v curl >/dev/null 2>&1 || { echo "NO_CURL: 没有 curl，本脚本不降级" >&2; exit 1; }
command -v bash >/dev/null 2>&1 || { echo "NO_BASH: 需要 bash（macOS 自带）" >&2; exit 1; }

CURL_VER=$(curl -V | head -n1 | awk '{print $2}')
CURL_FEATURES=$(curl -V | sed -n '2,3p' | tr -d '\n')
# --proxy-http2 是 curl 8.1+ 的新参数；macOS 自带 curl 7.64~8.7，不支持时绝不能硬塞。
# 能力探测必须看「运行时能不能用」，不能只看 --help 里有没有这个词：
# 本机 curl 8.22 的 --help 列出了 --proxy-http2，实际一用就报 the installed libcurl version does not support this
has_opt() {  # has_opt <option...>：跑一次 --version，看 stderr 是否报不支持
  if curl "$@" --version 2>&1 | grep -qiE 'does not support|is unknown|unrecognized'; then echo 0; else echo 1; fi
}
HAS_HTTP2=$(has_opt --http2)
HAS_PROXY_HTTP2=$(has_opt --proxy-http2)
HAS_BUFSIZE=$(has_opt --buffer-size 102400)

PROXY=${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}
P2SP_URLS=${P2SP_URLS:-}   # 空格分隔的备源 URL：同一份文件的另一个可达地址（自建镜像/CDN）

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ghdl.XXXXXX") || { echo "NO_TMP: mktemp 失败" >&2; exit 1; }
PIDS="$TMPD/pids"
: > "$PIDS"
cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then echo "TMPD_KEPT=$TMPD"; return 0; fi
  # 只杀自己登记过的 pid，绝不动用户其它下载
  if [ -s "$PIDS" ]; then
    while read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true; done < "$PIDS"
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT INT TERM

# ---------- 0.5 孤儿收尾：上次被强杀的 curl 会和这次抢同一个文件 ----------
sweep_orphans() {
  pat="${asset:-}"
  [ -n "$pat" ] || pat="ghdl"
  list=""
  if command -v pgrep >/dev/null 2>&1; then
    list=$(pgrep -f "curl.*${pat}" 2>/dev/null || true)
  else
    list=$(ps -ax -o pid=,args= 2>/dev/null | grep '[c]url' | grep -F "$pat" | awk '{print $1}' || true)
  fi
  [ -z "${list:-}" ] && return 0
  for pid in $list; do
    kill -9 "$pid" 2>/dev/null || true
    echo "ORPHANS_KILLED: $pid"
  done
  sleep 1
}

# ---------- 0. 解析 URL ----------
DIRECT=0
case "$URL" in
  https://github.com/*/releases/*) ;;
  https://*) DIRECT=1 ;;
  http://127.0.0.1:*/*|http://localhost:*/*) DIRECT=1 ;;
  *) echo "BAD_URL: 只接受 https 直链、本机 http 直链，或 https://github.com/<owner>/<repo>/releases/... ：$URL" >&2; exit 2 ;;
esac
if [ "$DIRECT" = "1" ]; then
  repo=""; tag=""
  asset=${URL##*/}
  asset=$(printf '%s' "$asset" | sed 's/[?#].*$//')
  echo "direct=True asset=$asset"
else
  rest=${URL#https://github.com/}
  owner=${rest%%/*}; rest=${rest#*/}
  repo_name=${rest%%/*}; rest=${rest#*/}
  rest=${rest#releases/}
  tag=$(printf '%s' "$rest" | sed -n 's#^download/\([^/]*\)/.*#\1#p; s#^tag/\([^/]*\).*#\1#p' | head -n1)
  asset=$(printf '%s' "$rest" | sed -n 's#^download/[^/]*/\(.*\)#\1#p' | head -n1)
  repo="$owner/$repo_name"
  echo "repo=$repo tag=$tag asset=${asset:-(待定)}"
fi

# ---------- 1. 自检：端口 / 代理 / curl 能力 ----------
os=$(uname -s)
echo "os=$os curl=$CURL_VER http2=$HAS_HTTP2 proxy_http2=$HAS_PROXY_HTTP2 bufsize=$HAS_BUFSIZE ulimit_n=$(ulimit -n 2>/dev/null || echo '?')"

# macOS 用 nc -z（BSD netcat，系统自带）；没有 nc 的环境（Git Bash / 精简 Linux）
# 用 bash 的 /dev/tcp 直接握手。两条都是「连不上立刻返回」，关闭端口不会拖时间。
# 曾经还有第三条「把端口当 HTTP 代理 curl 一下」的兜底，实测在 Windows 上每个关闭的
# 端口要 2 秒（20 个端口 = 40 秒白等），而它对「端口在听」没有任何额外判别力，已删除。
HAS_NC=0
command -v nc >/dev/null 2>&1 && HAS_NC=1
port_open() {
  local p=$1
  if [ "$HAS_NC" = "1" ]; then
    nc -z -w 1 127.0.0.1 "$p" >/dev/null 2>&1 && return 0
    return 1
  fi
  # 子 shell 里打开 /dev/tcp：退出即关闭连接。绝不能在主 shell 里 `exec 2>/dev/null`，
  # 那会把整个脚本的 stderr 永久吞掉（本次实测踩过：后面所有报错全部消失）。
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    return 0
  fi
  return 1
}
# 端口清单按「常见优先级」排（7897 = Clash Verge 默认混合端口，排最前）。
PORT_ORDER="7897 7890 7891 7898 7899 7892 7893 7894 7895 7896 1080 1081 10808 10809 2080 8889 20171 8080 8118 9090"

# 串行探测在 Windows 上每个「关闭的端口」要 ~2 秒（/dev/tcp 在 MSYS 下握手失败很慢），
# 20 个端口就是 40 秒。这里并行探测：全部同时发，谁先应答就记下来，最多等 3 秒，
# 再按优先级从「有应答的端口」里挑一个。macOS/Linux 有 nc 时几乎是瞬间。
probe_ports() {
  local pf pids x p i found
  pf=$(mktemp "${TMPDIR:-/tmp}/ghdlports.XXXXXX") || return 1
  pids=""
  for p in $PORT_ORDER; do
    ( port_open "$p" && printf '%s\n' "$p" >> "$pf" ) &
    pids="$pids $!"
  done
  i=0
  while [ "$i" -lt 30 ]; do
    [ -s "$pf" ] && break
    sleep 0.1
    i=$(( i + 1 ))
  done
  sleep 0.2
  for x in $pids; do kill "$x" 2>/dev/null || true; done
  found=""
  for p in $PORT_ORDER; do
    if grep -qx "$p" "$pf" 2>/dev/null; then found=$p; break; fi
  done
  rm -f "$pf"
  printf '%s' "$found"
}

found_port=""
if [ -n "${PROXY:-}" ]; then
  # 环境变量已经指名代理，没必要再花时间扫本机端口
  echo "PORT_SCAN_SKIPPED: 环境里已有代理 $PROXY"
else
  found_port=$(probe_ports)
fi
echo "listen_port=${found_port:-(无)} proxy_env=${PROXY:-(空)}"

http_proxy_url=""
if [ -n "${PROXY:-}" ]; then
  http_proxy_url=$PROXY
elif [ -n "$found_port" ]; then
  http_proxy_url="http://127.0.0.1:$found_port"
fi

# ---------- 2. 元数据：total / digest（GitHub API；直链用 1 字节 Range 反推） ----------
TOTAL=0
WANT=""
api_get() { # $1=url $2=out $3=extra header(可空)
  local args
  set +u
  args=(-sS -L --connect-timeout 5 --max-time 25 -A 'Mozilla/5.0')
  if [ -n "$http_proxy_url" ]; then args+=(--proxy "$http_proxy_url"); else args+=(--noproxy "*"); fi
  [ -n "${3:-}" ] && args+=(-H "$3")
  set -e
  curl "${args[@]}" -o "$2" -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

if [ "$DIRECT" = "1" ]; then
  set +u
  # 大小探测必须看状态码：以前这里只抓最后一个 Content-Length，503/429/登录页的
  # 几十字节会被当成「资产总大小」，后面整条链路都按这个错值算，最后报 SIZE_MISMATCH。
  probe_try=0
  while [ "$probe_try" -lt 3 ]; do
    probe_try=$((probe_try + 1))
    p_args=(-sS -L --connect-timeout 5 --max-time 20 -r 0-0 -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}')
    if [ -n "$http_proxy_url" ]; then p_args+=(--proxy "$http_proxy_url"); else p_args+=(--noproxy "*"); fi
    s_code=$(curl "${p_args[@]}" -D "$TMPD/probe.hdr" "$URL" 2>/dev/null || echo 000)
    case "$s_code" in
      206|200)
        cr=$(tr -d '\r' < "$TMPD/probe.hdr" | sed -n 's/^[Cc]ontent-[Rr]ange: *bytes [0-9]*-[0-9]*\/\([0-9][0-9]*\).*/\1/p' | tail -n1)
        if [ -z "${cr:-}" ] && [ "$s_code" = "200" ]; then
          cr=$(tr -d '\r' < "$TMPD/probe.hdr" | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9][0-9]*\)$/\1/p' | tail -n1)
        fi
        break ;;
      403) echo "HTTP_403: 资产地址拒绝访问（私库/权限/token 失效/限流），不再重试" >&2; break ;;
      404) echo "HTTP_404: 资产地址不存在（tag 或文件名写错，或被 302 到登录页）" >&2; break ;;
      408|425|429|500|502|503|504)
        echo "PROBE_RETRY: code=$s_code，1 秒后重试（第 $probe_try/3 次）" >&2
        sleep 1 ;;
      *) echo "PROBE_UNEXPECTED: code=$s_code，按未知大小继续" >&2; break ;;
    esac
  done
  set -e
  [ -n "${cr:-}" ] && [ "$cr" -gt 0 ] && TOTAL=$cr
  echo "asset=$asset total=${TOTAL:-0} api=direct"
else
  api="https://api.github.com/repos/$repo/releases/tags/$tag"
  tok=${GITHUB_TOKEN:-}
  api_json="$TMPD/api.json"
  if [ -n "$tok" ]; then api_code=$(api_get "$api" "$api_json" "Authorization: Bearer $tok")
  else api_code=$(api_get "$api" "$api_json" ""); fi
  api_code=$(printf '%s' "$api_code" | tr -dc '0-9' | tail -c 3)
  [ -n "$api_code" ] || api_code=000
  api_body=$(cat "$api_json" 2>/dev/null || true)

  if [ "$api_code" = "404" ]; then
    echo "RELEASE_NOT_FOUND: $repo tag=$tag" >&2; exit 1
  fi
  if [ "$api_code" = "200" ]; then
    if [ -z "$asset" ]; then
      asset=$(printf '%s' "$api_body" | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -n1)
      [ -n "$asset" ] || { echo "ASSET_NOT_FOUND: release 里没有资产" >&2; exit 1; }
      echo "asset=${asset}（URL 未指定，取第一个资产）"
    fi
    names=$(printf '%s' "$api_body" | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
    if ! printf '%s\n' "$names" | grep -Fxq "$asset"; then
      echo "ASSET_NOT_FOUND: $asset 不在该 release 里，候选：" >&2
      printf '%s\n' "$names" | sed 's/^/  - /' >&2
      exit 1
    fi
    objs=$(printf '%s' "$api_body" | tr -d '\r\n' | awk '{gsub(/\}[ \t]*,[ \t]*\{/,"}\n{"); print}')
    obj=$(printf '%s\n' "$objs" | grep -F "\"name\": \"$asset\"" | head -n1)
    [ -n "$obj" ] || obj=$(printf '%s\n' "$objs" | grep -F "\"name\":\"$asset\"" | head -n1)
    if [ -n "$obj" ]; then
      TOTAL=$(printf '%s' "$obj" | grep -o '"size": *[0-9]*' | sed 's/[^0-9]//g' | head -n1)
      dig=$(printf '%s' "$obj" | grep -o '"digest": *"sha256:[0-9a-fA-F]*"' | sed 's/.*sha256:\([0-9a-fA-F]*\)".*/\1/' | head -n1 || true)
    else
      TOTAL=$(printf '%s' "$api_body" | grep -o '"size": *[0-9]*' | sed 's/[^0-9]//g' | head -n1)
      dig=""
    fi
    [ -n "${dig:-}" ] && WANT=$dig
    echo "asset=$asset total=${TOTAL:-0} want=${WANT:-(无 digest)} api=200"
  elif [ "$api_code" = "403" ]; then
    echo "API_RATE_LIMITED: 403，继续但只做字节校验；想提升限额可设 GITHUB_TOKEN"
  elif [ "$api_code" = "000" ]; then
    echo "ASSET_UNVERIFIED: API 不可达，按 URL 继续，只做字节校验"
  else
    echo "API_UNEXPECTED: code=${api_code}，按 URL 继续" >&2
  fi
fi

if [ -n "${SHA256_EXPECT:-}" ]; then
  WANT=$(printf '%s' "$SHA256_EXPECT" | tr 'A-F' 'a-f')
  echo "want_override=$WANT (SHA256_EXPECT)"
fi

[ -n "${asset:-}" ] || { echo "BAD_URL: 没解析出资产名" >&2; exit 2; }
if [ "$DIRECT" = "1" ]; then u="$URL"; else u="https://github.com/$repo/releases/download/$tag/$asset"; fi

# 本机/内网地址：代理与公共镜像只会把请求绕远、还可能中途断，直接走原地址
host=""
case "$u" in *://*) host=${u#*://}; host=${host%%/*}; host=${host%%:*} ;; esac
IS_LOCAL=0
case "$host" in
  localhost|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) IS_LOCAL=1 ;;
esac
[ "$IS_LOCAL" = "1" ] && echo "LOCAL_TARGET: 目标是本机/内网地址（${host}），跳过代理与公共镜像"

# ---------- 3. 选路：每条路线真跑一次 1MB Range ----------
: > "$TMPD/probes"
probe() { # $1=name $2=url $3=proxy(可空)
  local out
  set +u
  a=(-sS -L --connect-timeout 5 -m 8 -r 0-1048575 -A 'Mozilla/5.0' -o /dev/null
     -w '%{http_code}|%{size_download}|%{speed_download}')
  if [ -n "${3:-}" ]; then a+=(--proxy "$3"); else a+=(--noproxy '*'); fi
  set -e
  out=$(curl "${a[@]}" "$2" 2>/dev/null) || true
  out=$(printf '%s' "$out" | tr -d '\r' | head -n1)
  [ -n "$out" ] || out='000|0|0'
  printf '%s|%s|%s|%s\n' "$1" "$out" "$2" "${3:-}"
}

i=0
if [ "$DIRECT" = "0" ] && [ "$IS_LOCAL" = "0" ]; then
  for m in https://ghfast.top https://ghproxy.net https://gh-proxy.com https://hk.gh-proxy.com https://github.moeyy.xyz https://gh.llkk.cc https://ghproxy.cc; do
    probe "C 镜像 $m" "$m/$u" "" >> "$TMPD/probes" &
    echo $! >> "$PIDS"
  done
fi
if [ -n "${P2SP_URLS:-}" ]; then
  k=0
  for extra in $P2SP_URLS; do
    k=$((k+1))
    probe "M 备源$k" "$extra" "" >> "$TMPD/probes" &
    echo $! >> "$PIDS"
  done
fi
if [ -n "$found_port" ] && [ "$IS_LOCAL" = "0" ]; then
  probe "A 现有代理 :$found_port" "$u" "http://127.0.0.1:$found_port" >> "$TMPD/probes" &
  echo $! >> "$PIDS"
elif [ -n "$PROXY" ]; then
  probe "A 环境代理" "$u" "$PROXY" >> "$TMPD/probes" &
  echo $! >> "$PIDS"
fi
probe "D 直连" "$u" "" >> "$TMPD/probes" &
echo $! >> "$PIDS"
wait || true

minb=524288
if [ "${TOTAL:-0}" -gt 0 ] && [ "$TOTAL" -lt "$minb" ]; then minb=$TOTAL; fi
best=$(awk -F'|' -v minb="$minb" '{
    code=$2; bytes=$3+0; spd=$4+0;
    if ((code=="200"||code=="206") && bytes>=minb) printf "%d\t%s\t%s\t%s\t%s\n", spd/1024, $1, $5, $6, code;
  }' "$TMPD/probes" | sort -rn | head -n1)
if [ -z "$best" ]; then
  echo "NO_ROUTE: 所有路线都没拿到数据" >&2
  awk -F'|' '{printf "  %-28s code=%s bytes=%s\n", $1, $2, $3}' "$TMPD/probes" >&2
  exit 1
fi
win_kbps=$(printf '%s' "$best" | cut -f1)
win_name=$(printf '%s' "$best" | cut -f2)
win_url=$(printf '%s' "$best" | cut -f3)
win_proxy=$(printf '%s' "$best" | cut -f4)
win_name=$(printf '%s' "$best" | cut -f2)
win_code=$(printf '%s' "$best" | cut -f5)
echo "route=$win_name KBps=$win_kbps"

# P2SP 路线池：2 个槽位。槽1 = 当前最快路线；槽2 = 用户显式给的备源（M）里最快的一条，
# 没有备源才用「探针 ≥1MB 且速度 ≥ 最快 35%」的其它自动发现路由。
# 不用相对门槛淘汰显式备源：本机/同机房的 1MB 探针 speed 噪声极大（同一对源 47MB/s 与 414MB/s 交替出现），
# 门槛会把活着的备源误杀；自动发现的公共镜像/代理仍按门槛淘汰。
POOL_N=0; POOL_URL1=""; POOL_PX1=""; POOL_URL2=""; POOL_PX2=""
pool_tab="$TMPD/pool"
awk -F'|' -v minb="$minb" -v best="$win_kbps" -v win="$win_url" '{
    code=$2; bytes=$3+0; spd=$4+0; kb=int(spd/1024);
    if (!((code=="200"||code=="206") && bytes>=minb)) next;
    explicit = ($1 ~ /^M /) ? 1 : 0;
    if ($5 == win && !winseen) { print kb "\t" $5 "\t" $6 "\t" 2 "\t" 1; winseen=1; next }
    if (explicit) { print kb "\t" $5 "\t" $6 "\t" 1 "\t" 0; next }
    if (kb >= best*35/100) print kb "\t" $5 "\t" $6 "\t" 0 "\t" 0;
  }' "$TMPD/probes" | sort -t"$(printf '\t')" -k1,1rn > "$pool_tab"
# 取：槽1 优先「最快的显式备源」，否则最快的一条；槽2 取剩下里最快的（win 也算候选）
pick=$(awk -F'\t' '{print $2 "\t" $3}' "$pool_tab" | awk '!seen[$0]++' | head -n2)
n=0
while IFS="$(printf '\t')" read -r pu ppx; do
  [ -n "${pu:-}" ] || continue
  n=$((n + 1))
  if [ "$n" = 1 ]; then POOL_URL1=$pu; POOL_PX1=$ppx; fi
  if [ "$n" = 2 ]; then POOL_URL2=$pu; POOL_PX2=$ppx; fi
done <<EOF
$pick
EOF
POOL_N=$n
[ "$POOL_N" -ge 1 ] || { POOL_N=1; POOL_URL1=$win_url; POOL_PX1=$win_proxy; }
echo "POOL: $POOL_N 条路线（$([ "$POOL_N" -ge 2 ] && echo '混拨 proxy+mirror' || echo '单源')）"

# ---------- 3.5 没有 total 时用 Content-Range 反推 ----------
if [ "${TOTAL:-0}" -le 0 ]; then
  set +u
  ra=(-sS -L --connect-timeout 5 --max-time 20 -r 0-0 -A 'Mozilla/5.0')
  if [ -n "$win_proxy" ]; then ra+=(--proxy "$win_proxy"); else ra+=(--noproxy "*"); fi
  set -e
  h=$(curl "${ra[@]}" -D - -o /dev/null "$win_url" 2>/dev/null || true)
  cr=$(printf '%s' "$h" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *bytes [0-9]*-[0-9]*\/\([0-9][0-9]*\).*/\1/p' | tail -n1)
  if [ -n "${cr:-}" ]; then TOTAL=$cr; echo "total_from_range=$TOTAL"; fi
fi

# ---------- 4. 单连接速度 + Range 支持判定 ----------
single_kbps=0
range_ok=1
fetch_8m() {
  local a
  set +u
  a=(-sS -L --connect-timeout 3 -r 0-8388607 -A 'Mozilla/5.0' -o /dev/null
     -w '%{http_code}|%{size_download}|%{speed_download}')
  if [ -n "$win_proxy" ]; then a+=(--proxy "$win_proxy"); else a+=(--noproxy "*"); fi
  set -e
  out=$(curl "${a[@]}" "$win_url" 2>/dev/null) || true
  out=$(printf '%s' "$out" | tr -d '\r' | head -n1)
  [ -n "$out" ] || out='000|0|0'
  printf '%s\n' "$out"
}
s=$(fetch_8m)
s_code=$(printf '%s' "$s" | cut -d'|' -f1)
s_spd=$(printf '%s' "$s" | cut -d'|' -f3 | cut -d. -f1)
case "$s_code" in
  206) single_kbps=$(( ${s_spd:-0} / 1024 )) ;;
  200) single_kbps=$(( ${s_spd:-0} / 1024 )); range_ok=0 ;;
  *) single_kbps=0 ;;
esac
echo "singleKB=$single_kbps range_ok=$range_ok"
if [ "$range_ok" = "0" ]; then
  echo "RANGE_UNSUPPORTED: 服务器忽略 Range（code=200），立即降级单流，不死磕"
fi

# ---------- 5. 限时阶梯（只在「大 + 单连接慢」时跑） ----------
rung() { # $1=n → "n|kbps|full"
  local n=$1 sec=4 dir total_spd=0 full=0 j=0 f sz v
  dir="$TMPD/r$n"; mkdir -p "$dir"
  while [ $j -lt "$n" ]; do
    set +u
    a=(-sS -L --connect-timeout 3 -m "$sec" -r "$((TOTAL / n * j))-" -A 'Mozilla/5.0'
       -o "$dir/p$j.bin" -w '%{speed_download}')
    if [ -n "$win_proxy" ]; then a+=(--proxy "$win_proxy"); else a+=(--noproxy "*"); fi
    set -e
    curl "${a[@]}" "$win_url" > "$dir/s$j.txt" 2>/dev/null &
    echo $! >> "$PIDS"
    j=$((j+1))
  done
  wait || true
  for f in "$dir"/p*.bin; do
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f" | tr -d ' ')
    [ "$sz" -gt 0 ] && full=$((full + 1))
  done
  for f in "$dir"/s*.txt; do
    [ -f "$f" ] || continue
    v=$(cat "$f" 2>/dev/null | tr -dc '0-9.')
    [ -n "$v" ] || continue
    total_spd=$(awk -v a="$total_spd" -v b="$v" 'BEGIN{printf "%d", a+b}')
  done
  echo "$n|$(( total_spd / 1024 ))|$full"
}

# 三遍交错跑 1 段与 16 段，取中位数；完成度取最后一遍的「有效分片数」。
# 单次 1MB/连接 的测速噪声可达 3-10 倍（同一对源交替出现 48MB/s 与 414MB/s），
# 只跑一遍会把「16 段其实更快」误判成更慢，反之亦然。
do_ladder() {
  r1s=""; r16s=""; f1=0; f16=0; rep=1
  while [ "$rep" -le 3 ]; do
    a=$(rung 1); b=$(rung 16)
    r1s="$r1s $(printf '%s' "$a" | cut -d'|' -f2)"
    r16s="$r16s $(printf '%s' "$b" | cut -d'|' -f2)"
    f1=$(printf '%s' "$a" | cut -d'|' -f3)
    f16=$(printf '%s' "$b" | cut -d'|' -f3)
    rep=$(( rep + 1 ))
  done
  k1=$(median $r1s); k16=$(median $r16s)
  rung1="1|$k1|$f1"; rung16="16|$k16|$f16"
  echo "LADDER_DONE: rungs=1/16 passes=3 median1=${k1}KB/s median16=${k16}KB/s full=$f1/$f16"
}

median() {
  n=$#
  [ "$n" -eq 0 ] && { echo 0; return; }
  printf '%s\n' $* | sort -n | awk -v n="$n" 'NR==int((n+1)/2) { print; exit }'
}

big_enough=0
[ "${TOTAL:-0}" -ge $(( LADDER_MIN_MB * 1024 * 1024 )) ] && big_enough=1
if [ "$range_ok" = "0" ]; then
  echo "SKIP_LADDER: 不支持 Range，单流"
  rung1="1|0|0"; rung16="16|0|0"
elif [ "$FORCE_LADDER" = "1" ] && [ "${TOTAL:-0}" -gt 0 ]; then
  do_ladder
elif [ "$big_enough" = "1" ] && [ "$single_kbps" -lt "$FAST_KBPS" ]; then
  do_ladder
else
  rung1="1|0|0"; rung16="16|0|0"
  tmb=$(awk -v t="${TOTAL:-0}" 'BEGIN{ if (t<=0) print "unknown"; else printf "%.1f", t/1048576 }')
  echo "SKIP_LADDER: total=${tmb}MB singleKB=${single_kbps}（门槛 ${LADDER_MIN_MB}MB / ${FAST_KBPS}KB/s）-> 单流"
fi

k1=$(printf '%s' "$rung1" | cut -d'|' -f2)
k16=$(printf '%s' "$rung16" | cut -d'|' -f2)
winN=1
if [ "$k16" -gt 0 ] && [ "$k1" -gt 0 ] && [ "$k16" -ge $(( k1 * 125 / 100 )) ] && [ "${f16:-0}" -ge 16 ]; then winN=16; fi
if [ "$PARTS_OVERRIDE" -gt 0 ]; then
  if [ "${TOTAL:-0}" -gt 0 ] && [ "$range_ok" = "1" ]; then winN=$PARTS_OVERRIDE
  else
    echo "PARTS_IGNORED: 总字节数未知或不支持 Range，无法切 range，改走单流" >&2
    winN=1
  fi
fi
[ "$range_ok" = "0" ] && winN=1
win_ratio=$(awk -v a="${k16:-0}" -v b="${k1:-0}" 'BEGIN{ if (b<=0) print "-"; else printf "%.2f", a/b }')
echo "winN=$winN ratio=${win_ratio}x"

# ---------- 6. 下载 ----------
sweep_orphans
mkdir -p "$OUTDIR"
target="$OUTDIR/$asset"

if [ "$FORCE_CLEAN" = "1" ]; then
  rm -f "$target" "$target.headers"
  rm -rf "$OUTDIR/$asset.parts"
  echo "FORCE_CLEAN: 已删旧成品与旧分片"
fi

hash_file() { # $1=file → 纯小写 hex，或空
  local h
  if command -v openssl >/dev/null 2>&1; then
    # macOS 自带 LibreSSL：-r 输出 "<hex> *<file>"，取第一列
    h=$(openssl dgst -sha256 -r "$1" 2>/dev/null | awk '{print $1}')
    if [ -n "${h:-}" ] && [ ${#h} -eq 64 ]; then printf '%s\n' "$h" | tr 'A-F' 'a-f'; return 0; fi
  fi
  if command -v shasum >/dev/null 2>&1; then
    h=$(shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
    if [ -n "${h:-}" ] && [ ${#h} -eq 64 ]; then printf '%s\n' "$h" | tr 'A-F' 'a-f'; return 0; fi
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ -n "${h:-}" ] && printf '%s\n' "$h" | tr 'A-F' 'a-f'
  fi
}

skip_dl=0
if [ -f "$target" ] && [ "${TOTAL:-0}" -gt 0 ]; then
  have=$(wc -c < "$target" | tr -d ' ')
  if [ "$have" -eq "$TOTAL" ]; then
    skip_dl=1
    if [ -n "${WANT:-}" ]; then
      hh=$(hash_file "$target")
      want_lc=$(printf '%s' "$WANT" | tr 'A-F' 'a-f')
      if [ -z "$hh" ]; then
        echo "NO_HASH_TOOL: 没有 openssl/shasum/sha256sum，只做字节校验"
      elif [ "$hh" != "$want_lc" ]; then
        skip_dl=0
        echo "ALREADY_DONE_HASH_MISMATCH: 已有文件字节对但 SHA256 不符，重新下载" >&2
        rm -f "$target"
      fi
    fi
    [ "$skip_dl" = "1" ] && echo "ALREADY_DONE: $target 已存在且 $have 字节（不重下）"
  fi
fi

curl_seg() { # $1=url $2=proxy $3=range $4=out
  local a
  set +u
  a=(-sS -L --fail --connect-timeout 3 -A 'Mozilla/5.0' -m 1800 -r "$3" -o "$4"
     --retry 2 --retry-delay 1)
  [ "$HAS_HTTP2" = "1" ] && a+=(--http2)
  [ "$HAS_BUFSIZE" = "1" ] && a+=(--buffer-size 102400)
  if [ "$MIN_KBPS" -gt 0 ]; then a+=(--speed-limit $(( MIN_KBPS * 1024 )) --speed-time 3); fi
  if [ -n "${2:-}" ]; then
    a+=(--proxy "$2")
    [ "$HAS_PROXY_HTTP2" = "1" ] && a+=(--proxy-http2)
  else
    a+=(--noproxy "*")
  fi
  set -e
  curl "${a[@]}" "$1"
}

# 单段下载：断点续传 + 停滞检测 + 换源重试（只重试这一段，绝不影响别的段）
dl_segment() { # $1=idx
  local idx=$1 s e need part try have pick su sp rs tgt cpid last still cur got total_now
  dir="$PARTS_DIR"
  s=$(( SEG_CHUNK * idx ))
  if [ "$idx" -eq $(( SEG_N - 1 )) ]; then e=$(( TOTAL - 1 )); else e=$(( s + SEG_CHUNK - 1 )); fi
  need=$(( e - s + 1 ))
  part="$dir/p$idx.bin"

  try=0
  while [ "$try" -lt "$MAX_TRIES" ]; do
    have=0
    if [ -f "$part" ]; then have=$(wc -c < "$part" | tr -d ' '); fi
    if [ "$have" -eq "$need" ]; then return 0; fi
    if [ "$have" -gt "$need" ]; then rm -f "$part"; have=0; fi

    # 换源：失败一次换下一条路线（P2SP 混拨时这就是「窃取」）
    pick=$(( (idx + try) % POOL_N ))
    if [ "$pick" -eq 1 ] && [ "$POOL_N" -ge 2 ]; then
      su=$POOL_URL2; sp=$POOL_PX2
    else
      su=$POOL_URL1; sp=$POOL_PX1
    fi

    if [ "$have" -gt 0 ]; then
      rs=$(( s + have )); tgt="$part.resume"
      echo "SEG_RESUME: p$idx 从 $have/$need 字节继续"
    else
      rs=$s; tgt="$part"
    fi

    curl_seg "$su" "$sp" "$rs-$e" "$tgt" >> "$TMPD/seg_$idx.log" 2>&1 &
    cpid=$!
    echo "$cpid" >> "$PIDS"

    # 每 1 秒核对一次落盘字节数；连续 STALL_SEC 秒不动就掐断换源
    last=-1; still=0
    while kill -0 "$cpid" 2>/dev/null; do
      sleep 1
      cur=0
      [ -f "$tgt" ] && cur=$(wc -c < "$tgt" | tr -d ' ')
      if [ "$cur" -eq "$last" ]; then
        still=$((still + 1))
        if [ "$still" -ge "$STALL_SEC" ]; then
          kill -9 "$cpid" 2>/dev/null || true
          wait "$cpid" 2>/dev/null || true
          echo "SEG_STALL: p$idx 停滞 ${STALL_SEC}s（$cur 字节）-> 杀进程换源"
          if [ -n "${Q:-}" ]; then printf x >> "$Q/stalls" 2>/dev/null || true; fi
          break
        fi
      else
        still=0; last=$cur
      fi
    done
    wait "$cpid" 2>/dev/null || true

    got=0
    [ -f "$tgt" ] && got=$(wc -c < "$tgt" | tr -d ' ')
    if [ "$tgt" = "$part.resume" ] && [ "$got" -gt 0 ]; then cat "$tgt" >> "$part"; fi
    rm -f "$part.resume"
    total_now=0
    [ -f "$part" ] && total_now=$(wc -c < "$part" | tr -d ' ')
    if [ "$total_now" -eq "$need" ]; then return 0; fi
    try=$((try + 1))
    echo "SEG_RETRY: p$idx try=$try have=$total_now/${need}（换下一条路线）"
  done
  echo "SEGMENT_FAILED: p$idx 重试 $MAX_TRIES 次仍不足（need=${need}）" >&2
  return 1
}

if [ "$skip_dl" = "1" ]; then
  echo "engine=cached"
elif [ "$winN" -gt 1 ] && [ "${TOTAL:-0}" -gt 0 ]; then
  PARTS_DIR="$OUTDIR/$asset.parts"
  manifest="$PARTS_DIR/manifest"
  m_total=0; m_chunk=0; m_nseg=0; m_source=""
  if [ -f "$manifest" ]; then
    read -r m_total m_chunk m_nseg < "$manifest" || true
    m_source=$(sed -n '2p' "$manifest" 2>/dev/null || true)
  fi
  if [ "${m_total:-0}" -eq "$TOTAL" ] && [ "${m_nseg:-0}" -ge 1 ] && [ "${m_chunk:-0}" -ge 1 ] &&
     { [ -z "${m_source:-}" ] || [ "$m_source" = "$URL" ]; }; then
    SEG_N=$m_nseg; SEG_CHUNK=$m_chunk
    echo "RESUME_PLAN: 沿用上次分段 nseg=$SEG_N chunk=$SEG_CHUNK"
  else
    rm -rf "$PARTS_DIR"; mkdir -p "$PARTS_DIR"
    SEG_N=$winN
    SEG_CHUNK=$(( TOTAL / SEG_N ))
    while [ $(( SEG_CHUNK * SEG_N )) -lt "$TOTAL" ]; do SEG_CHUNK=$((SEG_CHUNK + 1)); done
    printf '%s %s %s\n%s\n' "$TOTAL" "$SEG_CHUNK" "$SEG_N" "$URL" > "$manifest"
    echo "PLAN: nseg=$SEG_N chunk=$SEG_CHUNK"
  fi

  # 并发数：分段越多越值得起满；单连接已被限速时直接拉满，不要靠爬坡（爬坡在「每连接
  # 限速且已跑满」的场景涨幅恒为 0，会永远卡在低并发）。
  wstart=$WORKERS
  [ "$SEG_N" -lt "$wstart" ] && wstart=$SEG_N
  if [ "$SEG_N" -ge 8 ] && [ "$single_kbps" -ge "$FAST_KBPS" ]; then wstart=8; [ "$SEG_N" -lt 8 ] && wstart=$SEG_N; fi
  echo "engine=pool workers=$wstart nseg=$SEG_N pool=$POOL_N"

  Q="$TMPD/q"; mkdir -p "$Q"
  : > "$Q/queue"
  i=0
  while [ $i -lt "$SEG_N" ]; do echo "$i" >> "$Q/queue"; i=$((i+1)); done

  claim() {
    local tries=0 idx=""
    while ! mkdir "$Q/lock" 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -gt 200 ]; then rm -rf "$Q/lock" 2>/dev/null || true; tries=0; fi
      sleep 0.05
    done
    if [ -s "$Q/queue" ]; then
      idx=$(head -n1 "$Q/queue")
      tail -n +2 "$Q/queue" > "$Q/queue.tmp"
      mv "$Q/queue.tmp" "$Q/queue"
    fi
    rmdir "$Q/lock" 2>/dev/null || true
    [ -n "$idx" ] && printf '%s\n' "$idx"
  }

  worker() {
    local idx
    while :; do
      idx=$(claim) || break
      [ -n "$idx" ] || break
      dl_segment "$idx" || echo "WORKER_CONTINUE: p$idx 放弃（其它段继续）" >&2
    done
  }

  # 已落盘字节数：一次 du 遍历整个分片目录，比逐个 wc 便宜得多，也不会因为
  # 某个正在写的文件暂时拒绝访问而把进度线程卡死。
  bytes_done() {
    local k
    k=$(du -sk "$PARTS_DIR" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "${k:-}" ] || k=0
    printf '%s' $(( k * 1024 ))
  }

  sw=$(date +%s 2>/dev/null || echo 0)
  started=0
  limit=4
  [ "$wstart" -lt 4 ] && limit=$wstart
  # 起始并发：阶梯已证明「多段快 ≥2 倍」或单连接明显被限速 -> 直接拉满；
  # 单连接够快（>= FAST_KBPS）说明链路没按连接限速，先起 8 条看一拍再加，
  # 避免一上来 16 条把同一条管子切碎反而更慢。
  if [ "${k16:-0}" -gt 0 ] && [ "${k1:-0}" -gt 0 ] && [ "$k16" -ge $(( k1 * 200 / 100 )) ]; then
    limit=$wstart
  elif [ "$single_kbps" -gt 0 ] && [ "$single_kbps" -lt "$FAST_KBPS" ]; then
    limit=$wstart
  elif [ "$wstart" -gt 8 ]; then
    limit=8
  fi
  [ "$limit" -gt "$wstart" ] && limit=$wstart
  wpids=""
  while [ "$started" -lt "$wstart" ]; do
    while [ "$started" -lt "$limit" ]; do
      worker & wp=$!
      wpids="$wpids $wp"
      echo "$wp" >> "$PIDS"
      started=$((started+1))
    done
    [ "$limit" -ge "$wstart" ] && break
    sleep 1
    stalls=0
    [ -f "$Q/stalls" ] && stalls=$(wc -c < "$Q/stalls" | tr -d ' ')
    if [ "${stalls:-0}" -ge 2 ]; then
      echo "BACKOFF: 1 秒内有 ${stalls} 段卡住 -> 不再加并发（已起 $started）"
      break
    fi
    limit=$(( limit + 4 )); [ "$limit" -gt "$wstart" ] && limit=$wstart
    echo "RAMP_UP: workers=$limit"
  done

  # 进度：每 4 秒一行（agent 靠它判断还在动）
  : > "$Q/busy"
  (
    last=0
    while [ -f "$Q/busy" ]; do
      sleep 4
      [ -f "$Q/busy" ] || break
      d=$(bytes_done 2>/dev/null) || d=0
      [ -n "$d" ] || d=0
      pct=0; [ "${TOTAL:-0}" -gt 0 ] && pct=$(( d * 100 / TOTAL ))
      rate=$(( (d - last) / 4 / 1024 )); last=$d
      echo "progress=$(( d / 1048576 ))MB/$(( ${TOTAL:-0} / 1048576 ))MB (${pct}%) running=$started rate=${rate}KB/s"
    done
  ) &
  rep_pid=$!
  for wp in $wpids; do wait "$wp" 2>/dev/null || true; done
  rm -f "$Q/busy"
  kill "$rep_pid" 2>/dev/null || true
  ew=$(date +%s 2>/dev/null || echo 0)
  echo "engine_done=pool segments=$SEG_N workers=$started pool=$POOL_N elapsed=$((ew - sw))s"

  # ---------- 7. 拼装前逐段强校验 ----------
  bad=""; sum=0; j=0
  while [ $j -lt "$SEG_N" ]; do
    s=$(( SEG_CHUNK * j ))
    if [ "$j" -eq $(( SEG_N - 1 )) ]; then e=$(( TOTAL - 1 )); else e=$(( s + SEG_CHUNK - 1 )); fi
    need=$(( e - s + 1 ))
    p="$PARTS_DIR/p$j.bin"
    got=0
    [ -f "$p" ] && got=$(wc -c < "$p" | tr -d ' ')
    if [ "$got" -ne "$need" ]; then bad="$bad p$j(need=$need got=$got)"; fi
    sum=$(( sum + got ))
    j=$((j+1))
  done
  if [ -n "$bad" ]; then
    echo "SEGMENT_SIZE_MISMATCH:${bad}（分片留在 ${PARTS_DIR}，重跑会续传）" >&2
    exit 1
  fi
  if [ "$sum" -ne "$TOTAL" ]; then
    echo "PARTS_MISMATCH: sum=$sum total=${TOTAL}（分片留在 ${PARTS_DIR}）" >&2
    exit 1
  fi
  echo "partsBytes=$sum total=$TOTAL ok=True"
  : > "$target"
  j=0
  while [ $j -lt "$SEG_N" ]; do cat "$PARTS_DIR/p$j.bin" >> "$target"; j=$((j+1)); done
  echo "assembled=$(wc -c < "$target" | tr -d ' ')"
  rm -rf "$PARTS_DIR"
else
  part0="$target.part"
  [ -f "$target" ] && mv -f "$target" "$part0" 2>/dev/null || true
  resume_flag=0
  if [ -f "$part0" ] && [ "${TOTAL:-0}" -gt 0 ]; then
    have=$(wc -c < "$part0" | tr -d ' ')
    if [ "$have" -gt 0 ] && [ "$have" -lt "$TOTAL" ]; then
      resume_flag=1
      echo "SINGLE_RESUME: 从 $have 字节继续"
    fi
  fi
  set +u
  a=(-sS -L --fail --connect-timeout 3 -A 'Mozilla/5.0' -o "$part0" -D "$target.headers" -m 1800
     --retry 3 --retry-delay 2
     -w 'code=%{http_code}|got=%{size_download}|speed=%{speed_download}\n')
  [ "$HAS_HTTP2" = "1" ] && a+=(--http2)
  [ "$HAS_BUFSIZE" = "1" ] && a+=(--buffer-size 102400)
  if [ "$MIN_KBPS" -gt 0 ]; then a+=(--speed-limit $(( MIN_KBPS * 1024 )) --speed-time 3); fi
  [ "$resume_flag" = "1" ] && a+=(-C -)
  if [ -n "$win_proxy" ]; then
    a+=(--proxy "$win_proxy")
    [ "$HAS_PROXY_HTTP2" = "1" ] && a+=(--proxy-http2)
  else
    a+=(--noproxy "*")
  fi
  set -e
  rc=0
  curl "${a[@]}" "$win_url" || rc=$?
  echo "SINGLE exit=$rc"
  if [ "$rc" -ne 0 ]; then
    echo "SINGLE_FAILED: exit=$rc" >&2
    exit 1
  fi
  if [ "$resume_flag" = "0" ] && [ -f "$target.headers" ] && [ "${TOTAL:-0}" -gt 0 ]; then
    cl=$(tr -d '\r' < "$target.headers" | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -n1)
    if [ -n "${cl:-}" ] && [ "$cl" -ne "$TOTAL" ]; then
      echo "SIZE_MISMATCH: Content-Length=$cl 与 total=$TOTAL 不一致" >&2
      exit 1
    fi
  fi
  rm -f "$target.headers"
  mv -f "$part0" "$target"
fi

# ---------- 8. 校验：字节数 + SHA256（macOS 降级链 openssl → shasum → sha256sum） ----------
size=$(wc -c < "$target" | tr -d ' ')
echo "size=$size expect=${TOTAL:-?}"
if [ "${TOTAL:-0}" -gt 0 ] && [ "$size" -ne "$TOTAL" ]; then
  echo "DOWNLOAD_VERIFY_FAILED: size mismatch" >&2; exit 1
fi

if [ -n "$WANT" ]; then
  got=$(hash_file "$target")
  if [ -z "$got" ]; then
    echo "NO_HASH_TOOL: 没有 openssl/shasum/sha256sum，只做了字节校验"
    echo "DOWNLOAD_SIZE_OK_NO_DIGEST"
  else
    echo "sha256=$got expect=$WANT"
    if [ "$got" = "$(printf '%s' "$WANT" | tr 'A-F' 'a-f')" ]; then
      echo "DOWNLOAD_VERIFIED_OK"
    else
      echo "DOWNLOAD_VERIFY_FAILED: sha256 mismatch" >&2; exit 1
    fi
  fi
else
  echo "NO_DIGEST: 只能保证字节数一致"
  echo "DOWNLOAD_SIZE_OK_NO_DIGEST"
fi

# ---------- 9. 冒烟：按后缀分派，绝不对 zip/tar 跑 --version ----------
if [ "$SMOKE" = "1" ]; then
  smoke="SKIP"
  case "$asset" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        if unzip -tqq "$target" >/dev/null 2>&1; then smoke="unzip_ok"; else smoke="SMOKE_FAILED"; fi
      else
        smoke="SKIP（没有 unzip，无法试解压）"
      fi ;;
    *.tar.gz|*.tgz|*.tar)
      if tar -tf "$target" >/dev/null 2>&1; then smoke="tar_list_ok"; else smoke="SMOKE_FAILED"; fi ;;
    *.exe)
      if [ "$os" = "Darwin" ]; then smoke="SKIP（macOS 不能执行 Windows exe，靠 SHA256 判定完整）"
      else smoke="SKIP（不执行未知 exe；需要时手工验证）"; fi ;;
    *) smoke="SKIP（后缀无通用冒烟方式，仅 SHA256）" ;;
  esac
  echo "smoke=$smoke"
fi

if [ "${SEG_N:-0}" -gt 0 ]; then res_engine=segments; else res_engine=single; fi
res_parts=${winN:-${PARTS:-1}}
if [ -n "${WANT:-}" ]; then
  if [ -n "${got:-}" ]; then res_verified=sha256; else res_verified=size_only; fi
else
  res_verified=size_only
fi
smoke=${smoke:-SKIP}
printf 'RESULT_JSON: {"asset":"%s","bytes":%s,"total":%s,"sha256":"%s","expected":"%s","verified":"%s","engine":"%s","parts":%s,"route":"%s","smoke":"%s","elapsed_s":%s}\n' \
  "$asset" "$size" "${TOTAL:-0}" "${got:-}" "$WANT" "$res_verified" "$res_engine" "$res_parts" "${win_name:-}" "$smoke" "$(( $(date +%s) - T_START ))"

echo "saved=$target"
exit 0
