#!/usr/bin/env bash
# Tests cho .env.pagent × backend opencode CLI (mặc định từ 2026-07-04).
# Lịch sử: backend claude CLI từng cấm PAGENT_MODEL dạng provider/model (claude 404) và
# pagent từng tự gỡ prefix "9router/". Backend opencode ĐẢO ngược: provider/model là
# format ĐÚNG ("9router/Claude"), sanitizer phải BIẾN MẤT khỏi pagent.
# Spec: docs/superpowers/specs/2026-07-04-opencode-backend-design.md

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env.pagent"
PASS=0
FAIL=0

ok()   { echo "PASS: $1"; ((PASS++)); }
bad()  { echo "FAIL: $1"; shift; for l in "$@"; do echo "      $l"; done; ((FAIL++)); }

# ── 1. PAGENT_MODEL trong .env.pagent phải là dạng provider/model của opencode ────────
model="$(bash -c "set -a; . '$ENV_FILE' 2>/dev/null; set +a; printf '%s' \"\${PAGENT_MODEL:-}\"")"
if [[ -z "$model" || "$model" == */* ]]; then
  ok "PAGENT_MODEL dạng provider/model hoặc rỗng (got: ${model:-<unset — dùng default opencode config>})"
else
  bad "PAGENT_MODEL phải là provider/model (vd 9router/Claude) hoặc rỗng cho backend opencode" "got: PAGENT_MODEL=$model"
fi

# ── 1b. Source .env.pagent KHÔNG được clobber PAGENT_MODEL đã set sẵn (web/shell) ─────
preset="$(bash -c "export PAGENT_MODEL='9router/FREE'; set -a; . '$ENV_FILE' 2>/dev/null; set +a; printf '%s' \"\$PAGENT_MODEL\"")"
if [[ "$preset" == "9router/FREE" ]]; then
  ok "PAGENT_MODEL set sẵn được giữ nguyên qua source (không clobber)"
else
  bad "source .env.pagent clobber PAGENT_MODEL đã set sẵn" "got: '$preset' (mong '9router/FREE')"
fi

# ── 2. pagent PHẢI tham chiếu PAGENT_OPENCODE_BIN (backend mặc định là opencode) ──────
if grep -q 'PAGENT_OPENCODE_BIN' "$ROOT/pagent"; then
  ok "pagent script tham chiếu PAGENT_OPENCODE_BIN (backend opencode)"
else
  bad "pagent script phải tham chiếu PAGENT_OPENCODE_BIN"
fi

# ── 3. Sanitizer gỡ prefix '9router/' phải BIẾN MẤT (dạng đó giờ là đúng) ─────────────
if grep -q 'PAGENT_MODEL#9router/' "$ROOT/pagent"; then
  bad "pagent còn sanitizer gỡ prefix 9router/ — backend opencode cần giữ nguyên provider/model"
else
  ok "không còn sanitizer gỡ prefix 9router/ trong pagent"
fi

# ── 4. Provider mặc định là opencode ──────────────────────────────────────────────────
if grep -q 'PAGENT_PROVIDER:-opencode' "$ROOT/pagent"; then
  ok "provider mặc định = opencode"
else
  bad "provider mặc định phải là opencode (PAGENT_PROVIDER:-opencode)"
fi

# ── 5. Nếu .env.pagent set ANTHROPIC_BASE_URL → phải export tới child process ─────────
# (chỉ cần cho provider claude ẨN; load_env: set -a; source; set +a)
base_url="$(bash -c "set -a; . '$ENV_FILE' 2>/dev/null; set +a; bash -c 'printf %s \"\${ANTHROPIC_BASE_URL:-}\"'")"
if grep -qE '^[[:space:]]*ANTHROPIC_BASE_URL=' "$ENV_FILE"; then
  if [[ -n "$base_url" ]]; then
    ok "ANTHROPIC_BASE_URL được export tới child process (cho provider claude ẩn)"
  else
    bad "ANTHROPIC_BASE_URL set trong .env.pagent nhưng KHÔNG export tới child"
  fi
else
  ok "ANTHROPIC_BASE_URL không set — provider claude ẩn sẽ dùng Anthropic mặc định"
fi

# ── 6. Source .env.pagent phải exit 0 (exit ≠0 → set +a bị skip trong load_env) ───────
if bash -c "set -a; . '$ENV_FILE'; set +a" 2>/dev/null; then
  ok ".env.pagent source sạch (exit 0)"
else
  bad ".env.pagent source bị exit ≠0 — load_env sẽ kẹt set -a"
fi

echo
echo "── kết quả: $PASS pass · $FAIL fail"
[[ $FAIL -eq 0 ]]
