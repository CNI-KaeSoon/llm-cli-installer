#!/bin/bash

test_manifest_list_sorted() {
  local list sorted
  list="$(/bin/bash "$MAC_DIR/tools/update-manifest.sh" --list "$PKG_ROOT")"
  sorted="$(printf '%s\n' "$list" | LC_ALL=C sort)"
  assert_eq "$sorted" "$list" "정렬 순서"
  assert_contains "$list" "files/macos/VERSION"
  assert_contains "$list" "files/macos/tests/run.sh"
  assert_not_contains "$list" "files/macos/manifest.sha256"
}

test_manifest_write_format() {
  local pkg bad
  pkg="$(copy_package)"
  assert_file_exists "$pkg/files/macos/manifest.sha256"
  bad="$(grep -cvE '^[0-9a-f]{64}  [^ ].*$' "$pkg/files/macos/manifest.sha256")"
  assert_eq 0 "$bad" "형식 불일치 줄 수"
}

test_manifest_skips_ds_store() {
  local pkg list
  pkg="$(copy_package)"
  mkdir -p "$pkg/files/macos/lib"
  : > "$pkg/files/macos/lib/.DS_Store"
  list="$(/bin/bash "$pkg/files/macos/tools/update-manifest.sh" --list "$pkg")"
  assert_not_contains "$list" ".DS_Store"
}
