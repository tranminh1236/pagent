#!/usr/bin/env bash
# Tests for kit/agents/coder.md — validates Coding Standards section addition

FILE="kit/agents/coder.md"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1" pattern="$2"
  if grep -qF "$pattern" "$FILE"; then
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

assert_section_order() {
  # Verify line number of $1 < line number of $2 < line number of $3
  local desc="$1" s1="$2" s2="$3" s3="$4"
  local l1 l2 l3
  l1=$(grep -n "$s1" "$FILE" | head -1 | cut -d: -f1)
  l2=$(grep -n "$s2" "$FILE" | head -1 | cut -d: -f1)
  l3=$(grep -n "$s3" "$FILE" | head -1 | cut -d: -f1)
  if [[ -n "$l1" && -n "$l2" && -n "$l3" && "$l1" -lt "$l2" && "$l2" -lt "$l3" ]]; then
    echo "PASS: $desc (lines $l1 < $l2 < $l3)"
    ((PASS++))
  else
    echo "FAIL: $desc (lines: '$l1' '$l2' '$l3' — expected ascending)"
    ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

echo "=== coder.md — Coding Standards verification ==="

# --- YAML frontmatter fields intact ---
assert_meta "name = coder" "name" "coder"
# Quy ước model (2026-07-09): kit/agents KHÔNG khai model — opencode+9router combo tự phân
# phối; claude backend fallback PAGENT_CLAUDE_MODEL. Nếu lỡ khai thì phải TÊN TRẦN, không
# phải provider/model (dạng đó vô nghĩa với claude → 404).
_m=$(awk -v k="model" '/^---$/{p++; next} p==1 && $1==k":"{sub("^[^:]+:[[:space:]]*",""); print; exit}' "$FILE")
if [[ -z "$_m" || "$_m" != */* ]]; then
  echo "PASS: coder không khai model (opencode combo) hoặc tên trần (got '${_m:-<unset>}')"; ((PASS++))
else
  echo "FAIL: nếu khai model phải là tên trần claude (không provider/model) — got '$_m'"; ((FAIL++))
fi
assert_meta "caveman = lite" "caveman" "lite"
assert_meta "mcp_servers = context7" "mcp_servers" "context7"

# --- allowed_tools unchanged ---
for tool in Read Write Edit Bash Grep Glob \
  mcp__plugin_context7_context7__resolve-library-id \
  mcp__plugin_context7_context7__query-docs; do
  assert_contains "allowed_tools still has: $tool" "$tool"
done

# --- Coding Standards section headings ---
assert_contains "main section heading present" "## Coding Standards (BẮT BUỘC)"
assert_contains "subsection: 1. Naming" "### 1. Naming"
assert_contains "subsection: 2. REST API" "### 2. REST API"
assert_contains "subsection: 3. Kiến trúc" "### 3. Kiến trúc"
assert_contains "subsection: 4. Readability" "### 4. Readability"

# --- Key content checks ---
assert_contains "Naming references source-summary.md" "source-summary.md"
assert_contains "snake_case for DB tables" "snake_case"
assert_contains "REST nouns plural" "số nhiều"
assert_contains "HTTP status codes mentioned" "200/201"
assert_contains "versioning via /v1/" "/v1/"
assert_contains "DDD terminology: entity" "entity"
assert_contains "Clean Architecture layers" "domain"
assert_contains "bounded context" "bounded context"
assert_contains "single responsibility rule" "1 nhiệm vụ"

# --- Section order: Nguyên tắc → Coding Standards → Output cuối ---
assert_section_order \
  "section order: Nguyên tắc < Coding Standards < Output cuối" \
  "## Nguyên tắc" \
  "## Coding Standards" \
  "## Output cuối"

# --- CHANGES block template still intact ---
assert_contains "CHANGES template present" "## CHANGES"
assert_contains "RATIONALE template present" "## RATIONALE"
assert_contains "ASSUMPTIONS template present" "## ASSUMPTIONS"
assert_contains "Leader Code reference intact" "Leader Code (reviewer) sẽ đọc"

# --- CODE_RULES compliance section (wording mới: Leader Code chưng luật MUST/SHOULD) ---
assert_contains "CODE_RULES section heading" "## Tuân thủ RULE của Leader Code (BẮT BUỘC)"
assert_contains "references ## CODE_RULES block" "## CODE_RULES"
assert_contains "MUST rule mandatory wording" "Luật \`MUST\` phải tuân"
assert_contains "SHOULD rule wording" "Luật \`SHOULD\` tuân trừ khi"
assert_contains "MUST violation → CHANGES_REQUESTED" "vi phạm 1 luật MUST"
assert_contains "no-CODE_RULES fallback to Coding Standards" "Không có khối \`## CODE_RULES\`"

# --- CHANGES_REQUESTED review-loop handling (wording mới) ---
assert_contains "verdict-loop section heading" "## Xử lý verdict CHANGES_REQUESTED"
assert_contains "reads PREVIOUS_REVIEW block" "## PREVIOUS_REVIEW"
assert_contains "reads VERDICT token" "## VERDICT"
assert_contains "FINDINGS as mandatory fix list" "## FINDINGS"
assert_contains "must fix all BLOCKING/MAJOR" "Sửa **HẾT** \`BLOCKING\` và \`MAJOR\`"
assert_contains "no regression rule" "KHÔNG regression"
assert_contains "re-emit CHANGES each round" "Xuất lại block \`## CHANGES\`"

# --- UNIT_TESTS template block (coder tự sinh test) ---
assert_contains "UNIT_TESTS section heading" "### 6. Unit test cho function tự sinh (BẮT BUỘC)"
assert_contains "UNIT_TESTS output block in template" "## UNIT_TESTS"
assert_contains "coder runs tests via Bash" "Chạy test thật bằng Bash"

# --- Section order: CODE_RULES → verdict-loop → Coding Standards ---
assert_section_order \
  "order: CODE_RULES < verdict-loop < Coding Standards" \
  "## Tuân thủ RULE của Leader Code" \
  "## Xử lý verdict CHANGES_REQUESTED" \
  "## Coding Standards"

# --- md_body starts with # Coder Role ---
body_first=$(awk 'BEGIN{p=0} /^---$/{p++; next} p>=2{print; exit}' "$FILE")
if [[ "$body_first" == "" ]]; then
  body_first=$(awk 'BEGIN{p=0} /^---$/{p++; next} p>=2 && /[^ ]/{print; exit}' "$FILE")
fi
if grep -qF "# Coder Role" "$FILE"; then
  echo "PASS: body contains # Coder Role heading"
  ((PASS++))
else
  echo "FAIL: # Coder Role heading missing from body"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
