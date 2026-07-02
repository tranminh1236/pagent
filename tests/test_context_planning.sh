#!/usr/bin/env bash
# Tests cho context-planning + wiring `pagent knowledge` + cache brief.
# Style: static-assertion trên file (như test_chore_find_modes.sh / test_domain_knowledge.sh)
#        + inline behavior test cho hàm cache-key (như test_gating_behavior.sh).
# Không spawn claude.

set -uo pipefail
PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

assert_contains() {  # desc file pattern (fixed string)
  if grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1 — expected: $3"; fi
}
assert_grep() {      # desc file regex
  if grep -qE -- "$3" "$2"; then ok "$1"; else fail "$1 — expected regex: $3"; fi
}

cd "$(dirname "$0")/.." || exit 1
SKILL="kit/skills/context-planning.md"
PAGENT="pagent"
ORCH="kit/agents/orchestrator.md"

echo "=== context-planning.md — file + frontmatter ==="
if [[ -f "$SKILL" ]]; then ok "skill file exists"; else fail "skill file missing: $SKILL"; fi
assert_grep "name: context-planning" "$SKILL" '^name:[[:space:]]*context-planning'
assert_grep "model: claude-opus-4-8" "$SKILL" '^model:[[:space:]]*claude-opus-4-8'
assert_grep "allowed_tools has Read" "$SKILL" '^allowed_tools:.*Read'
assert_grep "allowed_tools has Grep" "$SKILL" '^allowed_tools:.*Grep'
assert_grep "allowed_tools has Glob" "$SKILL" '^allowed_tools:.*Glob'
# read-only: KHÔNG có Write trong allowed_tools
if awk -F: '/^allowed_tools:/{print; exit}' "$SKILL" | grep -q 'Write'; then
  fail "context-planning phải read-only — allowed_tools KHÔNG được có Write"
else
  ok "read-only: allowed_tools không có Write"
fi

echo ""
echo "=== context-planning.md — layered reading (knowledge→feature→bug→git diff) ==="
assert_contains "reads knowledge layer"        "$SKILL" "knowledge"
assert_contains "reads feature reports layer"  "$SKILL" "feature"
assert_contains "reads bug reports layer"      "$SKILL" "bug"
assert_contains "reads git diff layer"         "$SKILL" "git diff"
assert_contains "early-stop khi đủ context"    "$SKILL" "dừng sớm"

echo ""
echo "=== context-planning.md — output contract ==="
assert_contains "outputs Relevant Context Bundle" "$SKILL" "Relevant Context Bundle"
assert_contains "gợi ý subtask"                    "$SKILL" "subtask"

echo ""
echo "=== context-planning.md — input sections (khớp khối gọi pagent) ==="
assert_contains "input MODE"               "$SKILL" "## MODE"
assert_contains "input TASK"               "$SKILL" "## TASK"
assert_contains "input KNOWLEDGE_PATHS"    "$SKILL" "KNOWLEDGE_PATHS"
assert_contains "input FEATURE_REPORTS_DIR" "$SKILL" "FEATURE_REPORTS_DIR"
assert_contains "input BUG_REPORTS_DIR"    "$SKILL" "BUG_REPORTS_DIR"
assert_contains "graceful: thiếu knowledge vẫn chạy" "$SKILL" "graceful"

echo ""
echo "=== pagent — knowledge subcommand dispatch ==="
assert_grep "dispatch: knowledge branch" "$PAGENT" '^[[:space:]]*knowledge\)'
assert_contains "dispatch → cmd_knowledge" "$PAGENT" "cmd_knowledge"
assert_grep "cmd_knowledge defined" "$PAGENT" '^cmd_knowledge\(\)'
assert_grep "knowledge refresh action" "$PAGENT" 'refresh\)'
assert_grep "knowledge show action" "$PAGENT" 'show\)'

echo ""
echo "=== pagent — knowledge dispatches 3 skills ==="
assert_contains "dispatch workflow-knowledge" "$PAGENT" "call_agent workflow-knowledge"
assert_contains "dispatch domain-knowledge"   "$PAGENT" "call_agent domain-knowledge"
assert_contains "dispatch decision-log"       "$PAGENT" "call_agent decision-log"

echo ""
echo "=== pagent — knowledge file paths ==="
assert_contains "path workflow.md"   "$PAGENT" ".pagent/knowledge"
assert_contains "workflow.md target" "$PAGENT" "workflow.md"
assert_contains "domain.md target"   "$PAGENT" "domain.md"
assert_contains "decisions.md target" "$PAGENT" "decisions.md"

echo ""
echo "=== pagent — context-planning step [0] + CONTEXT_BRIEF injection ==="
assert_contains "call context-planning skill" "$PAGENT" "call_agent context-planning"
assert_grep "build_context_brief defined" "$PAGENT" '^build_context_brief\(\)'
assert_contains "injects ## CONTEXT_BRIEF vào orchestrator" "$PAGENT" "## CONTEXT_BRIEF"
# chỉ feature/hotfix chạy step [0]
assert_grep "step[0] chỉ feature/hotfix" "$PAGENT" 'mode.*==.*feature.*\|\|.*mode.*==.*hotfix'

echo ""
echo "=== pagent — cache brief keyed git+workflow+knowledge hash ==="
assert_grep "context_cache_key defined"      "$PAGENT" '^context_cache_key\(\)'
assert_grep "context_git_hash defined"       "$PAGENT" '^context_git_hash\(\)'
assert_grep "context_workflow_hash defined"  "$PAGENT" '^context_workflow_hash\(\)'
assert_grep "context_knowledge_hash defined" "$PAGENT" '^context_knowledge_hash\(\)'
assert_contains "cache key dùng git hash"       "$PAGENT" "context_git_hash"
assert_contains "cache key dùng workflow hash"  "$PAGENT" "context_workflow_hash"
assert_contains "cache key dùng knowledge hash" "$PAGENT" "context_knowledge_hash"

echo ""
echo "=== pagent — graceful degrade ==="
assert_grep "degrade khi context-planning fail (return 1 / bỏ qua)" "$PAGENT" 'context_brief=""|degrade|bỏ qua'

echo ""
echo "=== pagent — help mentions knowledge ==="
assert_contains "help: pagent knowledge" "$PAGENT" "pagent knowledge"

echo ""
echo "=== orchestrator.md — nhận khối CONTEXT_BRIEF ==="
assert_contains "orchestrator mô tả CONTEXT_BRIEF" "$ORCH" "## CONTEXT_BRIEF"

echo ""
echo "=== inline: cache-key behavior (git+workflow+knowledge → deterministic + invalidation) ==="
# Copy logic từ pagent (giữ khớp — như test_gating_behavior extract helper).
_SHA_BIN="$(command -v shasum || command -v sha1sum || command -v md5sum || echo cksum)"
_sha() { "$_SHA_BIN" 2>/dev/null | awk '{print $1}'; }
_hash_file() { [[ -f "$1" ]] && _sha <"$1" || echo none; }
context_git_hash() { ( cd "$T_SRC" && { git rev-parse HEAD 2>/dev/null; git diff 2>/dev/null; } ) | _sha; }
context_workflow_hash() { _hash_file "$T_REPORTS/agent-workflow.md"; }
context_knowledge_hash() {
  local k="$T_SRC/.pagent/knowledge"
  { _hash_file "$k/workflow.md"; _hash_file "$k/domain.md"; _hash_file "$k/decisions.md"; } | _sha
}
context_cache_key() {
  printf '%s\0%s\0%s\0%s\0%s' "$1" "$2" \
    "$(context_git_hash)" "$(context_workflow_hash)" "$(context_knowledge_hash)" | _sha
}

T_SRC="$(mktemp -d)"; T_REPORTS="$(mktemp -d)"
trap 'rm -rf "$T_SRC" "$T_REPORTS"' EXIT
( cd "$T_SRC" && git init -q && git config user.email t@t && git config user.name t \
  && echo hello >a.txt && git add -A && git commit -qm init )
mkdir -p "$T_SRC/.pagent/knowledge"
echo "wf-v1"  >"$T_SRC/.pagent/knowledge/workflow.md"
echo "dom-v1" >"$T_SRC/.pagent/knowledge/domain.md"
echo "wf-spec-v1" >"$T_REPORTS/agent-workflow.md"

K1="$(context_cache_key feature "task X")"
K1b="$(context_cache_key feature "task X")"
[[ "$K1" == "$K1b" ]] && ok "cùng input → cùng key (deterministic)" || fail "key phải deterministic"

K_task="$(context_cache_key feature "task Y")"
[[ "$K1" != "$K_task" ]] && ok "đổi task → đổi key" || fail "task khác phải cho key khác"

echo "dom-v2" >"$T_SRC/.pagent/knowledge/domain.md"
K_know="$(context_cache_key feature "task X")"
[[ "$K1" != "$K_know" ]] && ok "đổi knowledge → invalidate key" || fail "knowledge đổi phải invalidate"

echo "wf-spec-v2" >"$T_REPORTS/agent-workflow.md"
K_wf="$(context_cache_key feature "task X")"
[[ "$K_know" != "$K_wf" ]] && ok "đổi workflow spec → invalidate key" || fail "workflow đổi phải invalidate"

( cd "$T_SRC" && echo world >>a.txt )   # dirty working tree
K_git="$(context_cache_key feature "task X")"
[[ "$K_wf" != "$K_git" ]] && ok "đổi git working tree → invalidate key" || fail "git đổi phải invalidate"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
