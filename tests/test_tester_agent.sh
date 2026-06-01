#!/usr/bin/env bash
# Tests for kit/agents/tester.md — validates Playwright MCP integration additions

FILE="kit/agents/tester.md"
PASS=0
FAIL=0

assert_contains() {
  local desc="$1"
  local pattern="$2"
  if grep -qF "$pattern" "$FILE"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      expected pattern: $pattern"
    ((FAIL++))
  fi
}

assert_not_contains() {
  local desc="$1"
  local pattern="$2"
  if ! grep -qF "$pattern" "$FILE"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc — pattern should NOT appear: $pattern"
    ((FAIL++))
  fi
}

cd "$(dirname "$0")/.." || exit 1

echo "=== tester.md — Playwright MCP integration ==="

# --- allowed_tools: all 15 Playwright tools present ---
TOOLS=(
  "mcp__plugin_playwright_playwright__browser_navigate"
  "mcp__plugin_playwright_playwright__browser_click"
  "mcp__plugin_playwright_playwright__browser_type"
  "mcp__plugin_playwright_playwright__browser_fill_form"
  "mcp__plugin_playwright_playwright__browser_select_option"
  "mcp__plugin_playwright_playwright__browser_press_key"
  "mcp__plugin_playwright_playwright__browser_hover"
  "mcp__plugin_playwright_playwright__browser_snapshot"
  "mcp__plugin_playwright_playwright__browser_take_screenshot"
  "mcp__plugin_playwright_playwright__browser_wait_for"
  "mcp__plugin_playwright_playwright__browser_console_messages"
  "mcp__plugin_playwright_playwright__browser_network_requests"
  "mcp__plugin_playwright_playwright__browser_close"
  "mcp__plugin_playwright_playwright__browser_resize"
  "mcp__plugin_playwright_playwright__browser_evaluate"
)
for tool in "${TOOLS[@]}"; do
  assert_contains "allowed_tools contains $tool" "$tool"
done

# --- core tools still present ---
for core in Read Write Edit Bash Grep Glob; do
  assert_contains "allowed_tools still has core tool: $core" "$core"
done

# --- web browser section exists ---
assert_contains "section: Test web bằng browser (Playwright MCP)" \
  "## Test web bằng browser (Playwright MCP)"

# --- navigate step references correct tool name ---
assert_contains "navigate step uses mcp__plugin_playwright_playwright__browser_navigate" \
  "mcp__plugin_playwright_playwright__browser_navigate"

# --- headless=false requirement ---
assert_contains "headless=false requirement present" "headless=false"
assert_contains "explicit ban on headless mode" "KHÔNG headless"
assert_contains "PLAYWRIGHT_HEADLESS=false env var example" "PLAYWRIGHT_HEADLESS=false"

# --- BROWSER block in output template ---
assert_contains "output template has ## BROWSER block" "## BROWSER"
assert_contains "output template mentions headless confirmation" "headless=false"

# --- edge: headless=true must NOT appear as a positive instruction ---
# The file may mention it in the negation context, so check the actual negation is present
assert_contains "negation of headless: Tester KHÔNG được dùng chế độ headless" \
  "Tester KHÔNG được dùng chế độ headless"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
