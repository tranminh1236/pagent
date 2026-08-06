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
  # fake opencode: đánh dấu đã spawn (FAKE_OC_SPAWN) + in NDJSON plan hợp lệ (opencode 1.17.13).
  # Dùng cho preflight test của `pagent init` (provider mặc định opencode).
  cat >"$SB/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "9.9.9-fake"; exit 0; fi
[[ -n "${FAKE_OC_SPAWN:-}" ]] && printf 'spawned %s\n' "$*" >>"$FAKE_OC_SPAWN"
plan='{\"title\":\"t\",\"summary\":\"s\",\"coder_task\":\"c\",\"reviewer_focus\":\"r\",\"risk\":\"low\",\"affected_paths\":[]}'
printf '{"type":"step_start","timestamp":1,"sessionID":"ses_fake1","part":{"type":"step-start"}}\n'
printf '{"type":"text","timestamp":2,"sessionID":"ses_fake1","part":{"type":"text","text":"%s"}}\n' "$plan"
printf '{"type":"step_finish","timestamp":3,"sessionID":"ses_fake1","part":{"type":"step-finish","reason":"stop","tokens":{"input":100,"output":50,"reasoning":5,"cache":{"read":10,"write":3}},"cost":0.012}}\n'
FAKE
  chmod +x "$SB/bin/opencode"
  echo "$SB"
}

run_init() {  # $1=SB $2=env bổ sung — chạy `pagent init` provider opencode, môi trường CÔ LẬP.
  local SB="$1" extra="$2"
  # QUAN TRỌNG: test có thể chạy BÊN TRONG một pipeline pagent → PAGENT_SOURCE/PAGENT_MODEL/
  # PAGENT_PROVIDER… leak vào subshell. Phải reset hết: ép PAGENT_SOURCE=sandbox, provider
  # opencode, PAGENT_MODEL do từng case tự set. XDG_CONFIG_HOME/PAGENT_OC_HOME cô lập →
  # preflight KHÔNG dính opencode.json/auth.json thật của máy dev (tránh false-pass).
  ( cd "$SB/src" && eval "env \
      -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u PAGENT_MODEL -u PAGENT_TASK_ID \
      -u PAGENT_RUN_DIR -u PAGENT_MODE -u PAGENT_PARENT -u PAGENT_RESUME \
      -u PAGENT_AGENT -u PAGENT_AGENT_PROVIDER -u PAGENT_AGENT_MODEL -u PAGENT_CONFIRM \
      PAGENT_SOURCE='$SB/src' PAGENT_PROVIDER=opencode PAGENT_SAVE_TOKEN=0 \
      PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR='$SB/reports' \
      PAGENT_OPENCODE_BIN='$SB/bin/opencode' PAGENT_OC_HOME='$SB/ochome' \
      XDG_CONFIG_HOME='$SB/xdgconfig' PAGENT_KNOWLEDGE=0 PAGENT_NO_CONFIRM=1 $extra \
      perl -e 'alarm 40; exec @ARGV' -- '$OLDPWD/$PAGENT' init </dev/null" 2>&1 )
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
rm -rf "$SB"

echo "=== claude backend dùng model TÊN TRẦN khai trong frontmatter (override sandbox) ==="
# kit/agents giờ KHÔNG khai model (opencode combo tự chọn); nhánh claude vẫn tôn trọng model
# tên trần khi agent CÓ khai. Default PAGENT_CLAUDE_MODEL=sonnet → "opus" chỉ có thể từ frontmatter.
SBM="$(make_sandbox)"
mkdir -p "$SBM/src/.pagent/agents"
printf -- '---\nname: orchestrator\ndescription: override khai model tên trần\nmodel: opus\n---\nRa JSON plan theo yêu cầu.\n' >"$SBM/src/.pagent/agents/orchestrator.md"
run_find "$SBM" ""
mm="$(cat "$SBM/marker.txt" 2>/dev/null)"
grep -q -- "opus" <<<"$mm" && ok "claude dùng model tên trần frontmatter (opus)" || bad "model frontmatter không được dùng" "$mm"
rm -rf "$SBM"

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

echo "=== START event (pre.sh) ghi model claude TÊN TRẦN, KHÔNG leak provider/model ==="
# Bug: PAGENT_AGENT_MODEL export TRƯỚC pre.sh còn dạng '9router/*' → START event leak →
# badge in-flight hiện 'claude · FREE'. Fix: strip provider/model cho claude TRƯỚC export.
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_CLAUDE_MODEL=sonnet"
ev="$(cat "$SB/reports/srcproj/tokens/"*.jsonl 2>/dev/null | grep '"event":"start"' | head -1)"
if grep -q "9router" <<<"$ev"; then bad "START event leak provider/model" "$ev"
elif grep -q '"model":"sonnet"' <<<"$ev"; then ok "START event ghi model claude tên trần (sonnet)"
else bad "START event model không đúng" "$ev"; fi
rm -rf "$SB"

echo "=== regression: pagent init thiếu creds/gateway + PAGENT_MODEL rỗng → die hướng dẫn, KHÔNG raw creds ==="
# Repro lỗi gốc: `pagent init` provider opencode không có nguồn chạy → opencode nhả
# 'No active credentials for provider: claude'. Preflight phải chặn TRƯỚC spawn với hướng dẫn.
SB="$(make_sandbox)"
out="$(run_init "$SB" "PAGENT_MODEL= ANTHROPIC_BASE_URL= ANTHROPIC_API_KEY= FAKE_OC_SPAWN='$SB/oc-spawned'")"; rc=$?
if (( rc != 0 )); then ok "init exit non-zero khi thiếu creds/gateway"; else bad "init phải fail khi thiếu creds+gateway+model" "$(tail -5 <<<"$out")"; fi
if grep -qi 'ANTHROPIC_BASE_URL' <<<"$out" && grep -qi 'PAGENT_MODEL' <<<"$out" && grep -q '.env.pagent' <<<"$out"; then
  ok "stderr có hướng dẫn cấu hình (.env.pagent / ANTHROPIC_BASE_URL / PAGENT_MODEL)"
else bad "stderr thiếu hướng dẫn cấu hình actionable" "$(tail -8 <<<"$out")"; fi
if grep -q 'No active credentials' <<<"$out"; then bad "vẫn lọt raw 'No active credentials'" "$(tail -8 <<<"$out")"; else ok "không lọt raw 'No active credentials'"; fi
if [[ ! -f "$SB/oc-spawned" ]]; then ok "opencode KHÔNG bị spawn (die sớm ở preflight)"; else bad "opencode vẫn spawn dù thiếu creds" "$(cat "$SB/oc-spawned")"; fi
rm -rf "$SB"

echo "=== regression: pagent init provider=opencode có PAGENT_MODEL hợp lệ → preflight KHÔNG chặn ==="
# Đảm bảo preflight không chặn nhầm luồng hợp lệ: model provider/model đủ điều kiện chạy.
SB="$(make_sandbox)"
out="$(run_init "$SB" "PAGENT_MODEL=9router/Claude ANTHROPIC_BASE_URL= ANTHROPIC_API_KEY= FAKE_OC_SPAWN='$SB/oc-spawned'")"; rc=$?
if (( rc == 0 )); then ok "init hoàn thành (rc=0) khi PAGENT_MODEL hợp lệ"; else bad "init phải chạy với PAGENT_MODEL provider/model" "$(tail -5 <<<"$out")"; fi
if [[ -f "$SB/oc-spawned" ]]; then ok "opencode được spawn (preflight cho qua)"; else bad "preflight chặn nhầm — opencode không spawn" "$(tail -8 <<<"$out")"; fi
if grep -q 'opencode thiếu nguồn chạy' <<<"$out"; then bad "preflight chặn nhầm dù PAGENT_MODEL hợp lệ" "$(tail -8 <<<"$out")"; else ok "không dính message preflight-block"; fi
[[ -s "$SB/src/.pagent/source-summary.md" ]] && ok "ghi source-summary.md" || bad "không ghi source-summary.md" "$(tail -8 <<<"$out")"
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
