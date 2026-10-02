#!/bin/bash
# summary.sh - 구성요소 결과 수집, 종료 코드 결정, summary.json, 콘솔 요약

# sum_home_tilde <경로>: 홈으로 시작하면 그 부분을 ~로 바꿔 보여 준다.
sum_home_tilde() {
  local p="$1" tilde='~'
  case "$p" in
    "$HOME"/*) printf '%s\n' "${tilde}${p#"$HOME"}" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

sum_set() {
  var_set "RES_STATE_$1" "$2"
  var_set "RES_CODE_$1" "$3"
  var_set "RES_VERSION_$1" "$4"
  var_set "RES_PATH_$1" "$5"
  var_set "RES_MSG_$1" "$6"
}

sum_message() {
  local code="$1" id="$2" cmd
  cmd="$(cat_get "$id" commands 2>/dev/null)"
  cmd="${cmd%% *}"
  case "$code" in
    20) printf '%s' '설치 스크립트를 받지 못했습니다. 인터넷 연결을 확인하고 다시 실행하세요.' ;;
    23) printf '%s' '설치 스크립트가 공식 주소·형식 검사를 통과하지 못해 실행하지 않았습니다.' ;;
    40) printf '%s' "설치 스크립트가 실패했습니다. 로그 폴더의 native/${id}-install.log를 확인하세요." ;;
    41) printf '%s' "설치는 됐지만 새 터미널을 열어야 ${cmd} 명령을 쓸 수 있습니다." ;;
    50) printf '%s' "설치 후 ${cmd} 버전을 확인하지 못했습니다." ;;
    *) printf '%s' '' ;;
  esac
}

# 결과가 없는 id는 Failed 90으로 취급해 값을 채운다.
_sum_fill_missing() {
  local id
  for id in $1; do
    if [ -z "$(var_get "RES_CODE_$id")" ]; then
      sum_set "$id" Failed 90 "" "" "내부 오류: 결과가 기록되지 않았습니다."
    fi
  done
}

sum_exit_code() {
  local plan="$1" id code
  local sset="" fset="" has41=0 first=""
  for id in $plan; do
    code="$(var_get "RES_CODE_$id")"
    if [ -z "$code" ]; then
      printf '%s\n' 90
      return 0
    fi
    case "$code" in
      0) sset="$sset $id" ;;
      41) sset="$sset $id"; has41=1 ;;
      *) fset="$fset $id" ;;
    esac
  done
  if [ -z "$fset" ]; then
    if [ "$has41" -eq 1 ]; then printf '%s\n' 41; else printf '%s\n' 0; fi
    return 0
  fi
  if [ -n "$sset" ]; then
    printf '%s\n' 60
    return 0
  fi
  for id in $(cat_ids); do
    case " $fset " in
      *" $id "*) first="$id"; break ;;
    esac
  done
  if [ -z "$first" ]; then
    first="${fset# }"
    first="${first%% *}"
  fi
  printf '%s\n' "$(var_get "RES_CODE_$first")"
  return 0
}

_sum_jstr() {
  printf '"%s"' "$(json_escape "$(redact_text "$1")")"
}

sum_write_json() {
  local selected="$1" plan="$2" exitcode="$3"
  local file="$LLMCLI_LOG_DIR/summary.json"
  local ver="unknown" id out sel="" comps="" first

  if [ -n "${LLMCLI_MAC_DIR:-}" ] && [ -f "$LLMCLI_MAC_DIR/VERSION" ]; then
    ver="$(head -n 1 "$LLMCLI_MAC_DIR/VERSION" | tr -d '\r')"
    [ -n "$ver" ] || ver="unknown"
  fi
  _sum_fill_missing "$plan"

  first=1
  for id in $selected; do
    [ "$first" -eq 1 ] || sel="$sel,"
    sel="$sel\"$id\""
    first=0
  done

  first=1
  for id in $plan; do
    [ "$first" -eq 1 ] || comps="$comps,"
    comps="$comps{\"id\":\"$id\",\"displayName\":$(_sum_jstr "$(cat_get "$id" display)"),\"state\":$(_sum_jstr "$(var_get "RES_STATE_$id")"),\"code\":$(var_get "RES_CODE_$id"),\"version\":$(_sum_jstr "$(var_get "RES_VERSION_$id")"),\"path\":$(_sum_jstr "$(var_get "RES_PATH_$id")"),\"message\":$(_sum_jstr "$(var_get "RES_MSG_$id")")}"
    first=0
  done

  out="{\"schemaVersion\":1,\"runId\":$(_sum_jstr "${LLMCLI_RUN_ID:-}"),\"installerVersion\":$(_sum_jstr "$ver"),\"platform\":{\"os\":$(_sum_jstr "${PLAT_OS:-}"),\"version\":$(_sum_jstr "${PLAT_VERSION:-}"),\"arch\":$(_sum_jstr "${PLAT_ARCH:-}")},\"selected\":[$sel],\"exitCode\":$exitcode,\"logDir\":$(_sum_jstr "${LLMCLI_LOG_DIR:-}"),\"finishedUtc\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"components\":[$comps]}"
  printf '%s\n' "$out" > "$file"
}

sum_print() {
  local plan="$1" exitcode="$2"
  local id state code ver msg disp cmd cmds="" label

  _sum_fill_missing "$plan"
  printf '\n'
  printf '==================================================\n'
  printf ' 설치 결과\n'
  printf '==================================================\n'
  for id in $plan; do
    state="$(var_get "RES_STATE_$id")"
    code="$(var_get "RES_CODE_$id")"
    ver="$(var_get "RES_VERSION_$id")"
    msg="$(var_get "RES_MSG_$id")"
    disp="$(cat_get "$id" display)"
    case "$code" in
      0)
        if [ "$state" = "AlreadyPresent" ]; then label="이미 설치되어 있음"; else label="새로 설치"; fi
        if [ -n "$ver" ]; then
          ui_success "$disp $ver ($label)"
        else
          ui_success "$disp ($label)"
        fi
        ;;
      41) ui_warn "$disp: $(sum_message 41 "$id")" ;;
      *)
        [ -n "$msg" ] || msg="$(sum_message "$code" "$id")"
        ui_fail "$disp: $msg"
        ;;
    esac
    case "$code" in
      0|41)
        cmd="$(cat_get "$id" commands)"
        cmd="${cmd%% *}"
        if [ -z "$cmds" ]; then cmds="$cmd"; else cmds="$cmds, $cmd"; fi
        ;;
    esac
  done
  printf '\n'
  if [ -n "$cmds" ]; then
    ui_info "새 터미널을 열고 쓸 수 있는 명령: $cmds"
  fi
  ui_info "처음 실행하면 각 CLI가 로그인 방법을 안내합니다. 설치기는 로그인 정보를 받거나 저장하지 않습니다."
  ui_info "진단 기록: $(sum_home_tilde "${LLMCLI_LOG_DIR:-}")"
}
