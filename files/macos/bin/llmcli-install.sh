#!/bin/bash
# llmcli-install.sh: macOS 메인 흐름. 고른 CLI만, 확인한 뒤에만 설치한다.

set -o pipefail

OPT_COMPONENTS=""
OPT_YES=""
OPT_NONINTERACTIVE=""
OPT_DRYRUN=""
OPT_LOG_ROOT=""

LLMCLI_BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
LLMCLI_MAC_DIR="$(cd "$LLMCLI_BIN_DIR/.." && pwd)"
LLMCLI_PKG_ROOT="$(cd "$LLMCLI_MAC_DIR/../.." && pwd)"
export LLMCLI_MAC_DIR

# integ_check <배포_폴더>: manifest 대조. 실패하면 23.
integ_check() {
  local root="$1"
  local manifest="$root/files/macos/manifest.sha256"
  local list line path hash actual rel name reason=""
  if [ ! -f "$manifest" ]; then
    reason="manifest.sha256 없음"
  fi
  list="$(mktemp "${TMPDIR:-/tmp}/llmcli-integ.XXXXXX")" || list=""
  if [ -z "$list" ]; then
    reason="임시 파일을 만들 수 없음"
  fi
  if [ -z "$reason" ]; then
    local re='^[0-9a-f]{64}  [^ ].*$'
    while IFS= read -r line || [ -n "$line" ]; do
      if ! [[ "$line" =~ $re ]]; then
        reason="manifest.sha256 형식 오류"
        break
      fi
      path="${line:66}"
      case "$path" in
        /*|*:*|..|../*|*/..|*/../*) reason="허용되지 않는 경로 $path"; break ;;
      esac
      if grep -Fxq -- "$path" "$list"; then
        reason="중복 항목 $path"
        break
      fi
      printf '%s\n' "$path" >> "$list"
    done < "$manifest"
  fi
  if [ -z "$reason" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      hash="${line:0:64}"
      path="${line:66}"
      if [ ! -f "$root/$path" ]; then
        reason="파일 없음 $path"
        break
      fi
      actual="$(shasum -a 256 "$root/$path" | awk '{print $1}')"
      if [ "$actual" != "$hash" ]; then
        reason="해시 불일치 $path"
        break
      fi
    done < "$manifest"
  fi
  if [ -z "$reason" ]; then
    while IFS= read -r line; do
      rel="${line#"$root"/}"
      name="${rel##*/}"
      case "$name" in
        *.sh|*.command|*.bash|*.zsh) ;;
        *) [ -x "$line" ] || continue ;;
      esac
      if ! grep -Fxq -- "$rel" "$list"; then
        reason="manifest에 없는 실행 파일 $rel"
        break
      fi
    done < <(find "$root/files/macos" -type f)
  fi
  [ -n "$list" ] && rm -f "$list"
  if [ -n "$reason" ]; then
    printf '%s\n' "설치기 무결성 검증 실패: $reason. 공식 릴리스 ZIP을 다시 내려받으세요." >&2
    return 23
  fi
  return 0
}

integ_check "$LLMCLI_PKG_ROOT" || exit 23

for _lib in common redact log platform catalog selection pathenv download provider verify summary; do
  # shellcheck disable=SC1090
  . "$LLMCLI_MAC_DIR/lib/$_lib.sh"
done
ui_init

usage() {
  cat <<'USAGE'
사용법: installer-mac.command [옵션]
  옵션 없이 실행하면 설치할 CLI를 번호로 고르는 메뉴가 나옵니다.
  --components <목록>   메뉴 없이 설치할 CLI 지정 (예: codex,claude). 이름: codex, claude, antigravity, grok, all
  --yes                 확인 질문 없이 진행 (--components와 함께만)
  --non-interactive     질문하지 않음 (--components와 --yes 필요)
  --dry-run             설치하지 않고 계획만 보여 줌
  --log-root <폴더>     로그 저장 위치 변경
  --version             설치기 버전 출력
  --help                이 도움말 출력
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --components)
      if [ $# -lt 2 ]; then ui_err "--components에 값이 필요합니다."; usage >&2; exit 2; fi
      OPT_COMPONENTS="$2"; shift 2 ;;
    --yes) OPT_YES=1; shift ;;
    --non-interactive) OPT_NONINTERACTIVE=1; shift ;;
    --dry-run) OPT_DRYRUN=1; shift ;;
    --log-root)
      if [ $# -lt 2 ]; then ui_err "--log-root에 값이 필요합니다."; usage >&2; exit 2; fi
      OPT_LOG_ROOT="$2"; shift 2 ;;
    --version) head -n 1 "$LLMCLI_MAC_DIR/VERSION" | tr -d '\r'; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) ui_err "알 수 없는 옵션: $1"; usage >&2; exit 2 ;;
  esac
done
if [ -n "$OPT_YES" ] && [ -z "$OPT_COMPONENTS" ]; then
  ui_err "--yes는 --components와 함께만 쓸 수 있습니다."
  exit 2
fi

INTERACTIVE=0
if [ -z "$OPT_NONINTERACTIVE" ]; then
  if [ "${LLMCLI_FORCE_INTERACTIVE:-}" = "1" ] || [ -t 0 ]; then
    INTERACTIVE=1
  fi
fi

if ! plat_check; then
  ui_fail "$PLAT_REASON"
  exit 10
fi

if ! log_init "$OPT_LOG_ROOT"; then
  ui_err "로그 폴더를 만들 수 없습니다."
  exit 12
fi
INSTALLER_VERSION="$(head -n 1 "$LLMCLI_MAC_DIR/VERSION" | tr -d '\r')"
log_event info run.started Init "" "설치기 시작" "" "" "version=$INSTALLER_VERSION"

on_interrupt() {
  trap '' INT TERM
  if [ -n "${RWT_WATCHER:-}" ]; then
    kill -TERM "$RWT_WATCHER" 2>/dev/null
  fi
  if [ -n "${RWT_PID:-}" ]; then
    run_kill_tree "$RWT_PID" TERM
    sleep 2
    if kill -0 "$RWT_PID" 2>/dev/null; then
      run_kill_tree "$RWT_PID" KILL
    fi
  fi
  if { : >/dev/tty; } 2>/dev/null; then
    ui_warn "사용자가 중단했습니다." >/dev/tty
  else
    ui_warn "사용자가 중단했습니다." >&2
  fi
  if [ -n "${PROV_RAW:-}" ]; then
    if [ -f "$PROV_RAW" ]; then
      redact_stream < "$PROV_RAW" > "${PROV_RAW%.raw}.log"
    fi
    rm -f "$PROV_RAW"
  fi
  if [ -n "${PROV_TMP:-}" ]; then
    rm -f "$PROV_TMP"
  fi
  log_event warning run.cancelled Interrupted "" "사용자가 중단했습니다" 70 "$(log_code_name 70)"
  exit 70
}
trap on_interrupt INT TERM

SEL_INVALID_COUNT=0
SELECTED=""

if [ -n "$OPT_COMPONENTS" ]; then
  rc=0
  sel_parse_components_arg "$OPT_COMPONENTS" || rc=$?
  if [ "$rc" -eq 3 ]; then
    ui_fail "Legacy Gemini CLI는 macOS 판에서 지원하지 않습니다."
    exit 2
  elif [ "$rc" -ne 0 ]; then
    ui_fail "알 수 없는 구성요소: $SEL_ERROR_TOKEN"
    exit 2
  fi
  SELECTED="$SEL_RESULT"
elif [ "$INTERACTIVE" -eq 0 ]; then
  ui_fail "질문 없이 실행하려면 --components로 설치할 CLI를 지정해야 합니다."
  exit 2
fi

cancel_run() {
  ui_info "설치를 취소했습니다. 변경된 것은 없습니다."
  log_event info run.cancelled Cancelled "" "설치 취소" 70 "$(log_code_name 70)"
  exit 70
}

invalid_exit() {
  ui_fail "입력이 반복해서 올바르지 않아 종료합니다. 변경된 것은 없습니다."
  exit 2
}

PLAN=""
PLAN_IDS=""
PLAN_TABLE=""
NEED_INSTALL=0
HAS_PATHONLY=0
PATH_NEEDED=0
PATH_TARGET_SHOWN=""

while true; do
  if [ -z "$OPT_COMPONENTS" ]; then
    rc=0
    sel_menu_loop || rc=$?
    if [ "$rc" -eq 70 ]; then cancel_run; fi
    if [ "$rc" -ne 0 ]; then invalid_exit; fi
    SELECTED="$SEL_RESULT"
  fi
  log_event info selection.completed Selection "" "선택 완료" "" "" "selected=$SELECTED"

  PLAN="$(sel_plan "$SELECTED")"
  PLAN_IDS=""
  PLAN_TABLE=""
  NEED_INSTALL=0
  HAS_PATHONLY=0
  PATH_NEEDED=0
  while IFS=$'\t' read -r id role reason; do
    [ -z "$id" ] && continue
    PLAN_IDS="${PLAN_IDS:+$PLAN_IDS }$id"
    var_set "PLAN_ROLE_$id" "$role"
    ui_step 진단 "$(cat_get "$id" display) 확인 중"
    ver_detect "$id"
    var_set "DIAG_STATE_$id" "$VER_STATE"
    var_set "DIAG_VERSION_$id" "$VER_VERSION"
    var_set "DIAG_PATH_$id" "$VER_PATH"
    case "$VER_STATE" in
      present) pstate="$VER_STATE" ;;
      pathonly) pstate="$VER_STATE"; HAS_PATHONLY=1 ;;
      *) pstate="install"; NEED_INSTALL=$((NEED_INSTALL + 1)) ;;
    esac
    var_set "PLAN_STATE_$id" "$pstate"
    PLAN_TABLE="${PLAN_TABLE}$(printf '%s\t%s\t%s\t%s\t%s' "$id" "$role" "$reason" "$pstate" "$VER_VERSION")"$'\n'
  done <<< "$PLAN"

  case " $PLAN_IDS " in
    *" grok "*)
      if [ "$(var_get PLAN_STATE_grok)" = "install" ]; then
        agent_path="$(ver_agent_conflict)" || agent_path=""
        if [ -n "$agent_path" ]; then
          ui_warn "이미 agent 명령이 있습니다($agent_path). Grok 설치 후 agent 명령이 바뀔 수 있습니다."
        fi
      fi
      ;;
  esac

  PATH_TARGET_SHOWN=""
  if [ "$NEED_INSTALL" -gt 0 ] || [ "$HAS_PATHONLY" -eq 1 ]; then
    if PATH_TARGET_SHOWN="$(path_target_file)" && ! { [ -f "$PATH_TARGET_SHOWN" ] && grep -Fq "$PATH_MARK_BEGIN" "$PATH_TARGET_SHOWN"; } && ! path_has_local_bin; then
      PATH_NEEDED=1
    else
      PATH_TARGET_SHOWN=""
    fi
  fi

  printf '%s' "$PLAN_TABLE" | sel_print_plan
  if [ "$PATH_NEEDED" -eq 1 ]; then
    ui_info "  - 셸 설정: 확인하면 $(sum_home_tilde "$PATH_TARGET_SHOWN")에 다음 줄을 추가합니다(원본은 백업): $PATH_LINE"
  fi
  if [ "$NEED_INSTALL" -gt 0 ]; then
    ui_info "  - 참고: 공식 설치 스크립트도 셸 설정 파일(~/.zprofile, ~/.zshrc)에 PATH를 추가할 수 있습니다."
  fi
  log_event info diagnose.completed Diagnosing "" "진단 완료" "" "" "plan=$PLAN_IDS" "needInstall=$NEED_INSTALL"

  if [ -n "$OPT_DRYRUN" ]; then
    ui_info "미리보기만 했습니다. 아무것도 바꾸지 않았습니다."
    exit 0
  fi
  if [ "$NEED_INSTALL" -eq 0 ] && [ "$PATH_NEEDED" -eq 0 ]; then break; fi
  if [ -n "$OPT_YES" ]; then break; fi
  if [ "$INTERACTIVE" -eq 0 ]; then
    ui_fail "질문 없이 설치하려면 --yes가 필요합니다."
    exit 2
  fi
  rc=0
  while true; do
    rc=0
    sel_confirm_prompt || rc=$?
    if [ "$rc" -ne 2 ]; then break; fi
    if [ "$SEL_INVALID_COUNT" -ge 5 ]; then invalid_exit; fi
  done
  if [ "$rc" -eq 0 ]; then
    log_event info plan.confirmed Confirming "" "설치 확인" "" "" "plan=$PLAN_IDS"
    break
  fi
  log_event info plan.declined Confirming "" "설치 거절" "" "" "plan=$PLAN_IDS"
  if [ -n "$OPT_COMPONENTS" ]; then cancel_run; fi
done

INSTALLED_ANY=0
i=0
for id in $PLAN_IDS; do
  state="$(var_get "PLAN_STATE_$id")"
  case "$state" in
    present|pathonly)
      sum_set "$id" AlreadyPresent 0 "$(var_get "DIAG_VERSION_$id")" "$(var_get "DIAG_PATH_$id")" ""
      ;;
    install)
      blocked=0
      for dep in $(cat_get "$id" depends); do
        dcode="$(var_get "RES_CODE_$dep")"
        if [ -n "$dcode" ] && [ "$dcode" != "0" ]; then blocked=1; fi
      done
      if [ "$blocked" -eq 1 ]; then
        sum_set "$id" Skipped 40 "" "" "의존성 설치 실패"
        continue
      fi
      i=$((i + 1))
      ui_progress "$i" "$NEED_INSTALL" "$(cat_get "$id" display) 설치 중"
      rc=0
      prov_install "$id" || rc=$?
      if [ "$rc" -ne 0 ]; then
        sum_set "$id" Failed "$rc" "" "" "$(sum_message "$rc" "$id")"
        ui_fail "$(cat_get "$id" display) 설치에 실패했습니다."
        log_event error component.failed Installing "$id" "설치 실패" "$rc" "$(log_code_name "$rc")"
      else
        INSTALLED_ANY=1
        var_set "NEW_$id" 1
        sum_set "$id" Installed 0 "" "" ""
        log_event info component.installed Installing "$id" "설치 완료" 0 "$(log_code_name 0)"
      fi
      ;;
  esac
done

PATH_NOTICE=""
if [ "$PATH_NEEDED" -eq 1 ]; then
  rc=0
  path_ensure_block || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ "$PATH_CHANGED" = "1" ]; then
      log_event info path.updated Installing "" "PATH 블록 추가" "" "" "target=$PATH_TARGET"
      if [ -n "$PATH_BACKUP" ]; then
        PATH_NOTICE="셸 설정을 바꿨습니다: $(sum_home_tilde "$PATH_TARGET")에 PATH 1줄 추가(백업: $(sum_home_tilde "$PATH_BACKUP"))"
      else
        PATH_NOTICE="셸 설정을 바꿨습니다: $(sum_home_tilde "$PATH_TARGET")에 PATH 1줄 추가(새 파일이라 백업 없음)"
      fi
    fi
  elif [ "$rc" -eq 2 ]; then
    ui_warn "자동으로 PATH를 설정하지 못했습니다. 셸 설정에 다음 줄을 추가하세요: $PATH_LINE"
  else
    ui_warn "PATH 설정 파일을 고치지 못했습니다. 셸 설정에 다음 줄을 추가하세요: $PATH_LINE"
  fi
fi

for id in $PLAN_IDS; do
  state="$(var_get "PLAN_STATE_$id")"
  isnew="$(var_get "NEW_$id")"
  if [ "$isnew" != "1" ] && [ "$state" != "pathonly" ]; then continue; fi
  ui_step 확인 "$(cat_get "$id" display) 버전 확인 중"
  ver_detect "$id"
  case "$VER_STATE" in
    present)
      if [ "$isnew" = "1" ]; then vstate=Installed; else vstate=AlreadyPresent; fi
      sum_set "$id" "$vstate" 0 "$VER_VERSION" "$VER_PATH" ""
      log_event info component.verified Verifying "$id" "버전 확인" 0 "$(log_code_name 0)" "version=$VER_VERSION"
      ;;
    pathonly)
      sum_set "$id" PathRefreshRequired 41 "$VER_VERSION" "$VER_PATH" "$(sum_message 41 "$id")"
      log_event warning component.verified Verifying "$id" "새 터미널 필요" 41 "$(log_code_name 41)" "version=$VER_VERSION"
      ;;
    *)
      sum_set "$id" Failed 50 "" "" "$(sum_message 50 "$id")"
      log_event error component.verified Verifying "$id" "버전 확인 실패" 50 "$(log_code_name 50)"
      ;;
  esac
done

EXIT="$(sum_exit_code "$PLAN_IDS")"
sum_write_json "$SELECTED" "$PLAN_IDS" "$EXIT"
sum_print "$PLAN_IDS" "$EXIT"
if [ -n "$PATH_NOTICE" ]; then
  ui_info "$PATH_NOTICE"
fi
log_event info run.completed Summary "" "완료" "$EXIT" "$(log_code_name "$EXIT")"
exit "$EXIT"
