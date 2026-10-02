#!/bin/bash
# PATH 설정 블록 관리. source 시 정의만 한다.

PATH_MARK_BEGIN='# >>> llm-cli-installer >>>'
PATH_MARK_END='# <<< llm-cli-installer <<<'
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
PATH_CHANGED=0
PATH_BACKUP=""
PATH_TARGET=""

path_target_file() {
  local sh
  sh="$(basename "${SHELL:-/bin/zsh}")"
  case "$sh" in
    zsh) printf '%s\n' "$HOME/.zprofile"; return 0 ;;
    bash) printf '%s\n' "$HOME/.bash_profile"; return 0 ;;
  esac
  return 2
}

path_has_local_bin() {
  local f files
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh) files=".zshenv .zprofile .zshrc" ;;
    bash) files=".bash_profile .bashrc .profile" ;;
    *) return 1 ;;
  esac
  for f in $files; do
    if [ -f "$HOME/$f" ] && grep -Eq '^[^#]*\.local/bin' "$HOME/$f"; then
      return 0
    fi
  done
  return 1
}

path_ensure_block() {
  local target rc
  PATH_CHANGED=0
  PATH_BACKUP=""
  PATH_TARGET=""
  target="$(path_target_file)"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    return 2
  fi
  PATH_TARGET="$target"
  if [ -f "$target" ] && grep -Fq "$PATH_MARK_BEGIN" "$target"; then
    return 0
  fi
  if path_has_local_bin; then
    return 0
  fi
  if [ -f "$target" ]; then
    PATH_BACKUP="$target.llmcli-backup-$(date +%Y%m%d%H%M%S)"
    if ! cp -p "$target" "$PATH_BACKUP"; then
      PATH_BACKUP=""
      return 1
    fi
    if [ -s "$target" ] && [ -n "$(tail -c 1 "$target")" ]; then
      printf '\n' >> "$target" || return 1
    fi
  fi
  if ! printf '%s\n%s\n%s\n' "$PATH_MARK_BEGIN" "$PATH_LINE" "$PATH_MARK_END" >> "$target"; then
    return 1
  fi
  PATH_CHANGED=1
  return 0
}
