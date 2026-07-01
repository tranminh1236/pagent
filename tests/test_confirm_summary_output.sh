#!/usr/bin/env bash
# Behavioral tests cho confirm-gate SUMMARY OUTPUT (regression cho fix double-print):
#   _print_plan_summary + confirm_plan_gate phải in plan summary ra stderr trong MỌI
#   nhánh skip, đúng MỘT lần (không double-print web/non-tty).
#
# Scenario:
#   (1) PAGENT_NO_CONFIRM=1   → return 0, stderr CÓ summary, KHÔNG prompt [Enter/y]
#   (2) PAGENT_YES=1          → giống (1)
#   (3) non-tty + KHÔNG PAGENT_CONFIRM (stdin </dev/null) → return 0, stderr CÓ summary
#   (4) tty mock (pty qua `script`) → in summary đúng 1 lần (grep -c 'title' == 1)
#
# Hàm thật được EXTRACT thẳng từ ./pagent (không spawn claude) để bám sát implementation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAGENT="$SCRIPT_DIR/../pagent"
[[ -f "$PAGENT" ]] || { echo "FATAL: không tìm thấy pagent tại $PAGENT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: cần jq"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

# ─── extract một hàm bash từ pagent: từ dòng `name() {` đến dòng `}` đứng riêng ──────
extract_fn() {
  awk -v fn="$1" 'match($0, "^"fn"\\(\\)") {p=1} p{print} p&&/^}$/{exit}' "$PAGENT"
}

# ─── dựng file funcs: color/log helpers (hardcode, ổn định) + hàm thật extract ───────
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
FUNCS="$TMPDIR_T/funcs.sh"
mktmp() { mktemp "$TMPDIR_T/t.XXXXXX"; }

{
  # color helpers — giữ y hệt pagent (in escape, không phụ thuộc terminal)
  echo "c_dim()   { printf '\\033[90m%s\\033[0m' \"\$*\"; }"
  echo "c_cyan()  { printf '\\033[36m%s\\033[0m' \"\$*\"; }"
  echo "c_green() { printf '\\033[32m%s\\033[0m' \"\$*\"; }"
  echo "c_yellow(){ printf '\\033[33m%s\\033[0m' \"\$*\"; }"
  echo "c_red()   { printf '\\033[31m%s\\033[0m' \"\$*\"; }"
  echo "log()  { printf '%s %s\\n' \"\$(c_cyan '›')\" \"\$*\" >&2; }"
  echo "warn() { printf '%s %s\\n' \"\$(c_yellow '⚠')\" \"\$*\" >&2; }"
  # logic thật, extract theo tên (bám implementation)
  extract_fn _is_truthy
  extract_fn _print_plan_summary
  extract_fn confirm_plan_via_file
  extract_fn confirm_plan_gate
} >"$FUNCS"

# sanity: các hàm target phải được extract
for fn in _print_plan_summary confirm_plan_gate; do
  grep -q "^$fn()" "$FUNCS" && ok "extract $fn từ pagent" \
                            || fail "KHÔNG extract được $fn (line shift trong pagent?)"
done

# shellcheck disable=SC1090
source "$FUNCS"

# ─── plan_json mẫu: title/summary/coder_task/required_agents/risk/affected_paths +
#     flow_diagram ĐA DÒNG + clarifying_questions ──────────────────────────────────
PLAN='{"title":"Add confirm summary","summary":"In plan summary truoc khi chay pipeline","coder_task":"Sua confirm_plan_gate de in dung 1 lan","required_agents":["coder"],"risk":"low","affected_paths":["pagent"],"flow_diagram":"[start] -> orchestrator\n  -> coder\n  -> done","clarifying_questions":["Co can them edge case khong?"]}'

FLOW_FIRST='[start] -> orchestrator'

# ─── assertion helpers ───────────────────────────────────────────────────────────
has() { grep -qF -- "$2" "$1"; }   # $1=file $2=substr
assert_summary() {
  local f="$1" tag="$2"
  has "$f" "Add confirm summary"               && ok "$tag: stderr có title" \
                                               || fail "$tag: thiếu title"
  has "$f" "In plan summary truoc khi chay"    && ok "$tag: stderr có summary" \
                                               || fail "$tag: thiếu summary"
  has "$f" "Sua confirm_plan_gate de in dung"  && ok "$tag: stderr có coder_task" \
                                               || fail "$tag: thiếu coder_task"
  has "$f" "$FLOW_FIRST"                        && ok "$tag: stderr có dòng đầu flow_diagram" \
                                               || fail "$tag: thiếu dòng đầu flow_diagram"
}

# run gate trong subshell (cô lập `exit` nếu có), stdin </dev/null (non-tty), bắt stderr
run_gate() {
  local errf="$1"; shift
  ( "$@" confirm_plan_gate "$PLAN" ) </dev/null 2>"$errf" >/dev/null
  return $?
}

echo "=== Scenario (1): PAGENT_NO_CONFIRM=1 → skip gate, vẫn in summary ==="
ERR1="$(mktmp)"
( unset PAGENT_YES PAGENT_CONFIRM; export PAGENT_NO_CONFIRM=1
  confirm_plan_gate "$PLAN" ) </dev/null 2>"$ERR1" >/dev/null
RC=$?
[[ "$RC" -eq 0 ]] && ok "(1) return 0" || fail "(1) return phải =0 (got $RC)"
assert_summary "$ERR1" "(1)"
has "$ERR1" "[Enter/y]" && fail "(1) KHÔNG được có prompt [Enter/y]" \
                        || ok "(1) không có prompt [Enter/y]"

echo ""
echo "=== Scenario (2): PAGENT_YES=1 → giống (1) ==="
ERR2="$(mktmp)"
( unset PAGENT_NO_CONFIRM PAGENT_CONFIRM; export PAGENT_YES=1
  confirm_plan_gate "$PLAN" ) </dev/null 2>"$ERR2" >/dev/null
RC=$?
[[ "$RC" -eq 0 ]] && ok "(2) return 0" || fail "(2) return phải =0 (got $RC)"
assert_summary "$ERR2" "(2)"
has "$ERR2" "[Enter/y]" && fail "(2) KHÔNG được có prompt [Enter/y]" \
                        || ok "(2) không có prompt [Enter/y]"

echo ""
echo "=== Scenario (3): non-tty + KHÔNG PAGENT_CONFIRM (stdin </dev/null) → in summary ==="
ERR3="$(mktmp)"
( unset PAGENT_NO_CONFIRM PAGENT_YES PAGENT_CONFIRM
  confirm_plan_gate "$PLAN" ) </dev/null 2>"$ERR3" >/dev/null
RC=$?
[[ "$RC" -eq 0 ]] && ok "(3) return 0 (auto-run non-tty)" || fail "(3) return phải =0 (got $RC)"
assert_summary "$ERR3" "(3)"
has "$ERR3" "[Enter/y]" && fail "(3) KHÔNG được có prompt [Enter/y]" \
                        || ok "(3) không có prompt [Enter/y]"

echo ""
echo "=== Scenario (4): tty mock (pty) → summary in đúng 1 lần ==="
# Cần `script` cấp pty để [[ -t 0 ]] true + /dev/tty đọc được. CI không có pty → skip.
if ! command -v script >/dev/null 2>&1 || ! script -q /dev/null true </dev/null >/dev/null 2>&1; then
  skip "(4) tty mock — `script`/pty không khả dụng trong môi trường này"
else
  INNER="$(mktmp)"
  cat >"$INNER" <<EOF
source "$FUNCS"
PLAN='$PLAN'
unset PAGENT_NO_CONFIRM PAGENT_YES PAGENT_CONFIRM
confirm_plan_gate "\$PLAN"
EOF
  TS="$(mktmp)"
  # feed 'y\n' qua pty → reply=y → return 0 (không treo). Session (stdout+stderr) -> $TS.
  printf 'y\n' | script -q "$TS" bash "$INNER" >/dev/null 2>&1 || true
  if has "$TS" "Add confirm summary"; then
    CNT="$(grep -c 'title' "$TS" 2>/dev/null || echo 0)"
    [[ "$CNT" -eq 1 ]] && ok "(4) summary in đúng 1 lần (grep -c title == 1)" \
                       || fail "(4) summary phải in đúng 1 lần (grep -c title = $CNT)"
    has "$TS" "$FLOW_FIRST" && ok "(4) tty path có dòng đầu flow_diagram" \
                            || fail "(4) thiếu dòng đầu flow_diagram"
  else
    fail "(4) pty session không chứa summary (script không capture được stderr?)"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
