#!/bin/sh
# ghdl.sh —— GitHub Release 大资产下载（POSIX sh 一次性 runner）
#
# 与 scripts/ghdl.ps1 同一套流程的 POSIX 实现：自检 → 选路 → （必要时）1/16 限时阶梯
# → 单流或多段 range 并发下载 → 字节数 + SHA256 校验 → 只清理自己创建的东西。
#
# 依赖：POSIX sh、系统 curl（macOS 自 10.15 起自带 7.64+；主流 Linux 发行版均自带）、
#       sha256sum 或 shasum 或 openssl 之一（只用于校验，缺了就只做字节校验并明说）。
# 不用：bash 数组、/dev/tcp、jq、python、node、wget、aria2。
#
# 用法：
#   sh scripts/ghdl.sh <release-url>
#   OUTDIR=/tmp/dl sh scripts/ghdl.sh <release-url>
#   FORCE_LADDER=1 sh scripts/ghdl.sh <release-url>     # 强制单流 vs 16 段对照
#   PARTS=16 sh scripts/ghdl.sh <release-url>           # 手动指定并发段数
#
# 退出码：0 成功 | 1 流程失败 | 2 用法错误
#
# !!! 重要：本脚本只在 Windows 的 Git Bash 下跑过语法检查（sh -n），
#     在真实 macOS / Linux 上**未实测**。照实说：这是「理论可用」，不是「已支持」。

set -eu

URL=${1:-}
if [ -z "$URL" ]; then
  echo "用法: sh $0 <github release url>" >&2
  exit 2
fi

OUTDIR=${OUTDIR:-$HOME/Downloads}
FORCE_LADDER=${FORCE_LADDER:-0}
PARTS_OVERRIDE=${PARTS:-0}
LADDER_MIN_MB=${LADDER_MIN_MB:-100}
FAST_KBPS=${FAST_KBPS:-3072}

command -v curl >/dev/null 2>&1 || { echo "NO_CURL: 没有 curl，本脚本不降级" >&2; exit 1; }
CURL_VER=$(curl -V | head -n1 | awk '{print $2}')
PROXY=${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}

# ---------- 0.5 孤儿收尾（必须在任何探测/下载之前） ----------
# pgrep 的 pattern 是正则：路径里的反斜杠会被当转义，所以只匹配资产名（无路径分隔符）
sweep_orphans() {
  pat="${asset:-}"
  [ -n "$pat" ] || pat="$OUTDIR"
  # pgrep 是首选（macOS/Linux 都有）；Git Bash 没有 pgrep，退回 ps。
  # 注意：MSYS 的 ps 不显示进程参数，所以在 Windows Git Bash 上这里大概率扫不到——
  # Windows 请用 scripts/ghdl.ps1（它用 WMI 拿完整命令行）。真实 macOS/Linux 走 pgrep 分支。
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

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/ghdl.XXXXXX")
cleanup() {
  rm -rf "$tmpd"
  # 只停自己起的 curl（后台 pid 记录在 $tmpd/pids）
  if [ -f "$tmpd/pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null || true; done < "$tmpd/pids"
  fi
}
trap cleanup EXIT INT TERM

# ---------- 0. 解析 URL ----------
DIRECT=0
case "$URL" in
  https://github.com/*/releases/*) ;;
  https://*) DIRECT=1 ;;
  *) echo "BAD_URL: 只接受 https 直链或 https://github.com/<owner>/<repo>/releases/... ：$URL" >&2; exit 2 ;;
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
rest=${rest#releases/}      # 去掉 releases/ 前缀，剩下 download/<tag>/<asset> 或 tag/<tag>
tag=$(printf '%s' "$rest" | sed -n 's#^download/\([^/]*\)/.*#\1#p; s#^tag/\([^/]*\).*#\1#p' | head -n1)
asset=$(printf '%s' "$rest" | sed -n 's#^download/[^/]*/\(.*\)#\1#p' | head -n1)
repo="$owner/$repo_name"
echo "repo=$repo tag=$tag asset=${asset:-(待定)}"
fi

# ---------- 1. 自检 ----------
os=$(uname -s)
# 代理端口探测：用 curl 连一下 http://127.0.0.1:<port>（连不上返回 7），不依赖 /dev/tcp
echo "os=$os curl=$CURL_VER proxy_env=${PROXY:-(空)}"
found_port=""
for p in 7890 7891 7897 7898 1080 10808 10809 2080 8889 20171 8080; do
  if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$p" 2>/dev/null; then
    found_port=$p; break
  fi
done
echo "listen_port=${found_port:-(无)}"

# ---------- 2. 资产名校验（API；403 限流就降级继续） ----------
TOTAL=0
WANT=""
if [ "$DIRECT" = "1" ]; then
  # 直链没有 API：用 1 字节 range 的 Content-Range 反推总长，拿不到就只做字节校验
  dp=""
  if [ -n "${PROXY:-}" ]; then dp="--proxy $PROXY"; elif [ -n "$found_port" ]; then dp="--proxy http://127.0.0.1:$found_port"; fi
  h=$(curl -sS -L -m 20 -r 0-0 -A 'Mozilla/5.0' $dp -D - -o /dev/null "$URL" 2>/dev/null || true)
  cr=$(printf '%s' "$h" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *bytes [0-9]*-[0-9]*\/\([0-9][0-9]*\).*/\1/p' | tail -n1)
  if [ -z "${cr:-}" ]; then
    # 有的服务忽略 Range 直接回整包：退回 HEAD 的 Content-Length
    hl=$(curl -sSI -L -m 20 -A 'Mozilla/5.0' $dp "$URL" 2>/dev/null | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9][0-9]*\)$/\1/p' | tail -n1 || true)
    [ -n "${hl:-}" ] && [ "$hl" -gt 0 ] && cr=$hl
  fi
  [ -n "${cr:-}" ] && TOTAL=$cr
  echo "asset=$asset total=${TOTAL:-0} api=direct"
else
api="https://api.github.com/repos/$repo/releases/tags/$tag"
tok=${GITHUB_TOKEN:-}
# api.github.com 在很多网络里必须走代理：复用第 1 步探测到的端口（环境变量代理优先）。
# 下面的 $api_proxy 故意不加引号——它要么为空、要么正好是「--proxy http://...」两个词。
api_proxy=""
if [ -n "${PROXY:-}" ]; then api_proxy="--proxy $PROXY"
elif [ -n "$found_port" ]; then api_proxy="--proxy http://127.0.0.1:$found_port"
fi
api_json="$tmpd/api.json"
if [ -n "$tok" ]; then
  api_code=$(curl -sS -m 20 $api_proxy -H "Authorization: Bearer $tok" -o "$api_json" -w '%{http_code}' "$api" 2>/dev/null || echo 000)
else
  api_code=$(curl -sS -m 20 $api_proxy -o "$api_json" -w '%{http_code}' "$api" 2>/dev/null || echo 000)
fi
api_code=$(printf '%s' "$api_code" | tr -dc '0-9' | tail -c 3)
[ -n "$api_code" ] || api_code=000
api_body=$(cat "$api_json" 2>/dev/null || true)

if [ "$api_code" = "404" ]; then
  echo "RELEASE_NOT_FOUND: $repo tag=$tag" >&2
  exit 1
fi

TOTAL=0
WANT=""
if [ "$api_code" = "200" ]; then
  if [ -z "$asset" ]; then
    asset=$(printf '%s' "$api_body" | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -n1)
    [ -n "$asset" ] || { echo "ASSET_NOT_FOUND: release 里没有资产" >&2; exit 1; }
    echo "asset=$asset（URL 未指定，取第一个资产）"
  fi
  names=$(printf '%s' "$api_body" | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
  if ! printf '%s\n' "$names" | grep -Fxq "$asset"; then
    echo "ASSET_NOT_FOUND: $asset 不在该 release 里，候选：" >&2
    printf '%s\n' "$names" | sed 's/^/  - /' >&2
    exit 1
  fi
  # 多资产 release 里第一个 "size" 往往是别的资产的：先把 JSON 切成「一个资产一行的对象」，再取自己的
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
  echo "API_UNEXPECTED: code=$api_code，按 URL 继续" >&2
fi

fi

[ -n "${asset:-}" ] || { echo "BAD_URL: 没解析出资产名，请直接给 /releases/download/<tag>/<file> 链接" >&2; exit 2; }

if [ "$DIRECT" = "1" ]; then
  u="$URL"
else
  u="https://github.com/$repo/releases/download/$tag/$asset"
fi

# ---------- 3. 选路（镜像 vs 直连 vs 现有代理，1MB range 探针） ----------
probe() { # $1=name $2=url $3=proxy(可空)
  pf="$tmpd/p_$(echo "$1" | tr -c 'a-zA-Z0-9' '_')"
  set +e
  if [ -n "$3" ]; then
    curl -sS -L --connect-timeout 5 -m 8 -r 0-1048575 -A 'Mozilla/5.0' -o /dev/null \
      --proxy "$3" -w '%{http_code}|%{size_download}|%{speed_download}' "$2" > "$pf" 2>/dev/null
  else
    curl -sS -L --connect-timeout 5 -m 8 -r 0-1048575 -A 'Mozilla/5.0' -o /dev/null \
      -w '%{http_code}|%{size_download}|%{speed_download}' "$2" > "$pf" 2>/dev/null
  fi
  set -e
  printf '%s|%s|%s|%s\n' "$1" "$(cat "$pf" 2>/dev/null || echo '000|0|0')" "$2" "${3:-}"
}

: > "$tmpd/probes"
i=0
if [ "$DIRECT" = "0" ]; then
for m in https://ghfast.top https://ghproxy.net https://gh-proxy.com https://github.moeyy.xyz https://gh.llkk.cc https://ghproxy.cc; do
  probe "C 镜像 $m" "$m/$u" "" >> "$tmpd/probes" &
  i=$((i+1)); echo $! >> "$tmpd/pids"
done
fi
if [ -n "$found_port" ]; then
  probe "A 现有代理 :$found_port" "$u" "http://127.0.0.1:$found_port" >> "$tmpd/probes" &
  echo $! >> "$tmpd/pids"
elif [ -n "$PROXY" ]; then
  probe "A 环境代理" "$u" "$PROXY" >> "$tmpd/probes" &
  echo $! >> "$tmpd/pids"
fi
probe "D 直连" "$u" "" >> "$tmpd/probes" &
echo $! >> "$tmpd/pids"
wait || true

# 过滤出真正拿到数据的路线，按速度排序
# 每行格式：name|code|bytes|speed|url|proxy
# 小文件（<256KB）不能拿 256KB 当门槛：直链已知总长时门槛降到总长
minb=262144
if [ "${TOTAL:-0}" -gt 0 ] && [ "$TOTAL" -lt 262144 ]; then minb=$TOTAL; fi
best=$(awk -F'|' -v minb="$minb" '{
    code=$2; bytes=$3+0; spd=$4+0;
    if ((code=="200"||code=="206") && bytes>=minb) printf "%d\t%s\t%s\t%s\n", spd/1024, $1, $5, $6;
  }' "$tmpd/probes" | sort -rn | head -n1)
if [ -z "$best" ]; then
  echo "NO_ROUTE: 所有路线都没拿到数据" >&2
  awk -F'|' '{printf "  %-28s code=%s bytes=%s\n", $1, $2, $3}' "$tmpd/probes" >&2
  exit 1
fi
win_kbps=$(printf '%s' "$best" | cut -f1)
win_name=$(printf '%s' "$best" | cut -f2)
win_url=$(printf '%s' "$best" | cut -f3)
win_proxy=$(printf '%s' "$best" | cut -f4)
echo "route=$win_name KBps=$win_kbps"
echo "PROBE_206_OK=1"

# ---------- 3.5 拿不到 API（403 限流）时，用 1 字节 range 的 Content-Range 反推总长 ----------
# 没有 total 的后果很实在：没法幂等、没法续传、没法做 Content-Length 比对，所以必须补。
if [ "${TOTAL:-0}" -le 0 ]; then
  if [ -n "$win_proxy" ]; then
    h=$(curl -sS -L --connect-timeout 10 --max-time 20 -r 0-0 -A 'Mozilla/5.0' -D - -o /dev/null \
          --proxy "$win_proxy" "$win_url" 2>/dev/null || true)
  else
    h=$(curl -sS -L --connect-timeout 10 --max-time 20 -r 0-0 -A 'Mozilla/5.0' -D - -o /dev/null \
          "$win_url" 2>/dev/null || true)
  fi
  cr=$(printf '%s' "$h" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Rr]ange: *bytes [0-9]*-[0-9]*\/\([0-9][0-9]*\).*/\1/p' | tail -n1)
  if [ -z "${cr:-}" ]; then
    # 有的路线对 0-0 返回 200（忽略 Range），此时用 HEAD 的 Content-Length 兜底
    if [ -n "$win_proxy" ]; then
      hl=$(curl -sSI -L --connect-timeout 10 --max-time 20 -A 'Mozilla/5.0' --proxy "$win_proxy" "$win_url" 2>/dev/null | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9][0-9]*\)$/\1/p' | tail -n1 || true)
    else
      hl=$(curl -sSI -L --connect-timeout 10 --max-time 20 -A 'Mozilla/5.0' "$win_url" 2>/dev/null | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9][0-9]*\)$/\1/p' | tail -n1 || true)
    fi
    [ -n "${hl:-}" ] && [ "$hl" -gt 0 ] && cr=$hl
  fi
  if [ -n "${cr:-}" ]; then
    TOTAL=$cr
    echo "total_from_range=$TOTAL"
  fi
fi

# ---------- 4. 单连接探针（8MB） ----------
single_kbps=0
if [ -n "$win_proxy" ]; then
  s=$(curl -sS -L --connect-timeout 10 -r 0-8388607 -A 'Mozilla/5.0' -o /dev/null --proxy "$win_proxy" \
        -w '%{http_code}|%{size_download}|%{speed_download}' "$win_url" 2>/dev/null || echo '000|0|0')
else
  s=$(curl -sS -L --connect-timeout 10 -r 0-8388607 -A 'Mozilla/5.0' -o /dev/null \
        -w '%{http_code}|%{size_download}|%{speed_download}' "$win_url" 2>/dev/null || echo '000|0|0')
fi
s_code=$(printf '%s' "$s" | cut -d'|' -f1)
s_spd=$(printf '%s' "$s" | cut -d'|' -f3 | cut -d. -f1)
case "$s_code" in 200|206) single_kbps=$(( ${s_spd:-0} / 1024 )) ;; esac
echo "singleKB=$single_kbps"

# ---------- 5. 1/16 限时阶梯（只在值得测的时候测） ----------
rung() { # $1=n -> 输出 "n|kbps|full"
  # 不依赖 date +%s%N（BSD/macOS 的 date 没有 %N），改用每条 curl 自报的 speed_download：
  # 同一时间窗内并发 N 条的瞬时速度之和，就是这一档的聚合吞吐。
  n=$1; sec=4; dir="$tmpd/r$n"; mkdir -p "$dir"
  total_spd=0; full=0; j=0
  while [ $j -lt "$n" ]; do
    if [ -n "$win_proxy" ]; then
      curl -sS -L --connect-timeout 8 -m "$sec" -r "$((TOTAL / n * j))-" -A 'Mozilla/5.0' \
        -o "$dir/p$j.bin" --proxy "$win_proxy" -w '%{speed_download}' "$win_url" > "$dir/s$j.txt" 2>/dev/null &
    else
      curl -sS -L --connect-timeout 8 -m "$sec" -r "$((TOTAL / n * j))-" -A 'Mozilla/5.0' \
        -o "$dir/p$j.bin" -w '%{speed_download}' "$win_url" > "$dir/s$j.txt" 2>/dev/null &
    fi
    echo $! >> "$dir/pids"
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

big_enough=0
[ "${TOTAL:-0}" -ge $(( LADDER_MIN_MB * 1024 * 1024 )) ] && big_enough=1
if [ "$FORCE_LADDER" = "1" ] && [ "${TOTAL:-0}" -gt 0 ]; then
  rung16=$(rung 16); rung1=$(rung 1)
  echo "LADDER_DONE: rungs=1/16 passes=1 (sh 版只跑一遍)"
elif [ "$big_enough" = "1" ] && [ "$single_kbps" -lt "$FAST_KBPS" ]; then
  rung1=$(rung 1); rung16=$(rung 16)
  echo "LADDER_DONE: rungs=1/16 passes=1 (sh 版只跑一遍)"
else
  rung1="1|0|0"; rung16="16|0|0"
  tmb=$(awk -v t="${TOTAL:-0}" 'BEGIN{ if (t<=0) print "unknown"; else printf "%.1f", t/1048576 }')
  echo "SKIP_LADDER: total=${tmb}MB singleKB=$single_kbps (门槛 ${LADDER_MIN_MB}MB / ${FAST_KBPS}KB/s) -> 单流"
fi

k1=$(printf '%s' "$rung1" | cut -d'|' -f2)
k16=$(printf '%s' "$rung16" | cut -d'|' -f2)
winN=1
if [ "$k16" -gt 0 ] && [ "$k1" -gt 0 ] && [ "$k16" -ge $(( k1 * 125 / 100 )) ]; then winN=16; fi
if [ "$PARTS_OVERRIDE" -gt 0 ]; then
  if [ "${TOTAL:-0}" -gt 0 ]; then winN=$PARTS_OVERRIDE
  else
    # 没有总字节数就没法算 range 边界：与其假装分段，不如说清楚然后走单流
    echo "PARTS_IGNORED: 总字节数未知（API 限流或不可达），无法切 range，改走单流" >&2
    winN=1
  fi
fi
echo "winN=$winN"

# ---------- 6. 下载 ----------
# 6.0 再扫一次孤儿（第 0.5 步之后可能有新进程；只按资产名匹配，避免正则吃掉反斜杠）
sweep_orphans
mkdir -p "$OUTDIR"
target="$OUTDIR/$asset"
if [ "${FORCE_CLEAN:-0}" = "1" ]; then
  rm -f "$target" "$target.headers"
  rm -rf "$OUTDIR/$asset.parts"
  echo "FORCE_CLEAN: 已删旧成品与旧分片"
fi

# 6.1 幂等：成品已存在且字节数与 total 一致 → 不重下（校验留到第 7 步统一做）
skip_dl=0
if [ -f "$target" ] && [ "${TOTAL:-0}" -gt 0 ]; then
  have=$(wc -c < "$target" | tr -d ' ')
  if [ "$have" -eq "$TOTAL" ]; then
    skip_dl=1
    echo "ALREADY_DONE: $target 已存在且 $have 字节（不重下）"
  fi
fi

if [ "$skip_dl" = "1" ]; then
  echo "engine=cached"
elif [ "$winN" -gt 1 ] && [ "${TOTAL:-0}" -gt 0 ]; then
  dir="$OUTDIR/$asset.parts"
  manifest="$dir/manifest"
  # 6.2 跨进程续传：分段方案落盘（total chunk nseg），重跑方案一致就沿用，已下好的段跳过
  m_total=0; m_chunk=0; m_nseg=0
  if [ -f "$manifest" ]; then
    read -r m_total m_chunk m_nseg < "$manifest" || true
  fi
  if [ "${m_total:-0}" -eq "$TOTAL" ] && [ "${m_nseg:-0}" -ge 1 ] && [ "${m_chunk:-0}" -ge 1 ]; then
    chunk=$m_chunk; winN=$m_nseg
    echo "RESUME_PLAN: 沿用上次分段 nseg=$winN chunk=$chunk"
  else
    rm -rf "$dir"; mkdir -p "$dir"
    chunk=$(( TOTAL / winN ))
    # 反算 chunk 保证 nseg*chunk >= total（否则最后一段会短）
    while [ $(( chunk * winN )) -lt "$TOTAL" ]; do chunk=$((chunk + 1)); done
    printf '%s %s %s\n' "$TOTAL" "$chunk" "$winN" > "$manifest"
    echo "PLAN: nseg=$winN chunk=$chunk"
  fi
  echo "engine=plain parts=$winN chunk=$chunk"
  j=0
  while [ $j -lt "$winN" ]; do
    s=$(( chunk * j ))
    if [ "$j" -eq $((winN - 1)) ]; then e=$(( TOTAL - 1 )); else e=$(( s + chunk - 1 )); fi
    part="$dir/p$j.bin"
    need=$(( e - s + 1 ))
    have=0
    if [ -f "$part" ]; then have=$(wc -c < "$part" | tr -d ' '); fi
    if [ "$have" -eq "$need" ]; then
      j=$((j+1)); continue
    fi
    if [ "$have" -gt "$need" ]; then
      # 多出来的部分是上次写坏的，从正确边界重来
      rm -f "$part"; have=0
    fi
    if [ "$have" -gt 0 ]; then
      rs=$(( s + have )); tgt="$part.resume"
      echo "SEG_RESUME: p$j 从 $have/$need 字节继续"
    else
      rs=$s; tgt="$part"
    fi
    if [ -n "$win_proxy" ]; then
      ( curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -r "$rs-$e" -m 1800 \
          -o "$tgt" --proxy "$win_proxy" --retry 3 --retry-delay 2 "$win_url" ; echo $? > "$tgt.rc" ) &
    else
      ( curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -r "$rs-$e" -m 1800 \
          -o "$tgt" --retry 3 --retry-delay 2 "$win_url" ; echo $? > "$tgt.rc" ) &
    fi
    echo $! >> "$tmpd/pids"
    j=$((j+1))
  done
  wait || true
  # 6.3 拼前先逐段硬核：每段字节数必须精确等于 end-start+1，再合并
  j=0; bad=""
  while [ $j -lt "$winN" ]; do
    s=$(( chunk * j ))
    if [ "$j" -eq $((winN - 1)) ]; then e=$(( TOTAL - 1 )); else e=$(( s + chunk - 1 )); fi
    need=$(( e - s + 1 ))
    part="$dir/p$j.bin"
    if [ -f "$part.resume" ]; then cat "$part.resume" >> "$part"; rm -f "$part.resume"; fi
    got=0
    if [ -f "$part" ]; then got=$(wc -c < "$part" | tr -d ' '); fi
    if [ "$got" -ne "$need" ]; then bad="$bad p$j(need=$need got=$got)"; fi
    j=$((j+1))
  done
  if [ -n "$bad" ]; then
    echo "SEGMENT_SIZE_MISMATCH:$bad（分片留在 $dir，可直接重跑续传）" >&2
    exit 1
  fi
  : > "$target"
  j=0
  while [ $j -lt "$winN" ]; do cat "$dir/p$j.bin" >> "$target"; j=$((j+1)); done
  echo "assembled=$(wc -c < "$target" | tr -d ' ')"
  rm -rf "$dir"
else
  part0="$target.part"
  [ -f "$target" ] && mv -f "$target" "$part0" 2>/dev/null || true
  resume=""
  if [ -f "$part0" ] && [ "${TOTAL:-0}" -gt 0 ]; then
    have=$(wc -c < "$part0" | tr -d ' ')
    if [ "$have" -gt 0 ] && [ "$have" -lt "$TOTAL" ]; then
      resume="-C -"
      echo "SINGLE_RESUME: 从 $have 字节继续"
    fi
  fi
  if [ -n "$win_proxy" ]; then
    # shellcheck disable=SC2086
    curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -o "$part0" -D "$target.headers" -m 1800 \
      --proxy "$win_proxy" --retry 3 --retry-delay 2 $resume \
      -w 'code=%{http_code}|got=%{size_download}|speed=%{speed_download}\n' "$win_url"
  else
    # shellcheck disable=SC2086
    curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -o "$part0" -D "$target.headers" -m 1800 \
      --retry 3 --retry-delay 2 $resume \
      -w 'code=%{http_code}|got=%{size_download}|speed=%{speed_download}\n' "$win_url"
  fi
  rc=$?
  echo "SINGLE exit=$rc"
  if [ "$rc" -ne 0 ]; then
    echo "SINGLE_FAILED: exit=$rc" >&2
    exit 1
  fi
  # 三方差一即失败：远端声明的 Content-Length 必须等于 total（续传时只剩剩余字节，不参与比对）
  if [ -z "$resume" ] && [ -f "$target.headers" ] && [ "${TOTAL:-0}" -gt 0 ]; then
    cl=$(tr -d '\r' < "$target.headers" | sed -n 's/^[Cc]ontent-[Ll]ength: *//p' | tail -n1)
    if [ -n "${cl:-}" ] && [ "$cl" -ne "$TOTAL" ]; then
      echo "SIZE_MISMATCH: Content-Length=$cl 与 total=$TOTAL 不一致" >&2
      exit 1
    fi
  fi
  rm -f "$target.headers"
  mv -f "$part0" "$target"
fi

# ---------- 7. 校验 ----------
size=$(wc -c < "$target" | tr -d ' ')
echo "size=$size expect=${TOTAL:-?}"
if [ "${TOTAL:-0}" -gt 0 ] && [ "$size" -ne "$TOTAL" ]; then
  echo "DOWNLOAD_VERIFY_FAILED: size mismatch" >&2
  exit 1
fi
if [ -n "$WANT" ]; then
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$target" | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$target" | cut -d' ' -f1)
  elif command -v openssl >/dev/null 2>&1; then got=$(openssl dgst -sha256 "$target" | sed 's/.*= //')
  else got=""; fi
  if [ -z "$got" ]; then
    echo "NO_HASH_TOOL: 没有 sha256sum/shasum/openssl，只做了字节校验"
    echo "DOWNLOAD_SIZE_OK_NO_DIGEST"
  else
    echo "sha256=$got expect=$WANT"
    [ "$got" = "$(printf '%s' "$WANT" | tr 'A-F' 'a-f')" ] && echo "DOWNLOAD_VERIFIED_OK" || { echo "DOWNLOAD_VERIFY_FAILED: sha256 mismatch" >&2; exit 1; }
  fi
else
  echo "NO_DIGEST: 只能保证字节数一致"
  echo "DOWNLOAD_SIZE_OK_NO_DIGEST"
fi

echo "saved=$target"
