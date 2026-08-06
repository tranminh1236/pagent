#!/usr/bin/env bash
# Tests cho backend opencode CLI (provider mặc định thay claude CLI).
# Spec: docs/superpowers/specs/2026-07-04-opencode-backend-design.md
# Fake opencode bin in NDJSON events (đúng shape thực nghiệm opencode 1.17.13),
# dump argv + XDG env ra marker để assert cách pagent invoke.

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

ok()  { echo "PASS: $1"; ((PASS++)); }
bad() { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; ((FAIL++)); }

make_sandbox() {  # tạo sandbox + fake opencode; echo đường dẫn SB
  local SB; SB="$(mktemp -d)"
  mkdir -p "$SB/src" "$SB/reports" "$SB/bin"
  git -C "$SB/src" init -q 2>/dev/null
  cat >"$SB/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
# fake opencode run: dump argv + env rồi in NDJSON events như opencode 1.17.13
if [[ "$1" == "--version" ]]; then echo "9.9.9-fake"; exit 0; fi
if [[ -n "${FAKE_OC_ARGS_FILE:-}" ]]; then
  printf '%s\n' "$@" >"$FAKE_OC_ARGS_FILE"
  printf 'XDG_DATA_HOME=%s\nXDG_STATE_HOME=%s\nXDG_CACHE_HOME=%s\n' \
    "${XDG_DATA_HOME:-}" "${XDG_STATE_HOME:-}" "${XDG_CACHE_HOME:-}" >"$FAKE_OC_ARGS_FILE.env"
fi
if [[ "${FAKE_OC_FAIL:-}" == "1" ]]; then
  printf '{"type":"error","timestamp":1,"sessionID":"ses_err1","error":{"name":"ProviderAuthError","data":{"message":"401 Invalid authentication cred from gateway"}}}\n'
  exit 1
fi
plan='{\"title\":\"t\",\"summary\":\"s\",\"coder_task\":\"c\",\"reviewer_focus\":\"r\",\"risk\":\"low\",\"affected_paths\":[]}'
printf '{"type":"step_start","timestamp":1,"sessionID":"ses_fake1","part":{"type":"step-start"}}\n'
printf '{"type":"text","timestamp":2,"sessionID":"ses_fake1","part":{"type":"text","text":"%s"}}\n' "$plan"
printf '{"type":"step_finish","timestamp":3,"sessionID":"ses_fake1","part":{"type":"step-finish","reason":"stop","tokens":{"input":100,"output":50,"reasoning":5,"cache":{"read":10,"write":3}},"cost":0.012}}\n'
FAKE
  chmod +x "$SB/bin/opencode"
  echo "$SB"
}

run_find() {  # $1=SB $2=env bổ sung
  local SB="$1" extra="$2"
  ( cd "$SB/src" && eval "PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR='$SB/reports' \
      PAGENT_OPENCODE_BIN='$SB/bin/opencode' PAGENT_NO_CONFIRM=1 PAGENT_KNOWLEDGE=0 \
      FAKE_OC_ARGS_FILE='$SB/args.txt' $extra \
      perl -e 'alarm 40; exec @ARGV' -- '$OLDPWD/$PAGENT' find 'câu hỏi test' </dev/null" 2>&1 )
}

echo "=== syntax ==="
if bash -n "$PAGENT"; then ok "bash -n pagent"; else bad "bash -n pagent"; fi

echo "=== e2e: pipeline find qua fake opencode ==="
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL=9router/FakeModel")"; rc=$?
if (( rc == 0 )); then ok "pipeline find hoàn thành (rc=0)"; else bad "pipeline fail rc=$rc" "$(tail -5 <<<"$out")"; fi

# argv: -m model, --agent pagent-orchestrator, --dir src, --format json, --auto
args="$(cat "$SB/args.txt" 2>/dev/null)"
grep -q "^run$" <<<"$args"                    && ok "invoke subcommand run"            || bad "thiếu subcommand run" "$args"
grep -q "^9router/FakeModel$" <<<"$args"      && ok "-m nhận PAGENT_MODEL provider/model" || bad "-m sai" "$args"
grep -q "^pagent-" <<<"$args"                 && ok "--agent pagent-<agent>"            || bad "--agent thiếu" "$args"
grep -q "^--format$" <<<"$args" && grep -q "^json$" <<<"$args" && ok "--format json"    || bad "--format json thiếu" "$args"
grep -q "^--auto$" <<<"$args"                 && ok "--auto (headless permission)"      || bad "--auto thiếu" "$args"
# macOS: mktemp trả /var/... nhưng git toplevel resolve /private/var/... → so theo suffix
grep -q "^--dir$" <<<"$args" && grep -q "/src$" <<<"$args" && ok "--dir trỏ PAGENT_SOURCE" || bad "--dir sai" "$args"

# XDG redirect về PAGENT_OC_HOME (mặc định $PAGENT_REPORT_DIR/.opencode)
envf="$(cat "$SB/args.txt.env" 2>/dev/null)"
grep -q "XDG_DATA_HOME=$SB/reports/.opencode/data" <<<"$envf" && ok "XDG_DATA_HOME → PAGENT_OC_HOME/data" || bad "XDG_DATA_HOME sai" "$envf"
grep -q "XDG_STATE_HOME=$SB/reports/.opencode/state" <<<"$envf" && ok "XDG_STATE_HOME → PAGENT_OC_HOME/state" || bad "XDG_STATE_HOME sai" "$envf"

# JSON claude-shape trong bundle (run dir được bundle cuối pipeline)
bundle="$(ls "$SB/reports/srcproj/runs/"*/bundle.tar.gz 2>/dev/null | head -1)"
oj="$(tar -xzf "$bundle" -O ./orchestrator.json 2>/dev/null)"
if [[ -n "$oj" ]]; then
  jq -e '.is_error == false and .subtype == "success"' <<<"$oj" >/dev/null && ok "is_error/subtype đúng" || bad "is_error/subtype sai" "$oj"
  jq -e '.usage.input_tokens == 100 and .usage.output_tokens == 50' <<<"$oj" >/dev/null && ok "usage tokens từ step_finish" || bad "usage sai" "$oj"
  jq -e '.usage.cache_read_input_tokens == 10 and .usage.cache_creation_input_tokens == 3' <<<"$oj" >/dev/null && ok "cache tokens đúng" || bad "cache sai" "$oj"
  jq -e '.total_cost_usd == 0.012' <<<"$oj" >/dev/null && ok "total_cost_usd từ cost" || bad "cost sai" "$oj"
  jq -e '.session_id == "ses_fake1"' <<<"$oj" >/dev/null && ok "session_id giữ nguyên" || bad "session_id sai" "$oj"
  jq -e '.provider == "opencode"' <<<"$oj" >/dev/null && ok "provider=opencode (tokens log/web pill)" || bad "provider sai" "$oj"
  jq -e '(.modelUsage | keys | length) == 1' <<<"$oj" >/dev/null && ok "modelUsage 1 entry cho web pill" || bad "modelUsage sai" "$oj"
  jq -e '.result | fromjson | .title == "t"' <<<"$oj" >/dev/null && ok ".result = text event (plan parse được)" || bad ".result sai" "$oj"
else
  bad "không tìm thấy orchestrator.json trong bundle" "$bundle"
fi

# tokens log ghi provider opencode + cost
tok="$(cat "$SB/reports/srcproj/tokens/"*.jsonl 2>/dev/null)"
jq -e 'select(.agent=="orchestrator" and .event=="end") | .provider == "opencode" and .cost_usd == 0.012' <<<"$tok" >/dev/null 2>&1 \
  && ok "tokens log: provider + cost đúng qua post.sh" || bad "tokens log sai" "$(head -2 <<<"$tok")"

# agent file sinh trong .opencode/agents với permission map từ allowed_tools
af="$SB/src/.opencode/agents/pagent-orchestrator.md"
if [[ -f "$af" ]]; then
  ok "sinh .opencode/agents/pagent-orchestrator.md"
  grep -q "mode: primary" "$af"        && ok "agent file: mode primary"        || bad "thiếu mode primary" "$(head -20 "$af")"
  # #1 description = mô tả THẬT của agent (không phải generic auto-gen)
  grep -q 'description: "Lead agent' "$af" && ok "orchestrator: description thật (kit)" || bad "description phải là mô tả thật của agent" "$(head -20 "$af")"
  if grep -q "auto-generated" "$af"; then bad "vẫn dùng description generic" "$(head -20 "$af")"; else ok "orchestrator: bỏ description generic"; fi
  # #2 orchestrator có Bash(ls *)… → permission.bash MAP least-privilege (KHÔNG full allow)
  if grep -qE '^  bash: allow' "$af"; then bad "orchestrator KHÔNG được full bash (mất least-privilege)" "$(head -20 "$af")"; else ok "orchestrator: không full bash"; fi
  grep -q '"\*": deny' "$af"           && ok "orchestrator: bash map default deny"    || bad "thiếu default deny trong bash map" "$(head -20 "$af")"
  grep -q '"git diff' "$af"            && ok "orchestrator: giữ scoped git diff allow" || bad "mất scoped bash allow" "$(head -20 "$af")"
  grep -q "edit: deny" "$af"           && ok "orchestrator: edit deny"         || bad "edit phải deny" "$(head -20 "$af")"
  # body phải chứa system prompt thật của orchestrator
  grep -qi "orchestrator\|điều phối\|plan" "$af" && ok "agent file body = system prompt" || bad "body rỗng/sai"
else
  bad "không sinh agent file" "$(ls "$SB/src/.opencode/agents/" 2>/dev/null)"
fi
rm -rf "$SB"

echo "=== opencode dùng PAGENT_MODEL, KHÔNG lấy model từ frontmatter ==="
# kit/agents KHÔNG khai model (opencode để 9router combo tự phân phối) → -m luôn là PAGENT_MODEL,
# không bao giờ dính tên model claude-cli.
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL=9router/Claude")"
args="$(cat "$SB/args.txt" 2>/dev/null)"
if grep -q "^9router/Claude$" <<<"$args" && ! grep -qE "claude-(opus|sonnet|haiku)" <<<"$args"; then
  ok "opencode -m dùng PAGENT_MODEL (9router/Claude), không dính model claude-cli"
else bad "opencode phải dùng PAGENT_MODEL, không frontmatter model" "$args"; fi
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/src/.pagent/agents"
printf -- '---\nname: orchestrator\ndescription: override có model provider/model\nmodel: cc/claude-opus-4-8\n---\nRa JSON plan theo yêu cầu.\n' >"$SB/src/.pagent/agents/orchestrator.md"
out="$(run_find "$SB" "PAGENT_MODEL=9router/Claude")"
args="$(cat "$SB/args.txt" 2>/dev/null)"
if ! grep -q "^cc/claude-opus-4-8$" <<<"$args" && grep -q "^9router/Claude$" <<<"$args"; then
  ok "cả model provider/model trong frontmatter cũng bị bỏ — 9router tự chọn"
else bad "provider/model frontmatter lọt vào opencode" "$args"; fi
rm -rf "$SB"

echo "=== PAGENT_MODEL rỗng + có gateway → spawn nhưng không truyền -m (default opencode config) ==="
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL= ANTHROPIC_BASE_URL=http://gw")"
args="$(cat "$SB/args.txt" 2>/dev/null)"
if [[ -n "$args" ]] && ! grep -q "^-m$" <<<"$args" && ! grep -q "^--model$" <<<"$args"; then
  ok "spawn opencode, không có -m khi model rỗng"
else bad "vẫn truyền -m khi model rỗng (hoặc không spawn)" "$args"; fi
rm -rf "$SB"

echo "=== preflight: opencode thiếu model+gateway+creds → die sớm, KHÔNG spawn ==="
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL= ANTHROPIC_BASE_URL= ANTHROPIC_API_KEY= PAGENT_OC_HOME='$SB/ochome'")"; rc=$?
if (( rc != 0 )); then ok "preflight fail sớm (rc=$rc)"; else bad "phải fail khi thiếu model+gateway+creds" "$(tail -5 <<<"$out")"; fi
if [[ ! -f "$SB/args.txt" ]]; then ok "opencode KHÔNG bị spawn"; else bad "opencode vẫn spawn dù thiếu creds" "$(cat "$SB/args.txt")"; fi
grep -qi 'ANTHROPIC_BASE_URL' <<<"$out" && grep -qi 'PAGENT_MODEL' <<<"$out" && ok "message actionable (hướng dẫn .env.pagent)" || bad "message không actionable" "$(tail -8 <<<"$out")"
if grep -q 'No active credentials for provider' <<<"$out"; then bad "vẫn lộ raw 'No active credentials'" "$out"; else ok "không nhả raw opencode error"; fi
rm -rf "$SB"

echo "=== preflight: có ANTHROPIC_BASE_URL (không model) → cho chạy ==="
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL= ANTHROPIC_API_KEY= ANTHROPIC_BASE_URL=http://gw PAGENT_OC_HOME='$SB/ochome'")"; rc=$?
if (( rc == 0 )) && [[ -f "$SB/args.txt" ]]; then ok "gateway đủ điều kiện → spawn opencode"; else bad "gateway phải cho chạy" "$(tail -5 <<<"$out")"; fi
rm -rf "$SB"

echo "=== cmd_init: opencode fail → surface reason gốc (không die trơ 'agent fail') ==="
SB="$(make_sandbox)"
out="$( cd "$SB/src" && eval "PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR='$SB/reports' \
    PAGENT_OPENCODE_BIN='$SB/bin/opencode' PAGENT_MODEL=9router/Claude FAKE_OC_FAIL=1 \
    PAGENT_KNOWLEDGE=0 FAKE_OC_ARGS_FILE='$SB/args.txt' \
    perl -e 'alarm 40; exec @ARGV' -- '$OLDPWD/$PAGENT' init </dev/null" 2>&1 )"; rc=$?
if (( rc != 0 )); then ok "init fail (rc=$rc)"; else bad "init phải fail khi source scan lỗi"; fi
grep -q '401 Invalid authentication cred' <<<"$out" && ok "surface reason gốc từ terminal_reason" || bad "thiếu reason gốc" "$(tail -8 <<<"$out")"
if grep -qE 'error:.*agent fail' <<<"$out"; then bad "vẫn die trơ 'agent fail' (nuốt reason)" "$(tail -8 <<<"$out")"; else ok "không die trơ 'agent fail'"; fi
grep -q '.env.pagent' <<<"$out" && ok "gợi ý fix .env.pagent" || bad "thiếu gợi ý .env.pagent" "$(tail -8 <<<"$out")"
rm -rf "$SB"

echo "=== event error → pipeline fail + reason trong log ==="
SB="$(make_sandbox)"
out="$(run_find "$SB" "PAGENT_MODEL=9router/Claude FAKE_OC_FAIL=1")"; rc=$?
if (( rc != 0 )); then ok "error event → pipeline fail (rc=$rc)"; else bad "pipeline phải fail khi opencode error"; fi
if grep -q "401 Invalid authentication cred" <<<"$out"; then ok "log có reason thật từ error event"; else bad "log thiếu reason" "$(tail -5 <<<"$out")"; fi
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
