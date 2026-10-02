#!/bin/bash

test_host_of() {
  load_libs common download
  assert_eq "claude.ai" "$(dl_host_of 'https://Claude.AI/install.sh')"
  assert_eq "x.ai" "$(dl_host_of 'https://u:p@x.ai:443/cli')"
  assert_eq "a.b" "$(dl_host_of 'https://a.b?x')"
  dl_host_of 'http://x.ai/' >/dev/null
  assert_exit 1 $?
}

test_host_allowed() {
  load_libs common download
  dl_host_allowed claude.ai "claude.ai downloads.claude.ai"
  assert_exit 0 $?
  dl_host_allowed evil.claude.ai "claude.ai downloads.claude.ai"
  assert_exit 1 $?
  dl_host_allowed claude.ai.evil.com "claude.ai downloads.claude.ai"
  assert_exit 1 $?
}

test_fetch_ok() {
  load_libs common download
  dl_fetch_script https://claude.ai/install.sh "claude.ai downloads.claude.ai" "$SANDBOX/s.sh"
  assert_exit 0 $?
  assert_eq 64 "${#DL_SHA256}" "sha256 길이"
  [ "$DL_BYTES" -gt 0 ] || fail "DL_BYTES > 0"
  assert_count "$STUB_LOG" "CURL" 1
}

test_fetch_bad_initial_host() {
  load_libs common download
  dl_fetch_script https://evil.example/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
  assert_count "$STUB_LOG" "CURL" 0
}

test_fetch_redirect_offlist() {
  load_libs common download
  export STUB_CURL_EFFECTIVE_URL=https://evil.example/x
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
  assert_contains "$DL_ERROR" "evil.example"
}

test_fetch_redirect_http() {
  load_libs common download
  export STUB_CURL_EFFECTIVE_URL=http://claude.ai/x
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_fetch_network_error() {
  load_libs common download
  export STUB_CURL_FAIL_URL=claude.ai
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 20 $?
}

test_fetch_too_big_curl63() {
  load_libs common download
  export STUB_CURL_EXIT=63
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_fetch_empty() {
  load_libs common download
  : > "$SANDBOX/body"
  export STUB_CURL_BODY_FILE="$SANDBOX/body"
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_fetch_nul() {
  load_libs common download
  printf '#!/bin/sh\n\000x' > "$SANDBOX/body"
  export STUB_CURL_BODY_FILE="$SANDBOX/body"
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_fetch_no_shebang() {
  load_libs common download
  echo hi > "$SANDBOX/body"
  export STUB_CURL_BODY_FILE="$SANDBOX/body"
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_fetch_oversize() {
  load_libs common download
  { printf '#!'; head -c 2097200 /dev/zero | tr '\000' 'a'; } > "$SANDBOX/body"
  export STUB_CURL_BODY_FILE="$SANDBOX/body"
  dl_fetch_script https://claude.ai/install.sh "claude.ai" "$SANDBOX/s.sh"
  assert_exit 23 $?
}

test_live_hosts() {
  [ "${LLMCLI_LIVE-}" = "1" ] || { skip "live only"; return 0; }
  load_libs common download
  PATH=/usr/bin:/bin
  dl_fetch_script https://chatgpt.com/codex/install.sh "chatgpt.com releases.openai.com" "$SANDBOX/codex.sh"
  assert_exit 0 $? "codex: $DL_ERROR"
  dl_fetch_script https://claude.ai/install.sh "claude.ai downloads.claude.ai" "$SANDBOX/claude.sh"
  assert_exit 0 $? "claude: $DL_ERROR"
  dl_fetch_script https://antigravity.google/cli/install.sh "antigravity.google" "$SANDBOX/agy.sh"
  assert_exit 0 $? "antigravity: $DL_ERROR"
  dl_fetch_script https://x.ai/cli/install.sh "x.ai" "$SANDBOX/grok.sh"
  assert_exit 0 $? "grok: $DL_ERROR"
}
