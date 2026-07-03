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
REVIEWER="./kit/agents/reviewer.md"

echo "=== orchestrator.md — schema + rules ==="

assert_contains "schema declares required_agents field" "$ORCH" '"required_agents"'
assert_grep    "rule: luôn có ít nhất coder"            "$ORCH" 'LUÔN có ít nhất .?coder'
assert_grep    "rule: reviewer mặc định nên có"          "$ORCH" 'reviewer.*mặc định'
assert_grep    "rule: tester chỉ khi cần test mới"       "$ORCH" 'tester.*chỉ.*khi cần'
assert_grep    "ví dụ: task API dùng security"          "$ORCH" 'REST API.*security'
assert_grep    "ví dụ: task API không cần designer"      "$ORCH" 'không cần designer'
assert_grep    "rule: tester ngoài list → tester_task rỗng" "$ORCH" 'tester.*KHÔNG.*required_agents'

echo ""
echo "=== orchestrator.md — review layer (architecture/performance/security + Leader Code) ==="

# required_agents phải nêu đủ 4 giá trị tầng review là giá trị hợp lệ
assert_contains "valid value: architecture"          "$ORCH" '`architecture`'
assert_contains "valid value: performance"           "$ORCH" '`performance`'
assert_contains "valid value: security"              "$ORCH" '`security`'
assert_grep     "reviewer = Leader Code"             "$ORCH" 'reviewer.*Leader Code'
# ví dụ full AIDLC liệt kê đủ 4 auditor+reviewer trong required_agents
assert_contains "full-AIDLC example lists all auditors+reviewer" "$ORCH" \
  '"coder","architecture","performance","security","reviewer","tester"'
# rule cốt lõi: có auditor → BẮT BUỘC kèm reviewer (auditor không tự ra verdict)
assert_grep "rule: auditor bất kỳ → PHẢI kèm reviewer"  "$ORCH" 'PHẢI kèm .?reviewer'
assert_grep "rule: chỉ 1 auditor cũng phải kèm reviewer" "$ORCH" 'Chỉ 1 auditor cũng phải kèm .?reviewer'
assert_grep "rule: điều phối qua Leader Code"           "$ORCH" 'Leader Code điều phối'

echo ""
echo "=== orchestrator.md — Bước 0 guard code-touch (loại auditor cho task không sinh code) ==="

# (a) guard Bước 0 code-touch phải tồn tại và đứng trước Bước 1
assert_contains "Bước 0 — Guard code-touch header"      "$ORCH" 'Bước 0 — Guard code-touch'
assert_contains "guard đề cập thuật ngữ code-touch"     "$ORCH" 'code-touch'
assert_grep     "guard: task không sinh code → BỎ TOÀN BỘ auditor" "$ORCH" 'BỎ TOÀN BỘ auditor'
# carve-out: config chạm bề mặt rủi ro vẫn GIỮ auditor (bullet-2 thắng bullet-1)
assert_contains "carve-out config bullet-2 THẮNG bullet-1" "$ORCH" 'bullet-2 THẮNG bullet-1'

# (b) ví dụ 'quyết định logic pipeline' → KHÔNG auditor
assert_contains "ví dụ 'quyết định logic pipeline'"     "$ORCH" 'quyết định logic pipeline'
assert_grep     "ví dụ logic pipeline → [coder,reviewer] KHÔNG auditor" "$ORCH" \
  '\["coder","reviewer"\].*KHÔNG auditor'

# (c) invariant bất biến: có auditor → BẮT BUỘC reviewer; Bước 0 chỉ được LOẠI auditor
assert_grep     "invariant: có auditor → BẮT BUỘC kèm reviewer" "$ORCH" 'có auditor.*BẮT BUỘC.*kèm'
assert_grep     "Bước 0 chỉ có quyền LOẠI auditor, không bỏ ràng buộc reviewer" "$ORCH" \
  'Bước 0 chỉ có quyền'

echo ""
echo "=== reviewer.md — Leader Code quyền loại auditor thừa theo business (d) ==="

# (d) reviewer.md nêu quyền Leader Code loại auditor thừa theo business logic
assert_contains "reviewer.md: guard code-touch là QUYỀN & TRÁCH NHIỆM Leader Code" "$REVIEWER" \
  'guard code-touch — QUYỀN & TRÁCH NHIỆM của Leader Code'
assert_grep     "reviewer.md: được phép loại auditor thừa"   "$REVIEWER" 'loại auditor thừa'
# đồng bộ carve-out config với orchestrator: config không miễn auditor vô điều kiện
assert_contains "reviewer.md: config KHÔNG miễn auditor vô điều kiện" "$REVIEWER" \
  'Config KHÔNG được miễn auditor vô điều kiện'

echo ""
echo "=== orchestrator.md — audit_focus schema ==="

assert_contains "schema declares audit_focus field"  "$ORCH" '"audit_focus"'
assert_grep "audit_focus.architecture child"         "$ORCH" '"architecture": *"'
assert_grep "audit_focus.performance child"          "$ORCH" '"performance": *"'
assert_grep "audit_focus.security child"             "$ORCH" '"security": *"'
# audit_focus tùy chọn: chỉ field con cho auditor được chọn; không auditor → bỏ hẳn
assert_grep "rule: audit_focus chỉ field con auditor được chọn" "$ORCH" \
  'CHỈ xuất field con cho auditor nằm trong .?required_agents'
assert_grep "rule: không auditor nào → bỏ hẳn audit_focus" "$ORCH" \
  'Không có auditor nào.*BỎ HẲN .?audit_focus'

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
echo "=== orchestrator.md — devops/docs là giá trị required_agents hợp lệ ==="

# devops + docs là giá trị required_agents hợp lệ (roster mở rộng, cạnh 3 auditor)
assert_contains "valid value: devops"                "$ORCH" '`devops`'
assert_contains "valid value: docs"                  "$ORCH" '`docs`'
# devops/docs độc lập tầng auditor → KHÔNG bắt buộc kéo reviewer (khác luật auditor)
assert_grep "rule: devops/docs KHÔNG kéo theo reviewer" "$ORCH" 'KHÔNG kéo theo \`reviewer\`|devops./docs. KHÔNG'
# roster auditor cũ vẫn là giá trị hợp lệ (không bị devops/docs thay thế)
assert_contains "roster giữ architecture"            "$ORCH" '`architecture`'
assert_contains "roster giữ performance"             "$ORCH" '`performance`'
assert_contains "roster giữ security"                "$ORCH" '`security`'

echo ""
echo "=== pagent — devops/docs dispatch gated (mirror agent_enabled) ==="

assert_contains "devops gated by agent_enabled"      "$PAGENT" 'agent_enabled devops && want_devops=1'
assert_contains "docs gated by agent_enabled"        "$PAGENT" 'agent_enabled docs && want_docs=1'
assert_contains "devops skip logged"                 "$PAGENT" 'log_skip "devops'
assert_contains "docs skip logged"                   "$PAGENT" 'log_skip "docs'
assert_contains "devops spawn qua call_agent"        "$PAGENT" '| call_agent devops'
assert_contains "docs spawn qua call_agent"          "$PAGENT" '| call_agent docs'

echo ""
echo "=== pagent — thứ tự dispatch (devops SỚM, docs CUỐI) ==="

# devops phải chạy TRƯỚC vòng coder↔reviewer (hạ tầng/env sẵn cho coder)
dev_ln="$(grep -n '| call_agent devops' "$PAGENT" | head -1 | cut -d: -f1)"
coder_ln="$(grep -n 'Coder ↔ Reviewer loop' "$PAGENT" | head -1 | cut -d: -f1)"
if [[ -n "$dev_ln" && -n "$coder_ln" && "$dev_ln" -lt "$coder_ln" ]]; then
  echo "PASS: devops (line $dev_ln) dispatch TRƯỚC coder loop (line $coder_ln)"; ((PASS++))
else
  echo "FAIL: devops phải dispatch trước coder loop (devops=$dev_ln coder=$coder_ln)"; ((FAIL++))
fi
# docs phải chạy SAU tester và ngay TRƯỚC workflow-extractor (cuối pipeline)
docs_ln="$(grep -n '| call_agent docs' "$PAGENT" | head -1 | cut -d: -f1)"
tester_ln="$(grep -n '4\. Tester' "$PAGENT" | head -1 | cut -d: -f1)"
wf_ln="$(grep -n '5\. Agent orchestration workflow extractor' "$PAGENT" | head -1 | cut -d: -f1)"
if [[ -n "$docs_ln" && -n "$tester_ln" && "$docs_ln" -gt "$tester_ln" ]]; then
  echo "PASS: docs (line $docs_ln) dispatch SAU tester (line $tester_ln)"; ((PASS++))
else
  echo "FAIL: docs phải dispatch sau tester (docs=$docs_ln tester=$tester_ln)"; ((FAIL++))
fi
if [[ -n "$docs_ln" && -n "$wf_ln" && "$docs_ln" -lt "$wf_ln" ]]; then
  echo "PASS: docs (line $docs_ln) dispatch TRƯỚC workflow-extractor (line $wf_ln)"; ((PASS++))
else
  echo "FAIL: docs phải dispatch ngay trước workflow-extractor (docs=$docs_ln wf=$wf_ln)"; ((FAIL++))
fi

echo ""
echo "=== pagent — devops/docs KHÔNG làm hỏng gating auditor→reviewer ==="

# INVARIANT gating: vòng ENABLED_AUDITORS CHỈ gồm 3 auditor thật; devops/docs KHÔNG
# lọt vào list này → không kích luật 'có auditor ⇒ PHẢI kèm reviewer'.
assert_grep "ENABLED_AUDITORS chỉ lặp architecture/performance/security" "$PAGENT" \
  'for _aud in architecture performance security; do'
aud_loop="$(grep -n 'for _aud in ' "$PAGENT" | head -1)"
if echo "$aud_loop" | grep -qE '\b(devops|docs)\b'; then
  echo "FAIL: devops/docs lọt vào vòng ENABLED_AUDITORS → sai luật reviewer ($aud_loop)"; ((FAIL++))
else
  echo "PASS: devops/docs KHÔNG lọt vòng ENABLED_AUDITORS (auditor→reviewer nguyên vẹn)"; ((PASS++))
fi
# reviewer gating cũ vẫn nguyên (không bị devops/docs override)
assert_contains "reviewer vẫn gated bởi agent_enabled" "$PAGENT" 'agent_enabled reviewer'
assert_contains "tester vẫn gated bởi agent_enabled"   "$PAGENT" 'agent_enabled tester'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
