#!/usr/bin/env bash
# Smoke tests for Jira + GitLab task-reading MCP (pagent + kit/mcp + PAGENT_TASKS gate).
# Tests: JSON config validity, token env refs, orchestrator mcp_servers, gate logic, .env docs.

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; ((FAIL++)); fi
}
assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" == *"$pattern"* ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected to contain: $pattern"; echo "      actual: $text"; ((FAIL++)); fi
}
assert_file_contains() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc — pattern not found: $pattern"; echo "      in file: $file"; ((FAIL++)); fi
}
md_meta() {
  awk -v k="$2" '/^---$/{p++; next} p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }' "$1"
}

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$(pwd)"; KIT_DIR="$REPO_DIR/kit"

echo "=== Jira/GitLab task-MCP smoke tests ==="

# ── 1. jira.json + gitlab.json valid JSON + structure ───────────────────────
for spec in "jira|uvx|JIRA_URL,JIRA_API_TOKEN" "gitlab|npx|GITLAB_API_URL,GITLAB_PERSONAL_ACCESS_TOKEN"; do
  name="${spec%%|*}"; rest="${spec#*|}"; cmd="${rest%%|*}"; envs="${rest#*|}"
  f="$KIT_DIR/mcp/$name.json"
  echo "--- $name.json ---"
  if [[ -f "$f" ]] && jq . "$f" >/dev/null 2>&1; then
    echo "PASS: $name.json valid JSON"; ((PASS++))
  else echo "FAIL: $name.json missing/invalid ($f)"; ((FAIL++)); continue; fi
  assert_eq "$name: server key = $name" "$name" "$(jq -r ".mcpServers | keys[0]" "$f")"
  assert_eq "$name: transport = stdio" "stdio" "$(jq -r ".mcpServers.$name.type" "$f")"
  assert_eq "$name: command = $cmd" "$cmd" "$(jq -r ".mcpServers.$name.command" "$f")"
  IFS=',' read -ra want <<<"$envs"
  for e in "${want[@]}"; do
    assert_eq "$name: env $e tham chiếu \${$e}" "\${$e}" "$(jq -r ".mcpServers.$name.env.$e" "$f")"
  done
done

# ── 2. orchestrator khai jira + gitlab trong mcp_servers ────────────────────
echo "--- orchestrator mcp_servers ---"
OV="$(md_meta "$KIT_DIR/agents/orchestrator.md" mcp_servers)"
assert_contains "orchestrator mcp_servers có jira" "jira" "$OV"
assert_contains "orchestrator mcp_servers có gitlab" "gitlab" "$OV"

# ── 3. PAGENT_TASKS gate logic (mirror pagent) ──────────────────────────────
echo "--- PAGENT_TASKS gate ---"
simulate_gate() {  # $1=flag $2=server-name $3=mcp_servers $4=allowed
  local flag="$1" name="$2" mcp_servers_val="$3" allowed_val="$4"
  local cfg="$KIT_DIR/mcp/$name.json" out=""
  if [[ "${flag:-0}" == "1" || "${flag:-}" == "true" ]]; then
    if [[ "$mcp_servers_val" == *"$name"* || "$allowed_val" == *"$name"* ]]; then
      [[ -f "$cfg" ]] && out="$cfg"
    fi
  fi
  echo "$out"
}
assert_eq "PAGENT_TASKS unset → jira empty" "" "$(simulate_gate "" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=0 → jira empty" "" "$(simulate_gate "0" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=1 + mcp_servers jira → jira.json" \
  "$KIT_DIR/mcp/jira.json" "$(simulate_gate "1" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=true + mcp_servers gitlab → gitlab.json" \
  "$KIT_DIR/mcp/gitlab.json" "$(simulate_gate "true" gitlab "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=1 nhưng agent không khai gitlab → empty" \
  "" "$(simulate_gate "1" gitlab "context7" "Read Grep")"

# ── 4. pagent + .env docs ───────────────────────────────────────────────────
echo "--- pagent + .env docs ---"
assert_file_contains "pagent có PAGENT_TASKS gate" "PAGENT_TASKS" "$REPO_DIR/pagent"
assert_file_contains ".env.pagent.example ghi PAGENT_TASKS" "PAGENT_TASKS" "$REPO_DIR/.env.pagent.example"
assert_file_contains ".env.pagent.example ghi JIRA_API_TOKEN" "JIRA_API_TOKEN" "$REPO_DIR/.env.pagent.example"
assert_file_contains ".env.pagent.example ghi GITLAB_PERSONAL_ACCESS_TOKEN" "GITLAB_PERSONAL_ACCESS_TOKEN" "$REPO_DIR/.env.pagent.example"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
