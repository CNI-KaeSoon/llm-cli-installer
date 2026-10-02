#!/bin/bash
# macOS launcher: runs files/macos/bin/llmcli-install.sh with /bin/bash.
# Recommended start: type "bash " in Terminal, drag this file in, press Enter.
LLMCLI_LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
LLMCLI_MAIN="$LLMCLI_LAUNCH_DIR/files/macos/bin/llmcli-install.sh"
llmcli_wait() { if [ -t 0 ]; then printf '%s' "Enter를 누르면 창을 닫습니다."; IFS= read -r _; fi; }
if [ ! -f "$LLMCLI_MAIN" ]; then
  echo "files/macos/bin/llmcli-install.sh가 없습니다. ZIP 전체를 풀고 installer-mac.command를 files 폴더 옆에 두세요."
  llmcli_wait
  exit 24
fi
/bin/bash "$LLMCLI_MAIN" "$@"
LLMCLI_CODE=$?
echo
echo "종료 코드: $LLMCLI_CODE"
llmcli_wait
exit "$LLMCLI_CODE"
