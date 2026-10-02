#!/bin/bash

_sum_setup() {
  load_libs common redact log catalog summary
  NO_COLOR=1
  ui_init
  log_init
}

test_exit_all_ok() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "" ""
  sum_set claude AlreadyPresent 0 2.1.287 "" ""
  assert_eq "0" "$(sum_exit_code "codex claude")"
}

test_exit_path_only() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "" ""
  sum_set grok PathRefreshRequired 41 "" "" ""
  assert_eq "41" "$(sum_exit_code "codex grok")"
}

test_exit_partial() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "" ""
  sum_set claude Failed 20 "" "" ""
  assert_eq "60" "$(sum_exit_code "codex claude")"
  sum_set codex PathRefreshRequired 41 "" "" ""
  sum_set claude Failed 40 "" "" ""
  assert_eq "60" "$(sum_exit_code "codex claude")"
}

test_exit_all_fail_first_in_catalog_order() {
  _sum_setup
  sum_set grok Failed 50 "" "" ""
  sum_set claude Failed 20 "" "" ""
  assert_eq "20" "$(sum_exit_code "grok claude")"
}

test_messages() {
  _sum_setup
  assert_eq "설치는 됐지만 새 터미널을 열어야 grok 명령을 쓸 수 있습니다." "$(sum_message 41 grok)"
  assert_contains "$(sum_message 40 claude)" "native/claude-install.log"
  assert_contains "$(sum_message 50 antigravity)" "agy"
}

test_json_shape() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "$HOME/.local/bin/codex" ""
  sum_set grok Failed 20 "" "" "$(sum_message 20 grok)"
  sum_write_json "codex grok" "codex grok" 60
  local f="$LLMCLI_LOG_DIR/summary.json" c
  assert_file_exists "$f"
  c="$(cat "$f")"
  case "$c" in
    '{"schemaVersion":1,"runId":"'*) : ;;
    *) fail "summary.json 시작이 다름: $c" ;;
  esac
  assert_contains "$c" '"selected":["codex","grok"]'
  assert_contains "$c" '"exitCode":60'
  assert_contains "$c" '"state":"Installed"'
  assert_contains "$c" '"path":"~/'
  assert_not_contains "$c" "$HOME"
}

test_print_summary() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "" ""
  sum_set claude AlreadyPresent 0 2.1.287 "" ""
  sum_set grok PathRefreshRequired 41 "" "" "$(sum_message 41 grok)"
  sum_set antigravity Failed 20 "" "" "$(sum_message 20 antigravity)"
  local out
  out="$(sum_print "codex claude grok antigravity" 60 2>&1)"
  assert_contains "$out" "[성공] Codex CLI 0.160.0 (새로 설치)"
  assert_contains "$out" "[성공] Claude Code 2.1.287 (이미 설치되어 있음)"
  assert_contains "$out" "[경고] Grok CLI: 설치는 됐지만"
  assert_contains "$out" "[실패] Antigravity CLI: 설치 스크립트를 받지 못했습니다"
  assert_contains "$out" "새 터미널을 열고 쓸 수 있는 명령: codex, claude, grok"
  assert_contains "$out" "진단 기록:"
}

test_print_no_commands_line_when_all_fail() {
  _sum_setup
  sum_set codex Failed 20 "" "" "$(sum_message 20 codex)"
  sum_set claude Failed 40 "" "" "$(sum_message 40 claude)"
  local out
  out="$(sum_print "codex claude" 20 2>&1)"
  assert_not_contains "$out" "쓸 수 있는 명령"
  assert_contains "$out" "[실패]"
}

test_unset_result_is_90() {
  _sum_setup
  sum_set codex Installed 0 0.160.0 "" ""
  assert_eq "90" "$(sum_exit_code "codex claude")"
}
