#!/usr/bin/env bash
# Tests: parallel run isolation, spinner trap fix, with_lock fd scoping,
#        acquire_run_lock concurrent detection, JSONL integrity, task_id attribution.
# Covers: pagent:170-184 (spinner), kit/lib/lock.sh:13-18 (flock subshell).

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

cd "$(dirname "$0")/.." || exit 1

# ─────────────────────────────────────────────────────────
# 1. with_lock: command runs + mutex dir cleaned up (macOS mkdir path)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 1. with_lock basic: command runs, lockd cleaned up ==="

. kit/lib/lock.sh

LOCKBASE=$(mktemp -d)/lk
with_lock "$LOCKBASE" bash -c 'true'
if [[ $? -eq 0 ]]; then ok "with_lock executes command (exit 0)"; else fail "with_lock failed"; fi

if [[ ! -d "${LOCKBASE}.lockd" ]]; then
  ok "lockd removed after command completes"
else
  fail "lockd still present after command — not cleaned up"
fi

# ─────────────────────────────────────────────────────────
# 2. with_lock: fd 9 not open in caller after flock subshell (Linux path)
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 2. with_lock: fd 9 not leaked to calling process ==="

LOCKBASE2=$(mktemp -d)/lk2
with_lock "$LOCKBASE2" bash -c 'true'

if [[ -d /proc/$$/fd ]] && ls /proc/$$/fd/9 2>/dev/null; then
  fail "fd 9 is open in calling process after with_lock (flock subshell fix failed)"
else
  ok "fd 9 not open in calling process after with_lock"
fi

# ─────────────────────────────────────────────────────────
# 3. spinner fix: trap -p EXIT save/restore preserves outer trap
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 3. spinner trap fix: eval restore preserves outer EXIT trap ==="

# Simulate the exact save/restore idiom from pagent:173+183
outer_fn_called=false
outer_cleanup() { outer_fn_called=true; }
trap 'outer_cleanup' EXIT

# Save (pagent:173)
_old="$(trap -p EXIT)"

# Overwrite with spinner-style cleanup (pagent:174)
trap 'printf "\r" >&2' EXIT

# Restore with FIX (pagent:183): eval "${_old_exit_trap:-trap - EXIT}"
eval "${_old:-trap - EXIT}"

restored="$(trap -p EXIT)"
if [[ "$restored" == *"outer_cleanup"* ]]; then
  ok "eval restore: outer EXIT trap preserved (spinner fix correct)"
else
  fail "eval restore: outer EXIT trap lost — got: $restored"
fi

# Contrast: show pre-fix behavior (trap - EXIT wipes the trap)
trap 'outer_cleanup' EXIT
trap - EXIT
wiped="$(trap -p EXIT)"
if [[ -z "$wiped" ]]; then
  ok "pre-fix behavior confirmed: trap - EXIT clears trap entirely"
else
  fail "unexpected: trap - EXIT did not clear trap"
fi

trap - EXIT  # ensure clean state for remaining tests

# ─────────────────────────────────────────────────────────
# 4. acquire_run_lock: writes PID+task, warns on concurrent run
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 4. acquire_run_lock: PID+task_id written; concurrent-run warning ==="

# Inline the required pagent functions (avoid sourcing full script which has
# dependency checks and set -euo pipefail at global scope)
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
warn() { printf '%s %s\n' "$(c_yellow '⚠')" "$*" >&2; }

acquire_run_lock() {
  local lock="$PAGENT_REPORT_DIR/$PAGENT_PROJECT/.run.lock"
  mkdir -p "$(dirname "$lock")"
  if [[ -f "$lock" ]]; then
    local other_pid other_task
    read -r other_pid other_task <"$lock" 2>/dev/null || true
    if [[ -n "${other_pid:-}" ]] && kill -0 "$other_pid" 2>/dev/null; then
      warn "đang có run khác active trên project '$PAGENT_PROJECT' (pid=$other_pid task=${other_task:-?})"
      warn "  coder ghi file thật + git diff CÓ THỂ LẪN thay đổi của 2 task — cân nhắc đợi run kia xong"
    fi
  fi
  printf '%s %s\n' "$$" "$PAGENT_TASK_ID" >"$lock"
  PAGENT_RUN_LOCK="$lock"
  trap 'release_run_lock' EXIT
}

release_run_lock() {
  [[ -n "${PAGENT_RUN_LOCK:-}" && -f "${PAGENT_RUN_LOCK:-}" ]] || return 0
  local lp; read -r lp _ <"$PAGENT_RUN_LOCK" 2>/dev/null || true
  [[ "${lp:-}" == "$$" ]] && rm -f "$PAGENT_RUN_LOCK"
  return 0
}

TMP_RDIR=$(mktemp -d)
export PAGENT_REPORT_DIR="$TMP_RDIR" PAGENT_PROJECT="test-proj" PAGENT_TASK_ID="TASK-ALPHA"
PAGENT_RUN_LOCK=""

acquire_run_lock 2>/dev/null
lock_file="$PAGENT_REPORT_DIR/$PAGENT_PROJECT/.run.lock"
lock_content="$(<"$lock_file")"

if [[ "$lock_content" == *"$$"* ]]; then
  ok "run.lock contains own PID ($$)"
else
  fail "run.lock missing own PID — got: $lock_content"
fi

if [[ "$lock_content" == *"TASK-ALPHA"* ]]; then
  ok "run.lock contains TASK_ID (TASK-ALPHA)"
else
  fail "run.lock missing TASK_ID — got: $lock_content"
fi

# Simulate concurrent run: write a live PID ($$) so kill -0 succeeds
export PAGENT_TASK_ID="TASK-BETA"
printf '%s %s\n' "$$" "TASK-ALPHA" >"$lock_file"   # foreign run with live PID
warn_out=$(acquire_run_lock 2>&1)
if [[ "$warn_out" == *"đang có run khác"* ]]; then
  ok "concurrent run detected: warning emitted"
else
  fail "concurrent run NOT detected — warning missing. Output: $warn_out"
fi

# release should delete lock only if PID matches current $$
# (lock was last written by acquire_run_lock above with current $$)
release_run_lock
if [[ ! -f "$lock_file" ]]; then
  ok "release_run_lock: lock file deleted after release"
else
  fail "release_run_lock: lock file still present"
fi

trap - EXIT  # clear release_run_lock trap set by acquire_run_lock
rm -rf "$TMP_RDIR"

# ─────────────────────────────────────────────────────────
# 5. JSONL concurrent append: with_lock keeps every line valid JSON
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 5. tokens JSONL: 10 concurrent with_lock appends — all valid JSON ==="

TMPJSONL=$(mktemp)
LOCK_LIB_PATH="$(pwd)/kit/lib/lock.sh"

for i in {1..10}; do
  (
    . "$LOCK_LIB_PATH"
    _write() {
      printf '{"seq":%d,"pad":"%s"}\n' \
        "$i" "$(printf '%0.s-' {1..80})" >>"$TMPJSONL"
    }
    with_lock "$TMPJSONL" _write
  ) &
done
wait

line_count=$(wc -l <"$TMPJSONL" | tr -d ' ')
valid_count=$(jq -c '.' "$TMPJSONL" 2>/dev/null | wc -l | tr -d ' ')

if [[ "$line_count" -eq 10 ]]; then
  ok "10 lines in JSONL (no lost writes under concurrency)"
else
  fail "expected 10 lines, got $line_count (writes lost or merged)"
fi

if [[ "$valid_count" -eq 10 ]]; then
  ok "all 10 lines are valid JSON (no interleaved writes)"
else
  fail "expected 10 valid JSON lines, got $valid_count (interleave detected)"
fi

rm -f "$TMPJSONL"

# ─────────────────────────────────────────────────────────
# 6. Parallel RUN_DIR isolation: unique task_id → separate dirs, no overwrite
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 6. Parallel RUN_DIR: each run writes to its own directory ==="

TDIR=$(mktemp -d)
fake_run() {
  local tid="$1"
  local rd="$TDIR/runs/$tid"
  mkdir -p "$rd"
  sleep 0.03  # overlap window
  printf '%s\n' "coder:$tid" >"$rd/coder.txt"
  printf '%s\n' "report:$tid" >"$rd/report.md"
}
fake_run "TID-A" &
fake_run "TID-B" &
wait

ca=$(<"$TDIR/runs/TID-A/coder.txt")
cb=$(<"$TDIR/runs/TID-B/coder.txt")
ra=$(<"$TDIR/runs/TID-A/report.md")

if [[ "$ca" == "coder:TID-A" ]]; then
  ok "TID-A coder.txt has correct content"
else
  fail "TID-A coder.txt corrupted — got: $ca"
fi

if [[ "$cb" == "coder:TID-B" ]]; then
  ok "TID-B coder.txt has correct content"
else
  fail "TID-B coder.txt corrupted — got: $cb"
fi

if [[ "$ra" == "report:TID-A" ]]; then
  ok "TID-A report.md not overwritten by TID-B"
else
  fail "TID-A report.md overwritten — got: $ra"
fi

rm -rf "$TDIR"

# ─────────────────────────────────────────────────────────
# 7. JSONL task_id attribution: jq aggregation isolates per-task cost
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 7. JSONL task_id attribution: cost sums isolated per task ==="

TMPJSONL=$(mktemp)
printf '{"event":"end","task_id":"T1","input_tokens":100,"output_tokens":50,"cache_read":0,"cost_usd":0.010}\n' >>"$TMPJSONL"
printf '{"event":"end","task_id":"T2","input_tokens":200,"output_tokens":80,"cache_read":0,"cost_usd":0.020}\n' >>"$TMPJSONL"
printf '{"event":"end","task_id":"T1","input_tokens":30,"output_tokens":20,"cache_read":5,"cost_usd":0.005}\n' >>"$TMPJSONL"

t1_cost=$(jq -rs '[.[] | select(.task_id=="T1" and .event=="end")] | map(.cost_usd) | add' "$TMPJSONL")
t2_cost=$(jq -rs '[.[] | select(.task_id=="T2" and .event=="end")] | map(.cost_usd) | add' "$TMPJSONL")
t2_line_count=$(jq -rs '[.[] | select(.task_id=="T2" and .event=="end")] | length' "$TMPJSONL")

# Compare using awk (avoid bc dependency)
t1_ok=$(awk "BEGIN{printf (($t1_cost > 0.0149 && $t1_cost < 0.0151) ? \"yes\" : \"no\")}")
t2_ok=$(awk "BEGIN{printf (($t2_cost > 0.0199 && $t2_cost < 0.0201) ? \"yes\" : \"no\")}")

if [[ "$t1_ok" == "yes" ]]; then
  ok "T1 cost = $t1_cost (expected ~0.015)"
else
  fail "T1 cost = $t1_cost (expected ~0.015)"
fi

if [[ "$t2_ok" == "yes" ]]; then
  ok "T2 cost = $t2_cost (expected ~0.020)"
else
  fail "T2 cost = $t2_cost (expected ~0.020)"
fi

if [[ "$t2_line_count" -eq 1 ]]; then
  ok "T2 count = 1 (T1 entries not leaked into T2 filter)"
else
  fail "T2 filter returned $t2_line_count entries (expected 1)"
fi

rm -f "$TMPJSONL"

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
