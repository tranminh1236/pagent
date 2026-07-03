#!/usr/bin/env bash
# Tests for the two-phase parallel review layer wiring in pagent:
#   PHA 0: architecture/performance/security audit baseline SONG SONG → Leader Code (reviewer)
#          chưng CODE_RULES → inject vào coder.
#   PHA 1: 3 auditor review diff SONG SONG → Leader Code cân đối verdict.
# Static-assertion style (no claude spawn) — verifies dispatcher source + synced docs.

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; echo "      expected literal: $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}
assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc"; echo "      expected regex: $pattern"; echo "      in file: $file"; ((FAIL++))
  fi
}
assert_count_ge() {
  local desc="$1" file="$2" pattern="$3" min="$4" n
  n="$(grep -cE "$pattern" "$file")"
  if (( n >= min )); then
    echo "PASS: $desc ($n ≥ $min)"; ((PASS++))
  else
    echo "FAIL: $desc (got $n, want ≥ $min)"; echo "      regex: $pattern"; ((FAIL++))
  fi
}
assert_absent() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "FAIL: $desc"; echo "      must NOT contain literal: $pattern"; ((FAIL++))
  else
    echo "PASS: $desc"; ((PASS++))
  fi
}

cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"
SUMMARY="./.pagent/source-summary.md"
INDEX="./kit/web/index.html"
APPJS="./kit/web/app.js"

echo "=== pagent — helpers ==="
assert_grep "resolve_agent_md defined"            "$PAGENT" '^resolve_agent_md\(\)'
assert_grep "agent_meta defined"                  "$PAGENT" '^agent_meta\(\)'

echo ""
echo "=== pagent — ENABLED_AUDITORS gating ==="
assert_grep "auditors loop architecture/performance/security" "$PAGENT" 'for _aud in architecture performance security'
assert_contains "ENABLED_AUDITORS gated by agent_enabled"     "$PAGENT" 'agent_enabled "$_aud" && ENABLED_AUDITORS'

echo ""
echo "=== pagent — shared review budget + per-agent override ==="
assert_contains "eff_max_round seeded from shared budget" "$PAGENT" 'local eff_max_round="$PAGENT_MAX_REVIEW_ROUND"'
assert_contains "override read from reviewer.md frontmatter" "$PAGENT" 'agent_meta reviewer max_review_round'
assert_contains "loop condition uses eff_max_round"        "$PAGENT" 'while (( round <= eff_max_round ))'
assert_contains "post-loop warn uses eff_max_round"        "$PAGENT" '(( eff_max_round > 0 ))'

echo ""
echo "=== pagent — PHA 0 baseline audit → CODE_RULES ==="
assert_contains "code_rules reset each run"        "$PAGENT" 'rm -f "$PAGENT_RUN_DIR/code_rules.txt"'
assert_grep    "PHA 0 gated by review + auditors"  "$PAGENT" 'review_enabled \)\) && \(\( \$\{#ENABLED_AUDITORS\[@\]\} > 0'
assert_grep    "auditor invoked with PHASE 0"      "$PAGENT" 'echo "## PHASE"; echo 0'
assert_contains "Leader Code output saved as CODE_RULES" "$PAGENT" 'cp "$PAGENT_RUN_DIR/reviewer.txt" "$PAGENT_RUN_DIR/code_rules.txt"'
assert_contains "auditor report header ARCHITECTURE" "$PAGENT" '## ARCHITECTURE_REPORT'
assert_contains "auditor report header PERFORMANCE"  "$PAGENT" '## PERFORMANCE_REPORT'
assert_contains "auditor report header SECURITY"     "$PAGENT" '## SECURITY_REPORT'

echo ""
echo "=== pagent — CODE_RULES injected into coder (both branches) ==="
# single coder + fan-out subtask coder → at least 2 injection sites
assert_count_ge "coder consumes code_rules.txt" "$PAGENT" 'cat "\$PAGENT_RUN_DIR/code_rules.txt"' 2

echo ""
echo "=== pagent — PHA 1 diff review SONG SONG → verdict ==="
assert_grep    "auditor invoked with PHASE 1"       "$PAGENT" 'echo "## PHASE"; echo 1'
assert_contains "auditor diff review sees CODER_OUTPUT" "$PAGENT" 'echo "## CODER_OUTPUT"; cat "$PAGENT_RUN_DIR/coder.txt"'
assert_contains "Leader Code synthesizes verdict"   "$PAGENT" 'Leader Code (reviewer) cân đối verdict'
# Verdict parse MUST anchor to the "## VERDICT" block (read token on/after that header),
# NOT grep the whole reviewer.txt (a stray APPROVED in CODE_RULES/FINDINGS would leak a
# false pass). Fail-closed to CHANGES_REQUESTED when the token is absent.
assert_contains "verdict parse anchored to ## VERDICT block" "$PAGENT" '/^##[[:space:]]*VERDICT/'
assert_absent   "verdict no longer greps whole reviewer.txt" "$PAGENT" "grep -oE 'APPROVED|CHANGES_REQUESTED' \"\$PAGENT_RUN_DIR/reviewer.txt\""
assert_grep     "verdict fail-closed default CHANGES_REQUESTED" "$PAGENT" 'verdict="CHANGES_REQUESTED"'

echo ""
echo "=== pagent — parallel execution (background + wait) ==="
# each phase spawns auditors in background and waits on collected pids
assert_count_ge "background auditor spawns"  "$PAGENT" '_pids\+=\(\$!\)' 2
assert_count_ge "wait on auditor pids"       "$PAGENT" 'wait "\$_p"' 2

echo ""
echo "=== pagent — SKIPPED break precedes PHA 1 (no orphan audit) ==="
# The review_enabled==0 break must appear before the PHA 1 auditor loop.
skip_ln="$(grep -n 'verdict="SKIPPED"' "$PAGENT" | head -1 | cut -d: -f1)"
pha1_ln="$(grep -n 'pha1 review diff SONG SONG' "$PAGENT" | head -1 | cut -d: -f1)"
if [[ -n "$skip_ln" && -n "$pha1_ln" && "$skip_ln" -lt "$pha1_ln" ]]; then
  echo "PASS: SKIPPED break (line $skip_ln) precedes PHA 1 (line $pha1_ln)"; ((PASS++))
else
  echo "FAIL: SKIPPED break must precede PHA 1 (skip=$skip_ln pha1=$pha1_ln)"; ((FAIL++))
fi

echo ""
echo "=== docs — help + source-summary + web synced ==="
assert_grep    "help PIPELINE mentions PHA 0"   "$PAGENT" 'PHA 0.*audit baseline SONG SONG'
assert_grep    "help PIPELINE mentions PHA 1"   "$PAGENT" 'PHA 1.*review diff SONG SONG'
assert_contains "help mentions max_review_round override" "$PAGENT" 'reviewer.md có thể'
assert_contains "summary lists architecture agent" "$SUMMARY" 'architecture.md'
assert_contains "summary lists performance agent"  "$SUMMARY" 'performance.md'
assert_contains "summary lists security agent"     "$SUMMARY" 'security.md'
assert_contains "summary reviewer is Leader Code"  "$SUMMARY" 'Leader Code'
assert_contains "web index roster synced"          "$INDEX"   'architecture‖performance‖security'
assert_contains "web app roster synced"            "$APPJS"   'architecture‖performance‖security'

echo ""
echo "=== behavioral — PHA 0 parallel audit → Leader Code aggregates → coder injection ==="
# Mirrors the dispatcher: 3 auditors run in background (parallel), each writes its own
# <agent>.txt, Leader Code PHA 0 aggregates all three under *_REPORT headers → CODE_RULES,
# which is then injected into the coder input. Proves no report is lost across the parallel
# fan-in and that CODE_RULES reaches the coder.
SIM="$(mktemp -d)"; RUN="$SIM"
AUD=(architecture performance security)
stub_ca() { local a="$1"; printf 'REPORT-%s\n' "$a" >"$RUN/$a.txt"; }   # call_agent side-effect
pids=()
for a in "${AUD[@]}"; do ( stub_ca "$a" ) & pids+=($!); done            # SONG SONG spawn
for p in "${pids[@]}"; do wait "$p"; done                               # fan-in barrier
{
  for a in "${AUD[@]}"; do
    case "$a" in
      architecture) echo "## ARCHITECTURE_REPORT" ;;
      performance)  echo "## PERFORMANCE_REPORT" ;;
      security)     echo "## SECURITY_REPORT" ;;
    esac
    [[ -s "$RUN/$a.txt" ]] && cat "$RUN/$a.txt" || echo "(auditor $a không có baseline)"
    echo
  done
} >"$RUN/leader_input.txt"
printf '## CODE_RULES\n- [MUST] (sec) validate input\n' >"$RUN/reviewer.txt"  # Leader Code PHA0 out
cp "$RUN/reviewer.txt" "$RUN/code_rules.txt"
{ echo "## TASK"; echo "do x"; [[ -s "$RUN/code_rules.txt" ]] && { cat "$RUN/code_rules.txt"; echo; }; } >"$RUN/coder_input.txt"

miss=0
for a in architecture performance security; do
  grep -q "REPORT-$a" "$RUN/leader_input.txt" || { miss=1; echo "      missing REPORT-$a in Leader Code input"; }
done
(( miss == 0 )) && ok "all 3 auditor reports reach Leader Code PHA 0 input (parallel fan-in intact)" \
                || fail "an auditor report was lost before Leader Code synthesis"
grep -qF '## CODE_RULES' "$RUN/coder_input.txt" && ok "CODE_RULES injected into coder input" \
                                                 || fail "CODE_RULES not injected into coder input"
# validate: empty ENABLED_AUDITORS → no auditor headers, coder still gets no CODE_RULES (alone-review path)
rm -f "$RUN/code_rules.txt"
{ echo "## TASK"; echo "y"; [[ -s "$RUN/code_rules.txt" ]] && { cat "$RUN/code_rules.txt"; echo; }; } >"$RUN/coder_alone.txt"
grep -qF '## CODE_RULES' "$RUN/coder_alone.txt" && fail "CODE_RULES leaked when none produced" \
                                                 || ok "no CODE_RULES injected when auditors absent (safe fallback)"
rm -rf "$SIM"

echo ""
echo "=== agent frontmatter — 3 auditor read-only + override field parse ==="
# md_meta copy verbatim từ pagent (lines 74-79) — test parse frontmatter độc lập không spawn.
md_meta() {
  awk -v k="$2" '
    /^---$/{p++; next}
    p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }
  ' "$1"
}
for _a in architecture performance security; do
  _md="./kit/agents/$_a.md"
  [[ -f "$_md" ]] && ok "$_a.md tồn tại" || { fail "$_a.md thiếu"; continue; }
  # (1) YAML frontmatter hợp lệ: các field cốt lõi parse ra non-empty
  [[ "$(md_meta "$_md" name)" == "$_a" ]] \
    && ok "$_a: name khớp file (frontmatter parse được)" \
    || fail "$_a: name không parse ra '$_a'"
  [[ -n "$(md_meta "$_md" model)" ]]       && ok "$_a: model parse được"       || fail "$_a: model rỗng"
  _tools="$(md_meta "$_md" allowed_tools)"
  [[ -n "$_tools" ]]                        && ok "$_a: allowed_tools parse được" || fail "$_a: allowed_tools rỗng"
  # (2) read-only: allowed_tools KHÔNG chứa công cụ ghi
  if [[ "$_tools" =~ (Edit|Write|NotebookEdit) ]]; then
    fail "$_a: allowed_tools chứa write-tool → KHÔNG read-only ($_tools)"
  else
    ok "$_a: read-only (không Edit/Write/NotebookEdit trong allowed_tools)"
  fi
  # (3) override review-round: 3 auditor để COMMENTED (`# max_review_round`) → parse rỗng = kế thừa ngân sách chung
  [[ -z "$(md_meta "$_md" max_review_round)" ]] \
    && ok "$_a: max_review_round rỗng → kế thừa PAGENT_MAX_REVIEW_ROUND" \
    || fail "$_a: max_review_round không nên set (đang override ngoài ý muốn)"
  assert_grep "$_a: field override review-round có mặt dạng comment" "$_md" '^#[[:space:]]*max_review_round:'
done
# (3b) md_meta THỰC SỰ parse được override khi field bật (không phải luôn rỗng) — chống false-negative test trên
_tmp="$(mktemp)"; printf -- '---\nname: x\nmax_review_round: 3\n---\nbody\n' >"$_tmp"
[[ "$(md_meta "$_tmp" max_review_round)" == "3" ]] \
  && ok "md_meta parse được max_review_round khi field bật (=3)" \
  || fail "md_meta không parse được override khi field bật"
rm -f "$_tmp"

echo ""
echo "=== orchestrator plan — schema mở rộng: audit_focus + business_context ==="
# Plan JSON mở rộng: required_agents gồm 3 auditor + reviewer, audit_focus map per-auditor, business_context.
PLAN_EXT='{"title":"t","coder_task":"c","reviewer_focus":"correctness","required_agents":["architecture","performance","security","reviewer","coder"],"audit_focus":{"architecture":"layer boundaries","performance":"hot path N+1","security":"authz theo business"},"business_context":"e-commerce checkout","tester_task":"","risk":"high","affected_paths":[]}'
jq -e '.audit_focus | type == "object"' <<<"$PLAN_EXT" >/dev/null 2>&1 \
  && ok "audit_focus là object (schema mở rộng parse được)" \
  || fail "audit_focus phải là object"
# Dispatcher đọc focus theo từng auditor: jq -r --arg k "$_a" '.audit_focus[$k] // ""' (pagent:1097,1199)
for _a in architecture performance security; do
  _f="$(jq -r --arg k "$_a" '.audit_focus[$k] // ""' <<<"$PLAN_EXT" 2>/dev/null)"
  [[ -n "$_f" ]] && ok "audit_focus[$_a] đọc được: '$_f'" \
                 || fail "audit_focus[$_a] rỗng — dispatcher không lấy được focus"
done
# auditor thiếu focus → fallback rỗng (không lỗi jq)
[[ "$(jq -r --arg k "designer" '.audit_focus[$k] // ""' <<<"$PLAN_EXT" 2>/dev/null)" == "" ]] \
  && ok "audit_focus[missing] → rỗng an toàn (// \"\")" \
  || fail "audit_focus với key thiếu phải rỗng"
[[ "$(jq -r '.business_context // ""' <<<"$PLAN_EXT" 2>/dev/null)" == "e-commerce checkout" ]] \
  && ok "business_context parse được (Project Owner context)" \
  || fail "business_context không parse ra"
# Plan cũ KHÔNG có audit_focus → dispatcher fallback rỗng, không vỡ (backward-compat)
PLAN_OLD='{"title":"t","coder_task":"c","reviewer_focus":"r","required_agents":["coder","reviewer"],"tester_task":"","risk":"low","affected_paths":[]}'
[[ "$(jq -r --arg k "security" '.audit_focus[$k] // ""' <<<"$PLAN_OLD" 2>/dev/null)" == "" ]] \
  && ok "plan cũ thiếu audit_focus → focus rỗng (backward-compat)" \
  || fail "plan thiếu audit_focus phải fallback rỗng"

echo ""
echo "=== pagent — dispatcher đọc đúng field roles mới (audit_focus/business_context) ==="
assert_contains "dispatcher đọc audit_focus per-auditor" "$PAGENT" 'audit_focus[$k] // ""'
assert_grep    "dispatcher inject AUDIT_FOCUS vào auditor" "$PAGENT" 'echo "## AUDIT_FOCUS"'
assert_grep    "dispatcher inject BUSINESS_CONTEXT"        "$PAGENT" 'echo "## BUSINESS_CONTEXT"'
assert_contains "orchestrator parse business_context"     "$PAGENT" '.business_context // ""'

echo ""
echo "=== agent frontmatter — 4 read-only agents: NO bare Bash + write backstop ==="
# Quality gate is a sensitive flow: the 3 auditors + Leader Code (reviewer) must be
# read-only. allowed_tools must NOT carry a bare `Bash` (would let them run arbitrary
# shell), and disallowed_tools must backstop the write/shell tools (Write/Edit/
# NotebookEdit/Bash) so a soft prompt is not the only guard. Coder is the sole writer.
for _a in architecture performance security reviewer; do
  _md="./kit/agents/$_a.md"
  _tools="$(md_meta "$_md" allowed_tools)"
  _disallowed="$(md_meta "$_md" disallowed_tools)"
  # bare Bash = the token "Bash" not immediately followed by "(" (scoped Bash(git ...) is allowed)
  if echo "$_tools" | grep -qE '(^|[,[:space:]])Bash([,[:space:]]|$)'; then
    fail "$_a: allowed_tools chứa Bash trần ($_tools)"
  else
    ok "$_a: allowed_tools KHÔNG có Bash trần"
  fi
  for _wt in Write Edit NotebookEdit Bash; do
    if echo "$_disallowed" | grep -qE "(^|[,[:space:]])$_wt([,[:space:]]|\$)"; then
      ok "$_a: disallowed_tools backstop chặn $_wt"
    else
      fail "$_a: disallowed_tools thiếu backstop $_wt ($_disallowed)"
    fi
  done
  # perf SHOULD: auditor/reviewer khai max_turns (chặn token/vòng)
  [[ "$(md_meta "$_md" max_turns)" =~ ^[0-9]+$ ]] \
    && ok "$_a: max_turns khai báo (chặn token/vòng)" \
    || fail "$_a: max_turns thiếu/không phải số"
done

echo ""
echo "=== behavioral — verdict parse anchored to ## VERDICT (no false APPROVED) ==="
# Mirror the dispatcher parse: read the verdict token on/after the "## VERDICT" header only.
parse_verdict() {
  local v
  v="$(awk '
    /^##[[:space:]]*VERDICT/ { h=$0; sub(/^##[[:space:]]*VERDICT[[:space:]]*:?[[:space:]]*/,"",h);
                               if (h ~ /(APPROVED|CHANGES_REQUESTED)/) { print h; exit } f=1; next }
    f && NF { print; exit }
  ' "$1" | grep -oE 'CHANGES_REQUESTED|APPROVED' | head -1)"
  [[ -n "$v" ]] || v="CHANGES_REQUESTED"
  printf '%s' "$v"
}
VT="$(mktemp)"
# (a) VERDICT=CHANGES_REQUESTED but APPROVED appears in CODE_RULES/NOTES → must NOT read APPROVED
printf '## CODE_RULES\n- rule mentioning APPROVED path\n\n## VERDICT\nCHANGES_REQUESTED\n\n## FINDINGS\n- [BLOCKING] x\n' >"$VT"
[[ "$(parse_verdict "$VT")" == "CHANGES_REQUESTED" ]] \
  && ok "stray APPROVED in CODE_RULES không leak (verdict=CHANGES_REQUESTED)" \
  || fail "stray APPROVED leaked → false pass"
# (b) genuine APPROVED on line after header → APPROVED
printf '## VERDICT\nAPPROVED\n\n## FINDINGS\n' >"$VT"
[[ "$(parse_verdict "$VT")" == "APPROVED" ]] \
  && ok "genuine APPROVED đọc đúng" || fail "APPROVED không parse ra"
# (c) token on same line as header (## VERDICT: APPROVED)
printf '## VERDICT: APPROVED\n' >"$VT"
[[ "$(parse_verdict "$VT")" == "APPROVED" ]] \
  && ok "verdict cùng dòng header đọc được" || fail "verdict cùng dòng không parse"
# (d) no VERDICT block at all → fail-closed CHANGES_REQUESTED
printf '## FINDINGS\n- nothing\n' >"$VT"
[[ "$(parse_verdict "$VT")" == "CHANGES_REQUESTED" ]] \
  && ok "thiếu VERDICT → fail-closed CHANGES_REQUESTED" || fail "thiếu VERDICT không fail-closed"
rm -f "$VT"

echo ""
echo "=== pagent — eff_max_round clamp [1,cap] (source + behavioral) ==="
# eff_max_round PHẢI bị kẹp vào [1, cap]; cap mặc định 5, override PAGENT_MAX_REVIEW_ROUND_CAP.
# 0 vòng = coder không chạy lần nào (spec CODE_RULES ghi [1,N]); vượt cap = phồng token/chi phí.
assert_contains "cap default 5 + override PAGENT_MAX_REVIEW_ROUND_CAP" "$PAGENT" 'local _round_cap="${PAGENT_MAX_REVIEW_ROUND_CAP:-5}"'
assert_contains "clamp floor: eff_max_round < 1 → 1"                    "$PAGENT" '(( eff_max_round < 1 )) && eff_max_round=1'
assert_grep    "clamp ceil: eff_max_round > cap → cap"                  "$PAGENT" '\(\( eff_max_round > _round_cap \)\).*eff_max_round="\$_round_cap"'
assert_grep    "non-numeric eff_max_round → floor 1 (fail-safe)"        "$PAGENT" 'eff_max_round=~.*\|\| eff_max_round=1|\^\[0-9\]\+\$.*\|\| eff_max_round=1'
# behavioral — mirror pagent:1030-1033
clamp_round() { local eff="$1" cap="${2:-5}"; [[ "$eff" =~ ^[0-9]+$ ]] || eff=1; (( eff < 1 )) && eff=1; (( eff > cap )) && eff="$cap"; printf '%s' "$eff"; }
[[ "$(clamp_round 0)"    == "1" ]] && ok "clamp 0 → 1 (coder chạy ≥1 vòng)"        || fail "clamp 0 phải ra 1"
[[ "$(clamp_round '')"   == "1" ]] && ok "clamp rỗng → 1 (fail-safe non-numeric)"  || fail "clamp rỗng phải ra 1"
[[ "$(clamp_round abc)"  == "1" ]] && ok "clamp non-numeric → 1"                   || fail "clamp non-numeric phải ra 1"
[[ "$(clamp_round 3)"    == "3" ]] && ok "clamp 3 → 3 (trong dải, giữ nguyên)"     || fail "clamp 3 phải giữ 3"
[[ "$(clamp_round 99)"   == "5" ]] && ok "clamp 99 → 5 (cap mặc định)"             || fail "clamp 99 phải ra 5"
[[ "$(clamp_round 99 8)" == "8" ]] && ok "clamp 99 (cap=8) → 8 (override cap)"     || fail "clamp cap override sai"
[[ "$(clamp_round 2 8)"  == "2" ]] && ok "clamp 2 (cap=8) → 2 (dưới cap, giữ)"     || fail "clamp 2 dưới cap phải giữ"

echo ""
echo "=== pagent — CODE_RULES count section-scoped (không phồng bởi TRADEOFFS/NOTES) ==="
# Đếm "N luật" CHỈ trong block "## CODE_RULES"; bullet trong TRADEOFFS/NOTES không được cộng dồn.
assert_contains "rule count awk section-scoped tới CODE_RULES" "$PAGENT" '/^##[[:space:]]+CODE_RULES/{f=1;next} /^##[[:space:]]/{f=0} f&&/^-[[:space:]]/{c++}'
count_rules() { awk '/^##[[:space:]]+CODE_RULES/{f=1;next} /^##[[:space:]]/{f=0} f&&/^-[[:space:]]/{c++} END{print c+0}' "$1"; }
CR="$(mktemp)"
printf '## CODE_RULES\n- [MUST] validate input\n- [SHOULD] no bare Bash\n\n## TRADEOFFS\n- gave up caching\n- deferred retry\n\n## NOTES\n- model=opus pre-existing\n' >"$CR"
[[ "$(count_rules "$CR")" == "2" ]] \
  && ok "đếm đúng 2 luật (bỏ 2 TRADEOFFS + 1 NOTES bullet)" \
  || fail "rule count phồng bởi TRADEOFFS/NOTES (got $(count_rules "$CR"), want 2)"
printf '## NOTES\n- không có block CODE_RULES\n' >"$CR"
[[ "$(count_rules "$CR")" == "0" ]] \
  && ok "không có block CODE_RULES → 0 luật (không đếm nhầm NOTES)" \
  || fail "thiếu CODE_RULES phải ra 0 (got $(count_rules "$CR"))"
rm -f "$CR"

echo ""
echo "=== pagent — diff snapshot 1×/vòng: auditor/reviewer cat lại, không 3× git diff SONG SONG ==="
# Snapshot diff MỘT lần/vòng ra diff.snapshot (+ diff.full); mọi auditor SONG SONG + Leader Code
# `cat` lại (read-only, không đua ghi) thay vì mỗi cái tự chạy git diff → chốt token + tránh race.
assert_contains "snapshot head -500 ghi 1 lần vào diff.snapshot" "$PAGENT" 'head -n 500 "$_diff_full" >"$_diff_snap"'
assert_contains "diff.full giữ bản đầy đủ để tra sau"            "$PAGENT" 'git_diff_full >"$_diff_full"'
# auditor + reviewer đọc snapshot bằng cat (≥2 site: auditor loop + reviewer alone-path)
assert_count_ge "auditor/reviewer cat diff.snapshot (không tự git diff)" "$PAGENT" 'cat "\$_diff_snap"' 2
assert_grep    "cảnh báo khi cắt >500 dòng (không cắt im lặng)" "$PAGENT" 'git diff > 500 dòng'
# invariant song song còn nguyên: file diff dùng chung chỉ đọc → không có git diff bên trong vòng lặp auditor
_pha1_body="$(awk '/pha1 review diff SONG SONG/{f=1} f&&/Leader Code \(reviewer\) cân đối verdict/{exit} f' "$PAGENT")"
if grep -qE '(git[_ ]diff|git diff)' <<<"$_pha1_body"; then
  fail "vòng auditor PHA1 vẫn chạy git diff trực tiếp (phải cat snapshot)"
else
  ok "vòng auditor PHA1 không git diff trực tiếp — dùng snapshot dùng chung"
fi

echo ""
echo "=== pagent — vòng lặp coder↔review ép sửa: re-inject PREVIOUS_REVIEW ở round>1 ==="
# CHANGES_REQUESTED → vòng sau coder nhận lại review cũ như danh sách lỗi bắt buộc + chỉ thị fix
# BLOCKING/MAJOR, lặp tới eff_max_round. Không APPROVE sau hết vòng → vẫn tiếp tục để tester verify.
assert_grep    "round>1 mới inject review cũ (không inject vòng đầu)" "$PAGENT" 'if \(\( round > 1 \)\); then'
assert_contains "coder round>1 nhận PREVIOUS_REVIEW = review trước"   "$PAGENT" 'echo "## PREVIOUS_REVIEW"; cat "$PAGENT_RUN_DIR/reviewer.txt"'
assert_grep    "chỉ thị ép fix BLOCKING/MAJOR rồi xuất CHANGES mới"   "$PAGENT" 'Fix các điểm BLOCKING/MAJOR'
assert_contains "loop tới eff_max_round tới khi APPROVED"             "$PAGENT" 'while (( round <= eff_max_round )) && [[ "$verdict" != "APPROVED" ]]'
assert_grep    "hết vòng chưa APPROVE → warn + tiếp tục (không chặn tester)" "$PAGENT" 'chưa APPROVE sau .* vòng'

echo ""
echo "=== agent security.md — luật không lộ secret/token/PII verbatim ==="
# Report auditor có thể ghi ra Markdown/web dashboard → security PHẢI chỉ trích file:line, không dán secret.
SEC="./kit/agents/security.md"
assert_contains "security.md có luật không lộ secret khi report" "$SEC" 'Không lộ secret khi report'
assert_grep    "security.md cấm in secret/token/PII verbatim"    "$SEC" 'KHÔNG in giá trị verbatim'
assert_grep    "security.md yêu cầu chỉ trích vị trí file:line"  "$SEC" 'file:line'

echo ""
echo "=== pagent — syntax ==="
if bash -n "$PAGENT"; then
  echo "PASS: pagent parses (bash -n)"; ((PASS++))
else
  echo "FAIL: pagent syntax error"; ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
