#!/usr/bin/env bash
# Tests for orchestrator `required_agents` agent-selection gating.
# Static-assertion style (no claude spawn): verify schema/rules in orchestrator.md
# and the dispatch-gating logic in pagent.

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected pattern: $pattern"
    echo "      in file: $file"
    ((FAIL++))
  fi
}

assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected regex: $pattern"
    echo "      in file: $file"
    ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

PAGENT="./pagent"
ORCH="./kit/agents/orchestrator.md"

echo "=== orchestrator.md — schema + rules ==="

assert_contains "schema declares required_agents field" "$ORCH" '"required_agents"'
assert_grep    "rule: luôn có ít nhất coder"            "$ORCH" 'LUÔN có ít nhất .?coder'
assert_grep    "rule: reviewer mặc định nên có"          "$ORCH" 'reviewer.*mặc định'
assert_grep    "rule: tester chỉ khi cần test mới"       "$ORCH" 'tester.*chỉ.*khi cần'
assert_grep    "ví dụ: task API không cần designer"      "$ORCH" 'API.*không cần designer'
assert_grep    "rule: tester ngoài list → tester_task rỗng" "$ORCH" 'tester.*KHÔNG.*required_agents'

echo ""
echo "=== pagent — dispatch gating ==="

assert_grep "helper agent_enabled defined"        "$PAGENT" '^agent_enabled\(\)'
assert_grep "helper log_skip defined"             "$PAGENT" '^log_skip\(\)'
assert_grep "log_skip prefix is text \[skip\]"    "$PAGENT" "\[skip\]"
assert_grep "parses required_agents as array"     "$PAGENT" 'required_agents \| type == "array"'
assert_grep "coder forced into list"              "$PAGENT" 'coder \$_ra'
assert_grep "PAGENT_GATE backward-compat off"     "$PAGENT" 'PAGENT_GATE=0'
assert_contains "full-pipeline fallback log"      "$PAGENT" 'chạy full pipeline'

echo ""
echo "=== pagent — per-agent skip wiring ==="

assert_contains "designer gated by agent_enabled"  "$PAGENT" 'agent_enabled designer'
assert_contains "reviewer gated by agent_enabled"  "$PAGENT" 'agent_enabled reviewer'
assert_contains "tester gated by agent_enabled"    "$PAGENT" 'agent_enabled tester'
assert_contains "designer skip logged"             "$PAGENT" 'log_skip "designer'
assert_contains "reviewer skip logged"             "$PAGENT" 'log_skip "reviewer'
assert_contains "tester skip logged"               "$PAGENT" 'log_skip "tester'

echo ""
echo "=== pagent — coder always runs (loop integrity) ==="

# reviewer disabled → verdict SKIPPED, coder still runs one round
assert_contains "review-disabled path sets SKIPPED" "$PAGENT" 'verdict="SKIPPED"'
assert_contains "SKIPPED suppresses non-approve warn" "$PAGENT" '"$verdict" != "SKIPPED"'

echo ""
echo "=== pagent — syntax ==="
if bash -n "$PAGENT"; then
  echo "PASS: pagent parses (bash -n)"
  ((PASS++))
else
  echo "FAIL: pagent syntax error"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
