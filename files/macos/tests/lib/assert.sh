#!/bin/bash
# 테스트 단언 함수. 실패하면 서브셸이 종료 코드 1로 끝난다.

fail() {
  printf '  FAIL: %s\n' "$1" >&2
  exit 1
}

skip() {
  printf '  SKIP: %s\n' "$1"
  exit 200
}

_assert_fail_msg() {
  printf "  FAIL: %s (기대 '%s', 실제 '%s')\n" "$1" "$2" "$3" >&2
  exit 1
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    _assert_fail_msg "${3:-assert_eq}" "$1" "$2"
  fi
  return 0
}

assert_ne() {
  if [ "$1" = "$2" ]; then
    _assert_fail_msg "${3:-assert_ne}" "다른 값" "$2"
  fi
  return 0
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  _assert_fail_msg "${3:-assert_contains}" "포함: $2" "$1"
}

assert_not_contains() {
  case "$1" in
    *"$2"*) _assert_fail_msg "${3:-assert_not_contains}" "미포함: $2" "$1" ;;
  esac
  return 0
}

assert_exit() {
  if [ "$1" != "$2" ]; then
    _assert_fail_msg "${3:-assert_exit}" "$1" "$2"
  fi
  return 0
}

assert_file_exists() {
  if [ ! -e "$1" ]; then
    _assert_fail_msg "파일 존재" "있음" "없음: $1"
  fi
  return 0
}

assert_file_absent() {
  if [ -e "$1" ]; then
    _assert_fail_msg "파일 부재" "없음" "있음: $1"
  fi
  return 0
}

assert_count() {
  local file="$1" needle="$2" want="$3" desc="${4:-assert_count}" got=0
  if [ -f "$file" ]; then
    got="$(grep -cF -- "$needle" "$file")"
  fi
  if [ "$got" != "$want" ]; then
    _assert_fail_msg "$desc" "$want" "$got"
  fi
  return 0
}
