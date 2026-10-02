#!/bin/bash

test_cat_ids_order() {
  load_libs common platform catalog
  assert_eq "codex claude antigravity grok" "$(cat_ids)" "cat_ids"
}

test_cat_get_values() {
  load_libs common platform catalog
  assert_eq "https://chatgpt.com/codex/install.sh" "$(cat_get codex url)"
  assert_eq "https://claude.ai/install.sh" "$(cat_get claude url)"
  assert_eq "https://antigravity.google/cli/install.sh" "$(cat_get antigravity url)"
  assert_eq "https://x.ai/cli/install.sh" "$(cat_get grok url)"
  assert_eq "chatgpt.com releases.openai.com" "$(cat_get codex hosts)"
  assert_eq "claude.ai downloads.claude.ai" "$(cat_get claude hosts)"
  assert_eq "antigravity.google" "$(cat_get antigravity hosts)"
  assert_eq "x.ai" "$(cat_get grok hosts)"
  assert_eq "/bin/sh" "$(cat_get codex shell)"
  assert_eq "/bin/bash" "$(cat_get claude shell)"
  assert_eq "CODEX_NON_INTERACTIVE=1" "$(cat_get codex env)"
  assert_eq "agy antigravity" "$(cat_get antigravity commands)"
  assert_eq ".grok/bin/grok .local/bin/grok" "$(cat_get grok known_paths)"
  assert_eq "참고: Grok 설치기는 agent 명령도 만듭니다" "$(cat_get grok note)"
  assert_eq "Codex CLI (OpenAI)" "$(cat_get codex menu_label)"
  assert_eq "Claude Code (Anthropic)" "$(cat_get claude menu_label)"
  assert_eq "Antigravity CLI (Google 개인 계정, Gemini CLI 후속)" "$(cat_get antigravity menu_label)"
  assert_eq "Grok CLI (xAI)" "$(cat_get grok menu_label)"
}

test_cat_depends_empty() {
  load_libs common platform catalog
  local id out rc
  for id in $(cat_ids); do
    out="$(cat_get "$id" depends)"; rc=$?
    assert_eq "" "$out" "$id depends 출력"
    assert_exit 0 "$rc" "$id depends 반환"
  done
}

test_cat_get_unknown() {
  load_libs common platform catalog
  local out rc
  out="$(cat_get nope url)"; rc=$?
  assert_eq "" "$out" "unknown id 출력"
  assert_exit 1 "$rc" "unknown id"
  out="$(cat_get codex nope)"; rc=$?
  assert_eq "" "$out" "unknown field 출력"
  assert_exit 1 "$rc" "unknown field"
}

test_cat_urls_https_and_hosts_match() {
  load_libs common platform catalog
  local id url host h found
  for id in $(cat_ids); do
    url="$(cat_get "$id" url)"
    case "$url" in https://*) ;; *) fail "$id url이 https가 아님" ;; esac
    host="${url#https://}"; host="${host%%/*}"
    found=0
    for h in $(cat_get "$id" hosts); do
      [ "$h" = "$host" ] && found=1
    done
    assert_eq 1 "$found" "$id 호스트 $host 가 hosts에 있음"
  done
}

test_plat_ok() {
  load_libs common platform catalog
  plat_check; assert_exit 0 $? "기본값"
  LLMCLI_ARCH=x86_64 plat_check; assert_exit 0 $? "x86_64"
  LLMCLI_OS_VERSION=13.0 plat_check; assert_exit 0 $? "13.0"
}

test_plat_fail_os() {
  load_libs common platform catalog
  LLMCLI_OS_NAME=Linux plat_check; assert_exit 10 $? "Linux"
  LLMCLI_OS_NAME=Linux plat_check
  assert_eq "macOS에서만 실행할 수 있습니다." "$PLAT_REASON"
}

test_plat_fail_version() {
  load_libs common platform catalog
  LLMCLI_OS_VERSION=12.7.6 plat_check; assert_exit 10 $? "12.7.6"
  assert_eq "macOS 13 이상이 필요합니다(현재 12.7.6)." "$PLAT_REASON"
  LLMCLI_OS_VERSION=abc plat_check; assert_exit 10 $? "abc"
}

test_plat_fail_arch() {
  load_libs common platform catalog
  LLMCLI_ARCH=i386 plat_check; assert_exit 10 $? "i386"
  assert_eq "지원하지 않는 CPU 종류입니다(i386)." "$PLAT_REASON"
}
