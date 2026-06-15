#!/usr/bin/env bash
# Tests cho feature flow_diagram + report restructure (## Input / ## Output).
#
# Thay đổi được test (working tree):
#  - orchestrator.md: schema thêm field `flow_diagram` (ASCII đa dòng, JSON string),
#    mọi mode (feature/hotfix/chore/find) có bước "Xuất flow_diagram", chỉ thị LUÔN xuất.
#  - pagent write_report: parse flow_diagram qua extract_json|jq, render block
#    "Sơ đồ logic task" CHỈ khi flow non-empty (backward-compat); restructure
#    report thành ## Input / ## Output; nhánh find in thẳng reviewer.txt;
#    test_line tóm tắt 1 dòng pass/fail từ tester.txt.
#  - confirm_plan_gate: parse q_flow guarded `[[ -n "$q_flow" ]]`.
#
# Style: static-assert trên file thật + behavioral-sim replicate logic inline
# (giống test_root_cause_flow.sh / test_designer_integration.sh).

PASS=0
FAIL=0

assert_contains() { # desc file pattern  (fixed-string)
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; echo "      expected (fixed): $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}

assert_grep() { # desc file regex
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; echo "      expected (regex): $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}

assert_eq() { # desc actual expected
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; echo "      got     : [$actual]"; echo "      expected: [$expected]"; ((FAIL++))
  fi
}

assert_true() { # desc ; runs $2 as condition string already evaluated
  local desc="$1" cond="$2"
  if [[ "$cond" == "yes" ]]; then echo "PASS: $desc"; ((PASS++)); else echo "FAIL: $desc"; ((FAIL++)); fi
}

cd "$(dirname "$0")/.." || exit 1

PAGENT="./pagent"
ORCH="./kit/agents/orchestrator.md"

command -v jq      >/dev/null || { echo "SKIP: jq missing"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 0; }

#──────────────────────────────────────────────────────────────────
echo "=== orchestrator.md — schema khai báo flow_diagram ==="
#──────────────────────────────────────────────────────────────────
assert_contains "schema có field flow_diagram"        "$ORCH" '"flow_diagram"'
assert_grep     "chỉ thị LUÔN xuất flow_diagram"      "$ORCH" 'LUÔN xuất.*flow_diagram'
assert_grep     "flow_diagram là JSON string escape \\n" "$ORCH" 'flow_diagram.*(JSON string|escape|\\\\n)'
assert_grep     "cấm mermaid (ASCII terminal-renderable)" "$ORCH" 'KHÔNG mermaid'

echo ""
echo "=== orchestrator.md — mọi mode có bước Xuất flow_diagram ==="
# feature (khối quy trình đầu), hotfix, chore, find đều phải có 1 bước flow_diagram.
count_flow="$(grep -cE 'Xuất `flow_diagram`' "$ORCH")"
assert_true "≥4 bước 'Xuất flow_diagram' (feature/hotfix/chore/find)" \
  "$([[ "${count_flow:-0}" -ge 4 ]] && echo yes || echo no)"

echo ""
echo "=== pagent — write_report parse + render flow_diagram ==="
assert_grep "write_report parse flow_diagram qua extract_json|jq" \
  "$PAGENT" 'extract_json.*jq -r .*\.flow_diagram'
assert_contains "render block 'Sơ đồ logic task'" "$PAGENT" 'Sơ đồ logic task'
# Guard backward-compat: chỉ in block khi flow non-empty.
assert_grep "render guarded bằng [[ -n \$flow ]]" "$PAGENT" '\[\[ -n "\$flow" \]\]'

echo ""
echo "=== pagent — report restructure ## Input / ## Output ==="
assert_contains "report có section ## Input"  "$PAGENT" "printf '## Input"
assert_contains "report có section ## Output" "$PAGENT" "## Output"
# find mode: Output = nội dung reviewer.txt (deliverable), không affected/diff.
assert_grep "find mode in thẳng reviewer.txt" "$PAGENT" 'PAGENT_MODE.*==.*"find"'
assert_contains "non-find in Affected files"  "$PAGENT" "Affected files:"
assert_contains "non-find in Git diff stat"   "$PAGENT" "Git diff stat:"

echo ""
echo "=== pagent — confirm_plan_gate parse q_flow ==="
assert_grep "confirm_gate khai báo q_flow"            "$PAGENT" 'q_flow='
assert_grep "confirm_gate guard [[ -n \$q_flow ]]"    "$PAGENT" '\[\[ -n "\$q_flow" \]\]'

#──────────────────────────────────────────────────────────────────
echo ""
echo "=== BEHAVIORAL: extract flow_diagram từ plan JSON (mirror line 476) ==="
#──────────────────────────────────────────────────────────────────
# Plan có flow_diagram với \n escape → jq -r giải nén thành nhiều dòng.
plan_with_flow='{"title":"t","flow_diagram":"[task]\n  |\n  v\n[B1: locate]\n  |\n  v\n<test pass?>","required_agents":["coder"]}'
flow="$(printf '%s' "$plan_with_flow" | jq -r '.flow_diagram // ""' 2>/dev/null)"
# non-empty
assert_true "flow non-empty khi field có" "$([[ -n "$flow" ]] && echo yes || echo no)"
# multi-line: \n escape phải thành >1 dòng
nlines="$(printf '%s\n' "$flow" | wc -l | tr -d ' ')"
assert_true "flow đa dòng (>=5 dòng từ \\n escape)" \
  "$([[ "${nlines:-0}" -ge 5 ]] && echo yes || echo no)"
assert_true "flow chứa marker [B1: locate]" \
  "$(printf '%s' "$flow" | grep -qF '[B1: locate]' && echo yes || echo no)"

# Plan KHÔNG có flow_diagram → // "" fallback rỗng (backward-compat, không vỡ).
plan_no_flow='{"title":"t","required_agents":["coder"]}'
flow_empty="$(printf '%s' "$plan_no_flow" | jq -r '.flow_diagram // ""' 2>/dev/null)"
assert_eq "field vắng → flow rỗng (backward-compat)" "$flow_empty" ""

#──────────────────────────────────────────────────────────────────
echo ""
echo "=== BEHAVIORAL: render report (sim write_report Output branch) ==="
#──────────────────────────────────────────────────────────────────
# Replicate đúng logic phân nhánh write_report: find vs non-find + flow guard.
render_report() { # mode flow affected diffstat test_line reviewer
  local mode="$1" flow="$2" affected="$3" diffstat="$4" test_line="$5" reviewer="$6"
  printf '## Input\nTHE-TASK\n'
  if [[ -n "$flow" ]]; then
    printf '\n**Sơ đồ logic task:**\n```\n%s\n```\n' "$flow"
  fi
  printf '\n## Output\n'
  if [[ "$mode" == "find" ]]; then
    if [[ -n "$reviewer" ]]; then printf '%s\n' "$reviewer"; else printf '(reviewer không trả lời được)\n'; fi
  else
    printf '**Affected files:** %s\n\n' "${affected:-(none)}"
    printf '**Git diff stat:**\n```\n%s\n```\n' "$diffstat"
    [[ -n "$test_line" ]] && printf '\n**Test:** %s\n' "$test_line"
  fi
}

# Case A: hotfix có flow → có block Sơ đồ + Affected + Test, KHÔNG có reviewer answer.
rA="$(render_report hotfix "$flow" "pagent" "1 file changed" "5 passed, 1 failed" "")"
assert_true "A: chứa 'Sơ đồ logic task'" "$(grep -qF 'Sơ đồ logic task' <<<"$rA" && echo yes || echo no)"
assert_true "A: chứa Affected files"     "$(grep -qF 'Affected files:' <<<"$rA" && echo yes || echo no)"
assert_true "A: chứa Test line"          "$(grep -qF '**Test:** 5 passed, 1 failed' <<<"$rA" && echo yes || echo no)"

# Case B: hotfix KHÔNG flow → KHÔNG có block Sơ đồ (guard hoạt động).
rB="$(render_report hotfix "" "pagent" "1 file changed" "" "")"
assert_true "B: KHÔNG có 'Sơ đồ logic task' khi flow rỗng" \
  "$(grep -qF 'Sơ đồ logic task' <<<"$rB" && echo no || echo yes)"

# Case C: find → Output = reviewer answer, KHÔNG có Affected/Git diff stat.
rC="$(render_report find "" "" "" "" "ĐÂY LÀ CÂU TRẢ LỜI")"
assert_true "C: find in reviewer answer"          "$(grep -qF 'ĐÂY LÀ CÂU TRẢ LỜI' <<<"$rC" && echo yes || echo no)"
assert_true "C: find KHÔNG có 'Affected files'"   "$(grep -qF 'Affected files:' <<<"$rC" && echo no || echo yes)"
assert_true "C: find KHÔNG có 'Git diff stat'"    "$(grep -qF 'Git diff stat:' <<<"$rC" && echo no || echo yes)"

#──────────────────────────────────────────────────────────────────
echo ""
echo "=== BEHAVIORAL: test_line grep (mirror line 483) ==="
#──────────────────────────────────────────────────────────────────
extract_test_line() { # stdin tester.txt content
  grep -iE '[0-9]+ (passed|failed)|\b(PASS|FAIL)\b' | head -1 | sed -E 's/^[[:space:]]+//'
}
tl1="$(printf 'running tests\n5 passed, 1 failed\ndone\n' | extract_test_line)"
assert_eq "count line 'N passed, N failed'" "$tl1" "5 passed, 1 failed"

tl2="$(printf 'noise\n  PASS\nmore\n' | extract_test_line)"
assert_eq "standalone PASS token (leading ws stripped)" "$tl2" "PASS"

tl3="$(printf 'fails to load the page\neverything ok\n' | extract_test_line)"
assert_eq "prose 'fails to load' KHÔNG match" "$tl3" ""

#──────────────────────────────────────────────────────────────────
echo ""
echo "=== pagent parse OK ==="
#──────────────────────────────────────────────────────────────────
if bash -n "$PAGENT" 2>/tmp/pagent_parse_err; then
  echo "PASS: bash -n pagent clean"; ((PASS++))
else
  echo "FAIL: bash -n pagent error:"; cat /tmp/pagent_parse_err; ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
