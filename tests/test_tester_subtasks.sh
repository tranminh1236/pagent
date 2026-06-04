#!/usr/bin/env bash
# Tests for parallel tester fan-out via `tester_subtasks`.
# Style: static-assertion on orchestrator.md / tester.md / pagent (no claude spawn),
# plus a behavioral simulation of the tester fan-out accumulation in pagent.

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then ok "$desc"; else
    echo "FAIL: $desc"; echo "      expected pattern: $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}

assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then ok "$desc"; else
    echo "FAIL: $desc"; echo "      expected regex: $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

PAGENT="./pagent"
ORCH="./kit/agents/orchestrator.md"
TESTER="./kit/agents/tester.md"

# ─────────────────────────────────────────────────────────
# 1. orchestrator.md schema declares tester_subtasks field
# ─────────────────────────────────────────────────────────
echo ""
echo "=== 1. orchestrator.md — schema declares tester_subtasks ==="

assert_contains "schema has tester_subtasks key" "$ORCH" '"tester_subtasks"'

echo ""
echo "=== 2. orchestrator.md — tester_subtasks explained as optional w/ fallback ==="

# explanation block: optional, only when ≥2 independent test parts (2-4), keep tester_task fallback
assert_grep "tester_subtasks marked optional (tùy chọn)" "$ORCH" 'tester_subtasks.*[Tt]ùy chọn'
assert_grep "tester_subtasks keeps tester_task fallback"  "$ORCH" 'tester_subtasks.*([Gg]iữ|fallback)|[Gg]iữ.*tester_task'
# the tester_subtasks explanation paragraph (3 lines after its heading) states a 2–4 count
if grep -A3 'tester_subtasks` là \*\*tùy chọn' "$ORCH" | grep -qE '2.?4 cái'; then
  ok "tester_subtasks 2-4 range mentioned in its explanation"
else
  fail "tester_subtasks 2-4 range NOT found in its explanation paragraph"
fi

echo ""
echo "=== 3. orchestrator.md — Phân rã song song: priority rule + tester guards ==="

# new rule: prioritize parallel subagent for BOTH coder AND tester to speed up
assert_grep "rule ƯU TIÊN parallel for coder AND tester" "$ORCH" 'ƯU TIÊN.*song song|song song.*(coder.*tester|tester.*coder)'
assert_grep "rule mentions both coder and tester"        "$ORCH" 'coder.*tester|tester.*coder'
# 3 mandatory guards retained
assert_grep "guard: độc lập retained"                    "$ORCH" '[Đđ]ộc lập'
assert_grep "guard: không phụ thuộc thứ tự retained"     "$ORCH" '[Kk]hông phụ thuộc thứ tự'
assert_grep "guard: affected_paths không giao nhau"      "$ORCH" 'affected_paths.*không giao|không giao.*affected_paths|KHÔNG giao nhau'
# fallback to single task when unsure
assert_grep "fallback 1 task đơn khi không chắc"         "$ORCH" '[Kk]hông chắc.*(1|một).*(coder|tester|task)|fallback.*1'
# tester_subtasks shape described in the section: {id, tester_task, affected_paths}
assert_contains "tester_subtasks shape: id"              "$ORCH" 'tester_subtasks'
assert_grep "tester_subtasks object has tester_task+affected_paths" "$ORCH" 'id.*tester_task.*affected_paths'

echo ""
echo "=== 4. pagent — detects tester_subtasks (jq array length>0) ==="

assert_grep "detects tester_subtasks type==array & length>0" "$PAGENT" '\.tester_subtasks \| type == "array".*\.tester_subtasks \| length > 0'
assert_grep "n_tester_subtasks counter assigned"            "$PAGENT" 'n_tester_subtasks=.*jq -r .\.tester_subtasks \| length|n_tester_subtasks=0'

echo ""
echo "=== 5. pagent — tester fan-out accumulation + single-tester fallback ==="

assert_grep "fan-out branch guarded by n_tester_subtasks > 1" "$PAGENT" 'n_tester_subtasks > 1'
assert_grep "per-subtask jq extracts tester_subtasks[i].tester_task" "$PAGENT" 'tester_subtasks\[\$[a-z_]+\]\.tester_task'
assert_grep "per-subtask jq extracts affected_paths"         "$PAGENT" 'tester_subtasks\[\$[a-z_]+\]\.affected_paths'
assert_grep "accumulates into a tmp file (tester.tmp)"       "$PAGENT" 'tester\.tmp'
assert_grep "appends per-subtask output (>>)"                "$PAGENT" '>>"?\$(tmp_tester|\{?PAGENT_RUN_DIR\}?/tester\.tmp)'
assert_grep "copies tmp into tester.txt once"                "$PAGENT" 'cp .*tester\.tmp.*tester\.txt|cp "\$tmp_tester" .*tester\.txt'
assert_grep "spawns call_agent tester inside fan-out"        "$PAGENT" 'call_agent tester'
# backward-compat: single-tester branch still present
assert_grep "single-tester branch preserved (TESTER_TASK)"   "$PAGENT" 'TESTER_TASK'

echo ""
echo "=== 6. pagent — syntax (bash -n) ==="
if bash -n "$PAGENT"; then ok "pagent parses (bash -n)"; else fail "pagent syntax error"; fi

echo ""
echo "=== 7. behavioral — fan-out accumulates (append+cp) without losing subtasks ==="

# call_agent ALWAYS overwrites tester.txt (.result side-effect). The fan-out must
# accumulate into a tmp via >> then cp once — else only the LAST subtask survives.
SIMDIR=$(mktemp -d)
RUN_DIR="$SIMDIR"
# stub mirroring call_agent's side-effect: overwrite tester.txt, echo result to stdout
stub_call_agent() { local r="result-for-$1"; printf '%s\n' "$r" >"$RUN_DIR/tester.txt"; printf '%s\n' "$r"; }

n_tester_subtasks=3
tmp_tester="$RUN_DIR/tester.tmp"
: >"$tmp_tester"
for (( ti=0; ti<n_tester_subtasks; ti++ )); do
  tsub_id="tsub$((ti+1))"
  out="$(stub_call_agent "$tsub_id")"
  { printf '### Subtask %s\n\n' "$tsub_id"; printf '%s\n\n' "$out"; } >>"$tmp_tester"
done
cp "$tmp_tester" "$RUN_DIR/tester.txt"

acc="$(<"$RUN_DIR/tester.txt")"
miss=0
for id in tsub1 tsub2 tsub3; do
  [[ "$acc" == *"result-for-$id"* ]] || { miss=1; echo "      missing: result-for-$id"; }
done
if (( miss == 0 )); then
  ok "all 3 subtask outputs accumulated into tester.txt (no overwrite loss)"
else
  fail "fan-out lost subtask output (overwrite hazard not handled)"
fi
# contrast: prove the hazard is real — naive overwrite keeps only the last
naive="$(<"$RUN_DIR/tester.txt")"   # already the cp'd accumulation
last_only="$(stub_call_agent tsub3 >/dev/null; cat "$RUN_DIR/tester.txt")"
if [[ "$last_only" == *"result-for-tsub3"* && "$last_only" != *"result-for-tsub1"* ]]; then
  ok "hazard confirmed: bare call_agent overwrite keeps only last subtask"
else
  fail "hazard simulation unexpected"
fi
rm -rf "$SIMDIR"

echo ""
echo "=== 8. tester.md — per-subtask scope note ==="

assert_grep "tester.md mentions subtask spawn"           "$TESTER" 'subtask'
assert_grep "tester.md mentions affected_paths scope"    "$TESTER" 'affected_paths|AFFECTED_PATHS'
assert_grep "tester.md: only test within assigned scope" "$TESTER" '(CHỈ|[Cc]hỉ) test.*phạm vi|phạm vi.*được giao'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
