#!/bin/sh
echo "INSTALL codex" >> "$STUB_LOG"
echo "ENV codex CODEX_NON_INTERACTIVE=${CODEX_NON_INTERACTIVE-}" >> "$STUB_LOG"
case " ${STUB_INSTALL_FAIL-} " in *" codex "*) echo "fixture failure" >&2; exit 1 ;; esac
mkdir -p "$HOME/.local/bin"
printf '%s\n' '#!/bin/sh' 'echo "codex-cli 0.160.0"' > "$HOME/.local/bin/codex"
chmod 755 "$HOME/.local/bin/codex"
