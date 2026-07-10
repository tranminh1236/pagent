#!/usr/bin/env bash
# Tests for the devops + docs agent roster-expansion wiring:
#   devops — sinh Dockerfile/compose/.gitlab-ci + chốt env; chạy SỚM (trước coder loop).
#   docs   — cập nhật swagger/OpenAPI + admin config; scope hẹp, chạy CUỐI (gần workflow-extractor).
# Static-assertion style (no claude spawn) — verifies agent frontmatter + dispatcher wiring + synced docs.

PASS=0
FAIL=0
ok()   { echo "PASS: $1"; ((PASS++)); }
fail() { echo "FAIL: $1"; ((FAIL++)); }

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected literal: $pattern"; echo "      in file: $file"; ((FAIL++)); fi
}
assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then echo "PASS: $desc"; ((PASS++))
  else echo "FAIL: $desc"; echo "      expected regex: $pattern"; echo "      in file: $file"; ((FAIL++)); fi
}

cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"
SUMMARY="./.pagent/source-summary.md"
ORCH="./kit/agents/orchestrator.md"
INDEX="./kit/web/index.html"
APPJS="./kit/web/app.js"
DEVOPS="./kit/agents/devops.md"
DOCS="./kit/agents/docs.md"

# md_meta copy verbatim từ pagent (parse frontmatter độc lập không spawn).
md_meta() {
  awk -v k="$2" '
    /^---$/{p++; next}
    p==1 && $1==k":" { sub("^[^:]+:[[:space:]]*",""); print; exit }
  ' "$1"
}

echo "=== devops.md — frontmatter + writer tools ==="
if [[ -f "$DEVOPS" ]]; then ok "devops.md tồn tại"; else fail "devops.md thiếu"; fi
[[ "$(md_meta "$DEVOPS" name)" == "devops" ]] && ok "devops: name khớp file" || fail "devops: name sai"
# model: kit/agents KHÔNG khai (opencode combo tự chọn); nếu khai phải tên trần (không provider/model). max_turns optional.
_m="$(md_meta "$DEVOPS" model)"
[[ -z "$_m" || "$_m" != */* ]] && ok "devops: không khai model (opencode combo) hoặc tên trần (${_m:-<unset>})" || fail "devops: nếu khai model phải tên trần (không provider/model) — got '$_m'"
_mt="$(md_meta "$DEVOPS" max_turns)"
[[ -z "$_mt" || "$_mt" =~ ^[0-9]+$ ]] && ok "devops: max_turns rỗng hoặc là số" || fail "devops: max_turns không phải số ($_mt)"
DEV_TOOLS="$(md_meta "$DEVOPS" allowed_tools)"
for _t in Write Edit Bash; do
  echo "$DEV_TOOLS" | grep -qE "(^|[,[:space:]])$_t([,[:space:]]|\$)" \
    && ok "devops: allowed_tools có $_t (sinh Dockerfile/CI/env)" \
    || fail "devops: allowed_tools thiếu $_t ($DEV_TOOLS)"
done
assert_grep "devops: prompt nêu kích hoạt ở init/thiếu file hạ tầng" "$DEVOPS" 'KHỞI TẠO PROJECT|thiếu file hạ tầng|thiếu file'
assert_grep "devops: prompt nhắc .env.pagent + .example đồng bộ"     "$DEVOPS" '\.env\.pagent\.example'
assert_grep "devops: prompt nhắc CI (.gitlab-ci)"                    "$DEVOPS" 'gitlab-ci'
assert_grep "devops: prompt tách Docker dev + deploy"               "$DEVOPS" 'dev-code|deploy-server|dev/deploy'

# --- rule mới: docker-compose dev + Dockerfile deploy ---
assert_grep "devops: BẮT BUỘC sinh docker-compose dev"     "$DEVOPS" 'docker-compose'
assert_grep "devops: BẮT BUỘC sinh Dockerfile deploy"      "$DEVOPS" 'Dockerfile'
# --- rule mới: stage deploy + clean ---
assert_grep "devops: CI có stage deploy"                   "$DEVOPS" 'stage .deploy.|deploy →|→ deploy|deploy.*clean'
assert_grep "devops: CI có stage clean dọn image/volume"  "$DEVOPS" 'clean'
# --- rule mới: giữ tối đa N version rollback (mặc định 3) ---
assert_grep "devops: giữ N version image rollback"         "$DEVOPS" 'KEEP_IMAGE_VERSIONS'
assert_grep "devops: nhắc rollback / giữ version"          "$DEVOPS" 'rollback'
assert_grep "devops: mặc định giữ 3 version"               "$DEVOPS" 'mặc định 3|\(mặc định .3.\)|3'
# --- rule mới: giới hạn log ≤1GB + mount host ---
assert_grep "devops: giới hạn log container ≤1GB"          "$DEVOPS" '1GB|max-size'
assert_grep "devops: mount log ra host dir"                "$DEVOPS" 'LOG_HOST_DIR'
# --- rule mới: tags runner từ biến ---
assert_grep "devops: tags gitlab-runner từ biến"           "$DEVOPS" 'RUNNER_TAGS'
# --- rule mới: toggle network-host ---
assert_grep "devops: toggle network-host"                  "$DEVOPS" 'USE_NETWORK_HOST|network.host'
# --- rule mới: flag pushImage build né registry ---
assert_grep "devops: flag pushImage true/false"            "$DEVOPS" 'pushImage'
# --- rule mới: cache pnpm store + go module mount host ---
assert_grep "devops: cache pnpm store mount host"          "$DEVOPS" 'pnpm'
assert_grep "devops: cache go module/go.sum mount host"    "$DEVOPS" 'go module|go\.sum|CACHE_GO_DIR'

echo ""
echo "=== docs.md — scope hẹp, chặn code runtime ==="
if [[ -f "$DOCS" ]]; then ok "docs.md tồn tại"; else fail "docs.md thiếu"; fi
[[ "$(md_meta "$DOCS" name)" == "docs" ]] && ok "docs: name khớp file" || fail "docs: name sai"
_m="$(md_meta "$DOCS" model)"
[[ -z "$_m" || "$_m" != */* ]] && ok "docs: không khai model (opencode combo) hoặc tên trần (${_m:-<unset>})" || fail "docs: nếu khai model phải tên trần (không provider/model) — got '$_m'"
DOC_TOOLS="$(md_meta "$DOCS" allowed_tools)"
for _t in Read Edit Write; do
  echo "$DOC_TOOLS" | grep -qE "(^|[,[:space:]])$_t([,[:space:]]|\$)" \
    && ok "docs: allowed_tools có $_t (vùng doc)" \
    || fail "docs: allowed_tools thiếu $_t ($DOC_TOOLS)"
done
DOC_DIS="$(md_meta "$DOCS" disallowed_tools)"
echo "$DOC_DIS" | grep -qE "(^|[,[:space:]])Bash([,[:space:]]|\$)" \
  && ok "docs: disallowed_tools chặn Bash (không chạy/không sửa code runtime)" \
  || fail "docs: disallowed_tools thiếu Bash backstop ($DOC_DIS)"
assert_grep "docs: prompt cấm sửa code sản phẩm"        "$DOCS" 'KHÔNG sửa code|KHÔNG.*code sản phẩm'
assert_grep "docs: prompt kích hoạt khi thêm/sửa API"   "$DOCS" 'thêm/sửa API|thêm.sửa API'
assert_grep "docs: prompt nhắc swagger/OpenAPI"         "$DOCS" 'swagger|OpenAPI'
assert_grep "docs: prompt nhắc config setup admin page" "$DOCS" 'admin'

echo ""
echo "=== pagent — devops dispatch (SỚM, gated) ==="
assert_contains "devops gated by agent_enabled"        "$PAGENT" 'agent_enabled devops && want_devops=1'
assert_contains "devops spawn qua call_agent"          "$PAGENT" '| call_agent devops'
assert_grep    "devops log skip khi ngoài required_agents" "$PAGENT" 'log_skip "devops'
# devops PHẢI đứng TRƯỚC vòng coder↔review
dev_ln="$(grep -n '| call_agent devops' "$PAGENT" | head -1 | cut -d: -f1)"
coder_ln="$(grep -n 'Coder ↔ Reviewer loop' "$PAGENT" | head -1 | cut -d: -f1)"
if [[ -n "$dev_ln" && -n "$coder_ln" && "$dev_ln" -lt "$coder_ln" ]]; then
  ok "devops (line $dev_ln) chạy TRƯỚC coder loop (line $coder_ln)"
else
  fail "devops phải chạy trước coder loop (devops=$dev_ln coder=$coder_ln)"
fi

echo ""
echo "=== pagent — docs dispatch (CUỐI, gated) ==="
assert_contains "docs gated by agent_enabled"          "$PAGENT" 'agent_enabled docs && want_docs=1'
assert_contains "docs spawn qua call_agent"            "$PAGENT" '| call_agent docs'
assert_grep    "docs log skip khi ngoài required_agents" "$PAGENT" 'log_skip "docs'
# docs PHẢI đứng SAU tester, gần workflow-extractor
docs_ln="$(grep -n '| call_agent docs' "$PAGENT" | head -1 | cut -d: -f1)"
tester_ln="$(grep -n '4. Tester' "$PAGENT" | head -1 | cut -d: -f1)"
wf_ln="$(grep -n '5. Agent orchestration workflow extractor' "$PAGENT" | head -1 | cut -d: -f1)"
if [[ -n "$docs_ln" && -n "$tester_ln" && "$docs_ln" -gt "$tester_ln" ]]; then
  ok "docs (line $docs_ln) chạy SAU tester (line $tester_ln)"
else
  fail "docs phải chạy sau tester (docs=$docs_ln tester=$tester_ln)"
fi
if [[ -n "$docs_ln" && -n "$wf_ln" && "$docs_ln" -lt "$wf_ln" ]]; then
  ok "docs (line $docs_ln) chạy TRƯỚC workflow-extractor (line $wf_ln) — gần cuối"
else
  fail "docs phải đứng ngay trước workflow-extractor (docs=$docs_ln wf=$wf_ln)"
fi
# docs đọc CODER_CHANGES (code đã merged)
assert_contains "docs nhận CODER_CHANGES (code đã merged)" "$PAGENT" 'echo "## CODER_CHANGES"; cat "$PAGENT_RUN_DIR/coder.txt"'

echo ""
echo "=== orchestrator.md — devops/docs là giá trị required_agents hợp lệ ==="
assert_grep    "orchestrator liệt kê devops valid"  "$ORCH" '\`devops\`'
assert_grep    "orchestrator liệt kê docs valid"    "$ORCH" '\`docs\`'
assert_grep    "orchestrator: guard devops/docs độc lập auditor" "$ORCH" 'Guard devops / docs'
assert_grep    "orchestrator: devops kéo khi init/thiếu file hạ tầng" "$ORCH" 'KHỞI TẠO PROJECT|thiếu file hạ tầng'
assert_grep    "orchestrator: docs kéo khi thêm/sửa API"             "$ORCH" 'thêm/sửa API'
assert_grep    "orchestrator: devops/docs KHÔNG bắt buộc kèm reviewer" "$ORCH" 'KHÔNG kéo theo \`reviewer\`|devops./docs. KHÔNG'

echo ""
echo "=== docs synced — source-summary + web roster ==="
assert_contains "summary liệt kê devops.md" "$SUMMARY" 'devops.md'
assert_contains "summary liệt kê docs.md"   "$SUMMARY" 'docs.md'
assert_grep    "summary Domain nhắc devops SỚM + docs CUỐI" "$SUMMARY" 'devops.*chạy SỚM|devops.*SỚM'
assert_contains "web index nhắc devops"     "$INDEX" 'devops'
assert_contains "web index nhắc docs"       "$INDEX" 'docs'
assert_contains "web app nhắc devops"       "$APPJS" 'devops'
assert_contains "web app nhắc docs"         "$APPJS" 'docs'
# roster auditor cũ vẫn nguyên (không regress test_review_layer)
assert_contains "web index giữ roster auditor" "$INDEX" 'architecture‖performance‖security'
assert_contains "web app giữ roster auditor"   "$APPJS" 'architecture‖performance‖security'

echo ""
echo "=== pagent — syntax ==="
if bash -n "$PAGENT"; then echo "PASS: pagent parses (bash -n)"; ((PASS++))
else echo "FAIL: pagent syntax error"; ((FAIL++)); fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
