#!/bin/sh
echo "INSTALL claude" >> "$STUB_LOG"

case " ${STUB_INSTALL_FAIL-} " in *" claude "*) echo "fixture failure" >&2; exit 1 ;; esac
mkdir -p "$HOME/.local/bin"
printf '%s\n' '#!/bin/sh' 'echo "2.1.287 (Claude Code)"' > "$HOME/.local/bin/claude"
chmod 755 "$HOME/.local/bin/claude"
