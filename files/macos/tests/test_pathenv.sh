#!/bin/bash

test_target_by_shell() {
  load_libs common pathenv
  SHELL=/bin/zsh
  assert_eq "$HOME/.zprofile" "$(path_target_file)"
  SHELL=/bin/bash
  assert_eq "$HOME/.bash_profile" "$(path_target_file)"
  SHELL=/usr/local/bin/fish
  local out rc
  out="$(path_target_file)"; rc=$?
  assert_exit 2 "$rc"
  assert_eq "" "$out"
}

test_adds_block_new_file() {
  load_libs common pathenv
  path_ensure_block; local rc=$?
  assert_exit 0 "$rc"
  assert_eq 1 "$PATH_CHANGED"
  assert_eq "" "$PATH_BACKUP"
  assert_eq 3 "$(wc -l < "$HOME/.zprofile" | tr -d ' ')"
  assert_eq "$PATH_MARK_BEGIN" "$(sed -n 1p "$HOME/.zprofile")"
  assert_eq 'export PATH="$HOME/.local/bin:$PATH"' "$(sed -n 2p "$HOME/.zprofile")"
  assert_eq "$PATH_MARK_END" "$(sed -n 3p "$HOME/.zprofile")"
}

test_backup_and_newline() {
  load_libs common pathenv
  printf 'alias a=b' > "$HOME/.zprofile"
  path_ensure_block; local rc=$?
  assert_exit 0 "$rc"
  assert_ne "" "$PATH_BACKUP"
  printf 'alias a=b' > "$SANDBOX/orig"
  cmp -s "$SANDBOX/orig" "$PATH_BACKUP" || fail "백업이 원본과 다름"
  assert_eq 'alias a=b' "$(sed -n 1p "$HOME/.zprofile")"
  assert_eq "$PATH_MARK_BEGIN" "$(sed -n 2p "$HOME/.zprofile")"
}

test_idempotent() {
  load_libs common pathenv
  printf 'alias a=b\n' > "$HOME/.zprofile"
  path_ensure_block
  path_ensure_block
  assert_eq 0 "$PATH_CHANGED"
  assert_count "$HOME/.zprofile" "$PATH_MARK_BEGIN" 1
  local n
  n="$(find "$HOME" -maxdepth 1 -name '.zprofile.llmcli-backup-*' | wc -l | tr -d ' ')"
  assert_eq 1 "$n"
}

test_skip_if_local_bin_present() {
  load_libs common pathenv
  printf 'export PATH=$HOME/.local/bin:$PATH\n' > "$HOME/.zshrc"
  path_ensure_block; local rc=$?
  assert_exit 0 "$rc"
  assert_eq 0 "$PATH_CHANGED"
  assert_file_absent "$HOME/.zprofile"
}

test_unsupported_shell() {
  load_libs common pathenv
  SHELL=/usr/local/bin/fish
  path_ensure_block; local rc=$?
  assert_exit 2 "$rc"
  assert_eq 0 "$PATH_CHANGED"
  assert_eq 0 "$(find "$HOME" -type f | wc -l | tr -d ' ')"
}

test_bash_profile() {
  load_libs common pathenv
  SHELL=/bin/bash
  path_ensure_block
  assert_count "$HOME/.bash_profile" "$PATH_MARK_BEGIN" 1
  assert_eq 1 "$PATH_CHANGED"
}

test_comment_line_ignored() {
  load_libs common pathenv
  SHELL=/bin/zsh
  printf '# .local/bin\n' > "$HOME/.zprofile"
  path_has_local_bin; local rc=$?
  assert_exit 1 "$rc"
}

test_bashrc_ignored_for_zsh() {
  load_libs common pathenv
  SHELL=/bin/zsh
  printf 'export PATH=$HOME/.local/bin:$PATH\n' > "$HOME/.bashrc"
  path_has_local_bin; local rc=$?
  assert_exit 1 "$rc"
}
