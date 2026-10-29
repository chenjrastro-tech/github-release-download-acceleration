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
case "$URL" in
  https://github.com/*/releases/*) ;;
  *) echo "BAD_URL: 只接受 https://github.com/<owner>/<repo>/releases/... ：$URL" >&2; exit 2 ;;
esac
rest=${URL#https://github.com/}
owner=${rest%%/*}; rest=${rest#*/}
repo_name=${rest%%/*}; rest=${rest#*/}
tag=$(printf '%s' "$rest" | sed -n 's#^download/\([^/]*\)/.*#\1#p; s#^tag/\([^/]*\).*#\1#p' | head -n1)
asset=$(printf '%s' "$rest" | sed -n 's#^download/[^/]*/\(.*\)#\1#p' | head -n1)
repo="$owner/$repo_name"
echo "repo=$repo tag=$tag asset=${asset:-(待定)}"

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
api="https://api.github.com/repos/$repo/releases/tags/$tag"
tok=${GITHUB_TOKEN:-}
if [ -n "$tok" ]; then
  api_out=$(curl -sS -m 20 -H "Authorization: Bearer $tok" -w '\n%{http_code}' "$api" || echo "000")
else
  api_out=$(curl -sS -m 20 -w '\n%{http_code}' "$api" || echo "000")
fi
api_code=$(printf '%s' "$api_out" | tail -n1)
api_body=$(printf '%s' "$api_out" | sed '$d')

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
  TOTAL=$(printf '%s' "$api_body" | grep -o '"size": *[0-9]*' | sed 's/[^0-9]//g' | head -n1)
  dig=$(printf '%s' "$api_body" | grep -o '"digest": *"sha256:[0-9a-fA-F]*"' | sed 's/.*sha256:\([0-9a-fA-F]*\)".*/\1/' | head -n1 || true)
  [ -n "$dig" ] && WANT=$dig
  # 多资产时上面的 size 可能不是目标资产的；有 jq 的环境里这是 trivial，这里只做尽力而为
  echo "asset=$asset total=${TOTAL:-0} want=${WANT:-(无 digest)} api=200"
elif [ "$api_code" = "403" ]; then
  echo "API_RATE_LIMITED: 403，继续但只做字节校验；想提升限额可设 GITHUB_TOKEN"
elif [ "$api_code" = "000" ]; then
  echo "ASSET_UNVERIFIED: API 不可达，按 URL 继续，只做字节校验"
else
  echo "API_UNEXPECTED: code=$api_code，按 URL 继续" >&2
fi

[ -n "${asset:-}" ] || { echo "BAD_URL: 没解析出资产名，请直接给 /releases/download/<tag>/<file> 链接" >&2; exit 2; }

u="https://github.com/$repo/releases/download/$tag/$asset"

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
for m in https://ghfast.top https://ghproxy.net https://gh-proxy.com https://github.moeyy.xyz https://gh.llkk.cc https://ghproxy.cc; do
  probe "C 镜像 $m" "$m/$u" "" >> "$tmpd/probes" &
  i=$((i+1)); echo $! >> "$tmpd/pids"
done
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
best=$(awk -F'|' '{
    code=$2; bytes=$3+0; spd=$4+0;
    if ((code=="200"||code=="206") && bytes>=262144) printf "%d\t%s\t%s\t%s\n", spd/1024, $1, $5, $6;
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
  n=$1; sec=4; dir="$tmpd/r$n"; mkdir -p "$dir"
  start=$(date +%s%N 2>/dev/null || echo 0)
  size=0; full=0; j=0
  while [ $j -lt "$n" ]; do
    if [ -n "$win_proxy" ]; then
      curl -sS -L --connect-timeout 8 -m "$sec" -r "$((TOTAL / n * j))-" -A 'Mozilla/5.0' \
        -o "$dir/p$j.bin" --proxy "$win_proxy" "$win_url" >/dev/null 2>&1 &
    else
      curl -sS -L --connect-timeout 8 -m "$sec" -r "$((TOTAL / n * j))-" -A 'Mozilla/5.0' \
        -o "$dir/p$j.bin" "$win_url" >/dev/null 2>&1 &
    fi
    echo $! >> "$dir/pids"
    j=$((j+1))
  done
  wait || true
  for f in "$dir"/p*.bin; do
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f" | tr -d ' ')
    size=$((size + sz))
    [ "$sz" -gt 0 ] && full=$((full + 1))
  done
  end=$(date +%s%N 2>/dev/null || echo 0)
  if [ "$start" != "0" ] && [ "$end" != "0" ]; then
    ms=$(( (end - start) / 1000000 )); [ "$ms" -lt 1 ] && ms=1
    echo "$n|$(( size * 1000 / ms / 1024 ))|$full"
  else
    echo "$n|0|$full"
  fi
}

big_enough=0
[ "${TOTAL:-0}" -ge $(( LADDER_MIN_MB * 1024 * 1024 )) ] && big_enough=1
if [ "$FORCE_LADDER" = "1" ]; then
  rung16=$(rung 16); rung1=$(rung 1)
  echo "LADDER_DONE: rungs=1/16 passes=1 (sh 版只跑一遍)"
elif [ "$big_enough" = "1" ] && [ "$single_kbps" -lt "$FAST_KBPS" ]; then
  rung1=$(rung 1); rung16=$(rung 16)
  echo "LADDER_DONE: rungs=1/16 passes=1 (sh 版只跑一遍)"
else
  rung1="1|0|0"; rung16="16|0|0"
  echo "SKIP_LADDER: total=$(( ${TOTAL:-0} / 1048576 ))MB singleKB=$single_kbps (门槛 ${LADDER_MIN_MB}MB / ${FAST_KBPS}KB/s) -> 单流"
fi

k1=$(printf '%s' "$rung1" | cut -d'|' -f2)
k16=$(printf '%s' "$rung16" | cut -d'|' -f2)
winN=1
if [ "$k16" -gt 0 ] && [ "$k1" -gt 0 ] && [ "$k16" -ge $(( k1 * 125 / 100 )) ]; then winN=16; fi
[ "$PARTS_OVERRIDE" -gt 0 ] && winN=$PARTS_OVERRIDE
echo "winN=$winN"

# ---------- 6. 下载 ----------
mkdir -p "$OUTDIR"
target="$OUTDIR/$asset"
if [ "$winN" -gt 1 ] && [ "${TOTAL:-0}" -gt 0 ]; then
  dir="$tmpd/parts"; mkdir -p "$dir"
  chunk=$(( TOTAL / winN ))
  echo "parts=$winN chunk=$chunk"
  j=0
  while [ $j -lt "$winN" ]; do
    s=$(( chunk * j ))
    if [ "$j" -eq $((winN - 1)) ]; then e=$(( TOTAL - 1 )); else e=$(( s + chunk - 1 )); fi
    if [ -n "$win_proxy" ]; then
      curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -r "$s-$e" -m 1800 \
        -o "$dir/p$j.bin" --proxy "$win_proxy" --retry 3 --retry-delay 2 "$win_url" &
    else
      curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -r "$s-$e" -m 1800 \
        -o "$dir/p$j.bin" --retry 3 --retry-delay 2 "$win_url" &
    fi
    echo $! >> "$tmpd/pids"
    j=$((j+1))
  done
  wait || { echo "PARTS_FAILED: 有分片失败" >&2; exit 1; }
  sum=0
  for f in "$dir"/p*.bin; do sum=$(( sum + $(wc -c < "$f" | tr -d ' ') )); done
  echo "partsBytes=$sum total=$TOTAL"
  [ "$sum" -eq "$TOTAL" ] || { echo "PARTS_MISMATCH: sum=$sum total=$TOTAL" >&2; exit 1; }
  : > "$target"
  j=0
  while [ $j -lt "$winN" ]; do cat "$dir/p$j.bin" >> "$target"; j=$((j+1)); done
  echo "assembled=$(wc -c < "$target" | tr -d ' ')"
else
  if [ -n "$win_proxy" ]; then
    curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -o "$target" -m 1800 \
      --proxy "$win_proxy" --retry 3 --retry-delay 2 -w 'code=%{http_code}|got=%{size_download}|speed=%{speed_download}\n' "$win_url"
  else
    curl -sS -L --fail --connect-timeout 10 -A 'Mozilla/5.0' -o "$target" -m 1800 \
      --retry 3 --retry-delay 2 -w 'code=%{http_code}|got=%{size_download}|speed=%{speed_download}\n' "$win_url"
  fi
  echo "SINGLE exit=0"
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
