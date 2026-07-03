#!/usr/bin/env bash
# Test: pagent persist mode vào runs/<tid>/mode.txt (atomic) để web retry tái dựng.
# Inline trong cmd_pipeline (không extract được) → assert theo nội dung script + 1
# functional round-trip cho đúng snippet ghi file.

PASS=0; FAIL=0
cd "$(dirname "$0")/.." || exit 1
PAGENT="./pagent"

assert_grep() {
  local desc="$1" pattern="$2"
  if grep -qE -- "$pattern" "$PAGENT"; then
    echo "PASS: $desc"; ((PASS++))
  else
    echo "FAIL: $desc — regex not found: $pattern"; ((FAIL++))
  fi
}

echo "=== pagent syntax ==="
if bash -n "$PAGENT"; then echo "PASS: bash -n pagent"; ((PASS++)); else echo "FAIL: bash -n pagent"; ((FAIL++)); fi

echo "=== persist mode.txt ==="
assert_grep "ghi mode.txt từ PAGENT_MODE"       'PAGENT_MODE" >"\$PAGENT_RUN_DIR/mode.txt.tmp"'
assert_grep "atomic mv mode.txt.tmp → mode.txt" 'mv -f "\$PAGENT_RUN_DIR/mode.txt.tmp" "\$PAGENT_RUN_DIR/mode.txt"'
assert_grep "ghi ngay sau task.txt"             'echo "\$task" >"\$PAGENT_RUN_DIR/task.txt"'

echo "=== functional round-trip (snippet ghi file) ==="
RUN_DIR="$(mktemp -d)"
PAGENT_MODE="hotfix" PAGENT_RUN_DIR="$RUN_DIR" bash -c \
  'printf "%s\n" "$PAGENT_MODE" >"$PAGENT_RUN_DIR/mode.txt.tmp" && mv -f "$PAGENT_RUN_DIR/mode.txt.tmp" "$PAGENT_RUN_DIR/mode.txt"'
if [[ "$(cat "$RUN_DIR/mode.txt" 2>/dev/null)" == "hotfix" ]]; then
  echo "PASS: mode.txt chứa dispatch vocab (hotfix)"; ((PASS++))
else
  echo "FAIL: mode.txt sai nội dung"; ((FAIL++))
fi
if [[ ! -e "$RUN_DIR/mode.txt.tmp" ]]; then
  echo "PASS: không còn file .tmp (atomic)"; ((PASS++))
else
  echo "FAIL: còn sót mode.txt.tmp"; ((FAIL++))
fi
rm -rf "$RUN_DIR"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
