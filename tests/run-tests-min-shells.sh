#!/bin/bash
# run-tests-min-shells.sh —— 用不同的 POSIX shell 跑 scripts/ghdl-min.sh（自举最小版）。
#
#   用法：bash tests/run-tests-min-shells.sh [shell...]
#   默认测 bash / dash / busybox / ksh 中本机存在的那些。
#
# 为什么单独测它：ghdl-min.sh 宣称是「POSIX sh，无数组、无 [[ ]]」，但 CI 只覆盖过 bash。
# dash 对 `local`、`$(( ))` 里的前导空格、`test` 的空值最挑剔，busybox 又是另一套实现，
# 这层验证不写，文档里的「POSIX」就只是自我声明。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MIN="$ROOT/scripts/ghdl-min.sh"
PORT=${PORT:-18811}
PY=${PYTHON:-python3}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghdlmin.XXXXXX")
PASS=0; FAIL=0; SRV_PID=""

cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s %s\n' "$1" "${2:-}"; }

"$PY" -c 'import sys' >/dev/null 2>&1 || { echo "SKIP: 没有可用的 python3（可用 PYTHON=... 指定）"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: 没有 curl"; exit 0; }

"$PY" "$HERE/serve.py" "$PORT" >"$WORK/serve.log" 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/ok.bin" && break
  sleep 0.3
done
curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/ok.bin" || { echo "SKIP: 假服务器没起来"; exit 0; }
BASE="http://127.0.0.1:$PORT"

sha_of() {  # 与本仓库其它套件一致的三级降级
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1; fi
}

# 期望值：3MB / 64MB 同一条花纹 byte[i] = (i*7+3) & 0xFF
EXP3=""
EXP64=""

check_shell() {  # check_shell <label> <shell-cmd...>
  local label=$1; shift
  local shcmd="$*"
  printf '[%s] %s\n' "$label" "$shcmd"

  local d="$WORK/$label"
  mkdir -p "$d/one" "$d/seg"
  local out rc
  out=$($shcmd "$MIN" "$BASE/ok.bin" "$d/one" 2>&1); rc=$?
  if [ $rc -eq 0 ] && has "$out" "MIN_OK" && [ "$(wc -c <"$d/one/ok.bin" 2>/dev/null | tr -d ' ')" = 3145728 ]; then
    ok "$label 单流 3MB"
  else
    bad "$label 单流 3MB" "rc=$rc"; printf '%s\n' "$out" | tail -6
  fi

  # 64MB 会走 >=32MB 的 8 段分支，覆盖 $(( )) 与后台 wait
  out=$($shcmd "$MIN" "$BASE/big.bin" "$d/seg" 2>&1); rc=$?
  if [ $rc -eq 0 ] && { has "$out" "MIN_SEG_OK" || has "$out" "MIN_SEG_FALLBACK"; } && [ "$(wc -c <"$d/seg/big.bin" 2>/dev/null | tr -d ' ')" = 67108864 ]; then
    ok "$label 分段/回落 64MB"
  else
    bad "$label 64MB" "rc=$rc"; printf '%s\n' "$out" | tail -6
  fi

  if [ -f "$d/seg/big.bin" ] && [ -n "$EXP64" ]; then
    [ "$(sha_of "$d/seg/big.bin")" = "$EXP64" ] && ok "$label 内容 SHA256" || bad "$label 内容 SHA256"
  fi
}

has() { printf '%s' "$1" | grep -qF -- "$2"; }

EXP3=$("$PY" - <<'PY'
import hashlib
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
h = hashlib.sha256(); n = 3 * 1024 * 1024; done = 0
while done < n:
    take = min(len(pat), n - done); h.update(pat[:take]); done += take
print(h.hexdigest())
PY
)
EXP64=$("$PY" - <<'PY'
import hashlib
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
h = hashlib.sha256(); n = 64 * 1024 * 1024; done = 0
while done < n:
    take = min(len(pat), n - done); h.update(pat[:take]); done += take
print(h.hexdigest())
PY
)
: "$EXP3"

if [ $# -gt 0 ]; then
  for spec in "$@"; do
    case "$spec" in
      busybox) check_shell busybox busybox sh ;;
      *) check_shell "$spec" "$spec" ;;
    esac
  done
else
  command -v bash >/dev/null 2>&1 && check_shell bash bash
  command -v dash >/dev/null 2>&1 && check_shell dash dash
  if command -v busybox >/dev/null 2>&1; then check_shell busybox busybox sh; fi
  command -v ksh >/dev/null 2>&1 && check_shell ksh ksh
fi

echo "----------------------------------------"
if [ $PASS -eq 0 ]; then echo "SKIP: 本机没有任何可测的 POSIX shell"; exit 0; fi
if [ $FAIL -eq 0 ]; then echo "TESTS_MIN_SHELLS_OK: $PASS 项通过"; exit 0; fi
echo "TESTS_MIN_SHELLS_FAILED: $PASS 通过 / $FAIL 失败"; exit 1
