#!/usr/bin/env bash
# Tests for kit/skills/domain-knowledge.md — validates frontmatter + prompt contract.
# Static-assertion style (no claude spawn): verify schema/rules in the skill file.

FILE="kit/skills/domain-knowledge.md"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" pattern="$2"
  if grep -qF -- "$pattern" "$FILE"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected: $pattern"
    ((FAIL++))
  fi
}

assert_meta() {
  local desc="$1" key="$2" expected="$3"
  local val
  val=$(awk -v k="$2" '/^---$/{p++; next} p==1 && $1==k":"{sub("^[^:]+:[[:space:]]*",""); print; exit}' "$FILE")
  if [[ "$val" == "$expected" ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc — got '$val', expected '$expected'"
    ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

echo "=== domain-knowledge.md — file exists ==="
if [[ -f "$FILE" ]]; then
  echo "PASS: skill file exists"
  ((PASS++))
else
  echo "FAIL: skill file missing: $FILE"
  ((FAIL++))
fi

echo ""
echo "=== YAML frontmatter ==="
assert_meta "name = domain-knowledge" "name" "domain-knowledge"
assert_meta "model = claude-opus-4-8" "model" "claude-opus-4-8"
assert_contains "allowed_tools has Read"  "Read"
assert_contains "allowed_tools has Write" "Write"

echo ""
echo "=== Input contract (section names match pagent convention) ==="
assert_contains "reads SOURCE_SUMMARY_PATH"    "SOURCE_SUMMARY_PATH"
assert_contains "reads REPORT_HISTORY"         "REPORT_HISTORY"
assert_contains "reads EXISTING_KNOWLEDGE_PATH" "EXISTING_KNOWLEDGE_PATH"

echo ""
echo "=== Target document path + sections ==="
assert_contains "writes .pagent/knowledge/domain.md" ".pagent/knowledge/domain.md"
assert_contains "section: Overview"        "## Overview"
assert_contains "section: Concepts"        "## Concepts"
assert_contains "section: Business Rules"  "## Business Rules"
assert_contains "section: Glossary"        "## Glossary"
assert_contains "section: Constraints"     "## Constraints"
assert_contains "section: Open questions"  "## Open questions"

echo ""
echo "=== Idempotent-merge contract ==="
assert_contains "mentions idempotent"          "idempotent"
assert_contains "forbids infinite append"      "append"
assert_contains "no duplicate entries rule"    "trùng"
assert_contains "must create file even if input missing" "Thiếu input"

echo ""
echo "=== Scope guard: only writes the target file ==="
assert_contains "does not touch other files" "KHÔNG đụng"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
