#!/usr/bin/env bash
# Smoke tests for Jira + GitLab task-reading MCP (pagent + kit/mcp + PAGENT_TASKS gate).
# Tests: JSON config validity, token env refs, orchestrator mcp_servers, gate logic, .env docs.

# ── Cô lập env ─────────────────────────────────────────────────────────────
# Suite này chạy được TỪ TRONG pipeline pagent, nơi PAGENT_*/JIRA_* đã export sẵn vào
# môi trường con. Gate MCP đọc thẳng `${!FLAG:-0}` → env leak làm test xanh/đỏ theo môi
# trường chứ không theo giá trị test đặt. Re-exec đúng 1 lần với `env -u` TƯỜNG MINH,
# XDG/OC_HOME riêng, và PATH có stub uvx/npx (không bao giờ spawn mcp-atlassian thật).
if [[ -z "${TASKMCP_ISOLATED:-}" ]]; then
  _self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/taskmcp.XXXXXX")"
  mkdir -p "$_tmp/bin" "$_tmp/xdg" "$_tmp/oc"
  for _c in uvx npx; do
    printf '#!/usr/bin/env bash\necho "STUB:%s (test must never spawn a real MCP server)" >&2\nexit 97\n' \
      "$_c" > "$_tmp/bin/$_c"
    chmod +x "$_tmp/bin/$_c"
  done
  exec env \
    -u PAGENT_TASKS -u PAGENT_DESIGN -u PAGENT_CONTEXT7 -u PAGENT_SOURCE -u PAGENT_PROJECT \
    -u PAGENT_MODEL -u PAGENT_PROVIDER -u PAGENT_KIT_DIR -u PAGENT_SAVE_TOKEN -u PAGENT_CAVEMAN \
    -u PAGENT_MODE -u PAGENT_REPORT_DIR -u PAGENT_SUPERPOWERS -u PAGENT_MAX_TURNS \
    -u PAGENT_NO_CONFIRM -u PAGENT_YES \
    -u JIRA_URL -u JIRA_PERSONAL_TOKEN -u JIRA_USERNAME -u JIRA_API_TOKEN -u JIRA_ALLOW_PRIVATE \
    -u GITLAB_API_URL -u GITLAB_PERSONAL_ACCESS_TOKEN -u FIGMA_API_KEY -u CANVAS_API_TOKEN \
    TASKMCP_ISOLATED=1 TASKMCP_TMP="$_tmp" \
    PATH="$_tmp/bin:$PATH" \
    XDG_CONFIG_HOME="$_tmp/xdg/config" XDG_DATA_HOME="$_tmp/xdg/data" \
    XDG_CACHE_HOME="$_tmp/xdg/cache" XDG_STATE_HOME="$_tmp/xdg/state" OC_HOME="$_tmp/oc" \
    bash "$_self" "$@"
fi
trap '[[ -n "${TASKMCP_TMP:-}" && "$TASKMCP_TMP" == */taskmcp.* ]] && rm -rf "$TASKMCP_TMP"' EXIT

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; ((FAIL++)); fi
}
assert_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" == *"$pattern"* ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected to contain: $pattern"; echo "      actual: $text"; ((FAIL++)); fi
}
assert_file_contains() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc — pattern not found: $pattern"; echo "      in file: $file"; ((FAIL++)); fi
}
assert_not_contains() {
  local desc="$1" pattern="$2" text="$3"
  if [[ "$text" != *"$pattern"* ]]; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected NOT to contain: $pattern"; echo "      actual: $text"; ((FAIL++)); fi
}
md_meta() {
  awk -v k="$2" '/^---$/{p++; next} p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }' "$1"
}

cd "$(dirname "$0")/.." || exit 1
REPO_DIR="$(pwd)"; KIT_DIR="$REPO_DIR/kit"

# Logic thật extract từ pagent (không hardcode lại) — mirror sai = test xanh mà runtime khác.
extract_fn() {
  awk -v fn="$1" 'match($0, "^"fn"\\(\\)") {p=1} p{print} p&&/^}$/{exit}' "$REPO_DIR/pagent"
}
eval "$(extract_fn _is_truthy)"
eval "$(extract_fn expand_kit_dir)"

echo "=== Jira/GitLab task-MCP smoke tests ==="

# ── 1. jira.json + gitlab.json valid JSON + structure ───────────────────────
# Tên env DERIVE từ JSON (không hardcode trong test): JSON là source of truth, mỗi key
# dạng ${...} phải được document trong .env.pagent.example.
for spec in "jira|uvx" "gitlab|npx"; do
  name="${spec%%|*}"; cmd="${spec##*|}"
  f="$KIT_DIR/mcp/$name.json"
  echo "--- $name.json ---"
  if [[ -f "$f" ]] && jq . "$f" >/dev/null 2>&1; then
    echo "PASS: $name.json valid JSON"; ((PASS++))
  else echo "FAIL: $name.json missing/invalid ($f)"; ((FAIL++)); continue; fi
  assert_eq "$name: server key = $name" "$name" "$(jq -r ".mcpServers | keys[0]" "$f")"
  assert_eq "$name: transport = stdio" "stdio" "$(jq -r ".mcpServers.$name.type" "$f")"
  assert_eq "$name: command = $cmd" "$cmd" "$(jq -r ".mcpServers.$name.command" "$f")"
  refs="$(jq -r ".mcpServers.$name.env | to_entries[] | select(.value|startswith(\"\${\")) | .key" "$f")"
  if [[ -n "$refs" ]]; then echo "PASS: $name: có env ref \${...}"; ((PASS++))
  else echo "FAIL: $name: không có env ref \${...} nào"; ((FAIL++)); fi
  for e in $refs; do
    assert_eq "$name: env $e tham chiếu \${$e}" "\${$e}" "$(jq -r ".mcpServers.$name.env.$e" "$f")"
    assert_file_contains "$name: .env.pagent.example document $e" "$e" "$REPO_DIR/.env.pagent.example"
  done
done

# ── 1b. jira.json = ĐÚNG chế độ Jira Server/DC (PAT), không còn Cloud env ───
echo "--- jira.json Server/DC contract ---"
JF="$KIT_DIR/mcp/jira.json"
assert_eq "jira: env keys đúng bộ Server/DC" \
  "JIRA_PERSONAL_TOKEN JIRA_URL READ_ONLY_MODE" "$(jq -r '.mcpServers.jira.env | keys | join(" ")' "$JF")"
assert_eq "jira: READ_ONLY_MODE=true" "true" "$(jq -r '.mcpServers.jira.env.READ_ONLY_MODE' "$JF")"
for e in JIRA_USERNAME JIRA_API_TOKEN; do
  assert_eq "jira: KHÔNG còn env Cloud $e" "null" "$(jq -r ".mcpServers.jira.env.$e" "$JF")"
done

# ── 2. orchestrator khai jira + gitlab trong mcp_servers ────────────────────
echo "--- orchestrator mcp_servers ---"
OV="$(md_meta "$KIT_DIR/agents/orchestrator.md" mcp_servers)"
assert_contains "orchestrator mcp_servers có jira" "jira" "$OV"
assert_contains "orchestrator mcp_servers có gitlab" "gitlab" "$OV"

# ── 3. PAGENT_TASKS gate logic (CODE THẬT extract từ pagent) ────────────────
echo "--- PAGENT_TASKS gate ---"
# Vòng gate MCP nằm INLINE trong call_agent (không phải hàm riêng) → extract nguyên văn
# block `local mcp_configs=()` … `done` rồi bọc thành hàm. KHÔNG mirror lại: mirror sai
# = test xanh mà runtime khác (đã verify: xoá dedupe trong pagent thì mirror vẫn xanh).
_mcp_block="$(awk '/^  local mcp_configs=\(\)/{p=1} p{print} p&&/^  done$/{exit}' "$REPO_DIR/pagent")"
if [[ -z "$_mcp_block" ]] || [[ "$_mcp_block" != *"mcp_configs+=("* ]]; then
  echo "FAIL: không extract được block gate MCP từ pagent (đổi cấu trúc?)"; ((FAIL++))
else
  echo "PASS: extract được block gate MCP từ pagent"; ((PASS++))
fi
eval "build_mcp_configs() {  # \$1=mcp_servers \$2=allowed — thân hàm là CODE THẬT của pagent
  local mcp_servers=\"\$1\" allowed=\"\$2\"
$_mcp_block
  echo \"\${mcp_configs[*]:-}\"
}"
simulate_gate() {  # $1=flag $2=server-name $3=mcp_servers $4=allowed
  local flag="$1" name="$2"
  PAGENT_TASKS="$flag" PAGENT_DESIGN=0 PAGENT_CONTEXT7=0 build_mcp_configs "$3" "$4" \
    | tr ' ' '\n' | grep -F "/$name.json" || true
}
assert_eq "PAGENT_TASKS unset → jira empty" "" "$(simulate_gate "" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=0 → jira empty" "" "$(simulate_gate "0" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=1 + mcp_servers jira → jira.json" \
  "$KIT_DIR/mcp/jira.json" "$(simulate_gate "1" jira "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=true + mcp_servers gitlab → gitlab.json" \
  "$KIT_DIR/mcp/gitlab.json" "$(simulate_gate "true" gitlab "context7,jira,gitlab" "Read")"
assert_eq "PAGENT_TASKS=1 nhưng agent không khai gitlab → empty" \
  "" "$(simulate_gate "1" gitlab "context7" "Read Grep")"

# figma nạp được dưới CẢ PAGENT_DESIGN lẫn PAGENT_TASKS, nhưng KHÔNG trùng path
echo "--- figma dưới PAGENT_TASKS + dedupe ---"
assert_eq "PAGENT_TASKS=1 + agent khai figma → figma.json" \
  "$KIT_DIR/mcp/figma.json" "$(simulate_gate "1" figma "jira,figma" "Read")"
assert_eq "PAGENT_DESIGN=0 + PAGENT_TASKS=0 + khai figma → empty" \
  "" "$(simulate_gate "0" figma "jira,figma" "Read")"
count_figma="$(PAGENT_DESIGN=1 PAGENT_TASKS=1 PAGENT_CONTEXT7=0 build_mcp_configs "jira,figma" "Read" \
  | tr ' ' '\n' | grep -cF "/figma.json")"
assert_eq "PAGENT_DESIGN=1 + PAGENT_TASKS=1 → figma.json chỉ 1 lần" "1" "$count_figma"

# ── 4. pagent + .env docs ───────────────────────────────────────────────────
echo "--- pagent + .env docs ---"
assert_file_contains "pagent có PAGENT_TASKS gate" "PAGENT_TASKS" "$REPO_DIR/pagent"
assert_file_contains "pagent: figma nằm dưới gate PAGENT_TASKS" "figma|PAGENT_TASKS|figma.json" "$REPO_DIR/pagent"
assert_file_contains "pagent: figma nằm dưới gate PAGENT_DESIGN" "figma|PAGENT_DESIGN|figma.json" "$REPO_DIR/pagent"
assert_file_contains "pagent: dedupe mcp_configs theo path" 'mcp_configs[*]' "$REPO_DIR/pagent"
assert_file_contains ".env.pagent.example ghi PAGENT_TASKS" "PAGENT_TASKS" "$REPO_DIR/.env.pagent.example"
assert_eq "PAGENT_TASKS=yes (truthy) → jira.json — gate dùng _is_truthy như pagent" \
  "$KIT_DIR/mcp/jira.json" "$(simulate_gate "yes" jira "context7,jira,gitlab" "Read")"
# Tên env token KHÔNG assert hardcode ở đây — mục 1 đã derive từ JSON và đối chiếu file này.

# ── 4b. Tầng thứ 5: web server ghi ĐÚNG tên env mà jira.json tham chiếu ─────
echo "--- server.py _ENV_SETTINGS bắc cầu jira.json ---"
SRV="$KIT_DIR/web/server.py"
for e in $(jq -r '.mcpServers.jira.env | to_entries[] | select(.value|startswith("${")) | .key' "$KIT_DIR/mcp/jira.json"); do
  assert_file_contains "server.py _ENV_SETTINGS ghi $e" "\"$e\"" "$SRV"
done
assert_eq "server.py KHÔNG còn tên env Cloud" "" \
  "$(grep -c 'JIRA_API_TOKEN\|JIRA_USERNAME' "$SRV" | grep -v '^0$')"

# ── 5. Helper task-ref: allowlist theo path TUYỆT ĐỐI của kit ───────────────
# Agent chạy `cd $PAGENT_SOURCE` (repo target KHÔNG tin cậy) → path tương đối trong
# allowed_tools vừa không tồn tại ở project khác, vừa cho repo target đánh tráo script
# cùng tên vào allowlist. pagent nở {{KIT_DIR}} thành path tuyệt đối trước khi truyền.
echo "--- task-ref allowlist path tuyệt đối ---"
OM="$KIT_DIR/agents/orchestrator.md"
OA="$(md_meta "$OM" allowed_tools)"
assert_contains "orchestrator allowed_tools có helper qua {{KIT_DIR}}" \
  "{{KIT_DIR}}/lib/task-ref.sh" "$OA"
assert_eq "orchestrator allowed_tools KHÔNG còn path tương đối kit/lib" "" \
  "$(printf '%s' "$OA" | grep -c 'Bash(\(bash \)\?kit/lib/' | grep -v '^0$')"
assert_eq "helper nằm đúng kit/lib/task-ref.sh" "yes" \
  "$([[ -f "$KIT_DIR/lib/task-ref.sh" ]] && echo yes || echo no)"
assert_file_contains "pagent export PAGENT_KIT_DIR cho agent" "export PAGENT_KIT_DIR" "$REPO_DIR/pagent"
exp="$(KIT_DIR=/opt/k expand_kit_dir "$OA")"
assert_contains "expand_kit_dir nở ra path tuyệt đối" "/opt/k/lib/task-ref.sh" "$exp"
assert_eq "expand_kit_dir không để sót placeholder" "" \
  "$(printf '%s' "$exp" | grep -c '{{KIT_DIR}}' | grep -v '^0$')"
assert_contains "body orchestrator hướng dẫn helper qua {{KIT_DIR}}" \
  "{{KIT_DIR}}/lib/task-ref.sh" "$(cat "$OM")"
assert_eq "body orchestrator KHÔNG còn tham chiếu kit/lib tương đối" "" \
  "$(grep -c '[^{/]kit/lib/task-ref\.sh' "$OM" | grep -v '^0$')"

# ── 6. Ma trận đầy đủ PAGENT_TASKS × PAGENT_DESIGN × agent khai gì ──────────
# Assert TẬP --mcp-config CHÍNH XÁC (không chỉ "có chứa"), theo đúng thứ tự bảng trong
# pagent. `unset` khác `0` ở chỗ nó đi qua nhánh default `${!FLAG:-0}` — phải test cả hai
# vì `set -u` của pagent làm nhánh này dễ vỡ khi refactor.
echo "--- ma trận PAGENT_TASKS × PAGENT_DESIGN × agent ---"
mcp_set() {  # $1=TASKS ('unset'|val) $2=DESIGN $3=mcp_servers $4=allowed → basename list, order-preserving
  (
    unset PAGENT_TASKS PAGENT_DESIGN PAGENT_CONTEXT7
    [[ "$1" != unset ]] && export PAGENT_TASKS="$1"
    [[ "$2" != unset ]] && export PAGENT_DESIGN="$2"
    build_mcp_configs "$3" "$4"
  ) | tr ' ' '\n' | sed 's#.*/##' | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//'
}
# agent-profile: tên | mcp_servers | allowed_tools
AG_JIRA_S="context7,jira,gitlab";  AG_JIRA_A="Read Grep"
AG_FIGMA_S="figma";                AG_FIGMA_A="Read Grep"
AG_NONE_S="";                      AG_NONE_A="Read Grep Glob"
AG_BOTH_S="jira,figma";            AG_BOTH_A="Read Grep"

for t in unset 0 1; do
  for d in 0 1; do
    # agent chỉ khai jira → figma/canvas không bao giờ được nạp dù PAGENT_DESIGN=1
    exp_jira=""; [[ "$t" == 1 ]] && exp_jira="jira.json gitlab.json"
    assert_eq "matrix TASKS=$t DESIGN=$d agent=jira → [$exp_jira]" \
      "$exp_jira" "$(mcp_set "$t" "$d" "$AG_JIRA_S" "$AG_JIRA_A")"

    # agent chỉ khai figma → nạp nếu BẤT KỲ gate nào bật, và CHỈ 1 lần
    exp_figma=""; [[ "$t" == 1 || "$d" == 1 ]] && exp_figma="figma.json"
    assert_eq "matrix TASKS=$t DESIGN=$d agent=figma → [$exp_figma]" \
      "$exp_figma" "$(mcp_set "$t" "$d" "$AG_FIGMA_S" "$AG_FIGMA_A")"

    # agent không khai server nào → luôn rỗng, dù mọi gate bật
    assert_eq "matrix TASKS=$t DESIGN=$d agent=none → []" \
      "" "$(mcp_set "$t" "$d" "$AG_NONE_S" "$AG_NONE_A")"

    # agent khai CẢ jira lẫn figma → figma.json xuất hiện ĐÚNG 1 lần khi cả 2 gate bật
    exp_both=""
    [[ "$t" == 1 || "$d" == 1 ]] && exp_both="figma.json"
    [[ "$t" == 1 ]] && exp_both="${exp_both:+$exp_both }jira.json"
    assert_eq "matrix TASKS=$t DESIGN=$d agent=jira+figma → [$exp_both]" \
      "$exp_both" "$(mcp_set "$t" "$d" "$AG_BOTH_S" "$AG_BOTH_A")"
  done
done
# Chốt riêng: dedupe theo path, không phải theo tên server (2 row cùng trỏ figma.json)
assert_eq "TASKS=1 + DESIGN=1 + khai jira,figma → figma.json đúng 1 lần" "1" \
  "$(mcp_set 1 1 "$AG_BOTH_S" "$AG_BOTH_A" | tr ' ' '\n' | grep -cFx 'figma.json')"

# ── 7. Thiếu file config / thiếu env → exit 0, KHÔNG nạp MCP ────────────────
# pagent chạy `set -euo pipefail`: gate MCP phải degrade ÊM (bỏ qua), tuyệt đối không
# được abort run vì thiếu kit/mcp/*.json hay thiếu biến gate.
echo "--- thiếu config / thiếu env → degrade êm ---"
EMPTY_KIT="$TASKMCP_TMP/emptykit"; mkdir -p "$EMPTY_KIT/mcp"
out="$(set -euo pipefail; KIT_DIR="$EMPTY_KIT" PAGENT_TASKS=1 PAGENT_DESIGN=1 PAGENT_CONTEXT7=1 \
  build_mcp_configs "context7,jira,gitlab,figma,canvas" "Read")"; rc=$?
assert_eq "thiếu MỌI file config: exit 0" "0" "$rc"
assert_eq "thiếu MỌI file config: không nạp MCP nào" "" "$out"

# Thiếu MỘT file: các file còn lại vẫn nạp, file thiếu bị bỏ qua im lặng
PARTIAL_KIT="$TASKMCP_TMP/partialkit"; mkdir -p "$PARTIAL_KIT/mcp"
cp "$KIT_DIR/mcp/jira.json" "$PARTIAL_KIT/mcp/jira.json"
out="$(set -euo pipefail; KIT_DIR="$PARTIAL_KIT" PAGENT_TASKS=1 PAGENT_DESIGN=0 PAGENT_CONTEXT7=0 \
  build_mcp_configs "jira,gitlab,figma" "Read" | sed 's#.*/##')"; rc=$?
assert_eq "thiếu gitlab.json/figma.json: exit 0" "0" "$rc"
assert_eq "thiếu 1 file: chỉ nạp file tồn tại" "jira.json" "$out"

# Thiếu biến gate (unset) dưới `set -u` — nhánh ${!FLAG:-0} phải không unbound-error
out="$(set -euo pipefail; unset PAGENT_TASKS PAGENT_DESIGN PAGENT_CONTEXT7
  build_mcp_configs "context7,jira,gitlab,figma" "Read")"; rc=$?
assert_eq "thiếu env gate (unset) dưới set -u: exit 0" "0" "$rc"
assert_eq "thiếu env gate (unset): không nạp MCP nào" "" "$out"

# Thiếu env credential (JIRA_URL/JIRA_PERSONAL_TOKEN unset) KHÔNG chặn nạp config:
# gate chỉ theo PAGENT_TASKS; credential rỗng là việc của MCP server. Chốt để thay đổi
# hành vi này phải sửa test có ý thức.
out="$(set -euo pipefail; unset JIRA_URL JIRA_PERSONAL_TOKEN
  PAGENT_TASKS=1 PAGENT_DESIGN=0 PAGENT_CONTEXT7=0 build_mcp_configs "jira" "Read" | sed 's#.*/##')"; rc=$?
assert_eq "thiếu JIRA_URL/PAT: exit 0" "0" "$rc"
assert_eq "thiếu JIRA_URL/PAT: gate vẫn theo PAGENT_TASKS (nạp jira.json)" "jira.json" "$out"

# Stub uvx/npx phải là thứ PATH resolve ra → suite không bao giờ spawn MCP server thật
assert_contains "uvx trong PATH là stub của test" "$TASKMCP_TMP/bin/uvx" "$(command -v uvx)"
assert_contains "npx trong PATH là stub của test" "$TASKMCP_TMP/bin/npx" "$(command -v npx)"
assert_eq "command của jira.json là uvx (đã stub)" "uvx" "$(jq -r '.mcpServers.jira.command' "$JF")"

# ── 8. allowed_tools orchestrator: ĐỌC Jira được, GHI Jira thì không ────────
# READ_ONLY_MODE=true ở jira.json là lớp 1; allowlist tool là lớp 2. Chỉ 1 lớp là
# không đủ: env có thể bị override từ .env.pagent của repo target.
echo "--- allowed_tools orchestrator: read-only Jira ---"
for t in mcp__jira__jira_get_issue mcp__jira__jira_search mcp__jira__jira_download_attachments; do
  assert_contains "allowed_tools có tool ĐỌC jira: $t" "$t" "$OA"
done
assert_contains "allowed_tools có helper task-ref.sh (kit/lib)" "/lib/task-ref.sh" "$OA"
for t in mcp__jira__jira_create_issue mcp__jira__jira_update_issue mcp__jira__jira_delete_issue \
         mcp__jira__jira_add_comment mcp__jira__jira_transition_issue mcp__jira__jira_batch_create_issues \
         mcp__jira__jira_add_worklog mcp__jira__jira_create_issue_link mcp__jira__jira_link_to_epic; do
  assert_not_contains "allowed_tools KHÔNG có tool GHI jira: $t" "$t" "$OA"
done
# Chặn theo pattern (bắt cả tool ghi chưa có trong danh sách trên)
assert_eq "allowed_tools: 0 tool jira mang động từ ghi" "" \
  "$(printf '%s' "$OA" | tr ' ' '\n' \
     | grep -E '^mcp__jira__jira_(create|update|delete|add|remove|set|move|edit|transition|batch|upload)' \
     | tr '\n' ' ' | sed 's/ *$//')"
assert_contains "orchestrator disallowed_tools chặn Write" "Write" "$(md_meta "$OM" disallowed_tools)"
assert_contains "orchestrator disallowed_tools chặn Edit" "Edit" "$(md_meta "$OM" disallowed_tools)"

# ── 9. oc_mcp_config: OUTPUT THẬT (code extract từ pagent, không mirror jq) ─
# Backend mặc định là opencode → đây là đường CHÍNH nạp MCP. Assert nội dung file sinh ra
# ở repo target: PAT không bao giờ được ghi plaintext, `${VAR}` (cú pháp claude-cli) không
# được lọt vào config opencode, cờ read-only phải sống sót mọi biến đổi jq.
echo "--- oc_mcp_config output ---"
eval "$(extract_fn oc_mcp_config)"
eval "$(extract_fn oc_gitignore_guard)"
eval "$(extract_fn mcp_env_preflight)"
_mcp_env_warned=""
WARN_FILE="$TASKMCP_TMP/warn.log"; : >"$WARN_FILE"
warn() { printf '%s\n' "$*" >>"$WARN_FILE"; }   # capture qua file: oc_mcp_config chạy trong subshell

SENTINEL_PAT="SENTINEL-PAT-fake-do-not-leak"
OCS="$TASKMCP_TMP/ocsrc"; rm -rf "$OCS"; mkdir -p "$OCS"
OUT_JSON="$OCS/.opencode/opencode.json"
gen_mcp_config() {  # $@ = config paths — chạy với credential giả đã export
  ( export PAGENT_SOURCE="$OCS" JIRA_URL="https://jira.example.test" \
      JIRA_PERSONAL_TOKEN="$SENTINEL_PAT" GITLAB_API_URL="https://gitlab.example.test" \
      GITLAB_PERSONAL_ACCESS_TOKEN="$SENTINEL_PAT"
    oc_mcp_config "$@" )
}
gen_mcp_config "$KIT_DIR/mcp/jira.json" "$KIT_DIR/mcp/gitlab.json"

assert_eq "oc_mcp_config: sinh .opencode/opencode.json" "yes" \
  "$([[ -f "$OUT_JSON" ]] && echo yes || echo no)"
assert_eq "opencode.json: JSON hợp lệ" "0" "$(jq . "$OUT_JSON" >/dev/null 2>&1; echo $?)"
assert_eq "opencode.json: KHÔNG rò giá trị PAT" "0" "$(grep -cF "$SENTINEL_PAT" "$OUT_JSON" || true)"
assert_eq "opencode.json: KHÔNG còn \${VAR} literal (cú pháp claude-cli)" "0" \
  "$(grep -cF '${' "$OUT_JSON" || true)"
assert_eq "opencode.json: marker _pagent_generated" "true" "$(jq -r '._pagent_generated' "$OUT_JSON")"
assert_eq "jira: type local + command gộp args" "local uvx mcp-atlassian" \
  "$(jq -r '.mcp.jira | .type + " " + (.command|join(" "))' "$OUT_JSON")"
assert_eq 'jira: environment CHỈ giữ key literal (${VAR} drop để kế thừa env)' "READ_ONLY_MODE" \
  "$(jq -r '.mcp.jira.environment | keys | join(" ")' "$OUT_JSON")"
assert_eq "jira: READ_ONLY_MODE=true sống sót" "true" \
  "$(jq -r '.mcp.jira.environment.READ_ONLY_MODE' "$OUT_JSON")"
assert_eq "gitlab: environment CHỈ giữ key literal" "GITLAB_READ_ONLY_MODE" \
  "$(jq -r '.mcp.gitlab.environment | keys | join(" ")' "$OUT_JSON")"
assert_eq "gitlab: GITLAB_READ_ONLY_MODE=true sống sót" "true" \
  "$(jq -r '.mcp.gitlab.environment.GITLAB_READ_ONLY_MODE' "$OUT_JSON")"
assert_eq "opencode.json: mode 600 (umask 077 — file nằm trong repo user)" "600" \
  "$(stat -f '%OLp' "$OUT_JSON" 2>/dev/null || stat -c '%a' "$OUT_JSON")"

# File do bản pagent CŨ sinh (0644): `>` truncate giữ mode cũ → umask 077 không áp được
printf '%s\n' '{"_pagent_generated":true,"mcp":{}}' >"$OUT_JSON"; chmod 644 "$OUT_JSON"
gen_mcp_config "$KIT_DIR/mcp/jira.json"
assert_eq "opencode.json cũ mode 644 → siết về 600 khi sinh lại" "600" \
  "$(stat -f '%OLp' "$OUT_JSON" 2>/dev/null || stat -c '%a' "$OUT_JSON")"

# env toàn ${VAR} → environment rỗng ⇒ BỎ HẲN key (không ghi {} thừa)
ONLY_REF="$TASKMCP_TMP/onlyref.json"
cat >"$ONLY_REF" <<'JSON'
{"mcpServers":{"onlyref":{"type":"stdio","command":"uvx","args":["x"],"env":{"A_TOKEN":"${A_TOKEN}"}}}}
JSON
rm -f "$OUT_JSON"; gen_mcp_config "$ONLY_REF"
assert_eq "env toàn \${VAR} → bỏ hẳn key environment" "false" \
  "$(jq -r '.mcp.onlyref | has("environment")' "$OUT_JSON")"

# remote (url) giữ nguyên shape cũ
REMOTE_CFG="$TASKMCP_TMP/remote.json"
cat >"$REMOTE_CFG" <<'JSON'
{"mcpServers":{"ctx":{"type":"http","url":"https://mcp.example.test/x"}}}
JSON
rm -f "$OUT_JSON"; gen_mcp_config "$REMOTE_CFG"
assert_eq "http server → type remote + url" "remote https://mcp.example.test/x" \
  "$(jq -r '.mcp.ctx | .type + " " + .url' "$OUT_JSON")"

# Guard: config user tự quản (không có marker) KHÔNG bị clobber
printf '%s\n' '{"mcp":{"mine":{"type":"local","command":["x"]}}}' >"$OUT_JSON"
: >"$WARN_FILE"; gen_mcp_config "$KIT_DIR/mcp/jira.json"
assert_eq "config user tự quản: không bị ghi đè" "mine" "$(jq -r '.mcp | keys | join(" ")' "$OUT_JSON")"
assert_contains "config user tự quản: có warn" "user tự quản" "$(cat "$WARN_FILE")"

# Marker khai TƯỜNG MINH false (user copy file pagent sinh rồi tự sửa) — guard là
# `_pagent_generated == true`, không phải `has(...)` → vẫn phải coi là config user.
printf '%s\n' '{"_pagent_generated":false,"mcp":{"keepme":{"type":"local","command":["x"]}}}' >"$OUT_JSON"
: >"$WARN_FILE"; gen_mcp_config "$KIT_DIR/mcp/jira.json"
assert_eq "marker _pagent_generated=false: không bị ghi đè" "keepme" \
  "$(jq -r '.mcp | keys | join(" ")' "$OUT_JSON")"
assert_contains "marker false: có warn" "user tự quản" "$(cat "$WARN_FILE")"

# File tồn tại nhưng KHÔNG parse được (user gõ hỏng / file rác): jq -e fail → nhánh
# "user tự quản". Phải giữ nguyên file + không crash dưới set -e của pagent.
printf '%s' 'not json at all' >"$OUT_JSON"
: >"$WARN_FILE"; ( set -euo pipefail; gen_mcp_config "$KIT_DIR/mcp/jira.json" ); rc=$?
assert_eq "opencode.json hỏng cú pháp: exit 0 (không abort run)" "0" "$rc"
assert_eq "opencode.json hỏng cú pháp: giữ nguyên nội dung" "not json at all" "$(cat "$OUT_JSON")"
assert_contains "opencode.json hỏng cú pháp: có warn" "user tự quản" "$(cat "$WARN_FILE")"

# Server không khai `env` (context7/figma dạng stdio thuần) → jq `.value.env // {}` phải
# không nổ và KHÔNG sinh key environment rỗng.
NOENV_CFG="$TASKMCP_TMP/noenv.json"
cat >"$NOENV_CFG" <<'JSON'
{"mcpServers":{"noenv":{"type":"stdio","command":"uvx","args":["a","b"]}}}
JSON
rm -f "$OUT_JSON"; ( set -euo pipefail; gen_mcp_config "$NOENV_CFG" ); rc=$?
assert_eq "server không có env: exit 0" "0" "$rc"
assert_eq "server không có env: KHÔNG sinh key environment" "false" \
  "$(jq -r '.mcp.noenv | has("environment")' "$OUT_JSON")"
assert_eq "server không có env: command vẫn gộp args" "uvx a b" \
  "$(jq -r '.mcp.noenv.command | join(" ")' "$OUT_JSON")"

# Hợp đồng kit/mcp/*.json: mỗi env value phải HOẶC là ref nguyên vẹn `${VAR}` (bị drop để
# kế thừa env) HOẶC không chứa `${` nào. Value LAI (vd "https://${HOST}/x") lọt qua regex
# drop → ghi literal `${HOST}` vào opencode.json mà opencode không nở ⇒ MCP chết im lặng.
echo "--- kit/mcp/*.json: env value không được lai \${VAR} ---"
for f in "$KIT_DIR"/mcp/*.json; do
  bad="$(jq -r '[.mcpServers[]?.env // {} | to_entries[]
                | select((.value|tostring|test("\\$\\{")) and (.value|tostring|test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$")|not))
                | .key] | join(" ")' "$f")"
  assert_eq "$(basename "$f"): không có env value lai \${VAR}" "" "$bad"
done

# oc_mcp_config chạy trong repo target ⇒ tự ignore artefact mình sinh (không chỉ khi
# oc_agent_file chạy trước). Đây là đường mà user gặp thật: backend opencode + PAGENT_TASKS=1.
OCGIT="$TASKMCP_TMP/ocgit"; rm -rf "$OCGIT"; mkdir -p "$OCGIT"
git -C "$OCGIT" init -q 2>/dev/null
( export PAGENT_SOURCE="$OCGIT" JIRA_URL="https://jira.example.test" \
    JIRA_PERSONAL_TOKEN="$SENTINEL_PAT"
  oc_mcp_config "$KIT_DIR/mcp/jira.json" )
assert_eq "oc_mcp_config trong repo git: .opencode/ được ignore" "1" \
  "$(grep -cFx '.opencode/' "$OCGIT/.gitignore" 2>/dev/null || true)"
assert_eq "oc_mcp_config trong repo git: git status không thấy .opencode/" "" \
  "$(git -C "$OCGIT" status --porcelain --untracked-files=all | grep -F '.opencode/' || true)"
assert_eq "opencode.json sinh trong repo git: KHÔNG rò PAT" "0" \
  "$(grep -cF "$SENTINEL_PAT" "$OCGIT/.opencode/opencode.json" || true)"

# ── 10. oc_gitignore_guard: append .opencode/ idempotent vào repo target ────
echo "--- oc_gitignore_guard ---"
GITSRC="$TASKMCP_TMP/gitsrc"; rm -rf "$GITSRC"; mkdir -p "$GITSRC"
git -C "$GITSRC" init -q 2>/dev/null
printf '%s\n' 'node_modules/' >"$GITSRC/.gitignore"
( export PAGENT_SOURCE="$GITSRC"; oc_gitignore_guard; oc_gitignore_guard )
assert_eq "repo target: .opencode/ được append" "1" \
  "$(grep -cFx '.opencode/' "$GITSRC/.gitignore" || true)"
assert_eq "repo target: CHỈ append, giữ nội dung cũ" "1" \
  "$(grep -cFx 'node_modules/' "$GITSRC/.gitignore" || true)"

# .gitignore user KHÔNG kết thúc bằng newline → append thô sẽ nối vào dòng cuối
# ('.env' → '.env.opencode/') làm mất pattern ignore cuối = credential lọt vào git add.
NOEOL="$TASKMCP_TMP/noeol"; rm -rf "$NOEOL"; mkdir -p "$NOEOL"
git -C "$NOEOL" init -q 2>/dev/null
printf '%s' 'node_modules/' >"$NOEOL/.gitignore"   # cố ý KHÔNG có \n cuối
( export PAGENT_SOURCE="$NOEOL"; oc_gitignore_guard; oc_gitignore_guard )
assert_eq ".gitignore không có newline cuối: dòng cũ còn nguyên" "1" \
  "$(grep -cFx 'node_modules/' "$NOEOL/.gitignore" || true)"
assert_eq ".gitignore không có newline cuối: .opencode/ thành dòng riêng, 1 lần" "1" \
  "$(grep -cFx '.opencode/' "$NOEOL/.gitignore" || true)"

# Repo target CHƯA có .gitignore → tạo mới, đúng 1 dòng `.opencode/`, gọi 2 lần không nhân đôi.
NOGI="$TASKMCP_TMP/nogi"; rm -rf "$NOGI"; mkdir -p "$NOGI"
git -C "$NOGI" init -q 2>/dev/null
( export PAGENT_SOURCE="$NOGI"; oc_gitignore_guard; oc_gitignore_guard )
assert_eq "repo chưa có .gitignore: được tạo" "yes" \
  "$([[ -f "$NOGI/.gitignore" ]] && echo yes || echo no)"
assert_eq "repo chưa có .gitignore: nội dung đúng 1 dòng .opencode/" ".opencode/" "$(cat "$NOGI/.gitignore")"

# Idempotent MẠNH: đã có `.opencode/` (ở giữa file) → file KHÔNG đổi 1 byte nào.
HAVE="$TASKMCP_TMP/have"; rm -rf "$HAVE"; mkdir -p "$HAVE"
git -C "$HAVE" init -q 2>/dev/null
printf '%s\n' 'node_modules/' '.opencode/' '*.log' >"$HAVE/.gitignore"
_before="$(cksum <"$HAVE/.gitignore")"
( export PAGENT_SOURCE="$HAVE"; oc_gitignore_guard; oc_gitignore_guard )
assert_eq "đã có .opencode/ sẵn: file không đổi 1 byte" "$_before" "$(cksum <"$HAVE/.gitignore")"

# PAGENT_SOURCE là SUBDIR của repo → ghi vào .gitignore ở TOPLEVEL (rev-parse --show-toplevel),
# không rải .gitignore rác vào từng thư mục con.
SUBR="$TASKMCP_TMP/subrepo"; rm -rf "$SUBR"; mkdir -p "$SUBR/pkg/app"
git -C "$SUBR" init -q 2>/dev/null
( export PAGENT_SOURCE="$SUBR/pkg/app"; oc_gitignore_guard )
assert_eq "PAGENT_SOURCE là subdir: ignore ghi ở toplevel" "1" \
  "$(grep -cFx '.opencode/' "$SUBR/.gitignore" 2>/dev/null || true)"
assert_eq "PAGENT_SOURCE là subdir: KHÔNG tạo .gitignore trong subdir" "no" \
  "$([[ -f "$SUBR/pkg/app/.gitignore" ]] && echo yes || echo no)"

NOGIT="$TASKMCP_TMP/nogit"; rm -rf "$NOGIT"; mkdir -p "$NOGIT"
( export PAGENT_SOURCE="$NOGIT"; oc_gitignore_guard )
assert_eq "không phải repo git → KHÔNG tạo .gitignore" "no" \
  "$([[ -f "$NOGIT/.gitignore" ]] && echo yes || echo no)"
assert_file_contains "repo pagent tự ignore .opencode/" ".opencode/" "$REPO_DIR/.gitignore"

# ── 11. mcp_env_preflight: warn CHỈ khi user khai một phần ──────────────────
# Hợp đồng: không khai gì → IM LẶNG (fallback cũ). Khai một phần → warn 1 dòng, CHỈ tên
# biến + tên file (run dir bị tar czf + web dashboard phục vụ → cấm in giá trị).
echo "--- mcp_env_preflight ---"
preflight_warn() {  # $1=JIRA_URL $2=JIRA_PERSONAL_TOKEN → stdout = warn đã phát
  ( : >"$WARN_FILE"; _mcp_env_warned=""
    unset JIRA_URL JIRA_PERSONAL_TOKEN
    [[ -n "$1" ]] && export JIRA_URL="$1"
    [[ -n "$2" ]] && export JIRA_PERSONAL_TOKEN="$2"
    mcp_env_preflight "$KIT_DIR/mcp/jira.json"
    cat "$WARN_FILE" )
}
assert_eq "không khai gì → im lặng" "" "$(preflight_warn "" "")"
assert_eq "khai đủ → im lặng" "" "$(preflight_warn "https://jira.example.test" "$SENTINEL_PAT")"
out="$(preflight_warn "https://jira.example.test" "")"
assert_contains "khai URL nhưng thiếu PAT → warn tên biến thiếu" "JIRA_PERSONAL_TOKEN" "$out"
assert_contains "warn nêu tên file config" "jira.json" "$out"
assert_not_contains "warn KHÔNG in giá trị PAT" "$SENTINEL_PAT" \
  "$(preflight_warn "https://jira.example.test" "")$(preflight_warn "" "$SENTINEL_PAT")"
assert_not_contains "warn KHÔNG in giá trị URL" "jira.example.test" "$out"
assert_eq "warn chỉ 1 lần cho mỗi file config" "1" \
  "$( ( : >"$WARN_FILE"; _mcp_env_warned=""; export JIRA_URL="https://jira.example.test"
       unset JIRA_PERSONAL_TOKEN
       mcp_env_preflight "$KIT_DIR/mcp/jira.json"
       mcp_env_preflight "$KIT_DIR/mcp/jira.json"
       cat "$WARN_FILE" ) | grep -oF 'JIRA_PERSONAL_TOKEN' | wc -l | tr -d ' ' )"
assert_file_contains "pagent gọi mcp_env_preflight sau vòng gate" "mcp_env_preflight" "$REPO_DIR/pagent"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
