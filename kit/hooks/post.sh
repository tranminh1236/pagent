#!/usr/bin/env bash
# Post-prompt hook
# Env: PAGENT_PROJECT, PAGENT_MODE, PAGENT_TASK_ID, PAGENT_AGENT, PAGENT_REPORT_DIR, PAGENT_RUN_DIR
# Args: $1 = path to claude JSON response file
set -euo pipefail

# Portable file lock — append jsonl không bị interleave khi 2 agent chạy song song
_lock_lib="$(dirname "${BASH_SOURCE[0]}")/../lib/lock.sh"
if [[ -f "$_lock_lib" ]]; then . "$_lock_lib"; else with_lock() { shift; "$@"; }; fi

resp_file="${1:-}"
[[ -s "$resp_file" ]] || { echo "post.sh: empty response file" >&2; exit 0; }

date_str="$(date -u +%Y-%m-%d)"
log_dir="$PAGENT_REPORT_DIR/$PAGENT_PROJECT/tokens"
mkdir -p "$log_dir"
log_file="$log_dir/$date_str.jsonl"

# Extract usage từ claude CLI JSON. Fallback 0/empty nếu response không parse được.
# `model` = model LÀM CHÍNH (nhiều output tokens nhất) chứ KHÔNG phải key đầu theo alphabet.
# Lý do: claude CLI 1 lượt thường gọi 2+ model (vd haiku phụ + sonnet chính); `keys|first`
# sắp alphabet nên luôn ra haiku → hiển thị sai model. max_by(outputTokens) lấy model thật.
if ! parsed="$(jq -r '
  [
    .usage.input_tokens                  // 0,
    .usage.output_tokens                 // 0,
    .usage.cache_read_input_tokens       // 0,
    .usage.cache_creation_input_tokens   // 0,
    .total_cost_usd                      // 0,
    .duration_ms                         // 0,
    ((.modelUsage // {} | to_entries | max_by(.value.outputTokens // 0) | .key) // "unknown"),
    .session_id                          // "",
    .terminal_reason                     // "",
    (.is_error // false | tostring),
    (.provider                           // "claude")
  ] | @tsv
' "$resp_file" 2>/dev/null)"; then
  parsed=$'0\t0\t0\t0\t0\t0\tunknown\t\tparse_fail\ttrue\tclaude'
fi
read -r in_tok out_tok cache_r cache_c cost dur_ms model sid term_reason is_err provider <<<"$parsed"

# Breakdown TẤT CẢ model đã làm việc trong lượt này (không chỉ model chính) → field `models`.
# Web hiển thị hết để user thấy "có bao nhiêu model làm việc".
if ! models_json="$(jq -c '
  (.modelUsage // {}) | to_entries | map({
    model:          .key,
    input_tokens:   (.value.inputTokens               // 0),
    output_tokens:  (.value.outputTokens              // 0),
    cache_read:     (.value.cacheReadInputTokens      // 0),
    cache_creation: (.value.cacheCreationInputTokens  // 0),
    cost_usd:       (.value.costUSD                   // 0)
  })
' "$resp_file" 2>/dev/null)"; then
  models_json="[]"
fi
[[ -n "$models_json" ]] || models_json="[]"

line="$(jq -nc \
  --arg ts        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg event     "end" \
  --arg project   "$PAGENT_PROJECT" \
  --arg mode      "${PAGENT_MODE:-}" \
  --arg task_id   "$PAGENT_TASK_ID" \
  --arg agent     "$PAGENT_AGENT" \
  --arg model     "$model" \
  --arg sid       "$sid" \
  --argjson in    "${in_tok:-0}" \
  --argjson out   "${out_tok:-0}" \
  --argjson cr    "${cache_r:-0}" \
  --argjson cc    "${cache_c:-0}" \
  --argjson cost  "${cost:-0}" \
  --argjson durms "${dur_ms:-0}" \
  --arg term      "${term_reason:-}" \
  --arg err       "${is_err:-false}" \
  --arg prov      "${provider:-claude}" \
  --argjson models "$models_json" \
  --arg subtid    "${PAGENT_SUBTASK_ID:-}" \
  --arg subtask   "${PAGENT_SUBTASK_LABEL:-}" '
  {ts:$ts, event:$event, project:$project, mode:$mode, task_id:$task_id, agent:$agent,
   subtask_id:$subtid, subtask:$subtask,
   provider:$prov, model:$model, models:$models, session_id:$sid,
   input_tokens:$in, output_tokens:$out, cache_read:$cr, cache_creation:$cc,
   cost_usd:$cost, duration_ms:$durms,
   terminal_reason:$term, is_error:($err=="true")}
  ')"
_append() { printf '%s\n' "$line" >>"$log_file"; }
with_lock "$log_file" _append

# Echo 1 dòng ngắn cho user thấy
printf '  [%s] in=%s out=%s cache=r%s/c%s cost=$%.4f %dms\n' \
  "$PAGENT_AGENT" "$in_tok" "$out_tok" "$cache_r" "$cache_c" "$cost" "$dur_ms" >&2
