#!/bin/bash
# 테스트 도우미. source될 때는 정의만 한다.

_HELPERS_SELF="${BASH_SOURCE[0]}"
TESTS_DIR="$(cd "$(dirname "$_HELPERS_SELF")/.." && pwd)"
MAC_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PKG_ROOT="$(cd "$MAC_DIR/../.." && pwd)"

setup_sandbox() {
  SANDBOX="$(mktemp -d "${LLMCLI_TEST_TMP:-${TMPDIR:-/tmp}}/sbx.XXXXXX")"
  mkdir -p "$SANDBOX/home" "$SANDBOX/tmp"
  : > "$SANDBOX/stub.log"
  export SANDBOX
  export HOME="$SANDBOX/home"
  export TMPDIR="$SANDBOX/tmp"
  export STUB_LOG="$SANDBOX/stub.log"
  export PATH="$TESTS_DIR/stubs:$PATH"
  export LLMCLI_ZSH="$TESTS_DIR/stubs/zsh"
  export LLMCLI_LOG_ROOT="$SANDBOX/logs"
  export NO_COLOR=1
  export LLMCLI_OS_NAME=Darwin
  export LLMCLI_OS_VERSION=15.0
  export LLMCLI_ARCH=arm64
  export SHELL=/bin/zsh
  export LLMCLI_INSTALL_TIMEOUT=30
  export LLMCLI_VERIFY_TIMEOUT=10
  export USER=tester
  unset STUB_CURL_FAIL_URL STUB_CURL_EXIT STUB_CURL_BODY_FILE STUB_CURL_EFFECTIVE_URL
  unset STUB_ZSH_PATH STUB_INSTALL_FAIL STUB_FIXTURE_NO_PATH
  unset LLMCLI_FORCE_INTERACTIVE
  local v
  for v in $(env | sed -n -E 's/^(STUB_[A-Za-z0-9_]*)=.*/\1/p'); do
    if [ "$v" != "STUB_LOG" ]; then
      unset "$v"
    fi
  done
}

load_libs() {
  local n
  for n in "$@"; do
    . "$MAC_DIR/lib/$n.sh"
  done
}

copy_package() {
  mkdir -p "$SANDBOX/pkg/files"
  cp -Rp "$MAC_DIR" "$SANDBOX/pkg/files/macos"
  if [ -f "$PKG_ROOT/installer-mac.command" ]; then
    cp -p "$PKG_ROOT/installer-mac.command" "$SANDBOX/pkg/"
  fi
  /bin/bash "$SANDBOX/pkg/files/macos/tools/update-manifest.sh" "$SANDBOX/pkg" > /dev/null
  printf '%s\n' "$SANDBOX/pkg"
}

run_main() {
  /bin/bash "$SANDBOX/pkg/files/macos/bin/llmcli-install.sh" "$@" > "$SANDBOX/out.txt" 2>&1
}
