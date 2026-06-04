#!/usr/bin/env bash
# Tests cho 2 mode mới: chore và find (alias query).
# Verify: mode regex, dispatch, report subdir, pipeline conditionals,
# help/completion, skill files, orchestrator sections.

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
  if grep -qE -- "$pattern" "$file"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected regex: $pattern"
    echo "      in file: $file"
    ((FAIL++))
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  if [[ -f "$file" ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc — missing file: $file"
    ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

PAGENT="./pagent"
COMPLETION="./kit/completions/_pagent"
CHORE_SKILL="./kit/skills/chore.md"
FIND_SKILL="./kit/skills/find.md"
ORCH="./kit/agents/orchestrator.md"
REVIEWER="./kit/agents/reviewer.md"

echo "=== chore/find — mode regex ==="
# regex trong cmd_pipeline phải cho phép cả 4 mode
assert_grep "mode regex includes chore" "$PAGENT" 'feature\|hotfix\|chore\|find'

echo ""
echo "=== chore/find — dispatch ==="
assert_grep "dispatch: chore branch" "$PAGENT" '^[[:space:]]*chore\)'
assert_grep "dispatch: find|query branch" "$PAGENT" 'find\|query\)'
assert_grep "chore dispatches cmd_pipeline chore" "$PAGENT" 'cmd_pipeline chore'
assert_grep "find dispatches cmd_pipeline find" "$PAGENT" 'cmd_pipeline find'

echo ""
echo "=== chore/find — report subdir mapping ==="
assert_grep "report subdir: chores cho chore" "$PAGENT" 'chore\).*chores'
assert_grep "report subdir: findings cho find" "$PAGENT" 'find\).*findings'

echo ""
echo "=== chore/find — help text ==="
assert_contains "help shows pagent chore" "$PAGENT" "pagent chore"
assert_contains "help shows pagent find" "$PAGENT" "pagent find"
assert_contains "help mentions query alias" "$PAGENT" "query"
assert_contains "help PAGENT_MODE lists chore" "$PAGENT" "feature | hotfix | chore | find"
assert_contains "help OUTPUT TREE chores" "$PAGENT" "chores/"
assert_contains "help OUTPUT TREE findings" "$PAGENT" "findings/"

echo ""
echo "=== chore/find — completion ==="
assert_contains "completion: chore in top list" "$COMPLETION" "'chore:"
assert_contains "completion: find in top list" "$COMPLETION" "'find:"
assert_grep "completion: chore in case dispatch" "$COMPLETION" 'chore|find|query'

echo ""
echo "=== chore/find — skill files exist ==="
assert_file_exists "kit/skills/chore.md exists" "$CHORE_SKILL"
assert_file_exists "kit/skills/find.md exists" "$FIND_SKILL"

if [[ -f "$CHORE_SKILL" ]]; then
  assert_grep "chore.md name: chore" "$CHORE_SKILL" '^name:[[:space:]]*chore'
  assert_grep "chore.md report_dir: chores" "$CHORE_SKILL" '^report_dir:[[:space:]]*chores'
fi
if [[ -f "$FIND_SKILL" ]]; then
  assert_grep "find.md name: find" "$FIND_SKILL" '^name:[[:space:]]*find'
  assert_grep "find.md report_dir: findings" "$FIND_SKILL" '^report_dir:[[:space:]]*findings'
fi

echo ""
echo "=== chore/find — orchestrator.md sections ==="
assert_contains "orchestrator has Mode = chore section" "$ORCH" "## Mode = chore"
assert_contains "orchestrator has Mode = find section" "$ORCH" "## Mode = find"

echo ""
echo "=== chore/find — pipeline conditionals ==="
# find mode phải skip coder
assert_grep "find skips coder block" "$PAGENT" 'mode.*!=.*find|mode.*==.*find'
# find mode phải skip tester
# (kiểm tra reviewer nhận input khác khi mode=find)
assert_contains "find feeds QUESTION/SOURCE_SUMMARY vào reviewer" "$PAGENT" "QUESTION"

echo ""
echo "=== find — reviewer.md handles find mode ==="
# reviewer.md PHẢI có nhánh xử lý mode=find: KHÔNG xuất VERDICT, trả lời bằng văn bản
assert_grep "reviewer.md mentions find mode handling" "$REVIEWER" 'MODE.*find|mode.*find|=.*find|Mode = find'
assert_contains "reviewer.md instructs to answer question in find mode" "$REVIEWER" "QUESTION"

echo ""
echo "=== chore/find — coder không bị force-add vào required_agents khi find ==="
# pagent KHÔNG được ép coder vào required_agents khi mode=find (cosmetic correctness)
assert_contains "coder force-add skipped khi mode=find" "$PAGENT" "find: read-only, không spawn coder"

echo ""
echo "=== find — review_enabled log_skip guarded ==="
# log_skip về 'coder chạy 1 vòng' chỉ áp dụng cho mode != find
assert_grep "review_enabled gated by mode != find" "$PAGENT" 'mode.*!=.*find.*agent_enabled reviewer|mode != "find".*agent_enabled'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
