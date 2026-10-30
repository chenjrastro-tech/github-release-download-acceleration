#!/bin/bash
# run-tests-sh.sh —— POSIX runner（scripts/ghdl.sh）的离线回归，确定性、不依赖外网。
#
#   前置：bash 3.2+、curl、python3（只用来起本地假服务器并算期望 SHA256）
#   用法：bash tests/run-tests-sh.sh [port]
#
# 覆盖：单流 / 分段 / 续传 / 不支持 Range / 404 / 截断包 / P2SP / 死源 / 坏分片 / 幂等 / KEEP_TMP / 冒烟 / 退出码
# 与 Windows 侧 tests/run-tests.ps1 是姊妹套件，改契约时两边一起改。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
RUNNER="$ROOT/scripts/ghdl.sh"
PORT=${1:-18795}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghdlsh.XXXXXX")
PASS=0; FAIL=0
SRV_PID=""

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "${SRV2_PID:-}" ] && kill "$SRV2_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s %s\n' "$1" "${2:-}"; }
has()  { printf '%s' "$1" | grep -qF -- "$2"; }

# 假服务器要 python3；Windows 的 python3 常是应用商店占位符，可通过 PYTHON=<真实解释器> 覆盖
PY=${PYTHON:-python3}
"$PY" -c 'import sys' >/dev/null 2>&1 || { echo "SKIP: 没有可用的 python3（可用 PYTHON=/path/to/python3 指定）"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: 没有 curl"; exit 0; }

"$PY" "$HERE/serve.py" "$PORT" >"$WORK/serve.log" 2>&1 &
SRV_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/ok.bin" && break
  sleep 0.3
done
curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/ok.bin" || { echo "SKIP: 假服务器没起来"; exit 0; }
BASE="http://127.0.0.1:$PORT"

run() {  # run <outdir> <env...> -- <url>
  local out=$1; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  mkdir -p "$out"
  env OUTDIR="$out" SMOKE=0 KEEP_TMP=0 ${envs[@]+"${envs[@]}"} bash "$RUNNER" "$1" 2>&1
}

echo "[1] 单流 3MB"
OUT=$(run "$WORK/t1" -- "$BASE/ok.bin"); RC=$?
if [ $RC -eq 0 ] && has "$OUT" "SINGLE exit=0" && has "$OUT" "size=3145728"; then ok "单流 + 字节"; else bad "单流 + 字节" "rc=$RC"; printf '%s\n' "$OUT" | tail -20; fi
if [ -f "$WORK/t1/ok.bin" ] && [ "$(wc -c <"$WORK/t1/ok.bin")" -eq 3145728 ]; then ok "落盘 3,145,728 字节"; else bad "落盘字节"; fi

echo "[2] 分段 8 段 64MB"
OUT=$(run "$WORK/t2" PARTS=8 -- "$BASE/big.bin"); RC=$?
EXP=$("$PY" - "$BASE" "$PORT" <<'PY'
import hashlib, sys
n = 64 * 1024 * 1024
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
h = hashlib.sha256()
done = 0
while done < n:
    take = min(len(pat), n - done)
    h.update(pat[:take]); done += take
print(h.hexdigest())
PY
)
if [ $RC -eq 0 ] && has "$OUT" "assembled=67108864"; then ok "拼装 67,108,864 字节"; else bad "拼装字节" "rc=$RC"; printf '%s\n' "$OUT" | tail -5; fi
GOT=$(sha256sum "$WORK/t2/big.bin" 2>/dev/null | cut -d' ' -f1)
[ -z "$GOT" ] && GOT=$(openssl dgst -sha256 -r "$WORK/t2/big.bin" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$EXP" ] && ok "内容 SHA256 与期望一致" || bad "内容 SHA256" "got=${GOT:0:12} exp=${EXP:0:12}"

echo "[3] 续传（预置 manifest + 分片，模拟上次中断）"
D3="$WORK/t3/big.bin.parts"
mkdir -p "$D3"
printf '%s %s %s\n' 67108864 8388608 8 > "$D3/manifest"
"$PY" - "$D3" <<'PY'
import sys
d = sys.argv[1]
total, chunk, n = 67108864, 8388608, 8
pat = bytes(((i * 7 + 3) & 0xFF) for i in range(1024 * 1024))
def body(start, end):
    m = end - start + 1
    base = pat[start % len(pat):] + pat * (m // len(pat) + 2)
    return base[:m]
for k in range(n):
    s0 = k * chunk
    e0 = min(s0 + chunk, total) - 1
    need = e0 - s0 + 1
    take = need if k < 4 else need // 3          # 前 4 段完整，第 5 段只 1/3
    with open("%s/p%03d.bin" % (d, k), "wb") as f:
        f.write(body(s0, s0 + take - 1))
PY
OUT=$(run "$WORK/t3" PARTS=8 -- "$BASE/big.bin"); RC=$?
if [ $RC -eq 0 ] && has "$OUT" "RESUME_PLAN:" && [ "$(wc -c <"$WORK/t3/big.bin" 2>/dev/null | tr -d ' ')" = 67108864 ]; then ok "沿用 manifest 并补齐"; else bad "续传" "rc=$RC"; printf '%s\n' "$OUT" | head -6; printf '%s\n' "$OUT" | tail -5; printf "  [dbg] t3 ls=%s wc=%s\n" "$(ls -l $WORK/t3 2>&1 | head -3 | tr '\n' ';')" "$(wc -c <$WORK/t3/big.bin 2>/dev/null)"; fi
GOT=$(sha256sum "$WORK/t3/big.bin" 2>/dev/null | cut -d' ' -f1)
[ -z "$GOT" ] && GOT=$(openssl dgst -sha256 -r "$WORK/t3/big.bin" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$EXP" ] && ok "续传后内容一致" || bad "续传后内容" "got=${GOT:0:12} exp=${EXP:0:12}"

echo "[4] 服务器忽略 Range"
OUT=$(run "$WORK/t4" PARTS=8 -- "$BASE/norange.bin"); RC=$?
if [ $RC -eq 0 ] && has "$OUT" "RANGE_UNSUPPORTED"; then ok "秒级降级单流"; else bad "忽略 Range 降级" "rc=$RC"; printf '%s\n' "$OUT" | tail -4; fi

echo "[5] 404"
OUT=$(run "$WORK/t5" -- "$BASE/missing.bin"); RC=$?
if [ $RC -ne 0 ] && { has "$OUT" "NO_ROUTE" || has "$OUT" "SINGLE_FAILED"; }; then ok "404 非零退出并报错"; else bad "404 行为" "rc=$RC"; printf '%s\n' "$OUT" | tail -4; fi

echo "[6] 截断包（声明 2MB 实发 700KB）"
OUT=$(run "$WORK/t6" -- "$BASE/short.bin"); RC=$?
if [ $RC -ne 0 ] && { has "$OUT" "SIZE_MISMATCH" || has "$OUT" "SINGLE_FAILED"; }; then ok "截断被拦住"; else bad "截断检测" "rc=$RC"; printf '%s\n' "$OUT" | tail -4; fi

echo "[7] P2SP 双源混拨（两个本地服务器）"
PORT2=$((PORT + 1))
"$PY" "$HERE/serve.py" "$PORT2" >"$WORK/serve2.log" 2>&1 &
SRV2_PID=$!
# 备源必须真的能吐 1MB（探测阶段跑的就是 Range 1MB，光连上不代表能服务）
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  r=$(curl -s -L --connect-timeout 1 -m 5 -r 0-1048575 -o /dev/null \
        -w '%{http_code}|%{size_download}' --noproxy '*' "http://127.0.0.1:$PORT2/big.bin" 2>/dev/null || echo '000|0')
  [ "$r" = "200|1048576" ] || [ "$r" = "206|1048576" ] && { ready=1; break; }
  sleep 0.3
done
if [ "$ready" != 1 ]; then echo "  [WARN] 备源 $PORT2 没就绪，跳过后半用例" ; fi
OUT=$(run "$WORK/t7" PARTS=8 "P2SP_URLS=http://127.0.0.1:$PORT2/big.bin" -- "$BASE/big.bin"); RC=$?
kill "$SRV2_PID" 2>/dev/null
if [ $RC -eq 0 ] && has "$OUT" "POOL: 2"; then ok "双源都进池"; else bad "P2SP 双源" "rc=$RC"; printf '%s\n' "$OUT" | grep -E 'POOL|route=' | head -3; fi
if [ -f "$WORK/t7/big.bin" ] && [ "$(wc -c <"$WORK/t7/big.bin" | tr -d ' ')" = 67108864 ]; then ok "双源拼装字节正确"; else bad "双源拼装字节"; printf "  [dbg] t7 ls=%s wc=%s\n" "$(ls -l $WORK/t7 2>&1 | head -3 | tr '\n' ';')" "$(wc -c <$WORK/t7/big.bin 2>/dev/null)"; fi

echo "[8] 死 P2SP 源（不可达端口）不影响正经源"
OUT=$(run "$WORK/t8" PARTS=8 "P2SP_URLS=http://127.0.0.1:1/big.bin" -- "$BASE/big.bin"); RC=$?
if [ $RC -eq 0 ] && [ "$(wc -c <"$WORK/t8/big.bin" 2>/dev/null | tr -d ' ')" = 67108864 ]; then ok "死源被丢弃，仍拼装完整"; else bad "死 P2SP 源" "rc=$RC"; printf '%s\n' "$OUT" | tail -4; printf "  [dbg] t8 ls=%s wc=%s\n" "$(ls -l $WORK/t8 2>&1 | head -3 | tr '\n' ';')" "$(wc -c <$WORK/t8/big.bin 2>/dev/null)"; fi

echo "[9] 坏分片（长度超出应有值）→ 丢弃重下"
D9="$WORK/t9/big.bin.parts"
mkdir -p "$D9"
printf '%s %s %s\n' 67108864 8388608 8 > "$D9/manifest"
"$PY" - "$D9" <<'PY'
import sys
d = sys.argv[1]
with open(d + "/p001.bin", "wb") as f:      # 第 1 段应为 8,388,608，故意写 9,000,000
    f.write(b"\x00" * 9000000)
PY
OUT=$(run "$WORK/t9" PARTS=8 -- "$BASE/big.bin"); RC=$?
if [ $RC -eq 0 ] && [ "$(wc -c <"$WORK/t9/big.bin" 2>/dev/null | tr -d ' ')" = 67108864 ]; then ok "坏分片被丢弃重下"; else bad "坏分片处理" "rc=$RC"; printf '%s\n' "$OUT" | tail -4; printf "  [dbg] t9 ls=%s wc=%s\n" "$(ls -l $WORK/t9 2>&1 | head -3 | tr '\n' ';')" "$(wc -c <$WORK/t9/big.bin 2>/dev/null)"; fi
GOT=$(sha256sum "$WORK/t9/big.bin" 2>/dev/null | cut -d' ' -f1)
[ -z "$GOT" ] && GOT=$(openssl dgst -sha256 -r "$WORK/t9/big.bin" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$EXP" ] && ok "坏分片重下后内容一致" || bad "坏分片后内容" "got=${GOT:0:12}"

echo "[10] 幂等：成品已完整 → ALREADY_DONE 不重下"
OUT=$(run "$WORK/t10" -- "$BASE/ok.bin"); RC1=$?
BEFORE=$(wc -c <"$WORK/t10/ok.bin" 2>/dev/null)
OUT2=$(run "$WORK/t10" -- "$BASE/ok.bin"); RC2=$?
if [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && has "$OUT2" "ALREADY_DONE"; then ok "第二次直接跳过"; else bad "幂等" "rc1=$RC1 rc2=$RC2"; printf '%s\n' "$OUT2" | tail -3; fi

echo "[11] KEEP_TMP=1 保留现场"
OUT=$(run "$WORK/t11" KEEP_TMP=1 -- "$BASE/ok.bin"); RC=$?
KEPT=""
while IFS= read -r _line; do
  case $_line in TMPD_KEPT=*) KEPT=${_line#TMPD_KEPT=}; break;; esac
done <<EOF
$OUT
EOF
if [ $RC -eq 0 ] && [ -n "$KEPT" ] && [ -d "$KEPT" ]; then ok "临时目录被保留（$KEPT）"; rm -rf "$KEPT"; else bad "KEEP_TMP" "rc=$RC kept=$KEPT"; fi

echo "[12] 未知后缀不因冒烟失败"
OUT=$(run "$WORK/t12" SMOKE=1 -- "$BASE/ok.bin"); RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -qE 'smoke=(SKIP|ok)'; then ok "冒烟对 .bin 走 SKIP 不误报"; else bad "后缀冒烟" "rc=$RC"; printf '%s\n' "$OUT" | tail -3; fi

echo "----------------------------------------"
if [ $FAIL -eq 0 ]; then echo "TESTS_SH_OK: $PASS 项通过"; exit 0; fi
echo "TESTS_SH_FAILED: $PASS 通过 / $FAIL 失败"; exit 1