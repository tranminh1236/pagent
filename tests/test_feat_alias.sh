#!/usr/bin/env bash
# Tests for `feat` alias — verifies pagent feat == pagent feature (mode=feature)
# and that zsh completion exposes feat correctly.

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

assert_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if ! grep -qF -- "$pattern" "$file"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc — pattern should NOT be present: $pattern"
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
COMPLETION="./kit/completions/_pagent"

echo "=== feat alias — dispatch tests (pagent) ==="

# feat and feature must be in the same case branch
assert_grep "feat and feature share one case branch" "$PAGENT" 'feat\|feature\)'

# feat must dispatch to cmd_pipeline with mode=feature (not hotfix)
# The branch must contain 'feature' as the mode argument
feat_line=$(grep -n 'feat|feature' "$PAGENT" | head -1)
feat_linenum=$(echo "$feat_line" | cut -d: -f1)
if [[ -n "$feat_linenum" ]]; then
  context=$(sed -n "${feat_linenum}p" "$PAGENT")
  if echo "$context" | grep -q 'cmd_pipeline feature'; then
    echo "PASS: feat|feature branch calls cmd_pipeline feature (mode=feature)"
    ((PASS++))
  else
    echo "FAIL: feat|feature branch does not call cmd_pipeline feature"
    echo "      line $feat_linenum: $context"
    ((FAIL++))
  fi
fi

# fix/bug/hotfix must remain on their own separate branch (not merged with feat)
assert_grep "fix|bug|hotfix stay on own branch" "$PAGENT" 'fix\|bug\|hotfix\)'

# fix branch must still dispatch to hotfix mode
assert_grep "fix branch calls cmd_pipeline hotfix" "$PAGENT" 'cmd_pipeline hotfix'

echo ""
echo "=== feat alias — help text tests ==="

# help text must mention feat as alias for feature
assert_contains "help shows feat alias" "$PAGENT" "alias: feat"

# help must still have fix line
assert_contains "help still shows fix command" "$PAGENT" "pagent fix"

echo ""
echo "=== feat alias — completion tests (_pagent) ==="

# feat must appear in the top-level subcommand description list
assert_contains "completion: feat entry in top list" "$COMPLETION" "'feat:Build feature"

# feature must still appear in top list (not replaced by feat)
assert_contains "completion: feature entry still in top list" "$COMPLETION" "'feature:Build feature"

# feat must be in the case dispatch for arg-completion
assert_grep "completion: feat in case dispatch" "$COMPLETION" 'feat\|feature\|fix\|bug\|hotfix'

# The arg-completion case must cover -a, -s, and task args
assert_contains "completion: -a option still present" "$COMPLETION" "-a[chỉ định agent]"
assert_contains "completion: -s option still present" "$COMPLETION" "-s[chỉ định skill]"

# Sanity: workflow, report, gain completions not affected
assert_contains "completion: workflow entry unchanged" "$COMPLETION" "workflow)"
assert_contains "completion: report entry present" "$COMPLETION" "report)"
assert_contains "completion: gain entry present" "$COMPLETION" "gain)"

echo ""
echo "=== feat alias — regression: other subcommands unaffected ==="

# report subcommand still exists in dispatch
assert_grep "dispatch: report still present" "$PAGENT" '^\s*report\)'

# workflow subcommand still exists in dispatch
assert_grep "dispatch: workflow still present" "$PAGENT" '^\s*workflow\)'

# env subcommand still exists
assert_grep "dispatch: env still present" "$PAGENT" '^\s*env\)'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
