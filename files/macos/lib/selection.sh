#!/bin/bash
# selection.sh: 번호 메뉴, 이름·별칭 해석, 의존성 포함 계획, 계획 표, 확인 질문.
# source될 때 함수와 상수 정의 외에는 아무 동작도 하지 않는다.
# 원칙: EOF·무효 입력은 절대 "전체 설치"로 이어지지 않는다.

SEL_MAX_INVALID=5

# sel_normalize_name <이름>: 표준 id를 출력. legacy-gemini는 3, 모르는 이름은 1 반환.
sel_normalize_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$n" in
    codex|openai|chatgpt) printf '%s\n' codex ;;
    claude|claude-code|anthropic) printf '%s\n' claude ;;
    antigravity|agy|google|gemini) printf '%s\n' antigravity ;;
    grok|xai) printf '%s\n' grok ;;
    all) printf '%s\n' all ;;
    legacy-gemini) return 3 ;;
    *) return 1 ;;
  esac
  return 0
}

# sel_expand <토큰...>: all 펼치기 + 첫 순서 유지 중복 제거, 공백 구분 출력.
sel_expand() {
  local t x out="" seen
  for t in "$@"; do
    if [ "$t" = "all" ]; then
      set -- "$@" codex claude antigravity grok
      break
    fi
  done
  for t in "$@"; do
    [ "$t" = "all" ] && continue
    seen=0
    for x in $out; do
      if [ "$x" = "$t" ]; then seen=1; break; fi
    done
    if [ "$seen" -eq 0 ]; then
      if [ -z "$out" ]; then out="$t"; else out="$out $t"; fi
    fi
  done
  printf '%s\n' "$out"
}

# sel_parse_menu_answer "<응답>": 메뉴 응답 해석. 무효면 출력 없이 1.
sel_parse_menu_answer() {
  local s toks t id rc
  local resolved=""
  s="$(printf '%s' "$1" | tr ',' ' ')"
  toks=()
  read -r -a toks <<< "$s"
  if [ "${#toks[@]}" -eq 0 ]; then
    printf '%s\n' "codex claude antigravity grok"
    return 0
  fi
  if [ "${#toks[@]}" -eq 1 ] && [ "${toks[0]}" = "0" ]; then
    printf '%s\n' "CANCEL"
    return 0
  fi
  for t in "${toks[@]}"; do
    case "$t" in
      0) return 1 ;;
      1) id=codex ;;
      2) id=claude ;;
      3) id=antigravity ;;
      4) id=grok ;;
      5) id=all ;;
      *)
        rc=0
        id="$(sel_normalize_name "$t")" || rc=$?
        if [ "$rc" -ne 0 ] || [ -z "$id" ]; then return 1; fi
        ;;
    esac
    resolved="$resolved $id"
  done
  # shellcheck disable=SC2086
  sel_expand $resolved
  return 0
}

# sel_parse_components_arg "<목록>": 결과는 전역 SEL_RESULT, 오류 토큰은 SEL_ERROR_TOKEN.
sel_parse_components_arg() {
  local s toks t id rc bad="" legacy=0
  local resolved=""
  SEL_RESULT=""
  SEL_ERROR_TOKEN=""
  s="$(printf '%s' "$1" | tr ',' ' ')"
  toks=()
  read -r -a toks <<< "$s"
  if [ "${#toks[@]}" -eq 0 ]; then
    return 1
  fi
  for t in "${toks[@]}"; do
    rc=0
    id="$(sel_normalize_name "$t")" || rc=$?
    if [ "$rc" -eq 3 ]; then
      legacy=1
    elif [ "$rc" -ne 0 ] || [ -z "$id" ]; then
      [ -z "$bad" ] && bad="$t"
    else
      resolved="$resolved $id"
    fi
  done
  if [ "$legacy" -eq 1 ]; then
    return 3
  fi
  if [ -n "$bad" ]; then
    SEL_ERROR_TOKEN="$bad"
    return 1
  fi
  # shellcheck disable=SC2086
  SEL_RESULT="$(sel_expand $resolved)"
  return 0
}

# sel_plan "<선택 id 목록>": 의존성(재귀)을 포함해 <id>\t<role>\t<reason> 줄을 출력.
sel_plan() {
  local sel="$1" id dep d queue item
  local dep_ids="" dep_reason_ids="" dep_reason_vals=""
  local all_ids
  all_ids="$(cat_ids)"
  local reasons_k=() reasons_v=()
  local pending=() cur_owner owner_disp i found

  # 각 선택 CLI에서 시작해 의존성을 재귀(큐)로 모은다.
  for id in $all_ids; do
    case " $sel " in *" $id "*) ;; *) continue ;; esac
    owner_disp="$(cat_get "$id" display)" || owner_disp="$id"
    pending=("$id")
    while [ "${#pending[@]}" -gt 0 ]; do
      item="${pending[0]}"
      pending=("${pending[@]:1}")
      dep="$(cat_get "$item" depends)" || dep=""
      for d in $dep; do
        found=0
        for i in ${dep_ids}; do
          if [ "$i" = "$d" ]; then found=1; break; fi
        done
        if [ "$found" -eq 0 ]; then
          dep_ids="$dep_ids $d"
          reasons_k+=("$d")
          reasons_v+=("$owner_disp")
          pending+=("$d")
        fi
      done
    done
  done

  for id in $all_ids; do
    for i in "${!reasons_k[@]}"; do
      if [ "${reasons_k[$i]}" = "$id" ]; then
        printf '%s\t%s\t%s\n' "$id" dependency "${reasons_v[$i]}"
        break
      fi
    done
  done
  for id in $all_ids; do
    case " $sel " in *" $id "*) printf '%s\t%s\t%s\n' "$id" selected "-" ;; esac
  done
  return 0
}

# sel_print_menu: 설치 메뉴를 출력한다.
sel_print_menu() {
  printf '\n'
  printf '%s\n' "설치할 CLI를 선택하세요."
  printf '  1) %s\n' "$(cat_get codex menu_label)"
  printf '  2) %s\n' "$(cat_get claude menu_label)"
  printf '  3) %s\n' "$(cat_get antigravity menu_label)"
  printf '  4) %s\n' "$(cat_get grok menu_label)"
  printf '%s\n' "  5) 전체 설치 (1~4 모두)"
  printf '%s\n' "  0) 설치하지 않고 종료"
  printf '%s\n' "여러 개는 쉼표로 구분합니다(예: 1,3). 아무것도 입력하지 않고 Enter를 누르면 전체를 고릅니다."
}

# sel_read_line "<프롬프트>": 한 줄을 SEL_LINE에 읽는다. EOF(내용 없음)면 1 반환.
sel_read_line() {
  local rc=0
  SEL_LINE=""
  printf '%s' "$1"
  IFS= read -r SEL_LINE || rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$SEL_LINE" ]; then
    SEL_LINE=""
    return 1
  fi
  return 0
}

# sel_menu_loop: 결과는 SEL_RESULT. 0 선택됨, 70 취소, 2 무효 입력 한도 초과.
sel_menu_loop() {
  local ok rc
  SEL_INVALID_COUNT="${SEL_INVALID_COUNT:-0}"
  SEL_RESULT=""
  while true; do
    sel_print_menu
    ok=1
    if sel_read_line "번호 입력: "; then
      rc=0
      SEL_RESULT="$(sel_parse_menu_answer "$SEL_LINE")" || rc=$?
      if [ "$rc" -eq 0 ]; then
        ok=0
      fi
    fi
    if [ "$ok" -eq 0 ]; then
      if [ "$SEL_RESULT" = "CANCEL" ]; then
        return 70
      fi
      return 0
    fi
    SEL_RESULT=""
    ui_warn "잘못된 입력입니다. 0~5 사이 번호를 입력하세요."
    SEL_INVALID_COUNT=$((SEL_INVALID_COUNT + 1))
    if [ "$SEL_INVALID_COUNT" -ge "$SEL_MAX_INVALID" ]; then
      return 2
    fi
  done
}

# sel_print_plan: 표준 입력 줄 <id>\t<role>\t<reason>\t<state>\t<version> 을 계획 표로 출력.
sel_print_plan() {
  local id role reason state version disp note line
  printf '\n'
  printf '%s\n' "설치 계획"
  while IFS=$'\t' read -r id role reason state version; do
    [ -z "$id" ] && continue
    disp="$(cat_get "$id" display)" || disp="$id"
    case "$state" in
      present|pathonly) line="  - ${disp}: 이미 있음(버전 ${version}, 건너뜀)" ;;
      *) line="  - ${disp}: 설치함" ;;
    esac
    if [ "$role" = "dependency" ]; then
      line="${line} (${reason} 실행에 필요)"
    fi
    if [ "$state" = "install" ]; then
      note="$(cat_get "$id" note)" || note=""
      if [ -n "$note" ]; then
        line="${line} — ${note}"
      fi
    fi
    printf '%s\n' "$line"
  done
}

# sel_confirm_prompt: 0 진행, 1 다시 선택, 2 무효/EOF.
sel_confirm_prompt() {
  local a
  if sel_read_line "진행할까요? (Y: 진행 / N: 다시 선택): "; then
    a="$(str_lower "$(str_trim "$SEL_LINE")")"
    case "$a" in
      y|yes|예|ㅛ) return 0 ;;
      n|no|아니오|ㅜ) return 1 ;;
    esac
  fi
  ui_warn "Y 또는 N을 입력하세요."
  SEL_INVALID_COUNT=$(( ${SEL_INVALID_COUNT:-0} + 1 ))
  return 2
}
