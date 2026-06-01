#!/usr/bin/env bash
# Smoke tests for context7 MCP integration (pagent + kit/ agents/skills)
# Tests: JSON config validity, md_meta frontmatter parse, PAGENT_CONTEXT7 gate logic

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" == *"$pattern"* ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected to contain: $pattern"
    echo "      actual: $text"
    ((FAIL++))
  fi
}

assert_file_contains() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc — pattern not found: $pattern"
    echo "      in file: $file"
    ((FAIL++))
  fi
}

# Inline the md_meta awk logic (mirrors pagent exactly)
md_meta() {
  awk -v k="$2" '
    /^---$/{p++; next}
    p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }
  ' "$1"
}

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$(pwd)"
KIT_DIR="$REPO_DIR/kit"

echo "=== context7 integration smoke tests ==="
echo ""

# ── 1. context7.json valid JSON + structure ─────────────────────────────────
echo "--- 1. context7.json ---"
JSON_FILE="$KIT_DIR/mcp/context7.json"

if [[ -f "$JSON_FILE" ]]; then
  if jq . "$JSON_FILE" >/dev/null 2>&1; then
    echo "PASS: context7.json is valid JSON"
    ((PASS++))
  else
    echo "FAIL: context7.json is invalid JSON"
    ((FAIL++))
  fi
  SERVER_KEY="$(jq -r '.mcpServers | keys[0]' "$JSON_FILE")"
  assert_eq "server key = plugin_context7_context7" "plugin_context7_context7" "$SERVER_KEY"
  TRANSPORT="$(jq -r '.mcpServers.plugin_context7_context7.type' "$JSON_FILE")"
  assert_eq "transport type = http" "http" "$TRANSPORT"
  URL="$(jq -r '.mcpServers.plugin_context7_context7.url' "$JSON_FILE")"
  assert_contains "url contains mcp.context7.com" "mcp.context7.com" "$URL"
else
  echo "FAIL: context7.json not found at $JSON_FILE"
  ((FAIL++))
fi

# ── 2. md_meta: mcp_servers field present in all agents + research skill ────
echo ""
echo "--- 2. md_meta mcp_servers ---"
for agent in orchestrator coder reviewer; do
  val="$(md_meta "$KIT_DIR/agents/$agent.md" mcp_servers)"
  assert_contains "md_meta mcp_servers $agent.md contains 'context7'" "context7" "$val"
done
val="$(md_meta "$KIT_DIR/skills/research.md" mcp_servers)"
assert_contains "md_meta mcp_servers research.md contains 'context7'" "context7" "$val"

# ── 3. md_meta: allowed_tools parses space-style (orchestrator) ─────────────
echo ""
echo "--- 3. md_meta allowed_tools (space-style = orchestrator) ---"
ORCH_TOOLS="$(md_meta "$KIT_DIR/agents/orchestrator.md" allowed_tools)"
assert_contains "orchestrator allowed_tools: resolve-library-id" \
  "mcp__plugin_context7_context7__resolve-library-id" "$ORCH_TOOLS"
assert_contains "orchestrator allowed_tools: query-docs" \
  "mcp__plugin_context7_context7__query-docs" "$ORCH_TOOLS"

# ── 4. md_meta: allowed_tools parses comma-style (coder) ────────────────────
echo ""
echo "--- 4. md_meta allowed_tools (comma-style = coder) ---"
CODER_TOOLS="$(md_meta "$KIT_DIR/agents/coder.md" allowed_tools)"
assert_contains "coder allowed_tools: resolve-library-id" \
  "mcp__plugin_context7_context7__resolve-library-id" "$CODER_TOOLS"
assert_contains "coder allowed_tools: query-docs" \
  "mcp__plugin_context7_context7__query-docs" "$CODER_TOOLS"

# ── 5. md_meta: research skill allowed_tools ────────────────────────────────
echo ""
echo "--- 5. md_meta allowed_tools (research skill) ---"
RESEARCH_TOOLS="$(md_meta "$KIT_DIR/skills/research.md" allowed_tools)"
assert_contains "research allowed_tools: resolve-library-id" \
  "mcp__plugin_context7_context7__resolve-library-id" "$RESEARCH_TOOLS"
assert_contains "research allowed_tools: query-docs" \
  "mcp__plugin_context7_context7__query-docs" "$RESEARCH_TOOLS"

# ── 6. PAGENT_CONTEXT7 gate logic (mirrors pagent:214-218) ──────────────────
echo ""
echo "--- 6. PAGENT_CONTEXT7 gate ---"

# Simulate the exact gate from pagent
simulate_gate() {
  local pagent_context7="$1" mcp_servers_val="$2" allowed_val="$3"
  local config_file="$KIT_DIR/mcp/context7.json"
  local mcp_config=""
  if [[ "${pagent_context7:-0}" == "1" || "${pagent_context7:-}" == "true" ]]; then
    if [[ "$mcp_servers_val" == *context7* || "$allowed_val" == *context7* ]]; then
      [[ -f "$config_file" ]] && mcp_config="$config_file"
    fi
  fi
  echo "$mcp_config"
}

SERVERS="context7"
TOOLS_WITH_C7="mcp__plugin_context7_context7__resolve-library-id Read"
TOOLS_NO_C7="Read Write Edit Bash"

assert_eq "PAGENT_CONTEXT7=0 → mcp_config empty" \
  "" "$(simulate_gate "0" "$SERVERS" "$TOOLS_WITH_C7")"

assert_eq "PAGENT_CONTEXT7 unset → mcp_config empty" \
  "" "$(simulate_gate "" "$SERVERS" "$TOOLS_WITH_C7")"

assert_eq "PAGENT_CONTEXT7=1 + mcp_servers=context7 → mcp_config path set" \
  "$KIT_DIR/mcp/context7.json" "$(simulate_gate "1" "$SERVERS" "$TOOLS_WITH_C7")"

assert_eq "PAGENT_CONTEXT7=true → mcp_config path set" \
  "$KIT_DIR/mcp/context7.json" "$(simulate_gate "true" "$SERVERS" "$TOOLS_WITH_C7")"

assert_eq "PAGENT_CONTEXT7=1 + mcp_servers=context7 (allowed no c7) → mcp_config set via mcp_servers" \
  "$KIT_DIR/mcp/context7.json" "$(simulate_gate "1" "$SERVERS" "$TOOLS_NO_C7")"

assert_eq "PAGENT_CONTEXT7=1 but agent has no context7 → mcp_config empty" \
  "" "$(simulate_gate "1" "playwright" "$TOOLS_NO_C7")"

# ── 7. pagent: --mcp-config wired into args ─────────────────────────────────
echo ""
echo "--- 7. pagent --mcp-config arg ---"
assert_file_contains "pagent has --mcp-config in args" "--mcp-config" "$REPO_DIR/pagent"
# Must be gated (conditional), not unconditional
if grep -q 'mcp_config.*--mcp-config\|--mcp-config.*mcp_config\|\[\[ -n.*mcp_config.*\]\]' "$REPO_DIR/pagent"; then
  echo "PASS: --mcp-config is conditionally added"
  ((PASS++))
else
  echo "FAIL: --mcp-config is not gated on mcp_config variable"
  ((FAIL++))
fi

# ── 8. .env.pagent.example has PAGENT_CONTEXT7 ──────────────────────────────
echo ""
echo "--- 8. .env.pagent.example ---"
assert_file_contains ".env.pagent.example documents PAGENT_CONTEXT7" \
  "PAGENT_CONTEXT7" "$REPO_DIR/.env.pagent.example"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
