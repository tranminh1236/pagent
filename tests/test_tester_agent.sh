#!/usr/bin/env bash
# Tests for kit/agents/tester.md — backend opencode (2026-07-04).
# Lịch sử: tester từng khai 15 tool mcp__plugin_playwright_playwright__* — đó là MCP của
# plugin USER-SCOPE Claude Code, chưa bao giờ được nạp qua pagent (call_agent dùng
# --setting-sources project,local và kit/mcp/ không có playwright.json) → dead-weight
# đốt system prompt mỗi run. Đã DỌN khỏi tester.md; muốn browser test thật thì thêm
# kit/mcp/playwright.json + mcp_servers: playwright rồi khôi phục section.

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

echo "=== tester.md — tool playwright chết đã được dọn ==="

# --- không còn bất kỳ tham chiếu MCP playwright plugin nào (frontmatter LẪN body) ---
assert_not_contains "không còn tool mcp playwright plugin" "mcp__plugin_playwright_playwright__"
assert_not_contains "không còn section browser flow Playwright MCP" "## Test web bằng browser (Playwright MCP)"
assert_not_contains "không còn block ## BROWSER trong output template" "## BROWSER"
assert_not_contains "không còn yêu cầu PLAYWRIGHT_HEADLESS" "PLAYWRIGHT_HEADLESS"

# --- core tools còn đủ ---
TOOLS_LINE="$(awk '/^allowed_tools:/{print; exit}' "$FILE")"
for core in Read Write Edit Bash Grep Glob; do
  if grep -qE "(:|,)[[:space:]]*$core(,|[[:space:]]|$)" <<<"$TOOLS_LINE"; then
    echo "PASS: allowed_tools còn core tool: $core"; ((PASS++))
  else
    echo "FAIL: allowed_tools thiếu core tool: $core — $TOOLS_LINE"; ((FAIL++))
  fi
done

# --- ghi chú browser-test để lại dấu vết (biết đường khôi phục khi có MCP) ---
assert_contains "có ghi chú browser test tạm không khả dụng" "Browser test"

# --- các phần nghiệp vụ cốt lõi giữ nguyên ---
assert_contains "quy trình đọc source-summary còn" ".pagent/source-summary.md"
assert_contains "phối hợp performance/security còn" "PERFORMANCE_REPORT"
assert_contains "output template TESTS_ADDED còn" "## TESTS_ADDED"
assert_contains "output template RUN còn" "## RUN"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
