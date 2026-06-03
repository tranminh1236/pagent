#!/usr/bin/env bash
# Regression: orchestrator pipe must not die under `set -o pipefail` when
# extra_info is empty (the normal first round).
#
# Bug: the left-hand brace group feeding `call_agent orchestrator` ended with
#   [[ -n "$extra_info" ]] && { ...; }
# When extra_info is empty, `[[ -n "" ]]` exits 1. As the LAST command of the
# LHS brace group, pipefail propagated that 1 as the whole pipeline's exit code
# even though call_agent succeeded — firing `|| die "orchestrator fail"`.
# Every normal `pagent fix`/`feat` run hit this.

PASS=0
FAIL=0

cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

echo "=== orchestrator pipefail — static guard ==="

# The orchestrator pipe must NOT end the LHS brace group with a bare
# `[[ ... ]] &&` conditional. Require the `if ...; fi` form instead.
if grep -qE '^\s*\[\[ -n "\$extra_info" \]\] &&' "$PAGENT"; then
  echo "FAIL: LHS of orchestrator pipe ends with bare '[[ -n \$extra_info ]] &&' — breaks pipefail"
  ((FAIL++))
else
  echo "PASS: no bare trailing conditional in orchestrator pipe LHS"
  ((PASS++))
fi

echo ""
echo "=== orchestrator pipefail — behavioral repro ==="

# Reproduce the exact construct: brace group (ending in the extra_info guard)
# piped into a successful consumer, under the same shell options pagent uses.
run_pipe() {
  local extra_info="$1"
  # mirror pagent's `set -euo pipefail`
  set -euo pipefail
  out="$( {
    echo "## MODE"; echo "hotfix"; echo
    echo "## TASK"; echo "demo"
    if [[ -n "$extra_info" ]]; then echo; echo "## ADDITIONAL_INFO"; echo "$extra_info"; fi
  } | cat )"
  printf '%s' "$out" >/dev/null
}

if ( run_pipe "" ); then
  echo "PASS: pipeline exits 0 when extra_info empty (normal run)"
  ((PASS++))
else
  echo "FAIL: pipeline exited nonzero with empty extra_info — would 'orchestrator fail'"
  ((FAIL++))
fi

if ( run_pipe "more context" ); then
  echo "PASS: pipeline exits 0 when extra_info set (re-run round)"
  ((PASS++))
else
  echo "FAIL: pipeline exited nonzero with extra_info set"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
