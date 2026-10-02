#!/bin/sh
echo "INSTALL antigravity" >> "$STUB_LOG"

case " ${STUB_INSTALL_FAIL-} " in *" antigravity "*) echo "fixture failure" >&2; exit 1 ;; esac
mkdir -p "$HOME/.local/bin"
printf '%s\n' '#!/bin/sh' 'echo "1.2.14"' > "$HOME/.local/bin/agy"
chmod 755 "$HOME/.local/bin/agy"
