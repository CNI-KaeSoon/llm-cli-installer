#!/bin/bash
# 정적 검사: 셔뱅, 구문, 금지 패턴
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PKG_ROOT="$(cd "$MAC_DIR/../.." && pwd)"
SELF="$TESTS_DIR/static_check.sh"
NG=0

PATTERNS=(
  '(^|[^A-Za-z_])sudo([^A-Za-z_]|$)|sudo'
  'rm[[:space:]]+-[A-Za-z]*[rR]|재귀 삭제'
  'declare[[:space:]]+-[A-Za-z]*[An]|연관 배열·nameref'
  '(^|[^A-Za-z_])(mapfile|readarray|coproc)([^A-Za-z_]|$)|bash 4 내장 명령'
  '(^|[;&|[:space:]])eval[[:space:]]|eval'
  '\|[[:space:]]*(/bin/)?(ba|z)?sh([[:space:]]|$)|파이프 셸 실행'
  '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|대소문자 확장'
  '\|&|&>>|bash 4 리디렉션'
  'xattr[[:space:]]+-[dwc]|quarantine 변경'
  'brew[[:space:]]+install|brew install'
)

FILES=()
[ -f "$PKG_ROOT/installer-mac.command" ] && FILES+=("$PKG_ROOT/installer-mac.command")
for pat in "$MAC_DIR"/bin/*.sh "$MAC_DIR"/lib/*.sh "$MAC_DIR"/tools/*.sh \
  "$MAC_DIR"/tests/*.sh "$MAC_DIR"/tests/lib/*.sh "$MAC_DIR"/tests/stubs/* \
  "$MAC_DIR"/tests/fixtures/installers/*.sh; do
  [ -f "$pat" ] && FILES+=("$pat")
done

HAVE_SC=0
if command -v shellcheck > /dev/null 2>&1; then
  HAVE_SC=1
else
  echo "shellcheck 없음: 건너뜀"
fi

for f in "${FILES[@]}"; do
  first="$(head -n 1 "$f")"
  case "$first" in
    '#!/bin/'*) ;;
    *) echo "$f:1: 첫 줄이 #!/bin/ 로 시작하지 않음"; NG=$((NG + 1)) ;;
  esac
  interp=/bin/bash
  [ "$first" = '#!/bin/sh' ] && interp=/bin/sh
  if ! "$interp" -n "$f" 2> /dev/null; then
    echo "$f:1: 구문 오류 ($interp -n 실패)"
    NG=$((NG + 1))
  fi
  if [ "$f" != "$SELF" ]; then
    for entry in "${PATTERNS[@]}"; do
      re="${entry%|*}"
      desc="${entry##*|}"
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        echo "$f:${hit%%:*}: 금지 패턴 $desc"
        NG=$((NG + 1))
      done < <(grep -nE -- "$re" "$f")
    done
  fi
  if [ "$HAVE_SC" -eq 1 ]; then
    case "$f" in
      *.sh)
        if ! shellcheck -s bash -S error "$f" > /dev/null 2>&1; then
          echo "$f: shellcheck 오류"
          NG=$((NG + 1))
        fi
        ;;
    esac
  fi
done

if [ "$NG" -eq 0 ]; then
  echo "STATIC OK"
  exit 0
fi
echo "STATIC NG $NG"
exit 1
