#!/usr/bin/env bash
# Tests cho flag opt-in PAGENT_SAVE_TOKEN (mặc định TẮT).
# Gate 2 trục: (1) dispatch gán model RẺ cho agent 'đơn giản' bằng list model từ gateway;
# (2) báo orchestrator nới guard (bỏ auditor cho nhiều task hơn).
# Bất biến: flag=0 → hành vi y hệt hiện tại (0 regression).

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
PAGENT="./pagent"

# Hermetic: gỡ mọi PAGENT_* runtime rò rỉ (khi test chạy BÊN TRONG 1 pipeline pagent),
# để auto-detect source/provider + gate flag chạy sạch như CI.
unset PAGENT_SOURCE PAGENT_PROVIDER PAGENT_MODE PAGENT_RUN_DIR PAGENT_TASK_ID \
      PAGENT_PARENT PAGENT_AGENT PAGENT_AGENT_PROVIDER PAGENT_AGENT_MODEL \
      PAGENT_CONFIRM PAGENT_PROJECT PAGENT_MODEL PAGENT_SAVE_TOKEN PAGENT_SAVE_TOKEN_MODELS

ok()  { echo "PASS: $1"; ((PASS++)); }
bad() { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; ((FAIL++)); }

# Source pagent chỉ để test hàm helper (cmd=help → in help rồi trả về, không exit).
# assignments đi qua `export` để tồn tại tới lời gọi hàm (prefix của `.` không bền vững).
srcfn() {  # $1=assignments (VAR=val ...), $2=lệnh gọi hàm → in stdout của hàm
  bash -c "set -- help; ${1:+export $1;} . '$ROOT/$PAGENT' >/dev/null 2>&1; $2"
}

echo "=== syntax ==="
if bash -n "$PAGENT"; then ok "bash -n pagent"; else bad "bash -n pagent"; fi

echo "=== unit: savetoken_is_simple (agent 'đơn giản' vs 'mạnh') ==="
for a in orchestrator docs workflow-extractor designer; do
  r="$(srcfn '' "if savetoken_is_simple $a; then echo simple; else echo strong; fi")"
  [[ "$r" == "simple" ]] && ok "simple: $a" || bad "phải là simple: $a" "got=$r"
done
for a in coder reviewer architecture performance security tester devops; do
  r="$(srcfn '' "if savetoken_is_simple $a; then echo simple; else echo strong; fi")"
  [[ "$r" == "strong" ]] && ok "mạnh (giữ model mạnh): $a" || bad "phải giữ model mạnh: $a" "got=$r"
done

echo "=== unit: savetoken_model_for — pick model rẻ + format theo provider ==="
# list có Claude (mạnh) + FREE (rẻ) → chọn FREE
m="$(srcfn "PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/FREE' PAGENT_MODEL=9router/Claude" "savetoken_model_for opencode")"
[[ "$m" == "9router/FREE" ]] && ok "opencode giữ provider prefix → 9router/FREE" || bad "opencode model_for sai" "got: '$m'"
m="$(srcfn "PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/FREE' PAGENT_MODEL=9router/Claude" "savetoken_model_for claude")"
[[ "$m" == "FREE" ]] && ok "claude dùng tên trần → FREE" || bad "claude model_for sai" "got: '$m'"
# ưu tiên free, kế đến haiku/mini/flash...
m="$(srcfn "PAGENT_SAVE_TOKEN_MODELS='big-model claude-haiku pro' PAGENT_MODEL=9router/Claude" "savetoken_model_for claude")"
[[ "$m" == "claude-haiku" ]] && ok "fallback keyword haiku khi không có free" || bad "pick cheap keyword sai" "got: '$m'"
# không có model rẻ → rỗng (fallback im)
m="$(srcfn "PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/Opus' PAGENT_MODEL=9router/Claude" "savetoken_model_for opencode")"
[[ -z "$m" ]] && ok "không có model rẻ → rỗng (fallback im lặng)" || bad "phải rỗng khi không có model rẻ" "got: '$m'"

echo "=== unit: PAGENT_SAVE_TOKEN default 0 sau khi source ==="
v="$(srcfn '' 'printf %s "${PAGENT_SAVE_TOKEN}"')"
[[ "$v" == "0" ]] && ok "PAGENT_SAVE_TOKEN mặc định 0" || bad "default phải 0" "got: '$v'"

#─── e2e harness: fake opencode dump argv per-agent ────────────────────────────
make_sandbox() {
  local SB; SB="$(mktemp -d)"
  mkdir -p "$SB/src" "$SB/reports" "$SB/bin" "$SB/ocargs"
  git -C "$SB/src" init -q 2>/dev/null
  cat >"$SB/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then echo "9.9.9-fake"; exit 0; fi
agent=""; prev=""
for a in "$@"; do [[ "$prev" == "--agent" ]] && agent="${a#pagent-}"; prev="$a"; done
[[ -n "${FAKE_OC_DIR:-}" && -n "$agent" ]] && printf '%s\n' "$@" >"$FAKE_OC_DIR/$agent.args"
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
      FAKE_OC_DIR='$SB/ocargs' $extra \
      perl -e 'alarm 40; exec @ARGV' -- '$ROOT/$PAGENT' find 'câu hỏi test' </dev/null" 2>&1 )
}

echo "=== e2e: flag ON → orchestrator (simple) nhận model RẺ ==="
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN=1 PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/FREE'" >/dev/null
oa="$(cat "$SB/ocargs/orchestrator.args" 2>/dev/null)"
if grep -q "^9router/FREE$" <<<"$oa" && ! grep -q "^9router/Claude$" <<<"$oa"; then
  ok "orchestrator -m = model rẻ 9router/FREE khi flag ON"
else bad "orchestrator phải nhận model rẻ khi flag ON" "$oa"; fi
rm -rf "$SB"

echo "=== e2e: flag OFF (mặc định) → orchestrator giữ model đầy đủ (0 regression) ==="
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/FREE'" >/dev/null
oa="$(cat "$SB/ocargs/orchestrator.args" 2>/dev/null)"
if grep -q "^9router/Claude$" <<<"$oa" && ! grep -q "^9router/FREE$" <<<"$oa"; then
  ok "flag OFF: orchestrator giữ 9router/Claude (không siết token)"
else bad "flag OFF phải giữ model gốc" "$oa"; fi
rm -rf "$SB"

echo "=== e2e: flag ON nhưng không lấy được list model → fallback im (model gốc) ==="
SB="$(make_sandbox)"
# không PAGENT_SAVE_TOKEN_MODELS + không ANTHROPIC_BASE_URL → list rỗng
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN=1 ANTHROPIC_BASE_URL=" >/dev/null
oa="$(cat "$SB/ocargs/orchestrator.args" 2>/dev/null)"
if grep -q "^9router/Claude$" <<<"$oa"; then
  ok "list rỗng → fallback im về model gốc (không fail run)"
else bad "fallback phải giữ model gốc khi không lấy được list" "$oa"; fi
rm -rf "$SB"

echo "=== e2e: flag ON → inject [RUNTIME] PAGENT_SAVE_TOKEN vào orchestrator prompt ==="
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN=1 PAGENT_SAVE_TOKEN_MODELS='9router/FREE'" >/dev/null
af="$SB/src/.opencode/agents/pagent-orchestrator.md"
if grep -q 'PAGENT_SAVE_TOKEN=1' "$af" 2>/dev/null; then
  ok "orchestrator prompt có tín hiệu [RUNTIME] PAGENT_SAVE_TOKEN=1"
else bad "thiếu tín hiệu PAGENT_SAVE_TOKEN trong orchestrator prompt" "$(grep RUNTIME "$af" 2>/dev/null)"; fi
rm -rf "$SB"

echo "=== static: .env.pagent + example khai báo PAGENT_SAVE_TOKEN (default 0) ==="
for f in .env.pagent .env.pagent.example; do
  if grep -qE 'PAGENT_SAVE_TOKEN=0' "$ROOT/$f"; then ok "$f khai PAGENT_SAVE_TOKEN=0"; else bad "$f thiếu PAGENT_SAVE_TOKEN=0"; fi
done

echo "=== static: orchestrator.md có nhánh PAGENT_SAVE_TOKEN (nới guard) ==="
if grep -q 'PAGENT_SAVE_TOKEN' "$ROOT/kit/agents/orchestrator.md"; then
  ok "orchestrator.md tham chiếu PAGENT_SAVE_TOKEN"
else bad "orchestrator.md thiếu nhánh PAGENT_SAVE_TOKEN"; fi

#─── tester-added: invariant kit-agents-drop-model + tín hiệu guard + fetch thật ─────────
# helper: dòng frontmatter (giữa 2 dấu ---) của agent md sinh cho opencode
oc_frontmatter() {  # $1=path → in phần frontmatter
  awk 'BEGIN{p=0} /^---$/{p++; next} p==1{print} p>=2{exit}' "$1"
}

echo "=== e2e (b): flag ON gán model RẺ NHƯNG KHÔNG chèn 'model:' vào frontmatter ==="
# Bất biến kit-agents-drop-model (f7836cd): model rẻ đi qua -m ở DISPATCH, KHÔNG vào frontmatter.
# test_opencode_backend khẳng định opencode không lấy model từ frontmatter → save-token phải giữ đúng.
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN=1 PAGENT_SAVE_TOKEN_MODELS='9router/Claude 9router/FREE'" >/dev/null
af="$SB/src/.opencode/agents/pagent-orchestrator.md"
oa="$(cat "$SB/ocargs/orchestrator.args" 2>/dev/null)"
if grep -q "^9router/FREE$" <<<"$oa" && ! oc_frontmatter "$af" | grep -qiE '^[[:space:]]*model:'; then
  ok "flag ON: model rẻ qua -m nhưng frontmatter KHÔNG có key model:"
else bad "flag ON không được ghi model: vào frontmatter (phải qua -m)" \
     "argv: $oa" "frontmatter: $(oc_frontmatter "$af" 2>/dev/null)"; fi
rm -rf "$SB"

echo "=== e2e (a): flag OFF → orchestrator nhận tín hiệu [RUNTIME] PAGENT_SAVE_TOKEN=0 (guard nguyên) ==="
# Đối xứng với test inject ON: flag OFF phải báo orchestrator guard KHÔNG bị siết.
SB="$(make_sandbox)"
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN_MODELS='9router/FREE'" >/dev/null
af="$SB/src/.opencode/agents/pagent-orchestrator.md"
# anchor vào dòng inject [RUNTIME] (body orchestrator.md có prose nhắc cả =1 lẫn =0)
rt="$(grep -E '^\[RUNTIME\] PAGENT_SAVE_TOKEN=' "$af" 2>/dev/null)"
if [[ "$rt" == '[RUNTIME] PAGENT_SAVE_TOKEN=0' ]]; then
  ok "flag OFF: orchestrator prompt báo [RUNTIME] PAGENT_SAVE_TOKEN=0 (không siết guard)"
else bad "flag OFF phải inject [RUNTIME] PAGENT_SAVE_TOKEN=0" "got: '${rt:-<không thấy dòng RUNTIME>}'"; fi
rm -rf "$SB"

echo "=== e2e (c): flag ON + fetch model list THẤT BẠI (curl chạy thật, base_url chết) → fallback không fail ==="
# Khác test 'list rỗng' (ANTHROPIC_BASE_URL rỗng → short-circuit trước curl): ở đây base_url
# TỒN TẠI nhưng chết → curl thực sự chạy + fail → savetoken_list_models trả rỗng → giữ model gốc.
SB="$(make_sandbox)"
rc=0
run_find "$SB" "PAGENT_MODEL=9router/Claude PAGENT_SAVE_TOKEN=1 PAGENT_SAVE_TOKEN_MODELS= ANTHROPIC_BASE_URL=http://127.0.0.1:9" >/dev/null || rc=$?
oa="$(cat "$SB/ocargs/orchestrator.args" 2>/dev/null)"
if [[ -n "$oa" ]] && grep -q "^9router/Claude$" <<<"$oa" && ! grep -q "^9router/FREE$" <<<"$oa"; then
  ok "fetch fail (curl→gateway chết) → run vẫn chạy, orchestrator giữ model gốc (rc=$rc)"
else bad "fetch fail phải fallback im về model gốc, không làm hỏng run" "rc=$rc" "argv: ${oa:-<orchestrator không chạy>}"; fi
rm -rf "$SB"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
