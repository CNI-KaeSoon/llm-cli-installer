#!/bin/bash
# 테스트 실행기: run.sh [--no-static] [test_파일.sh ...]
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
NO_STATIC=0
FILES=()
for arg in "$@"; do
  case "$arg" in
    --no-static) NO_STATIC=1 ;;
    */*) FILES+=("$arg") ;;
    *) FILES+=("$TESTS_DIR/$arg") ;;
  esac
done
if [ "${#FILES[@]}" -eq 0 ]; then
  for f in "$TESTS_DIR"/test_*.sh; do
    [ -f "$f" ] && FILES+=("$f")
  done
fi

LLMCLI_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/llmcli-tests.XXXXXX")"
export LLMCLI_TEST_TMP
printf 'TMP: %s\n' "$LLMCLI_TEST_TMP"

PASS=0
FAIL=0
SKIP=0
STATIC_FAIL=0

if [ "$NO_STATIC" -eq 0 ]; then
  if /bin/bash "$TESTS_DIR/static_check.sh" > "$LLMCLI_TEST_TMP/static.log" 2>&1; then
    echo "STATIC: PASS"
  else
    echo "STATIC: FAIL"
    STATIC_FAIL=1
    sed -e 's/^/    /' "$LLMCLI_TEST_TMP/static.log"
  fi
fi

for file in "${FILES[@]}"; do
  base="$(basename "$file")"
  funcs="$(grep -E '^test_[A-Za-z0-9_]+\(\)' "$file" | sed -E 's/\(\).*//')"
  if [ -z "$funcs" ]; then
    echo "FAIL $base: 테스트 함수 없음"
    FAIL=$((FAIL + 1))
    continue
  fi
  for fn in $funcs; do
    log="$LLMCLI_TEST_TMP/$fn.log"
    ( . "$TESTS_DIR/lib/assert.sh"; . "$TESTS_DIR/lib/helpers.sh"; . "$file"; setup_sandbox; "$fn" ) > "$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "PASS $base:$fn"
      PASS=$((PASS + 1))
    elif [ "$rc" -eq 200 ]; then
      echo "SKIP $base:$fn"
      SKIP=$((SKIP + 1))
    else
      echo "FAIL $base:$fn"
      tail -n 20 "$log" | sed -e 's/^/    /'
      FAIL=$((FAIL + 1))
    fi
  done
done

echo "RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ] || [ "$STATIC_FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
