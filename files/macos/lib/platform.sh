#!/bin/bash
# platform.sh: 지원 환경(macOS 13+, arm64/x86_64) 판정.
# source될 때 함수와 상수 정의 외에는 아무 동작도 하지 않는다.

PLAT_OS=""
PLAT_VERSION=""
PLAT_ARCH=""
PLAT_REASON=""

plat_detect() {
  PLAT_OS="${LLMCLI_OS_NAME:-$(uname -s)}"
  PLAT_VERSION="${LLMCLI_OS_VERSION:-$(sw_vers -productVersion 2>/dev/null)}"
  PLAT_ARCH="${LLMCLI_ARCH:-$(uname -m)}"
}

plat_check() {
  local major
  plat_detect
  PLAT_REASON=""
  if [ "$PLAT_OS" != "Darwin" ]; then
    PLAT_REASON="macOS에서만 실행할 수 있습니다."
    return 10
  fi
  major="${PLAT_VERSION%%.*}"
  case "$major" in
    ''|*[!0-9]*)
      PLAT_REASON="macOS 13 이상이 필요합니다(현재 ${PLAT_VERSION})."
      return 10
      ;;
  esac
  if [ "$((10#$major))" -lt 13 ]; then
    PLAT_REASON="macOS 13 이상이 필요합니다(현재 ${PLAT_VERSION})."
    return 10
  fi
  case "$PLAT_ARCH" in
    arm64|x86_64) ;;
    *)
      PLAT_REASON="지원하지 않는 CPU 종류입니다(${PLAT_ARCH})."
      return 10
      ;;
  esac
  return 0
}
