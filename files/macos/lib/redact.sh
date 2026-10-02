#!/bin/bash
# 비밀값·홈 경로 마스킹. source 시 함수 정의 외 동작 없음.

# 표준 입력을 sed 규칙으로 마스킹해 표준 출력으로 낸다(셸 치환 전 단계).
_redact_sed() {
  sed -E \
    -e 's#Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+#Bearer [REDACTED]#g' \
    -e 's#Basic[[:space:]]+[A-Za-z0-9+/=]{8,}#Basic [REDACTED]#g' \
    -e 's#eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+#[REDACTED_JWT]#g' \
    -e 's#sk-[A-Za-z0-9_-]{16,}#[REDACTED_KEY]#g' \
    -e 's#xai-[A-Za-z0-9_-]{16,}#[REDACTED_KEY]#g' \
    -e 's#gh[pousr]_[A-Za-z0-9]{20,}#[REDACTED_TOKEN]#g' \
    -e 's#github_pat_[A-Za-z0-9_]{20,}#[REDACTED_TOKEN]#g' \
    -e 's#AIza[0-9A-Za-z_-]{30,}#[REDACTED_KEY]#g' \
    -e 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    -e 's#([?&]([Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Aa][Pp][Ii]_[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss]_[Tt][Oo][Kk][Ee][Nn])=)[^&[:space:]]+#\1[REDACTED]#g' \
    -e 's#([A-Za-z_]*([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Cc][Oo][Oo][Kk][Ii][Ee]|[Aa][Uu][Tt][Hh]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll])[A-Za-z_]*)=[^[:space:]&]+#\1=[REDACTED]#g' \
    -e 's#-----BEGIN [A-Z ]*PRIVATE KEY-----.*#[REDACTED_PRIVATE_KEY]#g'
}

# 한 줄(또는 여러 줄) 텍스트의 홈 경로·사용자 이름을 치환한다.
_redact_paths() {
  local text="$1" tilde='~' usertag='<USER>' ruser uprefix='/Users/' upat
  if [ -n "${HOME:-}" ]; then
    text="${text//"$HOME"/$tilde}"
  fi
  ruser="${USER:-}"
  if [ -n "$ruser" ]; then
    upat="$uprefix$ruser"
    text="${text//"$upat"/$uprefix$usertag}"
  fi
  printf '%s' "$text"
}

redact_text() {
  local out
  out="$(printf '%s\n' "$1" | _redact_sed; printf x)"
  out="${out%x}"
  out="${out%$'\n'}"
  _redact_paths "$out"
}

redact_stream() {
  local line
  _redact_sed | while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$(_redact_paths "$line")"
  done
}
