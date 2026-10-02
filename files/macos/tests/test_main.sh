#!/bin/bash

_main_in() { printf "$1" > "$SANDBOX/in.txt"; }

test_isel_single_each() {
  copy_package >/dev/null
  load_libs common platform catalog
  local id rc
  for id in codex claude antigravity grok; do
    HOME="$(mktemp -d "$SANDBOX/tmp/h.XXXXXX")"
    STUB_LOG="$(mktemp "$SANDBOX/tmp/s.XXXXXX")"
    export HOME STUB_LOG
    rc=0
    run_main --components "$id" --yes --non-interactive < /dev/null || rc=$?
    assert_exit 0 "$rc" "$id 종료 코드"
    assert_count "$STUB_LOG" "INSTALL " 1 "$id INSTALL 줄 수"
    assert_count "$STUB_LOG" "INSTALL $id" 1 "$id INSTALL"
    assert_count "$STUB_LOG" "CURL " 1 "$id CURL 줄 수"
    assert_count "$STUB_LOG" "CURL $(cat_get "$id" url)" 1 "$id URL"
  done
}

test_isel_menu_1_3() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '1,3\ny\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "INSTALL " 2
  assert_count "$STUB_LOG" "INSTALL codex" 1
  assert_count "$STUB_LOG" "INSTALL antigravity" 1
  assert_count "$STUB_LOG" "INSTALL claude" 0
  assert_count "$STUB_LOG" "INSTALL grok" 0
  assert_not_contains "$(cat "$SANDBOX/out.txt")" "  - Claude Code:"
  assert_not_contains "$(cat "$SANDBOX/out.txt")" "  - Grok CLI:"
}

test_isel_menu_2_4() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '2 4\ny\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "INSTALL " 2
  assert_count "$STUB_LOG" "INSTALL claude" 1
  assert_count "$STUB_LOG" "INSTALL grok" 1
  assert_count "$STUB_LOG" "INSTALL codex" 0
  assert_count "$STUB_LOG" "INSTALL antigravity" 0
}

test_isel_enter_all() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '\ny\n'
  local rc=0 id
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  for id in codex claude antigravity grok; do
    assert_count "$STUB_LOG" "INSTALL $id" 1
  done
  assert_count "$STUB_LOG" "INSTALL " 4
}

test_confirm_no_then_cancel() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '2\nn\n0\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 70 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
  assert_file_absent "$HOME/.zprofile"
  assert_contains "$(cat "$SANDBOX/out.txt")" "설치를 취소했습니다. 변경된 것은 없습니다."
}

test_confirm_no_then_reselect() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '2\nn\n1\ny\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "INSTALL " 1
  assert_count "$STUB_LOG" "INSTALL codex" 1
}

test_eof_never_installs() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  : > "$SANDBOX/in.txt"
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 2 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
}

test_invalid_five_times() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '9\n9\n9\n9\n9\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 2 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
}

test_confirm_invalid_then_yes() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '1\nmaybe\ny\n'
  local rc=0
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "INSTALL " 1
  assert_count "$STUB_LOG" "INSTALL codex" 1
}

test_components_then_no_cancels() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in 'n\n'
  local rc=0
  run_main --components codex < "$SANDBOX/in.txt" || rc=$?
  assert_exit 70 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
}

test_noninteractive_requires_components() {
  copy_package >/dev/null
  local rc=0
  run_main --non-interactive < /dev/null || rc=$?
  assert_exit 2 "$rc" "--non-interactive만"
  rc=0
  run_main --yes < /dev/null || rc=$?
  assert_exit 2 "$rc" "--yes만"
  assert_count "$STUB_LOG" "CURL" 0
}

test_noninteractive_requires_yes() {
  copy_package >/dev/null
  local rc=0
  run_main --components codex --non-interactive < /dev/null || rc=$?
  assert_exit 2 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
  assert_contains "$(cat "$SANDBOX/out.txt")" "Codex CLI: 설치함"
}

test_dry_run_changes_nothing() {
  copy_package >/dev/null
  local rc=0 n
  run_main --components all --dry-run --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
  assert_file_absent "$HOME/.zprofile"
  n="$(find "$HOME" -type f | wc -l | tr -d ' ')"
  assert_eq 0 "$n" "HOME 파일 수"
}

test_legacy_gemini_rejected() {
  copy_package >/dev/null
  local rc=0
  run_main --components legacy-gemini --yes --non-interactive < /dev/null || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$(cat "$SANDBOX/out.txt")" "Legacy Gemini CLI는 macOS 판에서 지원하지 않습니다."
  assert_count "$STUB_LOG" "CURL" 0
}

test_unknown_option() {
  copy_package >/dev/null
  local rc=0
  run_main --bogus < /dev/null || rc=$?
  assert_exit 2 "$rc"
}

test_unknown_component() {
  copy_package >/dev/null
  local rc=0
  run_main --components foo --yes --non-interactive < /dev/null || rc=$?
  assert_exit 2 "$rc"
  assert_contains "$(cat "$SANDBOX/out.txt")" "알 수 없는 구성요소: foo"
}

test_runs_without_no_color() {
  copy_package >/dev/null
  unset NO_COLOR
  local rc=0
  run_main --components codex --yes --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc"
}

test_already_present_skipped() {
  copy_package >/dev/null
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "codex-cli 0.160.0"\n' > "$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.zprofile"
  local rc=0
  run_main --components codex,claude --yes --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_count "$STUB_LOG" "INSTALL codex" 0
  assert_count "$STUB_LOG" "INSTALL claude" 1
  assert_contains "$(cat "$SANDBOX/out.txt")" "Codex CLI: 이미 있음(버전 0.160.0, 건너뜀)"
}

test_rerun_idempotent() {
  copy_package >/dev/null
  local rc=0
  run_main --components all --yes --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc" "첫 실행"
  : > "$STUB_LOG"
  rc=0
  run_main --components all --yes --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc" "두 번째 실행"
  assert_count "$STUB_LOG" "CURL" 0
  assert_count "$STUB_LOG" "INSTALL" 0
  assert_count "$HOME/.zprofile" "# >>> llm-cli-installer >>>" 1
}

test_failure_isolation_partial() {
  copy_package >/dev/null
  export STUB_INSTALL_FAIL=claude
  local rc=0 f
  run_main --components all --yes --non-interactive < /dev/null || rc=$?
  assert_exit 60 "$rc"
  assert_count "$STUB_LOG" "INSTALL " 4
  f="$(ls -d "$LLMCLI_LOG_ROOT"/*/ | head -n 1)summary.json"
  assert_file_exists "$f"
  assert_contains "$(cat "$f")" '"id":"claude","displayName":"Claude Code","state":"Failed","code":40'
}

test_network_failure_code() {
  copy_package >/dev/null
  export STUB_CURL_FAIL_URL=claude.ai
  local rc=0
  run_main --components claude --yes --non-interactive < /dev/null || rc=$?
  assert_exit 20 "$rc"
}

test_grok_path_refresh_41() {
  copy_package >/dev/null
  export STUB_FIXTURE_NO_PATH=grok
  local rc=0
  run_main --components grok --yes --non-interactive < /dev/null || rc=$?
  assert_exit 41 "$rc"
  assert_contains "$(cat "$SANDBOX/out.txt")" "새 터미널을 열어야 grok"
}

test_path_block_once() {
  copy_package >/dev/null
  local rc=0
  run_main --components codex --yes --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_count "$HOME/.zprofile" "# >>> llm-cli-installer >>>" 1
  assert_contains "$(cat "$SANDBOX/out.txt")" "진단 기록:"
}

test_summary_and_events_written() {
  copy_package >/dev/null
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in '1\ny\n'
  local rc=0 d
  run_main < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  d="$(ls -d "$LLMCLI_LOG_ROOT"/*/ | head -n 1)"
  assert_file_exists "${d}summary.json"
  assert_count "${d}events.jsonl" "run.started" 1
  assert_count "${d}events.jsonl" "plan.confirmed" 1
  assert_count "${d}events.jsonl" "run.completed" 1
}

test_integrity_tamper() {
  copy_package >/dev/null
  printf '# x\n' >> "$SANDBOX/pkg/files/macos/lib/catalog.sh"
  local rc=0
  run_main --components codex --yes --non-interactive < /dev/null || rc=$?
  assert_exit 23 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
}

test_integrity_unlisted_exec() {
  copy_package >/dev/null
  printf '#!/bin/bash\n' > "$SANDBOX/pkg/files/macos/lib/extra.sh"
  local rc=0
  run_main --components codex --yes --non-interactive < /dev/null || rc=$?
  assert_exit 23 "$rc"
  assert_count "$STUB_LOG" "CURL" 0
}

test_unsupported_platform() {
  copy_package >/dev/null
  export LLMCLI_OS_NAME=Linux
  local rc=0
  run_main --components codex --yes --non-interactive < /dev/null || rc=$?
  assert_exit 10 "$rc"
}

test_help_and_version() {
  copy_package >/dev/null
  local rc=0
  run_main --help < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_contains "$(cat "$SANDBOX/out.txt")" "사용법: installer-mac.command"
  rc=0
  run_main --version < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_eq "3.0.0" "$(cat "$SANDBOX/out.txt")"
}

_pathonly_prepare() {
  copy_package >/dev/null
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "codex-cli 0.160.0"\n' > "$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
}

test_pathonly_needs_confirmation() {
  _pathonly_prepare
  local rc=0
  run_main --components codex --non-interactive < /dev/null || rc=$?
  assert_exit 2 "$rc"
  assert_file_absent "$HOME/.zprofile"
  assert_contains "$(cat "$SANDBOX/out.txt")" "셸 설정: 확인하면"
}

test_pathonly_confirmed_adds_block() {
  _pathonly_prepare
  export LLMCLI_FORCE_INTERACTIVE=1
  _main_in 'y\n'
  local rc=0
  run_main --components codex < "$SANDBOX/in.txt" || rc=$?
  assert_exit 0 "$rc"
  assert_count "$HOME/.zprofile" "# >>> llm-cli-installer >>>" 1
  assert_contains "$(cat "$SANDBOX/out.txt")" "셸 설정을 바꿨습니다"
}

test_pathonly_dry_run_no_change() {
  _pathonly_prepare
  local rc=0
  run_main --components codex --dry-run --non-interactive < /dev/null || rc=$?
  assert_exit 0 "$rc"
  assert_file_absent "$HOME/.zprofile"
}

test_interrupt_stops_installer() {
  copy_package >/dev/null
  local body="$SANDBOX/body.sh" pid i rc=0 n
  printf '%s\n' '#!/bin/sh' 'echo started >> "$STUB_LOG"' 'sleep 20' 'echo finished >> "$STUB_LOG"' > "$body"
  export STUB_CURL_BODY_FILE="$body"
  set -m
  /bin/bash "$SANDBOX/pkg/files/macos/bin/llmcli-install.sh" --components claude --yes --non-interactive < /dev/null > "$SANDBOX/out.txt" 2>&1 &
  pid=$!
  set +m
  i=0
  while [ "$i" -lt 100 ] && ! grep -q started "$STUB_LOG" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_count "$STUB_LOG" "started" 1 "설치 스크립트 시작"
  kill -INT "$pid"
  wait "$pid" || rc=$?
  assert_exit 70 "$rc"
  sleep 25
  assert_count "$STUB_LOG" "finished" 0 "중단 뒤 finished"
  n="$(find "$LLMCLI_LOG_ROOT" -name '*.raw' | wc -l | tr -d ' ')"
  assert_eq 0 "$n" "raw 파일 수"
  n="$(find "$TMPDIR" -name 'llmcli-claude.*' | wc -l | tr -d ' ')"
  assert_eq 0 "$n" "임시 스크립트 수"
}
