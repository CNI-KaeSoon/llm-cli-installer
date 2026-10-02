#!/bin/bash

test_assert_eq_pass() {
  assert_eq a a
}

test_assert_fail_exits() {
  ( assert_eq a b ) 2> /dev/null
  assert_exit 1 $? "assert_eq 실패 종료 코드"
}

test_sandbox_home() {
  assert_eq "$SANDBOX/home" "$HOME"
  [ -d "$HOME" ] || fail "HOME 폴더 없음"
  [ -d "$TMPDIR" ] || fail "TMPDIR 폴더 없음"
  assert_file_exists "$STUB_LOG"
}

test_curl_stub_serves_fixture() {
  local out
  out="$(curl -fsSL -w '%{url_effective}' -o "$SANDBOX/c.sh" https://claude.ai/install.sh)"
  assert_eq "https://claude.ai/install.sh" "$out"
  assert_eq '#!/bin/sh' "$(head -n 1 "$SANDBOX/c.sh")"
  assert_count "$STUB_LOG" "CURL https://claude.ai/install.sh" 1
}

test_curl_stub_fail_url() {
  local rc
  STUB_CURL_FAIL_URL=claude.ai curl -fsSL -o "$SANDBOX/c.sh" https://claude.ai/install.sh
  rc=$?
  assert_exit 6 "$rc"
}

test_curl_stub_effective_override() {
  local out
  out="$(STUB_CURL_EFFECTIVE_URL=https://evil.example/x curl -fsSL -w '%{url_effective}' -o "$SANDBOX/c.sh" https://claude.ai/install.sh)"
  assert_eq "https://evil.example/x" "$out"
}

test_fixture_creates_binary() {
  /bin/sh "$TESTS_DIR/fixtures/installers/codex.sh"
  assert_eq "codex-cli 0.160.0" "$("$HOME/.local/bin/codex")"
  assert_count "$STUB_LOG" "INSTALL codex" 1
}

test_fixture_fail() {
  local rc
  STUB_INSTALL_FAIL=codex /bin/sh "$TESTS_DIR/fixtures/installers/codex.sh" 2> /dev/null
  rc=$?
  assert_exit 1 "$rc"
  assert_file_absent "$HOME/.local/bin/codex"
}

test_grok_fixture_path_line() {
  /bin/sh "$TESTS_DIR/fixtures/installers/grok.sh"
  assert_count "$HOME/.zshrc" ".grok/bin" 1
  rm -f "$HOME/.zshrc"
  STUB_FIXTURE_NO_PATH=grok /bin/sh "$TESTS_DIR/fixtures/installers/grok.sh"
  assert_count "$HOME/.zshrc" ".grok/bin" 0
}

test_zsh_stub_lookup() {
  local rc out
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n' > "$HOME/.local/bin/x"
  chmod 755 "$HOME/.local/bin/x"
  out="$("$LLMCLI_ZSH" -lic 'script' llmcli x)"
  rc=$?
  assert_exit 0 "$rc"
  assert_eq "LLMCLI_PATH:" "$out"
  echo 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  out="$("$LLMCLI_ZSH" -lic 'script' llmcli x)"
  assert_eq "LLMCLI_PATH:$HOME/.local/bin/x" "$out"
}
