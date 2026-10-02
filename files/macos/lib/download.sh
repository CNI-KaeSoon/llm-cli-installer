#!/bin/bash
# 안전 다운로드: 설치 스크립트를 파일로 받고 검사한다. source 시 동작 없음.

DL_EFFECTIVE_URL=""
DL_SHA256=""
DL_BYTES=""
DL_ERROR=""

# https URL에서 호스트를 소문자로 출력. https가 아니면 1.
dl_host_of() {
  local url="$1" rest
  case "$url" in
    https://*) ;;
    *) return 1 ;;
  esac
  rest="${url#https://}"
  rest="${rest%%[/?#]*}"
  rest="${rest##*@}"
  rest="${rest%%:*}"
  printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
  return 0
}

# 공백 구분 허용 목록에 정확히 일치하는 호스트가 있으면 0.
dl_host_allowed() {
  local host="$1" list="$2" item
  [ -n "$host" ] || return 1
  for item in $list; do
    [ "$item" = "$host" ] && return 0
  done
  return 1
}

dl_fetch_script() {
  local url="$1" allowed="$2" file="$3"
  local host rc nul_bytes
  DL_EFFECTIVE_URL=""
  DL_SHA256=""
  DL_BYTES=""
  DL_ERROR=""

  host="$(dl_host_of "$url")" || host=""
  if [ -z "$host" ] || ! dl_host_allowed "$host" "$allowed"; then
    DL_ERROR="허용되지 않은 다운로드 주소"
    return 23
  fi

  DL_EFFECTIVE_URL=$(curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-redirs 5 --max-filesize 2097152 --connect-timeout 20 --max-time 120 -w '%{url_effective}' -o "$file" "$url" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 63 ]; then
    DL_ERROR="설치 스크립트가 2 MiB를 넘습니다"
    return 23
  elif [ "$rc" -ne 0 ]; then
    DL_ERROR="다운로드 실패(curl 종료 코드 $rc)"
    return 20
  fi

  host="$(dl_host_of "$DL_EFFECTIVE_URL")" || host=""
  if [ -z "$host" ] || ! dl_host_allowed "$host" "$allowed"; then
    DL_ERROR="허용되지 않은 주소로 이동했습니다: $host"
    return 23
  fi

  DL_BYTES=$(wc -c < "$file" | tr -d ' ')
  if [ "$DL_BYTES" -eq 0 ]; then
    DL_ERROR="빈 파일"
    return 23
  fi
  if [ "$DL_BYTES" -gt 2097152 ]; then
    DL_ERROR="2 MiB 초과"
    return 23
  fi

  nul_bytes=$(LC_ALL=C tr -d '\000' < "$file" | wc -c | tr -d ' ')
  if [ "$nul_bytes" != "$DL_BYTES" ]; then
    DL_ERROR="NUL 바이트 포함"
    return 23
  fi

  if [ "$(head -c 2 "$file")" != '#!' ]; then
    DL_ERROR="셸 스크립트가 아닙니다"
    return 23
  fi

  DL_SHA256=$(shasum -a 256 "$file" | awk '{print $1}')
  return 0
}
