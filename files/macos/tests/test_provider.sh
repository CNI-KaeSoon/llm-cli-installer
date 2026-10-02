#!/bin/bash

_prov_init() {
  load_libs common redact log catalog download provider
  log_init
}

test_install_codex_ok() {
  _prov_init
  prov_install codex
  assert_exit 0 $?
  assert_file_exists "$HOME/.local/bin/codex"
  assert_count "$STUB_LOG" "INSTALL codex" 1
  assert_count "$STUB_LOG" "ENV codex CODEX_NON_INTERACTIVE=1" 1
  assert_file_exists "$LLMCLI_LOG_DIR/native/codex-install.log"
  assert_file_absent "$LLMCLI_LOG_DIR/native/codex-install.raw"
  local n
  n=$(find "$TMPDIR" -name 'llmcli-codex.*' | wc -l | tr -d ' ')
  assert_eq 0 "$n" "임시 파일 정리"
}

test_install_claude_no_codex_env() {
  _prov_init
  prov_install claude
  assert_exit 0 $?
  assert_count "$STUB_LOG" "ENV codex" 0
  assert_count "$STUB_LOG" "INSTALL claude" 1
  assert_count "$STUB_LOG" "INSTALL codex" 0
}

test_install_failure_40() {
  _prov_init
  STUB_INSTALL_FAIL=grok
  export STUB_INSTALL_FAIL
  prov_install grok
  assert_exit 40 $?
  assert_contains "$PROV_ERROR" "종료 코드 1"
}

test_install_download_fail_20() {
  _prov_init
  STUB_CURL_FAIL_URL=x.ai
  export STUB_CURL_FAIL_URL
  prov_install grok
  assert_exit 20 $?
  assert_count "$STUB_LOG" "INSTALL grok" 0
}

test_prov_tmp_set_before_download() {
  _prov_init
  local rec="$SANDBOX/prov_tmp.rec"
  : > "$rec"
  dl_fetch_script() {
    printf '%s' "$PROV_TMP" > "$rec"
    DL_ERROR="stub"
    return 20
  }
  prov_install codex
  assert_exit 20 $?
  local seen
  seen="$(cat "$rec")"
  [ -n "$seen" ] || fail "dl_fetch_script 호출 시 PROV_TMP가 비어 있음"
  [ ! -e "$seen" ] || fail "임시 파일이 남아 있음"
}

test_install_integrity_23() {
  _prov_init
  STUB_CURL_EFFECTIVE_URL=https://evil.example/x
  export STUB_CURL_EFFECTIVE_URL
  prov_install claude
  assert_exit 23 $?
  assert_count "$STUB_LOG" "INSTALL" 0
}

test_install_timeout() {
  _prov_init
  printf '#!/bin/sh\nsleep 30\n' > "$SANDBOX/slow.sh"
  STUB_CURL_BODY_FILE="$SANDBOX/slow.sh"
  export STUB_CURL_BODY_FILE
  LLMCLI_INSTALL_TIMEOUT=1
  local t0 t1
  t0=$(date +%s)
  prov_install claude
  assert_exit 40 $?
  t1=$(date +%s)
  assert_eq "설치 스크립트가 시간 안에 끝나지 않았습니다" "$PROV_ERROR"
  [ $((t1 - t0)) -lt 10 ] || fail "10초 안에 반환해야 함"
}

test_install_output_redacted() {
  _prov_init
  local key
  key="$(printf 'sk-%s' ABCDEFGHIJKLMNOPQRST)"
  printf '#!/bin/sh\necho token %s\n' "$key" > "$SANDBOX/leak.sh"
  STUB_CURL_BODY_FILE="$SANDBOX/leak.sh"
  export STUB_CURL_BODY_FILE
  prov_install claude
  assert_exit 0 $?
  assert_file_exists "$LLMCLI_LOG_DIR/native/claude-install.log"
  assert_not_contains "$(cat "$LLMCLI_LOG_DIR/native/claude-install.log")" "$key"
}

test_install_events() {
  _prov_init
  prov_install claude
  assert_exit 0 $?
  assert_count "$LLMCLI_LOG_DIR/events.jsonl" "component.install.started" 1
  assert_count "$LLMCLI_LOG_DIR/events.jsonl" "component.install.completed" 1
}
