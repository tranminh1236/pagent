#!/usr/bin/env bash
# Pre-prompt hook
# Env: PAGENT_PROJECT, PAGENT_MODE, PAGENT_TASK_ID, PAGENT_AGENT, PAGENT_REPORT_DIR, PAGENT_RUN_DIR
# Args: $1 = task text
set -euo pipefail
task="${1:-}"
ts_start="$(date -u +%s)"
echo "$ts_start" >"$PAGENT_RUN_DIR/started.$PAGENT_AGENT"

# Append start event vào daily log
date_str="$(date -u +%Y-%m-%d)"
log_dir="$PAGENT_REPORT_DIR/$PAGENT_PROJECT/tokens"
mkdir -p "$log_dir"
log_file="$log_dir/$date_str.jsonl"

jq -nc \
  --arg ts        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg event     "start" \
  --arg project   "$PAGENT_PROJECT" \
  --arg mode      "${PAGENT_MODE:-}" \
  --arg task_id   "$PAGENT_TASK_ID" \
  --arg agent     "$PAGENT_AGENT" \
  --arg task      "${task:0:200}" \
  '{ts:$ts, event:$event, project:$project, mode:$mode, task_id:$task_id, agent:$agent, task:$task}' \
  >>"$log_file"
