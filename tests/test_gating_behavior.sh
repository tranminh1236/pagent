#!/usr/bin/env bash
# Behavioral tests for required_agents gating:
#   (a) plan có required_agents=[coder,reviewer] → tester bị skip
#   (b) plan thiếu field required_agents       → full pipeline (PAGENT_GATE=0)
#   (c) JSON lỗi                               → fallback an toàn (PAGENT_GATE=0)
#
# Tất cả test chạy inline không spawn claude — giả lập logic gating từ pagent.

set -uo pipefail

PASS=0; FAIL=0

ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# ─── helpers được extract thẳng từ pagent (lines 85-90) ───────────────────────
# Giữ nguyên logic, chỉ bỏ c_yellow (color) để test không phụ thuộc terminal.
agent_enabled() {
  [[ "${PAGENT_GATE:-0}" == "1" ]] || return 0
  [[ " ${PAGENT_REQUIRED_AGENTS:-} " == *" $1 "* ]]
}

log_skip() { printf '[skip] %s\n' "$*" >&2; }

# ─── simulate_plan_parse: chạy đúng logic từ pagent lines 501-512 ─────────────
simulate_plan_parse() {
  local plan_json="$1"
  if jq -e '.required_agents | type == "array"' <<<"$plan_json" >/dev/null 2>&1; then
    local _ra; _ra="$(jq -r '.required_agents[]' <<<"$plan_json" 2>/dev/null | tr '\n' ' ')"
    [[ " $_ra " == *" coder "* ]] || _ra="coder $_ra"
    export PAGENT_GATE=1
    export PAGENT_REQUIRED_AGENTS=" $_ra "
  else
    export PAGENT_GATE=0
    export PAGENT_REQUIRED_AGENTS=""
  fi
}

echo "=== Scenario (a): required_agents=[coder,reviewer] → tester KHÔNG chạy ==="

PLAN_A='{"title":"t","summary":"s","required_agents":["coder","reviewer"],"coder_task":"c","reviewer_focus":"r","tester_task":"","risk":"low","affected_paths":[]}'
simulate_plan_parse "$PLAN_A"

[[ "$PAGENT_GATE" == "1" ]]         && ok  "PAGENT_GATE=1 khi array hợp lệ" \
                                    || fail "PAGENT_GATE phải =1"

[[ "$PAGENT_REQUIRED_AGENTS" == *" coder "* ]]    && ok  "coder có trong list"  \
                                                  || fail "coder phải có"

[[ "$PAGENT_REQUIRED_AGENTS" == *" reviewer "* ]] && ok  "reviewer có trong list" \
                                                  || fail "reviewer phải có"

agent_enabled tester                && fail "tester phải bị gate (không trong list)" \
                                    || ok  "tester bị skip đúng"

agent_enabled coder                 && ok  "coder luôn enabled" \
                                    || fail "coder phải enabled"

agent_enabled reviewer              && ok  "reviewer enabled" \
                                    || fail "reviewer phải enabled"

# simulate tester-gate logic (pagent lines 599-616)
run_tester=0
if [[ "${PAGENT_GATE}" == "1" ]]; then
  agent_enabled tester && run_tester=1
fi
[[ "$run_tester" -eq 0 ]] && ok "run_tester=0 → tester không spawn" \
                           || fail "run_tester phải =0 khi tester ngoài list"

echo ""
echo "=== Scenario (a2): required_agents=[coder,reviewer,tester] → tester chạy ==="

PLAN_A2='{"title":"t","summary":"s","required_agents":["coder","reviewer","tester"],"coder_task":"c","reviewer_focus":"r","tester_task":"verify endpoints","risk":"medium","affected_paths":[]}'
simulate_plan_parse "$PLAN_A2"

run_tester=0
if [[ "${PAGENT_GATE}" == "1" ]]; then
  agent_enabled tester && run_tester=1
fi
[[ "$run_tester" -eq 1 ]] && ok "run_tester=1 → tester spawn khi trong list" \
                           || fail "tester phải spawn khi trong list"

echo ""
echo "=== Scenario (a3): coder bị quên trong list → tự động ép vào ==="

PLAN_A3='{"title":"t","summary":"s","required_agents":["reviewer"],"coder_task":"c","reviewer_focus":"r","tester_task":"","risk":"low","affected_paths":[]}'
simulate_plan_parse "$PLAN_A3"

[[ "$PAGENT_REQUIRED_AGENTS" == *" coder "* ]] && ok "coder tự được ép vào dù plan quên" \
                                               || fail "coder phải được ép"

echo ""
echo "=== Scenario (b): plan thiếu field required_agents → full pipeline ==="

PLAN_B='{"title":"t","summary":"s","coder_task":"c","reviewer_focus":"r","tester_task":"verify","risk":"low","affected_paths":[]}'
simulate_plan_parse "$PLAN_B"

[[ "$PAGENT_GATE" == "0" ]]     && ok  "PAGENT_GATE=0 khi thiếu field" \
                                || fail "PAGENT_GATE phải =0"

[[ "$PAGENT_REQUIRED_AGENTS" == "" ]] && ok  "PAGENT_REQUIRED_AGENTS rỗng" \
                                       || fail "PAGENT_REQUIRED_AGENTS phải rỗng"

# Khi GATE=0, mọi agent đều enabled (backward-compat)
agent_enabled tester    && ok  "tester enabled (full pipeline)"  || fail "tester phải enabled"
agent_enabled designer  && ok  "designer enabled (full pipeline)" || fail "designer phải enabled"
agent_enabled reviewer  && ok  "reviewer enabled (full pipeline)" || fail "reviewer phải enabled"

echo ""
echo "=== Scenario (c): JSON lỗi → fallback an toàn (PAGENT_GATE=0) ==="

PLAN_C='{"title":"t", "required_agents": INVALID_JSON }'
simulate_plan_parse "$PLAN_C"

[[ "$PAGENT_GATE" == "0" ]]     && ok  "JSON lỗi → PAGENT_GATE=0 (fallback)" \
                                || fail "JSON lỗi phải fallback PAGENT_GATE=0"

agent_enabled tester    && ok  "tester enabled dù JSON lỗi (an toàn)" \
                         || fail "tester phải enabled khi fallback"
agent_enabled coder     && ok  "coder enabled dù JSON lỗi" \
                         || fail "coder phải enabled"

echo ""
echo "=== Scenario (c2): required_agents là string thay vì array → fallback ==="

PLAN_C2='{"title":"t","required_agents":"coder,reviewer","coder_task":"c"}'
simulate_plan_parse "$PLAN_C2"

[[ "$PAGENT_GATE" == "0" ]]     && ok  "required_agents string → PAGENT_GATE=0 (array check)" \
                                || fail "string không phải array → phải fallback"

echo ""
echo "=== Scenario (c3): required_agents mảng rỗng → gate bật nhưng chỉ coder ==="

PLAN_C3='{"title":"t","summary":"s","required_agents":[],"coder_task":"c","reviewer_focus":"r","tester_task":"","risk":"low","affected_paths":[]}'
simulate_plan_parse "$PLAN_C3"

[[ "$PAGENT_GATE" == "1" ]]                              && ok "PAGENT_GATE=1 với mảng rỗng" \
                                                         || fail "mảng rỗng vẫn là array hợp lệ"
[[ "$PAGENT_REQUIRED_AGENTS" == *" coder "* ]]           && ok "coder ép vào khi mảng rỗng" \
                                                         || fail "coder phải được ép"
agent_enabled tester                                     && fail "tester phải bị skip" \
                                                         || ok  "tester bị skip (không trong mảng rỗng + coder ép)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
