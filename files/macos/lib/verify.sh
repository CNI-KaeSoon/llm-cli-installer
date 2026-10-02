#!/bin/bash
# verify.sh: CLI 감지(진단)와 설치 후 검증. 읽기 전용이며 --version 실행 외에는 아무 명령도 실행하지 않는다.
# source될 때 함수와 상수 정의 외에는 아무 동작도 하지 않는다.

VER_STATE=""
VER_VERSION=""
VER_PATH=""

# ver_command_path <명령>: 새 로그인 셸에서 본 실행 파일 경로를 출력. 없으면 1.
ver_command_path() {
  local name="$1" p
  p="$(run_with_timeout "${LLMCLI_VERIFY_TIMEOUT:-60}" "${LLMCLI_ZSH:-/bin/zsh}" -lic 'p=$(command -v -- "$1" 2>/dev/null); printf "LLMCLI_PATH:%s\n" "$p"' llmcli "$name" </dev/null 2>/dev/null | grep '^LLMCLI_PATH:/' | tail -n 1)"
  p="${p#LLMCLI_PATH:}"
  if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then
    printf '%s\n' "$p"
    return 0
  fi
  return 1
}

# ver_run_version <id> <실행 파일>: 버전 문자열을 출력. 모두 실패하면 1.
ver_run_version() {
  local id="$1" exe="$2" args arg out rc v
  args="$(cat_get "$id" version_args)"
  for arg in $args; do
    out="$(run_with_timeout "${LLMCLI_VERIFY_TIMEOUT:-60}" "$exe" "$arg" </dev/null 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      v="$(ver_extract "$out")"
      if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
      fi
    fi
  done
  return 1
}

# ver_detect <id>: VER_STATE(present/pathonly/absent), VER_VERSION, VER_PATH 설정. 항상 0.
ver_detect() {
  local id="$1" cmds c p v kp
  VER_STATE="absent"
  VER_VERSION=""
  VER_PATH=""
  cmds="$(cat_get "$id" commands)"
  for c in $cmds; do
    p="$(ver_command_path "$c")" || continue
    [ -n "$p" ] || continue
    v="$(ver_run_version "$id" "$p")" || continue
    VER_STATE="present"
    VER_VERSION="$v"
    VER_PATH="$p"
    return 0
  done
  for kp in $(cat_get "$id" known_paths); do
    p="$HOME/$kp"
    if [ -f "$p" ] && [ -x "$p" ]; then
      v="$(ver_run_version "$id" "$p")" || continue
      VER_STATE="pathonly"
      VER_VERSION="$v"
      VER_PATH="$p"
      return 0
    fi
  done
  return 0
}

# ver_agent_conflict: agent 명령이 Grok 설치 폴더 밖에 있으면 그 경로를 출력하고 0, 아니면 1.
ver_agent_conflict() {
  local p
  p="$(ver_command_path agent)" || return 1
  [ -n "$p" ] || return 1
  case "$p" in
    "$HOME"/.grok/*) return 1 ;;
  esac
  printf '%s\n' "$p"
  return 0
}
