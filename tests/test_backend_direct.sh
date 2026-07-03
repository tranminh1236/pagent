#!/usr/bin/env bash
# Tests cho claude DIRECT mode — việc lớn dùng claude CLI thẳng subscription Anthropic.
# Spec: docs/superpowers/specs/2026-07-04-backend-switch-design.md
#   PAGENT_PROVIDER=claude + PAGENT_CLAUDE_DIRECT=1 (mặc định) → invoke claude qua
#   `env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY` (không dính gateway);
#   model = PAGENT_CLAUDE_MODEL (tên trần, mặc định sonnet); frontmatter model chứa
#   "/" bị bỏ qua. PAGENT_CLAUDE_DIRECT=0 → giữ đường gateway (BASE_URL còn nguyên).

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

# PASS=$((PASS+1)) chứ KHÔNG ((PASS++)) — post-increment từ 0 trả exit status false
# → assert đầu tiên dạng `grep && ok || bad` sẽ chạy CẢ ok lẫn bad.
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; FAIL=$((FAIL+1)); }

make_sandbox() {
  local SB; SB="$(mktemp -d)"
  mkdir -p "$SB/src" "$SB/reports" "$SB/bin"
  git -C "$SB/src" init -q 2>/dev/null
  cat >"$SB/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude: dump env + argv rồi trả plan hợp lệ
cat >/dev/null
if [[ "$1" == "--version" ]]; then echo "fake-claude"; exit 0; fi
if [[ -n "${FAKE_CL_MARKER:-}" ]]; then
  {
    printf 'BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-<unset>}"
    printf 'API_KEY=%s\n'  "${ANTHROPIC_API_KEY:-<unset>}"
    printf 'ARGS=%s\n' "$*"
  } >>"$FAKE_CL_MARKER"
fi
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"sid-cl","result":"{\\"title\\":\\"t\\",\\"summary\\":\\"s\\",\\"coder_task\\":\\"c\\",\\"reviewer_focus\\":\\"r\\",\\"risk\\":\\"low\\",\\"affected_paths\\":[]}"}'
FAKE
  chmod +x "$SB/bin/claude"
  echo "$SB"
}

run_find() {  # $1=SB $2=env bổ sung
  local SB="$1" extra="$2"
  ( cd "$SB/src" && eval "PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR='$SB/reports' \
      PAGENT_CLAUDE_BIN='$SB/bin/claude' PAGENT_PROVIDER=claude \
      ANTHROPIC_BASE_URL='http://127.0.0.1:20128' ANTHROPIC_API_KEY='sk-test-123' \
      FAKE_CL_MARKER='$SB/marker.txt' PAGENT_NO_CONFIRM=1 PAGENT_KNOWLEDGE=0 $extra \
      perl -e 'alarm 40; exec @ARGV' -- '$OLDPWD/$PAGENT' find 'câu hỏi test' </dev/null" >/dev/null 2>&1 )
}

echo "=== direct mode (mặc định): unset ANTHROPIC_BASE_URL/API_KEY + model frontmatter ==="
SB="$(make_sandbox)"
run_find "$SB" ""
m="$(cat "$SB/marker.txt" 2>/dev/null)"
grep -q "BASE_URL=<unset>" <<<"$m" && ok "ANTHROPIC_BASE_URL bị unset (direct sub)" || bad "BASE_URL vẫn còn" "$m"
grep -q "API_KEY=<unset>" <<<"$m"  && ok "ANTHROPIC_API_KEY bị unset"               || bad "API_KEY vẫn còn" "$m"
# orchestrator.md khai model tên trần cho claude-cli → phải được dùng
_orch_model="$(awk '/^model:/{print $2; exit}' kit/agents/orchestrator.md)"
grep -q -- "$_orch_model" <<<"$m"  && ok "claude dùng model frontmatter ($_orch_model)" || bad "model frontmatter không được dùng" "$m"
rm -rf "$SB"

echo "=== agent KHÔNG khai model → fallback PAGENT_CLAUDE_MODEL ==="
SB="$(make_sandbox)"
mkdir -p "$SB/src/.pagent/agents"
printf -- '---\nname: orchestrator\ndescription: override local không model\n---\nRa JSON plan theo yêu cầu.\n' >"$SB/src/.pagent/agents/orchestrator.md"
run_find "$SB" "PAGENT_CLAUDE_MODEL=haiku"
m="$(cat "$SB/marker.txt" 2>/dev/null)"
grep -q "haiku" <<<"$m" && ok "fallback PAGENT_CLAUDE_MODEL khi md không khai model" || bad "fallback PAGENT_CLAUDE_MODEL fail" "$m"
rm -rf "$SB"

echo "=== PAGENT_CLAUDE_DIRECT=0 → giữ đường gateway ==="
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_CLAUDE_DIRECT=0"
m="$(cat "$SB/marker.txt" 2>/dev/null)"
grep -q "BASE_URL=http://127.0.0.1:20128" <<<"$m" && ok "ANTHROPIC_BASE_URL giữ nguyên khi DIRECT=0" || bad "BASE_URL bị unset dù DIRECT=0" "$m"
rm -rf "$SB"

echo "=== PAGENT_MODEL dạng provider/model bị bỏ qua ở nhánh claude ==="
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude"
m="$(cat "$SB/marker.txt" 2>/dev/null)"
if ! grep -q "9router/Claude" <<<"$m"; then
  ok "model provider/model (combo 9router) không lọt vào claude"
else bad "model provider/model lọt vào claude" "$m"; fi
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
