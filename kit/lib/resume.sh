#!/usr/bin/env bash
# Resume gate khi agent chạm max_turns — mirror pattern confirm-plan gate
# (plan.pending.json/decision.json) nhưng namespace theo agent để các bước chạy
# song song (audits, coder subtasks) không giẫm file nhau.
# Spec: docs/superpowers/specs/2026-07-03-resume-max-turns-design.md
# shellcheck shell=bash

# Truthy helper riêng của lib (không dựa vào _is_truthy của pagent để lib
# sourceable độc lập trong test).
_resume_truthy() { [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" ]]; }

# Clamp số lượt vào [1, PAGENT_MAX_TURNS_CEILING (mặc định 60)]; rác → fallback $2.
_resume_clamp_turns() {
  local n="$1" fallback="$2" ceil="${PAGENT_MAX_TURNS_CEILING:-60}"
  [[ "$n" =~ ^[0-9]+$ ]] || n="$fallback"
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  (( n < 1 )) && n=1
  (( n > ceil )) && n="$ceil"
  printf '%s' "$n"
}

# File handshake: ghi pending (atomic tmp+mv) rồi poll decision.
#   stdout: số lượt mới · return 0 = resume · return 1 = stop/timeout
# Cleanup cả pending lẫn decision ở MỌI nhánh thoát.
resume_wait_decision() {
  local agent="$1" sid="$2" used="$3" default_turns="$4"
  local pend="$PAGENT_RUN_DIR/resume.pending.$agent.json"
  local dec="$PAGENT_RUN_DIR/resume.decision.$agent.json"
  rm -f "$dec"
  jq -n --arg agent "$agent" --arg sid "$sid" \
        --argjson used "${used:-0}" --argjson def "${default_turns:-20}" \
        '{agent:$agent, session_id:$sid, used_turns:$used, default_turns:$def,
          ts:(now|todate)}' >"$pend.tmp" && mv -f "$pend.tmp" "$pend"

  local timeout="${PAGENT_RESUME_TIMEOUT:-900}" waited=0
  while :; do
    if [[ -f "$dec" ]]; then
      local action turns
      action="$(jq -r '.action // "stop"' "$dec" 2>/dev/null || echo stop)"
      turns="$(jq -r '.extra_turns // ""' "$dec" 2>/dev/null || echo "")"
      rm -f "$pend" "$dec"
      if [[ "$action" == "resume" ]]; then
        _resume_clamp_turns "$turns" "$default_turns"
        return 0
      fi
      return 1
    fi
    sleep 2; waited=$((waited + 2))
    if (( waited >= timeout )); then
      rm -f "$pend" "$dec"
      return 1
    fi
  done
}

# Hỏi trực tiếp qua /dev/tty (CLI có người ngồi xem).
#   Enter = default_turns · số = custom · n/q = bỏ
resume_prompt_tty() {
  local agent="$1" used="$2" default_turns="$3"
  printf '\n\033[33m⚠\033[0m agent \033[36m%s\033[0m cạn lượt (đã dùng %s). [Enter] resume +%s lượt · số → lượt tuỳ chọn · [n] bỏ → ' \
    "$agent" "$used" "$default_turns" >&2
  local reply
  IFS= read -r reply </dev/tty || return 1
  case "$reply" in
    n|N|q|Q|no|NO) return 1 ;;
    "")            _resume_clamp_turns "$default_turns" "$default_turns"; return 0 ;;
    *)             if [[ "$reply" =~ ^[0-9]+$ ]]; then
                     _resume_clamp_turns "$reply" "$default_turns"; return 0
                   fi
                   return 1 ;;
  esac
}

# Gate dispatch — gọi từ call_agent khi subtype=error_max_turns.
#   $1=agent $2=session_id $3=used_turns $4=default_turns (env: PAGENT_RUN_DIR)
#   stdout: số lượt mới · return 0 = resume · return 1 = không resume (fail như cũ)
# Nhánh:
#   - tty mở được       → hỏi /dev/tty (trừ khi PAGENT_RESUME=0 tắt hẳn)
#   - non-tty + PAGENT_RESUME truthy (web spawn) → file handshake
#   - còn lại           → return 1 ngay (backward-compat automation/test không treo)
resume_gate() {
  local agent="$1" sid="$2" used="$3" default_turns="$4"
  [[ -n "$agent" && -n "$sid" && -n "$PAGENT_RUN_DIR" ]] || return 1
  if [[ "${PAGENT_RESUME:-}" == "0" ]]; then return 1; fi
  if [[ -t 0 && -e /dev/tty ]]; then
    resume_prompt_tty "$agent" "$used" "$default_turns"
    return $?
  fi
  if _resume_truthy "${PAGENT_RESUME:-}"; then
    resume_wait_decision "$agent" "$sid" "$used" "$default_turns"
    return $?
  fi
  return 1
}
