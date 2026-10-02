#!/bin/bash

_sel_init() { load_libs common catalog selection; NO_COLOR=1; ui_init; }
TAB=$'\t'
ALL4="codex claude antigravity grok"

test_normalize_aliases() {
  _sel_init
  local pair in out
  for pair in codex:codex OpenAI:codex chatgpt:codex claude:claude Claude-Code:claude anthropic:claude \
    antigravity:antigravity agy:antigravity google:antigravity gemini:antigravity grok:grok xai:grok all:all; do
    in="${pair%%:*}"
    out="$(sel_normalize_name "$in")"
    assert_eq "${pair#*:}" "$out" "normalize $in"
  done
  local rc=0
  out="$(sel_normalize_name legacy-gemini)" || rc=$?
  assert_exit 3 "$rc" "legacy-gemini rc"
  assert_eq "" "$out" "legacy-gemini empty"
  rc=0
  out="$(sel_normalize_name foo)" || rc=$?
  assert_exit 1 "$rc" "foo rc"
  assert_eq "" "$out" "foo empty"
}

test_expand_all_dedupe() {
  _sel_init
  assert_eq "grok codex claude antigravity" "$(sel_expand grok all)"
  assert_eq "codex" "$(sel_expand codex codex)"
}

_chk_menu() { # <응답> <기대 출력> <기대 rc>
  local out rc=0
  out="$(sel_parse_menu_answer "$1")" || rc=$?
  assert_eq "$2" "$out" "menu '$1' out"
  assert_exit "$3" "$rc" "menu '$1' rc"
}

test_menu_answer_examples() {
  _sel_init
  _chk_menu "1,3" "codex antigravity" 0
  _chk_menu " 2 4 " "claude grok" 0
  _chk_menu "5" "$ALL4" 0
  _chk_menu "" "$ALL4" 0
  _chk_menu "Codex, google" "codex antigravity" 0
  _chk_menu "0" "CANCEL" 0
  _chk_menu "0,1" "" 1
  _chk_menu "6" "" 1
  _chk_menu "legacy-gemini" "" 1
  _chk_menu "abc" "" 1
  _chk_menu "4,4,1" "grok codex" 0
}

test_components_arg() {
  _sel_init
  local rc
  rc=0; sel_parse_components_arg "codex,claude" || rc=$?
  assert_exit 0 "$rc"; assert_eq "codex claude" "$SEL_RESULT"
  rc=0; sel_parse_components_arg "google" || rc=$?
  assert_exit 0 "$rc"; assert_eq "antigravity" "$SEL_RESULT"
  rc=0; sel_parse_components_arg "all" || rc=$?
  assert_exit 0 "$rc"; assert_eq "$ALL4" "$SEL_RESULT"
  rc=0; sel_parse_components_arg "1" || rc=$?
  assert_exit 1 "$rc"; assert_eq "1" "$SEL_ERROR_TOKEN"
  rc=0; sel_parse_components_arg "codex,legacy-gemini" || rc=$?
  assert_exit 3 "$rc"
  rc=0; sel_parse_components_arg "" || rc=$?
  assert_exit 1 "$rc"; assert_eq "" "$SEL_ERROR_TOKEN"
}

test_plan_only_selected() {
  _sel_init
  local out
  out="$(sel_plan "grok codex")"
  assert_eq "codex${TAB}selected${TAB}-
grok${TAB}selected${TAB}-" "$out"
  assert_eq "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
}

test_plan_dependency_rows() {
  _sel_init
  cat_get() { case "$1:$2" in grok:depends) echo codex ;; codex:depends|claude:depends|antigravity:depends) : ;; grok:display) echo "Grok CLI" ;; codex:display) echo "Codex CLI" ;; *) return 1 ;; esac; }
  local out
  out="$(sel_plan grok)"
  assert_eq "codex${TAB}dependency${TAB}Grok CLI
grok${TAB}selected${TAB}-" "$out"
  out="$(sel_plan claude)"
  assert_not_contains "$out" "codex"
  assert_eq "claude${TAB}selected${TAB}-" "$out"
}

test_print_menu_text() {
  _sel_init
  local out
  out="$(sel_print_menu)"
  assert_contains "$out" "설치할 CLI를 선택하세요."
  assert_contains "$out" "  1) Codex CLI (OpenAI)"
  assert_contains "$out" "  2) Claude Code (Anthropic)"
  assert_contains "$out" "  3) Antigravity CLI (Google 개인 계정, Gemini CLI 후속)"
  assert_contains "$out" "  4) Grok CLI (xAI)"
  assert_contains "$out" "  5) 전체 설치 (1~4 모두)"
  assert_contains "$out" "  0) 설치하지 않고 종료"
  assert_contains "$out" "여러 개는 쉼표로 구분합니다(예: 1,3). 아무것도 입력하지 않고 Enter를 누르면 전체를 고릅니다."
}

test_print_plan_rows() {
  _sel_init
  local out
  out="$(printf 'codex\tselected\t-\tinstall\t\nclaude\tselected\t-\tpresent\t2.1.287\ngrok\tselected\t-\tinstall\t\n' | sel_print_plan)"
  assert_contains "$out" "설치 계획"
  assert_contains "$out" "  - Codex CLI: 설치함"
  assert_contains "$out" "  - Claude Code: 이미 있음(버전 2.1.287, 건너뜀)"
  assert_contains "$out" "  - Grok CLI: 설치함 — 참고: Grok 설치기는 agent 명령도 만듭니다"
  assert_not_contains "$out" "Antigravity"
  out="$(printf 'codex\tdependency\tGrok CLI\tinstall\t\n' | sel_print_plan)"
  assert_contains "$out" " (Grok CLI 실행에 필요)"
}

_run_loop() { # <입력 파일 내용(printf 형식)>
  printf "$1" > "$SANDBOX/in.txt"
  SEL_INVALID_COUNT=0
  LOOP_RC=0
  sel_menu_loop < "$SANDBOX/in.txt" > "$SANDBOX/o.txt" || LOOP_RC=$?
}

test_menu_loop_valid() {
  _sel_init
  _run_loop '1,3\n'
  assert_exit 0 "$LOOP_RC"; assert_eq "codex antigravity" "$SEL_RESULT"
}

test_menu_loop_reask() {
  _sel_init
  _run_loop '9\n2\n'
  assert_exit 0 "$LOOP_RC"; assert_eq "claude" "$SEL_RESULT"
  assert_count "$SANDBOX/o.txt" "잘못된 입력입니다. 0~5 사이 번호를 입력하세요." 1
}

test_menu_loop_enter_is_all() {
  _sel_init
  _run_loop '\n'
  assert_exit 0 "$LOOP_RC"; assert_eq "$ALL4" "$SEL_RESULT"
}

test_menu_loop_eof_is_not_all() {
  _sel_init
  _run_loop ''
  assert_exit 2 "$LOOP_RC"
  assert_ne "$ALL4" "$SEL_RESULT" "EOF must not select all"
  assert_eq "" "$SEL_RESULT"
}

test_menu_loop_cancel() {
  _sel_init
  _run_loop '0\n'
  assert_exit 70 "$LOOP_RC"
}

test_menu_loop_five_invalid() {
  _sel_init
  _run_loop 'x\nx\nx\nx\nx\n1\n'
  assert_exit 2 "$LOOP_RC"
  assert_ne "codex" "$SEL_RESULT"
}

test_confirm_answers() {
  _sel_init
  local a rc
  for a in y YES 예 ㅛ; do
    printf '%s\n' "$a" > "$SANDBOX/in.txt"; rc=0
    sel_confirm_prompt < "$SANDBOX/in.txt" > /dev/null || rc=$?
    assert_exit 0 "$rc" "confirm $a"
  done
  for a in n No 아니오 ㅜ; do
    printf '%s\n' "$a" > "$SANDBOX/in.txt"; rc=0
    sel_confirm_prompt < "$SANDBOX/in.txt" > /dev/null || rc=$?
    assert_exit 1 "$rc" "confirm $a"
  done
  SEL_INVALID_COUNT=0
  printf 'maybe\n' > "$SANDBOX/in.txt"; rc=0
  sel_confirm_prompt < "$SANDBOX/in.txt" > /dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc"; assert_eq "1" "$SEL_INVALID_COUNT"
  : > "$SANDBOX/in.txt"; rc=0
  sel_confirm_prompt < "$SANDBOX/in.txt" > /dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc"; assert_eq "2" "$SEL_INVALID_COUNT"
}
