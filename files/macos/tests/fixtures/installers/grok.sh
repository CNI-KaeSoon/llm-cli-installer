#!/bin/sh
echo "INSTALL grok" >> "$STUB_LOG"

case " ${STUB_INSTALL_FAIL-} " in *" grok "*) echo "fixture failure" >&2; exit 1 ;; esac
mkdir -p "$HOME/.grok/bin"
printf '%s\n' '#!/bin/sh' 'echo "grok 1.0.46"' > "$HOME/.grok/bin/grok"
chmod 755 "$HOME/.grok/bin/grok"
printf '%s\n' '#!/bin/sh' 'echo "grok 1.0.46"' > "$HOME/.grok/bin/agent"
chmod 755 "$HOME/.grok/bin/agent"
case " ${STUB_FIXTURE_NO_PATH-} " in
  *" grok "*) ;;
  *) echo 'export PATH="$HOME/.grok/bin:$PATH"' >> "$HOME/.zshrc" ;;
esac
