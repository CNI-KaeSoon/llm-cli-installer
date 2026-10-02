#!/bin/bash
# catalog.sh: 네 CLI의 설치 주소·허용 호스트·명령·경로 데이터.
# source될 때 함수와 상수 정의 외에는 아무 동작도 하지 않는다.

cat_ids() {
  printf '%s\n' "codex claude antigravity grok"
}

# cat_get <id> <field>: 값을 표준 출력. 알 수 없는 id/field면 1 반환.
cat_get() {
  case "$1:$2" in
    codex:display) printf '%s\n' 'Codex CLI' ;;
    claude:display) printf '%s\n' 'Claude Code' ;;
    antigravity:display) printf '%s\n' 'Antigravity CLI' ;;
    grok:display) printf '%s\n' 'Grok CLI' ;;

    codex:menu_label) printf '%s\n' 'Codex CLI (OpenAI)' ;;
    claude:menu_label) printf '%s\n' 'Claude Code (Anthropic)' ;;
    antigravity:menu_label) printf '%s\n' 'Antigravity CLI (Google 개인 계정, Gemini CLI 후속)' ;;
    grok:menu_label) printf '%s\n' 'Grok CLI (xAI)' ;;

    codex:depends|claude:depends|antigravity:depends|grok:depends) ;;

    codex:url) printf '%s\n' 'https://chatgpt.com/codex/install.sh' ;;
    claude:url) printf '%s\n' 'https://claude.ai/install.sh' ;;
    antigravity:url) printf '%s\n' 'https://antigravity.google/cli/install.sh' ;;
    grok:url) printf '%s\n' 'https://x.ai/cli/install.sh' ;;

    codex:hosts) printf '%s\n' 'chatgpt.com releases.openai.com' ;;
    claude:hosts) printf '%s\n' 'claude.ai downloads.claude.ai' ;;
    antigravity:hosts) printf '%s\n' 'antigravity.google' ;;
    grok:hosts) printf '%s\n' 'x.ai' ;;

    codex:shell) printf '%s\n' '/bin/sh' ;;
    claude:shell|antigravity:shell|grok:shell) printf '%s\n' '/bin/bash' ;;

    codex:env) printf '%s\n' 'CODEX_NON_INTERACTIVE=1' ;;
    claude:env|antigravity:env|grok:env) ;;

    codex:commands) printf '%s\n' 'codex' ;;
    claude:commands) printf '%s\n' 'claude' ;;
    antigravity:commands) printf '%s\n' 'agy antigravity' ;;
    grok:commands) printf '%s\n' 'grok' ;;

    codex:version_args|claude:version_args) printf '%s\n' '--version' ;;
    antigravity:version_args|grok:version_args) printf '%s\n' '--version version' ;;

    codex:known_paths) printf '%s\n' '.local/bin/codex' ;;
    claude:known_paths) printf '%s\n' '.local/bin/claude' ;;
    antigravity:known_paths) printf '%s\n' '.local/bin/agy' ;;
    grok:known_paths) printf '%s\n' '.grok/bin/grok .local/bin/grok' ;;

    codex:note|claude:note|antigravity:note) ;;
    grok:note) printf '%s\n' '참고: Grok 설치기는 agent 명령도 만듭니다' ;;

    codex:docs) printf '%s\n' 'https://github.com/openai/codex/blob/main/docs/install.md' ;;
    claude:docs) printf '%s\n' 'https://code.claude.com/docs/en/setup' ;;
    antigravity:docs) printf '%s\n' 'https://antigravity.google/docs/cli/install' ;;
    grok:docs) printf '%s\n' 'https://docs.x.ai/build/overview' ;;

    *) return 1 ;;
  esac
  return 0
}
