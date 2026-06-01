#!/usr/bin/env bash
# Tests for root_cause_analysis hotfix flow
# Covers: reviewer ROOT_CAUSE_ANALYSIS block, pagent MODE pass-through,
# orchestrator synthesis gate, extract_json+jq chain, report section,
# DONE summary, feature-mode safety (no regression).

set -uo pipefail
PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" == *"$pattern"* ]]; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected to contain: |$pattern|"
    echo "      actual snippet: ${text:0:200}"
    ((FAIL++))
  fi
}

assert_file_contains() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc — pattern not found: $pattern"
    echo "      in file: $file"
    ((FAIL++))
  fi
}

# Inline extract_json (mirrors pagent exactly)
extract_json() {
  python3 -c '
import sys, re, json
t = sys.stdin.read()
try: json.loads(t); print(t); sys.exit(0)
except Exception: pass
s = re.sub(r"^```\w*\s*", "", t.strip(), flags=re.M)
s = re.sub(r"\s*```$", "", s, flags=re.M)
try: json.loads(s); print(s); sys.exit(0)
except Exception: pass
def fb(s):
    i = s.find("{")
    while i >= 0:
        d=0; ins=False; esc=False
        for j in range(i, len(s)):
            c = s[j]
            if esc: esc=False; continue
            if c=="\\": esc=True; continue
            if c==chr(34): ins=not ins; continue
            if ins: continue
            if c=="{": d+=1
            elif c=="}":
                d-=1
                if d==0: return s[i:j+1]
        i = s.find("{", i+1)
    return None
c = fb(t)
if c:
    try: json.loads(c); print(c); sys.exit(0)
    except Exception: pass
sys.exit(1)
'
}

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$(pwd)"
KIT_DIR="$REPO_DIR/kit"
PAGENT="$REPO_DIR/pagent"

# Temp dir for simulated run artefacts
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== root_cause_analysis hotfix flow tests ==="
echo ""

# ── 1. reviewer.md: ROOT_CAUSE_ANALYSIS block exists ────────────────────────
echo "--- 1. reviewer.md has ROOT_CAUSE_ANALYSIS block ---"
REVIEWER="$KIT_DIR/agents/reviewer.md"
assert_file_contains "reviewer.md has ROOT_CAUSE_ANALYSIS header" "## ROOT_CAUSE_ANALYSIS" "$REVIEWER"
assert_file_contains "reviewer.md has 'cause:' field" "- cause:" "$REVIEWER"
assert_file_contains "reviewer.md has 'suspect:' field" "- suspect:" "$REVIEWER"
assert_file_contains "reviewer.md has 'confidence:' field" "- confidence:" "$REVIEWER"
assert_file_contains "reviewer.md gates on hotfix mode" "hotfix" "$REVIEWER"

# ── 2. reviewer.md: ## MODE declared in input list ──────────────────────────
echo ""
echo "--- 2. reviewer.md input list includes MODE ---"
assert_file_contains "reviewer.md declares ## MODE input" "## MODE" "$REVIEWER"

# ── 3. orchestrator.md: synthesis step + root_cause_summary ─────────────────
echo ""
echo "--- 3. orchestrator.md synthesis step ---"
ORCH="$KIT_DIR/agents/orchestrator.md"
assert_file_contains "orchestrator.md mentions REVIEWER_OUTPUT" "REVIEWER_OUTPUT" "$ORCH"
assert_file_contains "orchestrator.md mentions TESTER_OUTPUT" "TESTER_OUTPUT" "$ORCH"
assert_file_contains "orchestrator.md has root_cause_summary field in schema" "root_cause_summary" "$ORCH"

# ── 4. hotfix.md: updated flow describes 5-step with orchestrator synthesis ─
echo ""
echo "--- 4. hotfix.md: describes orchestrator synthesis ---"
HOTFIX="$KIT_DIR/skills/hotfix.md"
assert_file_contains "hotfix.md mentions orchestrator (tổng hợp)" "orchestrator (tổng hợp)" "$HOTFIX"
assert_file_contains "hotfix.md mentions root_cause_summary" "root_cause_summary" "$HOTFIX"

# ── 5. pagent: reviewer call passes ## MODE ──────────────────────────────────
echo ""
echo "--- 5. pagent: ## MODE echoed before call_agent reviewer ---"
# Extract lines between the reviewer log and call_agent reviewer
REVIEWER_CALL="$(awk '/\[3.4\].*reviewer/,/call_agent reviewer/' "$PAGENT")"
assert_contains "pagent echoes '## MODE' to reviewer" '## MODE' "$REVIEWER_CALL"
assert_contains "pagent echoes \$mode variable to reviewer" '"$mode"' "$REVIEWER_CALL"

# ── 6. pagent: synthesis block gate (mode==hotfix && reviewer.txt non-empty) ─
echo ""
echo "--- 6. pagent: 4b synthesis block present and gated ---"
assert_file_contains "pagent has 4b synthesis block" "4b. Orchestrator" "$PAGENT"
assert_file_contains "pagent gates synthesis on mode=hotfix" '"hotfix" && -s' "$PAGENT"
assert_file_contains "pagent backs up plan to orchestrator.plan.txt" "orchestrator.plan.txt" "$PAGENT"
assert_file_contains "pagent restores plan after synthesis" 'khôi phục plan gốc' "$PAGENT"
assert_file_contains "pagent extracts root_cause_summary via jq" "root_cause_summary" "$PAGENT"
assert_file_contains "pagent writes root_cause.txt" "root_cause.txt" "$PAGENT"

# ── 7. pagent: DONE summary prints root cause ────────────────────────────────
echo ""
echo "--- 7. pagent: DONE summary references root_cause.txt ---"
DONE_BLOCK="$(awk '/═══ DONE ═══/,/report:/' "$PAGENT")"
assert_contains "DONE summary prints root cause line" "root cause:" "$DONE_BLOCK"
assert_contains "DONE summary reads root_cause.txt" "root_cause.txt" "$DONE_BLOCK"

# ── 8. pagent: write_report includes Root cause section ─────────────────────
echo ""
echo "--- 8. pagent: write_report has Root cause section ---"
REPORT_BLOCK="$(awk '/write_report\(\)/,/^}/' "$PAGENT")"
assert_contains "write_report checks for root_cause.txt" "root_cause.txt" "$REPORT_BLOCK"
assert_contains "write_report emits Root cause header" "Root cause (review + test" "$REPORT_BLOCK"

# ── 9. extract_json: root_cause_summary survives round-trip ─────────────────
echo ""
echo "--- 9. extract_json: JSON with root_cause_summary round-trips ---"
SAMPLE_JSON='{
  "title": "Fix null pointer in parser",
  "summary": "Guard null before deref.",
  "coder_task": "add nil check at parser.go:45",
  "reviewer_focus": "nil guard covers all call sites",
  "tester_task": "",
  "risk": "low",
  "affected_paths": ["parser.go"],
  "root_cause_summary": "Null dereference at parser.go:45 when input empty — confirmed by reviewer (high) + regression test pass."
}'
PARSED="$(echo "$SAMPLE_JSON" | extract_json 2>/dev/null)"
if jq -e '.root_cause_summary' <<<"$PARSED" >/dev/null 2>&1; then
  echo "PASS: extract_json output contains root_cause_summary key"
  ((PASS++))
else
  echo "FAIL: extract_json output missing root_cause_summary"
  ((FAIL++))
fi
if jq . <<<"$PARSED" >/dev/null 2>&1; then
  echo "PASS: extract_json output is valid JSON (jq parse)"
  ((PASS++))
else
  echo "FAIL: extract_json output not valid JSON"
  ((FAIL++))
fi
RC_VAL="$(jq -r '.root_cause_summary' <<<"$PARSED")"
assert_contains "root_cause_summary value preserved" "Null dereference" "$RC_VAL"

# Edge: JSON wrapped in ```json fence
TICK='`'; FENCE="${TICK}${TICK}${TICK}"
FENCED="${FENCE}json"$'\n'"$SAMPLE_JSON"$'\n'"${FENCE}"
PARSED_FENCED="$(echo "$FENCED" | extract_json 2>/dev/null)"
if jq -e '.root_cause_summary' <<<"$PARSED_FENCED" >/dev/null 2>&1; then
  echo "PASS: extract_json strips backtick fence, root_cause_summary intact"
  ((PASS++))
else
  echo "FAIL: extract_json failed on fenced JSON"
  ((FAIL++))
fi

# Edge: root_cause_summary absent → jq returns ""
PLAIN_JSON='{"title":"t","coder_task":"c","reviewer_focus":"r","tester_task":"","risk":"low","affected_paths":[]}'
PARSED_PLAIN="$(echo "$PLAIN_JSON" | extract_json 2>/dev/null)"
RC_MISSING="$(jq -r '.root_cause_summary // ""' <<<"$PARSED_PLAIN")"
assert_eq "root_cause_summary absent → empty string via // \"\"" "" "$RC_MISSING"

# ── 10. Simulate synthesis: root_cause.txt written from JSON ────────────────
echo ""
echo "--- 10. Simulate synthesis: root_cause.txt written ---"
AGG_JSON='{
  "title": "Fix off-by-one in loop",
  "coder_task": "change < to <= at loop.go:12",
  "reviewer_focus": "boundary check",
  "tester_task": "",
  "risk": "low",
  "affected_paths": ["loop.go"],
  "root_cause_summary": "Off-by-one: loop.go:12 used < instead of <=, reviewer high-confidence, regression test passed."
}'
# Reproduce pagent lines 495-502 exactly
agg_json="$(echo "$AGG_JSON" | extract_json 2>/dev/null || true)"
root_cause_summary="$(jq -r '.root_cause_summary // ""' <<<"$agg_json" 2>/dev/null || true)"
if [[ -n "$root_cause_summary" ]]; then
  printf '%s\n' "$root_cause_summary" >"$TMP_DIR/root_cause.txt"
fi

if [[ -s "$TMP_DIR/root_cause.txt" ]]; then
  echo "PASS: root_cause.txt created and non-empty"
  ((PASS++))
else
  echo "FAIL: root_cause.txt missing or empty"
  ((FAIL++))
fi
WRITTEN="$(cat "$TMP_DIR/root_cause.txt")"
assert_contains "root_cause.txt contains summary" "Off-by-one" "$WRITTEN"

# ── 11. Simulate report: Root cause section present ──────────────────────────
echo ""
echo "--- 11. Simulate report: Root cause section ---"
rootcause_f="$TMP_DIR/root_cause.txt"
REPORT_SECTION=""
if [[ -s "$rootcause_f" ]]; then
  REPORT_SECTION="$(printf '## Root cause (review + test, đã xác nhận)\n%s\n\n' "$(cat "$rootcause_f")")"
fi
assert_contains "report section has correct header" "Root cause (review + test, đã xác nhận)" "$REPORT_SECTION"
assert_contains "report section has root cause text" "Off-by-one" "$REPORT_SECTION"

# ── 12. Simulate report: no root_cause.txt → no section ─────────────────────
echo ""
echo "--- 12. Simulate report: no root_cause.txt → no Root cause section ---"
rootcause_f2="$TMP_DIR/nonexistent_root_cause.txt"
REPORT_SECTION2=""
if [[ -s "$rootcause_f2" ]]; then
  REPORT_SECTION2="$(printf '## Root cause (review + test, đã xác nhận)\n%s\n\n' "$(cat "$rootcause_f2")")"
fi
assert_eq "absent root_cause.txt → empty report section" "" "$REPORT_SECTION2"

# ── 13. Gate simulation: feature mode → synthesis NOT triggered ──────────────
echo ""
echo "--- 13. Gate: feature mode → synthesis skipped ---"
FAKE_REVIEWER="$TMP_DIR/reviewer_sim.txt"
printf 'APPROVED\n' >"$FAKE_REVIEWER"
mode="feature"; synthesis_ran=false
if [[ "$mode" == "hotfix" && -s "$FAKE_REVIEWER" ]]; then synthesis_ran=true; fi
assert_eq "feature mode: synthesis NOT triggered" "false" "$synthesis_ran"

# ── 14. Gate simulation: hotfix + reviewer.txt → synthesis triggered ─────────
echo ""
echo "--- 14. Gate: hotfix + reviewer.txt → synthesis triggered ---"
mode="hotfix"; synthesis_ran=false
if [[ "$mode" == "hotfix" && -s "$FAKE_REVIEWER" ]]; then synthesis_ran=true; fi
assert_eq "hotfix mode + reviewer.txt: synthesis triggered" "true" "$synthesis_ran"

# ── 15. Gate simulation: hotfix + empty reviewer.txt → synthesis skipped ─────
echo ""
echo "--- 15. Gate: hotfix + empty reviewer.txt → synthesis skipped ---"
EMPTY_REVIEWER="$TMP_DIR/reviewer_empty.txt"
touch "$EMPTY_REVIEWER"
mode="hotfix"; synthesis_ran=false
if [[ "$mode" == "hotfix" && -s "$EMPTY_REVIEWER" ]]; then synthesis_ran=true; fi
assert_eq "hotfix + empty reviewer.txt: synthesis NOT triggered" "false" "$synthesis_ran"

# ── 16. Simulate DONE summary: root cause printed ───────────────────────────
echo ""
echo "--- 16. Simulate DONE summary ---"
DONE_OUT="$(
  rootcause_f="$TMP_DIR/root_cause.txt"
  [[ -s "$rootcause_f" ]] && printf '  root cause: %s\n' "$(cat "$rootcause_f")"
)"
assert_contains "DONE summary prints 'root cause:' label" "root cause:" "$DONE_OUT"
assert_contains "DONE summary value contains summary text" "Off-by-one" "$DONE_OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
