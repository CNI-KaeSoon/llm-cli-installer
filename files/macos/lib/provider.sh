#!/bin/bash
# 공급자 설치: 카탈로그의 공식 스크립트를 받아 실행한다. source 시 동작 없음.

PROV_ERROR=""
PROV_SHA256=""
PROV_TMP=""
PROV_RAW=""

prov_install() {
  local id="$1"
  local url hosts shell envs tmp raw log rc tdir code
  PROV_ERROR=""
  PROV_SHA256=""

  url="$(cat_get "$id" url)"
  hosts="$(cat_get "$id" hosts)"
  shell="$(cat_get "$id" shell)"
  envs="$(cat_get "$id" env)"

  tdir="${TMPDIR:-/tmp}"
  tdir="${tdir%/}"
  tmp="$(mktemp "$tdir/llmcli-$id.XXXXXX")"
  PROV_TMP="$tmp"

  dl_fetch_script "$url" "$hosts" "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    PROV_ERROR="$DL_ERROR"
    log_event error component.install.failed Installing "$id" "$DL_ERROR" "" "$(log_code_name "$rc")"
    return "$rc"
  fi
  PROV_SHA256="$DL_SHA256"

  log_event info component.install.started Installing "$id" "설치 스크립트 실행" "" "" "sha256=$DL_SHA256" "url=$DL_EFFECTIVE_URL"

  raw="$LLMCLI_LOG_DIR/native/$id-install.raw"
  log="$LLMCLI_LOG_DIR/native/$id-install.log"
  PROV_TMP="$tmp"
  PROV_RAW="$raw"
  if [ -n "$envs" ]; then
    run_with_timeout "${LLMCLI_INSTALL_TIMEOUT:-900}" env "$envs" "$shell" "$tmp" </dev/null >"$raw" 2>&1
  else
    run_with_timeout "${LLMCLI_INSTALL_TIMEOUT:-900}" "$shell" "$tmp" </dev/null >"$raw" 2>&1
  fi
  rc=$?

  redact_stream < "$raw" > "$log"
  rm -f "$raw" "$tmp"
  PROV_TMP=""
  PROV_RAW=""

  if [ "$rc" -eq 124 ]; then
    PROV_ERROR="설치 스크립트가 시간 안에 끝나지 않았습니다"
  elif [ "$rc" -ne 0 ]; then
    PROV_ERROR="설치 스크립트 실패(종료 코드 $rc)"
  fi
  if [ "$rc" -ne 0 ]; then
    log_event error component.install.failed Installing "$id" "$PROV_ERROR" "$rc" "E_INSTALL_FAILED"
    return 40
  fi
  log_event info component.install.completed Installing "$id" "설치 스크립트 완료" 0
  return 0
}
