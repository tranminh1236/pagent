#!/usr/bin/env bash
# Regression: find mode must SYNTHESIZE the plan JSON in bash, never parse the
# orchestrator's output as a plan.
#
# Bug (be-zalo-service runs 2026-07-06): in mode=find the orchestrator answers the
# QUESTION in prose (curl examples / explanation) instead of emitting a plan JSON —
# because a find task IS a question and the model (via opencode/9router, where the
# frontmatter model is ignored) jumps straight to answering like the reviewer.
# extract_json's brace fallback then grabs the FIRST `{…}` in that prose — e.g. a
# curl `-d '{…}'` request body — a valid object with NO `.title` → the `jq -e '.title'`
# gate fails → the plan card shows "(orchestrator JSON parse fail)". Happened on every
# find question.
#
# Fix: in find mode pagent builds the plan JSON deterministically (title/reviewer_focus
# from the task, required_agents=["reviewer"], empty coder/tester) and does NOT parse the
# orchestrator prose as a plan. The prose stays in orchestrator.txt as reviewer context.

PASS=0
FAIL=0

cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

echo "=== find plan synthesis — repro of the parse-fail trigger ==="

# The exact prose shape that fooled extract_json: a curl example whose `-d '{…}'` body
# is the first balanced object in the text. extract_json returns THAT object → no .title.
prose_out="$(cat <<'EOF'
`POST /v2/notifications-batch` — batch ZNS.

```bash
curl -X POST http://localhost:3000/v2/notifications-batch \
  -d '{ "oa_id": "OA", "type": "ZNS", "recipients": [ { "phone": "0901234567" } ] }'
```
EOF
)"

# Mirror extract_json's behavior via the same jq gate pagent uses (jq -e '.title').
# We can't call the in-script python here, but the point is: the first embedded object
# has no title. Demonstrate the gate would fire on a titleless object.
titleless='{ "oa_id": "OA", "type": "ZNS", "recipients": [] }'
if jq -e '.title' <<<"$titleless" >/dev/null 2>&1; then
  echo "FAIL: titleless curl body unexpectedly passed the .title gate"
  ((FAIL++))
else
  echo "PASS: an embedded curl body has no .title → would trip the old parse-fail path"
  ((PASS++))
fi

echo ""
echo "=== find plan synthesis — synthesized plan is valid ==="

# The synthesized plan pagent now builds in find mode.
synth() {
  local task="$1"
  jq -n --arg task "$task" '{
    title: ("Find: " + ($task | .[0:70])),
    summary: "find — reviewer đọc source trả lời câu hỏi",
    coder_task: "",
    reviewer_focus: $task,
    tester_task: "",
    risk: "low",
    required_agents: ["reviewer"],
    affected_paths: []
  }'
}

plan="$(synth 'xuất nguyên curl để tích hợp')"

if jq -e '.title' <<<"$plan" >/dev/null 2>&1; then
  echo "PASS: synthesized find plan has a .title (no parse-fail card)"
  ((PASS++))
else
  echo "FAIL: synthesized find plan missing .title"
  ((FAIL++))
fi

if [[ "$(jq -rc '.required_agents' <<<"$plan")" == '["reviewer"]' ]]; then
  echo "PASS: required_agents = [reviewer] (find gates to reviewer only)"
  ((PASS++))
else
  echo "FAIL: required_agents not [reviewer]: $(jq -rc '.required_agents' <<<"$plan")"
  ((FAIL++))
fi

if [[ -z "$(jq -r '.coder_task' <<<"$plan")" && -z "$(jq -r '.tester_task' <<<"$plan")" ]]; then
  echo "PASS: coder_task and tester_task empty (find spawns no coder/tester)"
  ((PASS++))
else
  echo "FAIL: coder_task/tester_task not empty in find plan"
  ((FAIL++))
fi

echo ""
echo "=== find plan synthesis — static guard in pagent ==="

# The find branch must synthesize BEFORE the generic extract_json/parse path, so the
# prose is never parsed as a plan in find mode.
if grep -qE 'elif \[\[ "\$mode" == "find" \]\]; then' "$PAGENT" \
   && awk '/elif \[\[ "\$mode" == "find" \]\]; then/{f=1} f&&/required_agents: \["reviewer"\]/{print; exit}' "$PAGENT" | grep -q reviewer; then
  echo "PASS: pagent has a find-mode branch that synthesizes required_agents=[reviewer]"
  ((PASS++))
else
  echo "FAIL: no find-mode synthesis branch found in pagent"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
