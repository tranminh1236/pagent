#!/usr/bin/env bash
# Dry-run tests: designer agent frontmatter parse, MCP config building,
# write_report designer section, and designer JSON schema smoke test.
# Does NOT call Claude — all tests are offline/unit.

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

cd "$(dirname "$0")/.." || exit 1

# ─────────────────────────────────────────────────────────────
# Shared helpers (same awk as pagent)
# ─────────────────────────────────────────────────────────────
md_meta() {
  awk -v k="$2" '
    /^---$/{p++; next}
    p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }
  ' "$1"
}

DESIGNER_MD="kit/agents/designer.md"

# ─────────────────────────────────────────────────────────────
# 1. Frontmatter: mcp_servers = figma,canvas
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 1. designer.md frontmatter parse ==="

val=$(md_meta "$DESIGNER_MD" mcp_servers)
if [[ "$val" == "figma,canvas" ]]; then
  ok "mcp_servers = figma,canvas"
else
  fail "mcp_servers expected 'figma,canvas', got '$val'"
fi

val=$(md_meta "$DESIGNER_MD" system_prompt_mode)
if [[ "$val" == "replace" ]]; then
  ok "system_prompt_mode = replace"
else
  fail "system_prompt_mode expected 'replace', got '$val'"
fi

val=$(md_meta "$DESIGNER_MD" allowed_tools)
if echo "$val" | grep -q "mcp__figma" && echo "$val" | grep -q "mcp__canvas"; then
  ok "allowed_tools contains mcp__figma and mcp__canvas"
else
  fail "allowed_tools missing mcp__figma or mcp__canvas: '$val'"
fi

val=$(md_meta "$DESIGNER_MD" disallowed_tools)
if echo "$val" | grep -q "Write" && echo "$val" | grep -q "Bash"; then
  ok "disallowed_tools contains Write and Bash (read-only enforcement)"
else
  fail "disallowed_tools missing Write or Bash: '$val'"
fi

# ─────────────────────────────────────────────────────────────
# 2. MCP config building: figma + canvas when PAGENT_DESIGN=1
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 2. call_agent MCP config building — PAGENT_DESIGN=1 ==="

_build_mcp_configs() {
  local mcp_servers="$1" allowed="$2"
  local mcp_configs=()

  if [[ "${PAGENT_CONTEXT7:-0}" == "1" || "${PAGENT_CONTEXT7:-}" == "true" ]]; then
    if [[ "$mcp_servers" == *context7* || "$allowed" == *context7* ]]; then
      [[ -f "kit/mcp/context7.json" ]] && mcp_configs+=("kit/mcp/context7.json")
    fi
  fi
  if [[ "${PAGENT_DESIGN:-0}" == "1" || "${PAGENT_DESIGN:-}" == "true" ]]; then
    if [[ "$mcp_servers" == *figma* || "$allowed" == *figma* ]]; then
      [[ -f "kit/mcp/figma.json" ]] && mcp_configs+=("kit/mcp/figma.json")
    fi
    if [[ "$mcp_servers" == *canvas* || "$allowed" == *canvas* ]]; then
      [[ -f "kit/mcp/canvas.json" ]] && mcp_configs+=("kit/mcp/canvas.json")
    fi
  fi
  echo "${mcp_configs[*]:-}"
}

# Test: PAGENT_DESIGN=1, designer servers figma,canvas
PAGENT_DESIGN=1 PAGENT_CONTEXT7=0
export PAGENT_DESIGN PAGENT_CONTEXT7

mcp_servers=$(md_meta "$DESIGNER_MD" mcp_servers)
allowed=$(md_meta "$DESIGNER_MD" allowed_tools)

result=$(_build_mcp_configs "$mcp_servers" "$allowed")
if echo "$result" | grep -q "figma.json"; then
  ok "figma.json loaded when PAGENT_DESIGN=1 and mcp_servers contains figma"
else
  fail "figma.json NOT loaded (result: '$result')"
fi
if echo "$result" | grep -q "canvas.json"; then
  ok "canvas.json loaded when PAGENT_DESIGN=1 and mcp_servers contains canvas"
else
  fail "canvas.json NOT loaded (result: '$result')"
fi

# ─────────────────────────────────────────────────────────────
# 3. MCP config building: context7 still correct when PAGENT_CONTEXT7=1
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 3. call_agent MCP config — context7 (PAGENT_DESIGN=0, PAGENT_CONTEXT7=1) ==="

PAGENT_DESIGN=0 PAGENT_CONTEXT7=1
export PAGENT_DESIGN PAGENT_CONTEXT7

# context7 agent declares mcp_servers context7
CODER_MCP_SERVERS=$(md_meta "kit/agents/coder.md" mcp_servers 2>/dev/null || true)
CODER_ALLOWED=$(md_meta "kit/agents/coder.md" allowed_tools 2>/dev/null || true)

result_c7=$(_build_mcp_configs "context7" "mcp__context7__resolve-library-id mcp__context7__get-library-docs")
if [[ -f "kit/mcp/context7.json" ]]; then
  if echo "$result_c7" | grep -q "context7.json"; then
    ok "context7.json loaded when PAGENT_CONTEXT7=1 and mcp_servers=context7"
  else
    fail "context7.json NOT loaded (result: '$result_c7')"
  fi
else
  ok "context7.json file absent — gate logic skips correctly (file check guards it)"
fi

# figma/canvas must NOT appear when PAGENT_DESIGN=0
if echo "$result_c7" | grep -q "figma.json"; then
  fail "figma.json leaked into context7-only config (PAGENT_DESIGN=0)"
else
  ok "figma.json not loaded when PAGENT_DESIGN=0 (correct isolation)"
fi

# ─────────────────────────────────────────────────────────────
# 4. write_report emits "## Design spec (designer)" only when designer.txt exists
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 4. write_report designer section ==="

TMP_RUN=$(mktemp -d)
TMP_REPORT="$TMP_RUN/report.md"

SAMPLE_SPEC='{
  "title": "Test UI spec",
  "summary": "Minimal spec for test",
  "platform": "web",
  "references": ["apple-hig"],
  "design_tokens": {"color": [], "spacing": [], "typography": []},
  "components": [],
  "layout": {"structure": "header+body", "grid": "12-col", "breakpoints": ["mobile"], "thumb_zone": "bottom"},
  "accessibility": {"min_touch_target": "44pt", "contrast": "WCAG AA", "dynamic_type": true, "notes": []},
  "coder_notes": "use tokens"
}'

# Write mock run files
echo "$SAMPLE_SPEC" >"$TMP_RUN/designer.txt"
echo "orchestrator plan" >"$TMP_RUN/orchestrator.txt"
echo "coder output" >"$TMP_RUN/coder.txt"
echo "APPROVED" >"$TMP_RUN/reviewer.txt"

# Minimal write_report simulation (same logic as pagent write_report, offline)
{
  printf '# %s\n\n' "Test Report"
  if [[ -s "$TMP_RUN/designer.txt" ]]; then
    printf '\n## Design spec (designer)\n'
    cat "$TMP_RUN/designer.txt"
  fi
  printf '\n## Code changes (coder)\n'
  cat "$TMP_RUN/coder.txt"
} >"$TMP_REPORT"

if grep -q "## Design spec (designer)" "$TMP_REPORT"; then
  ok "report contains '## Design spec (designer)' section"
else
  fail "report missing '## Design spec (designer)' section"
fi
if grep -q "Test UI spec" "$TMP_REPORT"; then
  ok "report body contains designer spec title"
else
  fail "report body missing designer spec content"
fi

# Test: no designer.txt → section absent
rm "$TMP_RUN/designer.txt"
{
  printf '# %s\n\n' "Test Report No Designer"
  if [[ -s "$TMP_RUN/designer.txt" ]]; then
    printf '\n## Design spec (designer)\n'
    cat "$TMP_RUN/designer.txt"
  fi
  printf '\n## Code changes (coder)\n'
  cat "$TMP_RUN/coder.txt"
} >"$TMP_REPORT"

if ! grep -q "## Design spec (designer)" "$TMP_REPORT"; then
  ok "report omits designer section when no designer.txt (non-UI task)"
else
  fail "report unexpectedly contains designer section without designer.txt"
fi

rm -rf "$TMP_RUN"

# ─────────────────────────────────────────────────────────────
# 5. UI keyword gate: designer triggers on UI keywords
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 5. UI keyword heuristic gate ==="

_ui_keyword_match() {
  printf '%s\n%s\n%s' "$1" "$2" "$3" \
    | grep -qiE 'ui|giao diện|screen|màn hình|component|layout|button|form|page|frontend|design|css|style|màu|theme|icon|responsive'
}

if _ui_keyword_match "Add login form" "Build form with button and CSS" "src/ui/login.tsx"; then
  ok "UI task triggers designer (form/button/css/ui keywords)"
else
  fail "UI task did NOT trigger designer"
fi

if ! _ui_keyword_match "Fix database migration" "Update SQL query" "src/db/migrate.sql"; then
  ok "Non-UI task skips designer (no UI keywords)"
else
  fail "Non-UI task incorrectly triggers designer"
fi

if _ui_keyword_match "thiết kế giao diện màn hình" "" ""; then
  ok "Vietnamese UI keywords trigger designer (giao diện, màn hình)"
else
  fail "Vietnamese UI keywords did NOT trigger designer"
fi

# ─────────────────────────────────────────────────────────────
# 6. Smoke test: designer JSON output schema validates with jq
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 6. Designer JSON schema smoke test (jq) ==="

FULL_SPEC='{
  "title": "Mobile Login Screen",
  "summary": "Grab-style login screen following Apple HIG touch targets and WCAG AA contrast.",
  "platform": "ios",
  "references": ["apple-hig", "grab"],
  "design_tokens": {
    "color": [
      {"name": "primary", "value": "#00B14F", "usage": "CTA button", "contrast": "AA on white"},
      {"name": "surface", "value": "#FFFFFF", "usage": "page background", "contrast": "n/a"}
    ],
    "spacing": [
      {"name": "sm", "value": "8px"},
      {"name": "md", "value": "16px"}
    ],
    "typography": [
      {"name": "title", "font": "SF Pro", "size": "20pt", "weight": 600, "line_height": "28pt", "dynamic_type": "title3"}
    ]
  },
  "components": [
    {
      "name": "PrimaryButton",
      "states": ["default", "pressed", "disabled", "loading"],
      "tokens": ["color.primary", "spacing.md"],
      "min_touch_target": "44pt"
    }
  ],
  "layout": {
    "structure": "logo → input group → CTA button → social login",
    "grid": "4-col 16px gutter",
    "breakpoints": ["mobile"],
    "thumb_zone": "CTA button in bottom third, thumb-reachable"
  },
  "accessibility": {
    "min_touch_target": "44pt",
    "contrast": "WCAG AA",
    "dynamic_type": true,
    "notes": ["all inputs have visible labels", "CTA has role=button"]
  },
  "coder_notes": "use design tokens instead of hardcoded hex; min touch target 44pt on all interactive elements"
}'

# Required top-level keys
for key in title summary platform references design_tokens components layout accessibility coder_notes; do
  if jq -e ".$key" <<<"$FULL_SPEC" >/dev/null 2>&1; then
    ok "JSON has required key: $key"
  else
    fail "JSON missing required key: $key"
  fi
done

# design_tokens sub-keys
for sub in color spacing typography; do
  if jq -e ".design_tokens.$sub | type == \"array\"" <<<"$FULL_SPEC" >/dev/null 2>&1; then
    ok "design_tokens.$sub is array"
  else
    fail "design_tokens.$sub missing or not array"
  fi
done

# color token has required fields
if jq -e '.design_tokens.color[0] | has("name") and has("value") and has("usage") and has("contrast")' <<<"$FULL_SPEC" >/dev/null 2>&1; then
  ok "color token has name/value/usage/contrast fields"
else
  fail "color token missing required fields"
fi

# component has states array
if jq -e '.components[0].states | type == "array" and length > 0' <<<"$FULL_SPEC" >/dev/null 2>&1; then
  ok "component has non-empty states array"
else
  fail "component states missing or empty"
fi

# min_touch_target is 44pt
if jq -e '.accessibility.min_touch_target == "44pt"' <<<"$FULL_SPEC" >/dev/null 2>&1; then
  ok "accessibility.min_touch_target = 44pt (Apple HIG)"
else
  fail "accessibility.min_touch_target not 44pt"
fi

# ─────────────────────────────────────────────────────────────
# 7. MCP JSON files are valid JSON with correct server name
# ─────────────────────────────────────────────────────────────
echo ""
echo "=== 7. MCP config files are valid JSON ==="

if jq -e '.mcpServers.figma | .type == "stdio"' kit/mcp/figma.json >/dev/null 2>&1; then
  ok "kit/mcp/figma.json valid — mcpServers.figma stdio"
else
  fail "kit/mcp/figma.json invalid or missing mcpServers.figma"
fi

if jq -e '.mcpServers.canvas | .type == "stdio"' kit/mcp/canvas.json >/dev/null 2>&1; then
  ok "kit/mcp/canvas.json valid — mcpServers.canvas stdio"
else
  fail "kit/mcp/canvas.json invalid or missing mcpServers.canvas"
fi

if jq -r '.mcpServers.figma.env.FIGMA_API_KEY' kit/mcp/figma.json | grep -q '${FIGMA_API_KEY}'; then
  ok "figma.json uses \${FIGMA_API_KEY} env placeholder"
else
  fail "figma.json missing \${FIGMA_API_KEY} env placeholder"
fi

if jq -r '.mcpServers.canvas.env.CANVAS_API_TOKEN' kit/mcp/canvas.json | grep -q '${CANVAS_API_TOKEN}'; then
  ok "canvas.json uses \${CANVAS_API_TOKEN} env placeholder"
else
  fail "canvas.json missing \${CANVAS_API_TOKEN} env placeholder"
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
