#!/bin/bash
# 맥 manifest 생성 도구: update-manifest.sh [--list] [배포_폴더]
LIST_ONLY=0
ROOT=""
for arg in "$@"; do
  case "$arg" in
    --list) LIST_ONLY=1 ;;
    *) ROOT="$arg" ;;
  esac
done
if [ -z "$ROOT" ]; then
  ROOT="$(dirname "$0")/../../.."
fi
ROOT="$(cd "$ROOT" && pwd)" || exit 1
cd "$ROOT" || exit 1

collect_paths() {
  if [ -f "installer-mac.command" ]; then
    printf '%s\n' "installer-mac.command"
  fi
  if [ -d files/macos ]; then
    find files/macos -type f ! -name .DS_Store ! -path files/macos/manifest.sha256
  fi
}

if [ "$LIST_ONLY" = "1" ]; then
  collect_paths | LC_ALL=C sort
  exit 0
fi

OUT="$ROOT/files/macos/manifest.sha256"
PATHS="$(collect_paths | LC_ALL=C sort)"
TMP_OUT="$OUT.tmp.$$"
: > "$TMP_OUT"
printf '%s\n' "$PATHS" | while IFS= read -r p; do
  h="$(shasum -a 256 < "$p" | awk '{print $1}')"
  printf '%s  %s\n' "$h" "$p" >> "$TMP_OUT"
done
mv -f "$TMP_OUT" "$OUT"
printf '%s\n' "$OUT"
exit 0
