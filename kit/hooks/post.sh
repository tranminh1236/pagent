#!/usr/bin/env bash
# Post-prompt hook
# Env: PAGENT_PROJECT, PAGENT_MODE, PAGENT_TASK_ID, PAGENT_AGENT, PAGENT_REPORT_DIR, PAGENT_RUN_DIR
# Args: $1 = path to claude JSON response file
set -euo pipefail
resp_file="${1:-}"
[[ -s "$resp_file" ]] || { echo "post.sh: empty response file" >&2; exit 0; }

date_str="$(date -u +%Y-%m-%d)"
log_dir="$PAGENT_REPORT_DIR/$PAGENT_PROJECT/tokens"
mkdir -p "$log_dir"
log_file="$log_dir/$date_str.jsonl"

# Extract usage từ claude CLI JSON
read -r in_tok out_tok cache_r cache_c cost dur_ms model sid <<<"$(jq -r '
  [
    .usage.input_tokens                  // 0,
    .usage.output_tokens                 // 0,
    .usage.cache_read_input_tokens       // 0,
    .usage.cache_creation_input_tokens   // 0,
    .total_cost_usd                      // 0,
    .duration_ms                         // 0,
    (.modelUsage | keys | first         // "unknown"),
    .session_id                          // ""
  ] | @tsv
' "$resp_file")"

jq -nc \
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
  --argjson durms "${dur_ms:-0}" '
  {ts:$ts, event:$event, project:$project, mode:$mode, task_id:$task_id, agent:$agent,
   model:$model, session_id:$sid,
   input_tokens:$in, output_tokens:$out, cache_read:$cr, cache_creation:$cc,
   cost_usd:$cost, duration_ms:$durms}
  ' >>"$log_file"

# Echo 1 dòng ngắn cho user thấy
printf '  [%s] in=%s out=%s cache=r%s/c%s cost=$%.4f %dms\n' \
  "$PAGENT_AGENT" "$in_tok" "$out_tok" "$cache_r" "$cache_c" "$cost" "$dur_ms" >&2
