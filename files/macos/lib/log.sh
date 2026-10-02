#!/bin/bash
# 실행 기록(run.log, events.jsonl). source 시 함수 정의 외 동작 없음.
# 필요: lib/common.sh(json_escape), lib/redact.sh(redact_text)

log_code_name() {
  case "$1" in
    0) printf 'OK' ;;
    2) printf 'E_INVALID_ARGUMENT' ;;
    10) printf 'E_UNSUPPORTED_PLATFORM' ;;
    12) printf 'E_LOG_UNAVAILABLE' ;;
    20) printf 'E_NETWORK' ;;
    23) printf 'E_INTEGRITY' ;;
    24) printf 'E_PACKAGE_LAYOUT' ;;
    40) printf 'E_INSTALL_FAILED' ;;
    41) printf 'E_PATH_REFRESH_REQUIRED' ;;
    50) printf 'E_VERIFY_FAILED' ;;
    60) printf 'E_PARTIAL_SUCCESS' ;;
    70) printf 'E_CANCELLED' ;;
    90) printf 'E_INTERNAL' ;;
    *) printf 'E_UNEXPECTED' ;;
  esac
}

_log_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# 폴더를 700 권한으로 만들고 기록 파일을 준비한다. umask는 서브셸 안에서만 건다.
_log_make_dir() {
  local dir="$1"
  ( umask 077; mkdir -p "$dir/native" && : > "$dir/run.log" && : > "$dir/events.jsonl" ) 2>/dev/null
}

log_init() {
  local root="${1:-${LLMCLI_LOG_ROOT:-$HOME/Library/Logs/LLMCliInstaller}}"
  local id short stamp dir tmp
  id="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  if [ -z "$id" ]; then
    id="$(date +%s)-$$-$RANDOM"
  fi
  LLMCLI_RUN_ID="$id"
  short="${id:0:8}"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dir="${root%/}/$stamp-$short"
  if ! _log_make_dir "$dir"; then
    tmp="${TMPDIR:-/tmp}"
    tmp="${tmp%/}"
    dir="$tmp/LLMCliInstaller-$short"
    if ! _log_make_dir "$dir"; then
      return "${EXIT_LOG_UNAVAILABLE:-12}"
    fi
  fi
  LLMCLI_LOG_DIR="$dir"
  LOG_SEQ=0
  return 0
}

log_text() {
  local level="$1" up
  case "$level" in
    warning) up=WARNING ;;
    error) up=ERROR ;;
    *) up=INFO ;;
  esac
  [ -n "${LLMCLI_LOG_DIR:-}" ] || return 1
  printf '[%s] %s %s\n' "$(_log_now)" "$up" "$(redact_text "$2")" >> "$LLMCLI_LOG_DIR/run.log" 2>/dev/null
  return 0
}

log_event() {
  local level="$1" etype="$2" stage="$3" comp="${4:-}" msg="${5:-}" pcode="${6:-}" ncode="${7:-}"
  [ -n "${LLMCLI_LOG_DIR:-}" ] || return 1
  if [ $# -ge 7 ]; then shift 7; else shift $#; fi
  local kv ctx="" k v sep="" name comp_json pcode_json msg_esc ts
  case "$ncode" in
    '') name="OK" ;;
    *[!0-9]*) name="$ncode" ;;
    *) name="$(log_code_name "$ncode")" ;;
  esac
  if [ -n "$comp" ]; then comp_json="\"$(json_escape "$comp")\""; else comp_json="null"; fi
  case "$pcode" in
    '') pcode_json="null" ;;
    *[!0-9-]*) pcode_json="null" ;;
    *) pcode_json="$pcode" ;;
  esac
  for kv in "$@"; do
    k="${kv%%=*}"
    [ "$k" != "$kv" ] || continue
    v="${kv#*=}"
    case "$k" in
      [A-Za-z]*) ;;
      *) continue ;;
    esac
    case "$k" in
      *[!A-Za-z0-9_]*) continue ;;
    esac
    ctx="$ctx$sep\"$k\":\"$(json_escape "$(redact_text "$v")")\""
    sep=","
  done
  LOG_SEQ=$(( ${LOG_SEQ:-0} + 1 ))
  ts="$(_log_now)"
  msg_esc="$(json_escape "$(redact_text "$msg")")"
  printf '{"schemaVersion":1,"timestampUtc":"%s","runId":"%s","sequence":%s,"level":"%s","eventType":"%s","stage":"%s","component":%s,"message":"%s","processExitCode":%s,"normalizedCode":"%s","context":{%s}}\n' \
    "$ts" "$LLMCLI_RUN_ID" "$LOG_SEQ" "$(json_escape "$level")" "$(json_escape "$etype")" "$(json_escape "$stage")" \
    "$comp_json" "$msg_esc" "$pcode_json" "$name" "$ctx" >> "$LLMCLI_LOG_DIR/events.jsonl" 2>/dev/null
  log_text "$level" "$msg"
  return 0
}
