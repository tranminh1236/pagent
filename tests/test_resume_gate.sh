#!/usr/bin/env bash
# Tests cho resume gate khi agent chạm max_turns.
# Spec: docs/superpowers/specs/2026-07-03-resume-max-turns-design.md
#   - kit/lib/resume.sh: file handshake (pending/decision namespace theo agent),
#     timeout, stop, clamp lượt, cleanup, atomic.
#   - pagent call_agent: loop resume (--resume <sid> --max-turns <N>), cap
#     PAGENT_MAX_RESUME, chỉ subtype error_max_turns.
#   - e2e fake claude bin: lần 1 error_max_turns → decision resume → lần 2 success.

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"
LIB="./kit/lib/resume.sh"

ok()  { echo "PASS: $1"; ((PASS++)); }
bad() { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; ((FAIL++)); }

assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then ok "$desc"; else bad "$desc" "regex not found: $pattern"; fi
}

echo "=== syntax ==="
if bash -n "$PAGENT"; then ok "bash -n pagent"; else bad "bash -n pagent"; fi
if [[ -f "$LIB" ]] && bash -n "$LIB"; then ok "bash -n kit/lib/resume.sh"; else bad "kit/lib/resume.sh tồn tại + syntax sạch"; fi

echo "=== lib: file handshake ==="
# Nạp lib trong subshell test — non-tty (stdin </dev/null) để đi nhánh file handshake.
run_gate() {  # $1=run_dir $2=agent $3=env_extra $4=pre_cmd(chạy nền trước poll)
  local run_dir="$1" agent="$2" env_extra="$3" pre="$4"
  bash -c "
    . '$LIB'
    export PAGENT_RUN_DIR='$run_dir' $env_extra
    $pre
    resume_gate '$agent' 'sid-123' 7 20 </dev/null
  " 2>/dev/null
}

# 1. decision resume → stdout đúng số lượt, pending + decision được dọn
d="$(mktemp -d)"
( sleep 0.5
  # đợi pending xuất hiện rồi mới ghi decision (mô phỏng web POST)
  for _ in $(seq 1 20); do [[ -f "$d/resume.pending.coder.json" ]] && break; sleep 0.2; done
  printf '{"action":"resume","extra_turns":25}' >"$d/resume.decision.coder.json.tmp"
  mv "$d/resume.decision.coder.json.tmp" "$d/resume.decision.coder.json"
) &
turns="$(run_gate "$d" coder "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=15" "")"
rc=$?
wait
if [[ $rc -eq 0 && "$turns" == "25" ]]; then ok "decision resume → trả 25 lượt"; else bad "decision resume" "rc=$rc turns=$turns"; fi
if [[ ! -e "$d/resume.pending.coder.json" && ! -e "$d/resume.decision.coder.json" ]]; then
  ok "cleanup pending + decision sau resume"
else bad "cleanup sau resume" "$(ls "$d")"; fi
rm -rf "$d"

# 2. pending file có đủ field cho web UI (agent, session_id, used_turns, default_turns)
d="$(mktemp -d)"
( for _ in $(seq 1 20); do [[ -f "$d/resume.pending.coder.json" ]] && break; sleep 0.2; done
  if jq -e '.agent=="coder" and .session_id=="sid-123" and .used_turns==7 and .default_turns==20' \
      "$d/resume.pending.coder.json" >/dev/null 2>&1; then touch "$d/.fields_ok"; fi
  printf '{"action":"stop"}' >"$d/resume.decision.coder.json"
) &
run_gate "$d" coder "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=15" "" >/dev/null
wait
if [[ -e "$d/.fields_ok" ]]; then ok "pending file đủ field {agent,session_id,used_turns,default_turns}"; else bad "pending file thiếu field" "$(cat "$d/resume.pending.coder.json" 2>/dev/null)"; fi
rm -rf "$d"

# 3. decision stop → return 1
d="$(mktemp -d)"
( for _ in $(seq 1 20); do [[ -f "$d/resume.pending.rev.json" ]] && break; sleep 0.2; done
  printf '{"action":"stop"}' >"$d/resume.decision.rev.json"
) &
if ! run_gate "$d" rev "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=15" "" >/dev/null; then
  ok "decision stop → return 1 (không resume)"
else bad "decision stop phải return 1"; fi
wait; rm -rf "$d"

# 4. timeout không có decision → return 1, pending được dọn
d="$(mktemp -d)"
start=$SECONDS
if ! run_gate "$d" coder "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=3" "" >/dev/null; then
  ok "timeout → return 1"
else bad "timeout phải return 1"; fi
(( SECONDS - start <= 10 )) && ok "timeout tôn trọng PAGENT_RESUME_TIMEOUT (~3s)" || bad "timeout quá lâu: $((SECONDS-start))s"
[[ ! -e "$d/resume.pending.coder.json" ]] && ok "cleanup pending sau timeout" || bad "còn sót pending sau timeout"
rm -rf "$d"

# 5. non-tty + PAGENT_RESUME không bật → return 1 NGAY (fail-fast, không treo)
d="$(mktemp -d)"
start=$SECONDS
if ! run_gate "$d" coder "PAGENT_RESUME_TIMEOUT=60" "" >/dev/null; then
  ok "gate off (non-tty, PAGENT_RESUME unset) → return 1 ngay"
else bad "gate off phải return 1"; fi
(( SECONDS - start <= 2 )) && ok "gate off không chờ" || bad "gate off bị treo $((SECONDS-start))s"
rm -rf "$d"

# 6. extra_turns rác/quá lớn → clamp [1, ceiling 60]; rỗng → default_turns
d="$(mktemp -d)"
( for _ in $(seq 1 20); do [[ -f "$d/resume.pending.coder.json" ]] && break; sleep 0.2; done
  printf '{"action":"resume","extra_turns":99999}' >"$d/resume.decision.coder.json"
) &
turns="$(run_gate "$d" coder "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=15" "")"
wait
[[ "$turns" == "60" ]] && ok "extra_turns 99999 → clamp 60" || bad "clamp ceiling" "got: $turns"
rm -rf "$d"

d="$(mktemp -d)"
( for _ in $(seq 1 20); do [[ -f "$d/resume.pending.coder.json" ]] && break; sleep 0.2; done
  printf '{"action":"resume"}' >"$d/resume.decision.coder.json"
) &
turns="$(run_gate "$d" coder "PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=15" "")"
wait
[[ "$turns" == "20" ]] && ok "extra_turns thiếu → dùng default_turns (20)" || bad "default_turns fallback" "got: $turns"
rm -rf "$d"

echo "=== call_agent tích hợp (grep-assert) ==="
assert_grep "pagent source kit/lib/resume.sh"            "$PAGENT" 'lib/resume\.sh'
assert_grep "detect subtype error_max_turns"             "$PAGENT" 'error_max_turns'
assert_grep "resume truyền --resume <session_id>"        "$PAGENT" '\-\-resume'
assert_grep "cap số vòng resume PAGENT_MAX_RESUME"       "$PAGENT" 'PAGENT_MAX_RESUME'
assert_grep "chỉ resume provider claude"                 "$PAGENT" 'provider.*==.*"claude"'

echo "=== e2e: fake claude bin — max_turns → resume → success ==="
# Fake claude: lần gọi KHÔNG --resume → error_max_turns; CÓ --resume → success.
# Fake này thay PAGENT_CLAUDE_BIN; pipeline find (2 bước) chạy trong sandbox project.
SB="$(mktemp -d)"
mkdir -p "$SB/src" "$SB/reports" "$SB/bin"
cat >"$SB/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude -p, stateful qua marker: CHỈ lần gọi -p ĐẦU TIÊN không --resume trả
# error_max_turns; resume và mọi lần sau trả success (reviewer/step sau chạy thẳng).
here="$(cd "$(dirname "$0")" && pwd)"
has_resume=0
for a in "$@"; do [[ "$a" == "--resume" || "$a" == "-r" ]] && has_resume=1; done
cat >/dev/null   # tiêu thụ stdin
if [[ "$1" == "--version" ]]; then echo "fake-claude 0.0.1"; exit 0; fi
if (( has_resume )); then
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"session_id":"sid-resumed","result":"{\\"title\\":\\"t\\",\\"summary\\":\\"s\\",\\"coder_task\\":\\"c\\",\\"reviewer_focus\\":\\"r\\",\\"risk\\":\\"low\\",\\"affected_paths\\":[]}"}'
elif [[ ! -e "$here/.first_done" ]]; then
  touch "$here/.first_done"
  printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":9,"session_id":"sid-first"}'
else
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"sid-later","result":"# tra loi - cau tra loi cua reviewer"}'
fi
FAKE
chmod +x "$SB/bin/claude"
git -C "$SB/src" init -q 2>/dev/null
# decision writer nền: đợi pending của orchestrator rồi duyệt resume
RUNS="$SB/reports/srcproj/runs"
( for _ in $(seq 1 100); do
    p="$(ls "$RUNS"/*/resume.pending.orchestrator.json 2>/dev/null | head -1)"
    [[ -n "$p" ]] && break; sleep 0.3
  done
  [[ -n "$p" ]] || exit 0
  printf '{"action":"resume","extra_turns":15}' >"${p%pending.orchestrator.json}decision.orchestrator.json"
) &
DECIDER=$!
out="$(cd "$SB/src" && PAGENT_PROJECT=srcproj PAGENT_REPORT_DIR="$SB/reports" \
  PAGENT_CLAUDE_BIN="$SB/bin/claude" PAGENT_PROVIDER=claude PAGENT_RESUME=1 PAGENT_RESUME_TIMEOUT=30 \
  PAGENT_NO_CONFIRM=1 PAGENT_KNOWLEDGE=0 \
  perl -e 'alarm 60; exec @ARGV' -- "$OLDPWD/$PAGENT" find "câu hỏi test" </dev/null 2>&1)"
rc=$?
wait "$DECIDER" 2>/dev/null
if [[ $rc -eq 0 ]]; then ok "e2e: pipeline find hoàn thành sau resume (rc=0)"; else bad "e2e: pipeline fail rc=$rc" "$(tail -5 <<<"$out")"; fi
if grep -q "resume" <<<"$out"; then ok "e2e: log có nhắc resume"; else bad "e2e: log không nhắc resume" "$(tail -5 <<<"$out")"; fi
# Run dir được bundle cuối pipeline → đọc session cuối của orchestrator từ tokens log
# (event end cuối phải là session ĐÃ resume, và trước đó có end của session gốc).
tok="$(cat "$SB/reports/srcproj/tokens/"*.jsonl 2>/dev/null)"
last_sid="$(jq -r 'select(.agent=="orchestrator" and .event=="end") | .session_id' <<<"$tok" 2>/dev/null | tail -1)"
if [[ "$last_sid" == "sid-resumed" ]]; then
  ok "e2e: kết quả cuối của orchestrator là session ĐÃ resume"
else bad "e2e: session cuối orchestrator không phải resume" "got: $last_sid"; fi
if jq -r 'select(.agent=="orchestrator" and .event=="end") | .session_id' <<<"$tok" 2>/dev/null | grep -q "sid-first"; then
  ok "e2e: tokens log giữ event của cả vòng gốc (sid-first) — pairing đủ"
else bad "e2e: thiếu event vòng gốc trong tokens log"; fi
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
