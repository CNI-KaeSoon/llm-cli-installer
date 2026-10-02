#!/bin/bash

test_launcher_runs_main() {
  local out rc
  copy_package >/dev/null
  out="$(/bin/bash "$SANDBOX/pkg/installer-mac.command" --version < /dev/null 2>&1)"
  rc=$?
  assert_exit 0 "$rc" "launcher exit"
  assert_contains "$out" "3.0.0"
  assert_contains "$out" "종료 코드: 0"
}

test_launcher_passes_exit_code() {
  local out rc
  copy_package >/dev/null
  out="$(/bin/bash "$SANDBOX/pkg/installer-mac.command" --bogus < /dev/null 2>&1)"
  rc=$?
  assert_exit 2 "$rc" "launcher exit"
  assert_contains "$out" "종료 코드: 2"
}

test_launcher_missing_main() {
  local out rc
  copy_package >/dev/null
  rm -f "$SANDBOX/pkg/files/macos/bin/llmcli-install.sh"
  out="$(/bin/bash "$SANDBOX/pkg/installer-mac.command" < /dev/null 2>&1)"
  rc=$?
  assert_exit 24 "$rc" "launcher exit"
  assert_contains "$out" "files/macos/bin/llmcli-install.sh가 없습니다"
}

test_launcher_in_manifest() {
  local out
  out="$(/bin/bash "$MAC_DIR/tools/update-manifest.sh" --list "$PKG_ROOT")"
  assert_contains "$out" "installer-mac.command"
}

test_launcher_exec_bit() {
  [ -x "$PKG_ROOT/installer-mac.command" ] || fail "installer-mac.command not executable"
}
