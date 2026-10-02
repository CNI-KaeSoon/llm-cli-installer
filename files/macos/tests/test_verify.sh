#!/bin/bash

load_libs common catalog verify

mkfake() {
  # mkfake <경로> <본문 줄...>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' '#!/bin/sh' "$@" > "$f"
  chmod 755 "$f"
}

test_absent() {
  ver_detect codex
  assert_eq absent "$VER_STATE"
  assert_eq "" "$VER_VERSION"
  assert_eq "" "$VER_PATH"
}

test_present_via_shell() {
  mkfake "$HOME/.local/bin/codex" 'echo "codex-cli 0.160.0"'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  ver_detect codex
  assert_eq present "$VER_STATE"
  assert_eq 0.160.0 "$VER_VERSION"
  assert_eq "$HOME/.local/bin/codex" "$VER_PATH"
}

test_pathonly() {
  mkfake "$HOME/.local/bin/codex" 'echo "codex-cli 0.160.0"'
  ver_detect codex
  assert_eq pathonly "$VER_STATE"
  assert_eq 0.160.0 "$VER_VERSION"
}

test_antigravity_alt_command() {
  mkfake "$HOME/.local/bin/antigravity" 'echo "1.2.14"'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  ver_detect antigravity
  assert_eq present "$VER_STATE"
  assert_eq 1.2.14 "$VER_VERSION"
  assert_eq "$HOME/.local/bin/antigravity" "$VER_PATH"
}

test_grok_known_path_grok_dir() {
  mkfake "$HOME/.grok/bin/grok" 'echo "grok 1.0.46"'
  ver_detect grok
  assert_eq pathonly "$VER_STATE"
  printf '%s\n' 'export PATH="$HOME/.grok/bin:$PATH"' > "$HOME/.zshrc"
  ver_detect grok
  assert_eq present "$VER_STATE"
  assert_eq 1.0.46 "$VER_VERSION"
}

test_version_fallback_arg() {
  mkfake "$HOME/.grok/bin/grok" 'case "$1" in version) echo "grok 1.0.46";; *) exit 1;; esac'
  printf '%s\n' 'export PATH="$HOME/.grok/bin:$PATH"' > "$HOME/.zshrc"
  ver_detect grok
  assert_eq present "$VER_STATE"
  assert_eq 1.0.46 "$VER_VERSION"
}

test_broken_binary_absent() {
  mkfake "$HOME/.local/bin/codex" 'exit 1'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  ver_detect codex
  assert_eq absent "$VER_STATE"
  assert_eq "" "$VER_VERSION"
}

test_agent_conflict() {
  mkfake "$SANDBOX/other/agent" 'echo agent'
  STUB_ZSH_PATH="$SANDBOX/other"
  export STUB_ZSH_PATH
  local out rc
  out="$(ver_agent_conflict)"
  rc=$?
  assert_exit 0 "$rc"
  assert_eq "$SANDBOX/other/agent" "$out"
  unset STUB_ZSH_PATH
  rm -f "$SANDBOX/other/agent"
  mkfake "$HOME/.grok/bin/agent" 'echo agent'
  printf '%s\n' 'export PATH="$HOME/.grok/bin:$PATH"' > "$HOME/.zshrc"
  out="$(ver_agent_conflict)"
  rc=$?
  assert_exit 1 "$rc"
  assert_eq "" "$out"
}

test_detect_is_read_only() {
  mkfake "$HOME/.local/bin/codex" 'echo "codex-cli 0.160.0"'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  local before after
  before="$(find "$HOME" | sort)"
  ver_detect codex
  after="$(find "$HOME" | sort)"
  assert_eq "$before" "$after"
}

test_zlogout_noise_ignored() {
  mkfake "$HOME/.local/bin/codex" 'echo "codex-cli 0.160.0"'
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$HOME/.zprofile"
  STUB_ZSH_NOISE=/usr/bin/true
  export STUB_ZSH_NOISE
  ver_detect codex
  unset STUB_ZSH_NOISE
  assert_eq present "$VER_STATE"
  assert_eq "$HOME/.local/bin/codex" "$VER_PATH"
}
