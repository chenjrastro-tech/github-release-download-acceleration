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
    echo "MIN_SEG_FALLBACK: 分片不齐（$sum/$total），改单流重下"; rm -rf "$tmpd"
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
