#!/usr/bin/env bash
# Bug thực tế (2026-07-03, run 20260703T151927): gateway trả 401 → claude CLI xuất
# {"subtype":"success","is_error":true,"result":"API Error: 401 ..."} — call_agent chỉ
# check `.result` tồn tại → coi là THÀNH CÔNG: reviewer chưng "0 luật" từ rác, coder
# "hoàn thành" với chuỗi lỗi làm output, không warn nào được in → chết câm.
# Fix: response ok = có .result VÀ is_error != true; fail phải warn kèm reason (.result).

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

ok()  { echo "PASS: $1"; ((PASS++)); }
bad() { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; ((FAIL++)); }

echo "=== e2e: fake claude trả is_error=true + result='API Error 401' ==="
SB="$(mktemp -d)"
mkdir -p "$SB/src" "$SB/reports" "$SB/bin"
cat >"$SB/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
if [[ "$1" == "--version" ]]; then echo "fake-claude 0.0.1"; exit 0; fi
printf '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"session_id":"sid-x","result":"API Error: 401 [claude/claude-opus-4-6] authentication_error Invalid authentication cred"}'
FAKE
chmod +x "$SB/bin/claude"
git -C "$SB/src" init -q 2>/dev/null
out="$(cd "$SB/src" && PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR="$SB/reports" \
  PAGENT_CLAUDE_BIN="$SB/bin/claude" PAGENT_PROVIDER=claude PAGENT_NO_CONFIRM=1 PAGENT_KNOWLEDGE=0 \
  perl -e 'alarm 30; exec @ARGV' -- "$OLDPWD/$PAGENT" find "hỏi gì đó" </dev/null 2>&1)"
rc=$?
if (( rc != 0 )); then ok "is_error=true → pipeline FAIL (rc=$rc), không giả vờ thành công"; else bad "pipeline phải fail khi is_error=true" "$(tail -3 <<<"$out")"; fi
if grep -q "API Error: 401" <<<"$out"; then ok "log có reason thật (API Error: 401 ...) — biết tại sao chết"; else bad "log phải chứa reason 'API Error: 401'" "$(tail -5 <<<"$out")"; fi
rm -rf "$SB"

echo "=== positive control: is_error=false vẫn chạy bình thường ==="
SB="$(mktemp -d)"
mkdir -p "$SB/src" "$SB/reports" "$SB/bin"
cat >"$SB/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
if [[ "$1" == "--version" ]]; then echo "fake-claude 0.0.1"; exit 0; fi
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"sid-ok","result":"{\\"title\\":\\"t\\",\\"summary\\":\\"s\\",\\"coder_task\\":\\"c\\",\\"reviewer_focus\\":\\"r\\",\\"risk\\":\\"low\\",\\"affected_paths\\":[]}"}'
FAKE
chmod +x "$SB/bin/claude"
git -C "$SB/src" init -q 2>/dev/null
( cd "$SB/src" && PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR="$SB/reports" \
  PAGENT_CLAUDE_BIN="$SB/bin/claude" PAGENT_PROVIDER=claude PAGENT_NO_CONFIRM=1 PAGENT_KNOWLEDGE=0 \
  perl -e 'alarm 30; exec @ARGV' -- "$OLDPWD/$PAGENT" find "hỏi gì đó" </dev/null >/dev/null 2>&1 )
rc=$?
if (( rc == 0 )); then ok "is_error=false → pipeline chạy bình thường (rc=0)"; else bad "positive control fail rc=$rc"; fi
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
