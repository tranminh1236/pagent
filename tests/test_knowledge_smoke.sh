#!/usr/bin/env bash
# Runtime smoke test cho knowledge/context-planning wiring trong `pagent`.
# KHÁC test_context_planning.sh (static grep-assertion): file này chạy THẬT
# — stub claude qua PAGENT_CLAUDE_BIN, dựng sandbox git + report dir tạm, gọi
# subcommand `pagent knowledge` end-to-end và exercise trực tiếp build_context_brief
# (source pagent trong bash) để kiểm cache + degrade.
#
# Không cần framework test; không spawn claude thật (stub emit result JSON).
# Stub ghi tên agent ($PAGENT_AGENT) vào $FAKE_CALLS → đếm số lần recompute.
#
# Bao phủ TESTER_TASK:
#   1. bash -n pagent parse sạch
#   2. `pagent knowledge show`/`refresh` khi .pagent/knowledge/ trống → no error
#   3. graceful degrade: skill thiếu / call fail → brief rỗng, pipeline không abort
#   4. cache: 2 lần liên tiếp cùng git/workflow/knowledge → cache hit (không recompute);
#      đổi 1 trong git/workflow/knowledge (+task) → invalidate → recompute
#   5. shellcheck nếu có

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGENT="$ROOT/pagent"

PASS=0; FAIL=0
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# ─── Sandbox ────────────────────────────────────────────────────────────────
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
SRC="$SB/src"; REP="$SB/reports"
mkdir -p "$SRC/.pagent" "$REP"
git -C "$SRC" init -q
git -C "$SRC" config user.email t@t; git -C "$SRC" config user.name t
echo hi >"$SRC/a.txt"
git -C "$SRC" add -A; git -C "$SRC" commit -qm init
printf '# Source Summary\nTest command: N/A\n' >"$SRC/.pagent/source-summary.md"

# Stub claude "good": bỏ qua --version (không đọc stdin → tránh block khi cmd_env),
# ngược lại nuốt prompt, log agent, emit result JSON hợp lệ (.result).
make_stub() { # $1=path  $2=good|bad
  cat >"$1" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && { echo "stub-claude 0.0"; exit 0; }; done
cat >/dev/null
printf '%s\n' "\${PAGENT_AGENT:-?}" >>"\${FAKE_CALLS:-/dev/null}"
STUB
  if [[ "$2" == good ]]; then
    echo 'printf '"'"'{"result":"STUB_OK for %s","total_cost_usd":0}\n'"'"' "${PAGENT_AGENT:-?}"' >>"$1"
  else
    echo 'printf '"'"'{"error":"boom","terminal_reason":"stub_fail"}\n'"'"'' >>"$1"
  fi
  chmod +x "$1"
}
make_stub "$SB/claude" good
make_stub "$SB/claude_bad" bad

export FAKE_CALLS="$SB/calls"; : >"$FAKE_CALLS"
export PAGENT_SOURCE="$SRC" PAGENT_PROJECT="proj" PAGENT_REPORT_DIR="$REP" PAGENT_KIT_DIR="$ROOT/kit"
export PAGENT_CLAUDE_BIN="$SB/claude"
export PAGENT_PROVIDER=claude   # test stub backend claude (backend mặc định giờ là opencode)
cp_calls() { grep -c context-planning "$FAKE_CALLS" 2>/dev/null || echo 0; }

# ─── 1. Parse ────────────────────────────────────────────────────────────────
echo "=== 1. bash -n parse ==="
if bash -n "$PAGENT" 2>/tmp/parse.$$; then ok "bash -n pagent parse sạch"; else fail "parse: $(cat /tmp/parse.$$)"; fi
rm -f /tmp/parse.$$

# ─── 2. knowledge show/refresh khi trống ─────────────────────────────────────
echo "=== 2. knowledge show/refresh (knowledge trống) ==="
out="$( ( cd "$SRC" && bash "$PAGENT" knowledge show ) 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "knowledge show exit 0 khi trống" || fail "knowledge show exit=$rc"
[[ "$out" == *"chưa có"* ]] && ok "show in placeholder cho file thiếu" || fail "show không có placeholder"
[[ "$out" == *workflow* && "$out" == *domain* && "$out" == *decisions* ]] \
  && ok "show liệt kê cả 3 file knowledge" || fail "show thiếu 1 trong 3 file"

: >"$FAKE_CALLS"
out="$( ( cd "$SRC" && bash "$PAGENT" knowledge refresh ) 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "knowledge refresh exit 0 khi trống" || fail "knowledge refresh exit=$rc"
[[ -d "$SRC/.pagent/knowledge" ]] && ok "refresh tạo dir .pagent/knowledge/" || fail "refresh không tạo dir"
grep -qx workflow-knowledge "$FAKE_CALLS" && ok "refresh dispatch workflow-knowledge" || fail "thiếu workflow-knowledge"
grep -qx domain-knowledge   "$FAKE_CALLS" && ok "refresh dispatch domain-knowledge"   || fail "thiếu domain-knowledge"
! grep -qx decision-log "$FAKE_CALLS" && ok "refresh KHÔNG chạy decision-log (append-only, cuối pipeline)" \
  || fail "refresh không nên chạy decision-log"

out="$( ( cd "$SRC" && bash "$PAGENT" knowledge bogus ) 2>&1 )"; rc=$?
[[ $rc -eq 0 && "$out" == *"pagent knowledge <action>"* ]] && ok "action lạ → in help, exit 0" || fail "bad action rc=$rc"

# ─── 3 & 4. Cache + degrade — exercise build_context_brief trực tiếp ─────────
# Source pagent trong bash (dispatch 'help' </dev/null: không spawn claude, không block).
echo "=== 3. cache hit / invalidation ==="
: >"$FAKE_CALLS"
cache_out="$(
  cd "$SRC"
  # shellcheck disable=SC1090
  source "$PAGENT" help </dev/null >/dev/null 2>&1
  set +e   # pagent bật set -e khi source; tắt để build fail (return 1) không abort subshell
  K(){ context_cache_key feature "add login"; }
  b0="$(K)"

  # run1 cold → spawn context-planning, viết cache
  build_context_brief feature "add login" >/dev/null 2>&1
  echo "cold=$(grep -c context-planning "$FAKE_CALLS")"
  # run2 cùng hash → cache hit, KHÔNG spawn thêm
  build_context_brief feature "add login" >/dev/null 2>&1
  echo "after_hit=$(grep -c context-planning "$FAKE_CALLS")"

  # invalidation từng factor
  echo x >>"$SRC/a.txt"; [[ "$(K)" != "$b0" ]] && echo "git=YES" || echo "git=NO"
  git -C "$SRC" checkout -q -- a.txt
  b1="$(K)"; [[ "$b1" == "$b0" ]] && echo "gitrevert=YES" || echo "gitrevert=NO"
  mkdir -p "$REP/proj"; echo wf >"$REP/proj/agent-workflow.md"
  w="$(K)"; [[ "$w" != "$b1" ]] && echo "workflow=YES" || echo "workflow=NO"
  mkdir -p "$SRC/.pagent/knowledge"; echo kn >"$SRC/.pagent/knowledge/domain.md"
  k="$(K)"; [[ "$k" != "$w" ]] && echo "knowledge=YES" || echo "knowledge=NO"
  [[ "$(context_cache_key feature OTHER)" != "$k" ]] && echo "task=YES" || echo "task=NO"

  # sau invalidation (knowledge đổi) → build phải recompute (miss), rồi hit
  : >"$FAKE_CALLS"
  build_context_brief feature "add login" >/dev/null 2>&1
  echo "recompute=$(grep -c context-planning "$FAKE_CALLS")"
  build_context_brief feature "add login" >/dev/null 2>&1
  echo "rehit=$(grep -c context-planning "$FAKE_CALLS")"
)"
get(){ printf '%s\n' "$cache_out" | grep "^$1=" | cut -d= -f2; }
[[ "$(get cold)"      == 1 ]] && ok "run1 cold → recompute (1 spawn)"            || fail "cold=$(get cold)"
[[ "$(get after_hit)" == 1 ]] && ok "run2 cùng hash → cache hit (0 spawn thêm)"  || fail "after_hit=$(get after_hit)"
[[ "$(get git)"       == YES ]] && ok "đổi git hash → invalidate"       || fail "git không invalidate"
[[ "$(get gitrevert)" == YES ]] && ok "revert git → key ổn định trở lại" || fail "git key không ổn định"
[[ "$(get workflow)"  == YES ]] && ok "đổi workflow hash → invalidate"  || fail "workflow không invalidate"
[[ "$(get knowledge)" == YES ]] && ok "đổi knowledge hash → invalidate" || fail "knowledge không invalidate"
[[ "$(get task)"      == YES ]] && ok "đổi task → key khác (brief lọc theo task)" || fail "task không đổi key"
[[ "$(get recompute)" == 1 ]] && ok "sau invalidate → recompute (1 spawn)" || fail "recompute=$(get recompute)"
[[ "$(get rehit)"     == 1 ]] && ok "chạy lại cùng key mới → cache hit (0 spawn)" || fail "rehit=$(get rehit)"

echo "=== 4. graceful degrade ==="
# A: skill context-planning THIẾU (kit rỗng) → build_context_brief return 1, brief rỗng
EMPTYKIT="$SB/emptykit"; mkdir -p "$EMPTYKIT/skills"
deg_a="$(
  cd "$SRC"
  export PAGENT_KIT_DIR="$EMPTYKIT"
  # shellcheck disable=SC1090
  source "$PAGENT" help </dev/null >/dev/null 2>&1
  set +e   # tắt set -e (bật khi source pagent) để nhánh degrade return 1 không abort
  b="$(build_context_brief feature t 2>/tmp/wa.$$)"; rc=$?
  # mô phỏng chính xác dòng pipeline dưới set -e (line ~868)
  set -e
  cb="$(build_context_brief feature t 2>/dev/null)" || cb=""
  set +e
  echo "rc=$rc|brief=[$b]|guarded=[$cb]|survived=YES"
  grep -q "context-planning skill thiếu" /tmp/wa.$$ && echo "warned=YES" || echo "warned=NO"
  rm -f /tmp/wa.$$
)"
[[ "$deg_a" == *"rc=1|brief=[]"* ]] && ok "skill thiếu → return 1, brief rỗng" || fail "degrade-A: $deg_a"
[[ "$deg_a" == *"survived=YES"* ]] && ok "dòng guarded '|| cb=\"\"' sống dưới set -e (pipeline không abort)" || fail "degrade-A abort"
[[ "$deg_a" == *"warned=YES"* ]] && ok "skill thiếu → warn (không die)" || fail "degrade-A không warn"

# B: claude call FAIL (JSON không .result) → return 1, brief rỗng, warn
deg_b="$(
  cd "$SRC"
  export PAGENT_CLAUDE_BIN="$SB/claude_bad"
  # dùng key mới để chắc chắn cache miss → thực sự gọi claude_bad
  echo more >>"$SRC/a.txt"
  # shellcheck disable=SC1090
  source "$PAGENT" help </dev/null >/dev/null 2>&1
  set +e   # tắt set -e (bật khi source pagent) để call fail return 1 không abort
  b="$(build_context_brief feature "fresh-task-b" 2>/tmp/wb.$$)"; rc=$?
  echo "rc=$rc|brief=[$b]"
  grep -q "context-planning fail" /tmp/wb.$$ && echo "warned=YES" || echo "warned=NO"
  rm -f /tmp/wb.$$
)"
[[ "$deg_b" == *"rc=1|brief=[]"* ]] && ok "claude fail → return 1, brief rỗng" || fail "degrade-B: $deg_b"
[[ "$deg_b" == *"warned=YES"* ]] && ok "claude fail → warn 'context-planning fail' (không die)" || fail "degrade-B không warn"

# ─── 5. shellcheck (nếu có) ──────────────────────────────────────────────────
echo "=== 5. shellcheck ==="
if command -v shellcheck >/dev/null; then
  if shellcheck -S error "$PAGENT" >/tmp/sc.$$ 2>&1; then ok "shellcheck (severity=error) sạch"
  else fail "shellcheck error: $(head -20 /tmp/sc.$$)"; fi
  rm -f /tmp/sc.$$
else
  echo "SKIP: shellcheck chưa cài"
fi

echo
echo "════════════════════════════════════"
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
