#!/usr/bin/env bash
# Portable advisory file lock cho pagent.
# Linux: flock(1). macOS (không có flock, bash 3.2): atomic mkdir spin-lock.
# shellcheck shell=bash

# with_lock <lock_path> <command...>
#   Giữ lock độc quyền theo <lock_path> trong khi chạy <command...>.
#   stdout/stderr/return code của <command...> được pass-through nguyên vẹn.
#   Lock tự nhả khi command xong (đóng fd hoặc rmdir).
with_lock() {
  local lock="$1"; shift
  local rc=0
  if command -v flock >/dev/null 2>&1; then
    # Subshell scoping: fd 9 chỉ tồn tại trong subshell, không leak ra
    # calling process → không conflict nếu code khác cũng dùng fd 9.
    ( flock 9; "$@" ) 9>"$lock.lock" || rc=$?
    return $rc
  fi
  # Fallback macOS: mkdir là atomic create-or-fail → dùng làm mutex.
  local lockdir="$lock.lockd" i=0
  until mkdir "$lockdir" 2>/dev/null; do
    sleep 0.05
    (( ++i > 200 )) && break   # ~10s timeout — thà chạy còn hơn deadlock
  done
  "$@" || rc=$?
  rmdir "$lockdir" 2>/dev/null || true
  return $rc
}
