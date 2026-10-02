#!/bin/bash

test_constants() {
  load_libs common
  assert_eq 70 "$EXIT_CANCELLED" "EXIT_CANCELLED"
  assert_eq 41 "$EXIT_PATH_REFRESH_REQUIRED" "EXIT_PATH_REFRESH_REQUIRED"
  assert_eq 124 "$EXIT_TIMEOUT" "EXIT_TIMEOUT"
}

test_ui_prefixes_no_color() {
  load_libs common
  NO_COLOR=1; ui_init
  assert_eq '[성공] hi' "$(ui_success hi)"
  assert_eq '[경고] hi' "$(ui_warn hi)"
  assert_eq '[실패] hi' "$(ui_fail hi)"
  assert_eq '[진단] x' "$(ui_step 진단 x)"
  assert_eq '[설치 2/3] y' "$(ui_progress 2 3 y)"
  local esc out
  esc="$(printf '\033')"
  out="$(ui_success hi; ui_warn hi; ui_fail hi)"
  assert_not_contains "$out" "$esc" "ESC 문자 없음"
}

test_ui_err_stderr() {
  load_libs common
  local out
  out="$(ui_err x 2>/dev/null)"
  assert_eq "" "$out"
}

test_str_helpers() {
  load_libs common
  assert_eq abc "$(str_lower ABC)"
  assert_eq "a b" "$(str_trim "  a b  ")"
}

test_var_set_get() {
  load_libs common
  var_set RES_STATE_codex Installed
  assert_eq Installed "$(var_get RES_STATE_codex)"
  assert_eq "" "$(var_get NOPE_codex)"
  var_set 'bad name' x
  assert_exit 90 $?
}

test_json_escape() {
  load_libs common
  local in out want
  in="$(printf 'a"b\\c\n\t')"
  # 명령 치환이 끝 줄바꿈을 지우므로 탭으로 끝나는 입력을 직접 만든다.
  in=$'a"b\\c\n\t'
  out="$(json_escape "$in")"
  want='a\"b\\c\n\t'
  assert_eq "$want" "$out"
  in="$(printf 'x\001y')"
  assert_eq "xy" "$(json_escape "$in")"
}

test_ver_extract() {
  load_libs common
  assert_eq 0.160.0 "$(ver_extract 'codex-cli 0.160.0')"
  assert_eq 2.1.287 "$(ver_extract '2.1.287 (Claude Code)')"
  local out rc
  out="$(ver_extract none)"; rc=$?
  assert_eq "" "$out"
  assert_exit 1 "$rc"
}

test_timeout_success() {
  load_libs common
  run_with_timeout 5 /bin/sh -c 'exit 3'
  assert_exit 3 $?
}

test_timeout_kills_grandchild() {
  load_libs common
  local before after rc
  before="$(pgrep -f 'sleep 30' | wc -l | tr -d ' ')"
  run_with_timeout 1 /bin/sh -c 'sleep 30 & wait'
  rc=$?
  assert_exit 124 "$rc"
  sleep 2
  after="$(pgrep -f 'sleep 30' | wc -l | tr -d ' ')"
  assert_eq "$before" "$after" "sleep 30 프로세스 수"
}

test_timeout_expires() {
  load_libs common
  local t0 t1 rc
  t0="$(date +%s)"
  run_with_timeout 1 sleep 10
  rc=$?
  t1="$(date +%s)"
  assert_exit 124 "$rc"
  [ $((t1 - t0)) -lt 8 ] || fail "시간 초과 처리가 너무 오래 걸림: $((t1 - t0))초"
}
