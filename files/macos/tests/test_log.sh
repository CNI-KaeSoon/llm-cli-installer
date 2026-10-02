#!/bin/bash

test_redact_tokens() {
  load_libs common redact log
  local up20 up18 up22 an35 jwt out s
  up20=ABCDEFGHIJKLMNOPQRST
  up18=ABCDEFGHIJKLMNOPQR
  up22=ABCDEFGHIJKLMNOPQRSTUV
  an35=abcdefghijklmnopqrstuvwxyz0123456789
  an35="${an35:0:35}"
  jwt="$(printf 'eyJ%s.eyJ%s.%s' abc123 def456 sig789)"
  local -a inputs secrets
  inputs=(
    "Authorization: Bearer abc.def-123"
    "$(printf 'sk-%s' "$up20")"
    "$(printf 'xai-%s' "$up18")"
    "$(printf 'gh%s%s' 'p_' "$up22")"
    "$(printf 'github%s%s' '_pat_' "$up22")"
    "$(printf 'AIza%s' "$an35")"
    "$jwt"
    "https://user:pw@example.com/x"
    "https://e.com/?token=abc&x=1"
    "$(printf 'API_%s%s' 'KEY=' 'secret123')"
    "$(printf 'pass%s%s' 'word=' 'hunter2')"
    "-----BEGIN RSA PRIVATE KEY-----abc"
  )
  secrets=(
    "abc.def-123" "$up20" "$up18" "$up22" "$up22" "$an35" "$jwt" "user:pw" "token=abc" "secret123" "hunter2" "RSA PRIVATE KEY-----abc"
  )
  local i=0
  while [ "$i" -lt "${#inputs[@]}" ]; do
    out="$(redact_text "${inputs[$i]}")"
    assert_not_contains "$out" "${secrets[$i]}" "비밀값 남음: case $i"
    i=$((i + 1))
  done
  out="$(redact_text "https://e.com/?token=abc&x=1")"
  assert_contains "$out" "x=1" "다른 파라미터 보존"
}

test_redact_home_user() {
  load_libs common redact log
  local out
  HOME=/Users/tester USER=tester
  out="$(redact_text "/Users/tester/.local/bin")"
  assert_eq "~/.local/bin" "$out" "홈 치환"
  out="$(redact_text "/tmp/xtester1/a")"
  assert_eq "/tmp/xtester1/a" "$out" "경로 일부의 사용자 이름은 그대로"
  out="$(redact_text "user is tester")"
  assert_eq "user is tester" "$out" "일반 단어는 치환 안 함"
  HOME=/home/other
  out="$(redact_text "/Users/tester/x")"
  assert_eq "/Users/<USER>/x" "$out" "/Users/<USER> 치환"
}

test_redact_plain_unchanged() {
  load_libs common redact log
  assert_eq "codex-cli 0.160.0 installed" "$(redact_text "codex-cli 0.160.0 installed")"
}

test_log_init_creates() {
  load_libs common redact log
  log_init
  assert_exit 0 $? "log_init"
  assert_contains "$LLMCLI_LOG_DIR" "$LLMCLI_LOG_ROOT/" "루트 아래"
  assert_file_exists "$LLMCLI_LOG_DIR/run.log"
  assert_file_exists "$LLMCLI_LOG_DIR/events.jsonl"
  [ -d "$LLMCLI_LOG_DIR/native" ] || fail "native 폴더 없음"
  local perm
  perm="$(ls -ld "$LLMCLI_LOG_DIR" | awk '{print substr($1,1,10)}')"
  assert_eq "drwx------" "$perm" "폴더 권한"
}

test_log_init_fallback() {
  load_libs common redact log
  LLMCLI_LOG_ROOT=/dev/null/x
  log_init
  assert_exit 0 $? "대체 경로"
  assert_contains "$LLMCLI_LOG_DIR" "$TMPDIR/LLMCliInstaller-" "TMPDIR 대체"
}

test_log_init_fail() {
  load_libs common redact log
  LLMCLI_LOG_ROOT=/dev/null/x
  TMPDIR=/dev/null/y
  log_init
  assert_exit 12 $? "둘 다 실패"
}

test_log_event_json_shape() {
  load_libs common redact log
  log_init
  log_event info run.started Init "" "시작" "" "" a=1 bad-key=2
  local line
  line="$(head -n 1 "$LLMCLI_LOG_DIR/events.jsonl")"
  assert_eq '{"schemaVersion":1,"timestampUtc":"' "${line:0:35}" "시작 부분"
  assert_contains "$line" '"sequence":1'
  assert_contains "$line" '"component":null'
  assert_contains "$line" '"processExitCode":null'
  assert_contains "$line" '"normalizedCode":"OK"'
  assert_contains "$line" '"context":{"a":"1"}'
  assert_not_contains "$line" 'bad-key'
}

test_log_event_sequence_and_redaction() {
  load_libs common redact log
  log_init
  local key
  key="$(printf 'sk-%s' ABCDEFGHIJKLMNOPQRST)"
  log_event info run.started Init "" "first" "" ""
  log_event error error Init "" "token $key \"q\"
x" "" ""
  local second
  second="$(sed -n 2p "$LLMCLI_LOG_DIR/events.jsonl")"
  assert_contains "$second" '"sequence":2'
  assert_contains "$second" '\"q\"'
  assert_contains "$second" '\nx'
  assert_count "$LLMCLI_LOG_DIR/events.jsonl" "$key" 0 "events 키 노출"
  assert_count "$LLMCLI_LOG_DIR/run.log" "$key" 0 "run.log 키 노출"
}

test_log_event_exit_code_number() {
  load_libs common redact log
  log_init
  log_event error error Installing codex "실패" 23 23
  local line
  line="$(head -n 1 "$LLMCLI_LOG_DIR/events.jsonl")"
  assert_contains "$line" '"processExitCode":23,'
  assert_contains "$line" '"normalizedCode":"E_INTEGRITY"'
  assert_contains "$line" '"component":"codex"'
}

test_log_code_name() {
  load_libs common redact log
  assert_eq OK "$(log_code_name 0)"
  assert_eq E_NETWORK "$(log_code_name 20)"
  assert_eq E_PATH_REFRESH_REQUIRED "$(log_code_name 41)"
  assert_eq E_UNEXPECTED "$(log_code_name 99)"
}
