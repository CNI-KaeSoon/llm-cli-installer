#!/bin/bash
# common.sh: 종료 코드 상수, 콘솔 출력, 문자열·변수 도우미, JSON 이스케이프, 버전 추출, 시간 제한 실행.
# source될 때 함수와 상수 정의 외에는 아무 동작도 하지 않는다.

EXIT_OK=0
EXIT_INVALID_ARGUMENT=2
EXIT_UNSUPPORTED_PLATFORM=10
EXIT_LOG_UNAVAILABLE=12
EXIT_NETWORK=20
EXIT_INTEGRITY=23
EXIT_PACKAGE_LAYOUT=24
EXIT_INSTALL_FAILED=40
EXIT_PATH_REFRESH_REQUIRED=41
EXIT_VERIFY_FAILED=50
EXIT_PARTIAL_SUCCESS=60
EXIT_CANCELLED=70
EXIT_INTERNAL=90
EXIT_TIMEOUT=124

UI_COLOR=0

ui_init() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    UI_COLOR=1
  else
    UI_COLOR=0
  fi
}

# _ui_emit <색 코드> <접두어> <메시지>
_ui_emit() {
  if [ "${UI_COLOR:-0}" = "1" ]; then
    printf '\033[%sm%s%s\033[0m\n' "$1" "$2" "$3"
  else
    printf '%s%s\n' "$2" "$3"
  fi
}

ui_info() {
  printf '%s\n' "$1"
}

ui_step() {
  printf '[%s] %s\n' "$1" "$2"
}

ui_progress() {
  printf '[설치 %s/%s] %s\n' "$1" "$2" "$3"
}

ui_success() {
  _ui_emit 32 '[성공] ' "$1"
}

ui_warn() {
  _ui_emit 33 '[경고] ' "$1"
}

ui_fail() {
  _ui_emit 31 '[실패] ' "$1"
}

ui_err() {
  printf '%s\n' "$1" >&2
}

str_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

str_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

var_set() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*) return 90 ;;
  esac
  if ! printf '%s' "$1" | grep -Eq '^[A-Z_][A-Z0-9_]*[a-z]*$'; then
    return 90
  fi
  printf -v "$1" '%s' "$2"
}

var_get() {
  if ! printf '%s' "$1" | grep -Eq '^[A-Z_][A-Z0-9_]*[a-z]*$'; then
    return 90
  fi
  printf '%s' "${!1-}"
}

json_escape() {
  local s bs dq nl cr tab
  bs=$'\\'
  dq='"'
  nl=$'\n'
  cr=$'\r'
  tab=$'\t'
  # 끝 줄바꿈이 명령 치환에서 사라지지 않도록 표식 x를 붙였다가 뗀다.
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037'; printf x)"
  s="${s%x}"
  # bash 3.2는 치환문 안의 따옴표를 글자 그대로 남기므로 치환문은 따옴표 없이 쓴다.
  local r_bs r_dq r_nl r_cr r_tab
  r_bs="$bs$bs"; r_dq="$bs$dq"; r_nl="${bs}n"; r_cr="${bs}r"; r_tab="${bs}t"
  s="${s//"$bs"/$r_bs}"
  s="${s//"$dq"/$r_dq}"
  s="${s//"$nl"/$r_nl}"
  s="${s//"$cr"/$r_cr}"
  s="${s//"$tab"/$r_tab}"
  printf '%s' "$s"
}

ver_extract() {
  local v
  v="$(printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  if [ -z "$v" ]; then
    return 1
  fi
  printf '%s\n' "$v"
}

# run_kill_tree <pid> [시그널]: 자식부터 차례로 끝낸 뒤 자기 자신에게 신호를 보낸다.
run_kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    run_kill_tree "$child" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null
}

RWT_PID=""
RWT_WATCHER=""

run_with_timeout() {
  local secs="$1"; shift
  local flag
  flag="$(mktemp -u "${TMPDIR:-/tmp}/llmcli-timeout.XXXXXX")"
  "$@" &
  local pid=$!
  RWT_PID=$!
  (
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$secs" & nap=$!; wait "$nap"
    : > "$flag"
    run_kill_tree "$pid" TERM
    sleep 5 & nap=$!; wait "$nap"
    run_kill_tree "$pid" KILL
  ) >/dev/null 2>&1 &
  local watcher=$!
  RWT_WATCHER=$!
  wait "$pid"
  local rc=$?
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  RWT_PID=""
  RWT_WATCHER=""
  if [ -e "$flag" ]; then
    rm -f "$flag"
    return 124
  fi
  return "$rc"
}
