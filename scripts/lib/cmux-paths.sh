#!/usr/bin/env bash

# Shared repo path contract for local scripts.
# Keep this narrowly focused on path resolution so directory moves can update
# one place without adding broader build orchestration layers.

cmux_paths_init() {
  local caller_path="${1:-${BASH_SOURCE[0]}}"
  local caller_dir script_dir

  caller_dir="$(cd "$(dirname "$caller_path")" && pwd)"
  if [[ "$(basename "$caller_dir")" == "lib" ]]; then
    script_dir="$(cd "$caller_dir/.." && pwd)"
  else
    script_dir="$caller_dir"
  fi

  if [[ -z "${CMUX_REPO_ROOT:-}" ]]; then
    CMUX_REPO_ROOT="$(cd "$script_dir/.." && pwd)"
  fi

  if [[ -z "${CMUX_TOOLS_SCRIPTS_DIR:-}" ]]; then
    CMUX_TOOLS_SCRIPTS_DIR="$CMUX_REPO_ROOT/scripts"
  fi
  if [[ -z "${CMUX_APP_ROOT:-}" ]]; then
    CMUX_APP_ROOT="$CMUX_REPO_ROOT/Apps/cmux-macOS"
  fi
  if [[ -z "${CMUX_XCODE_PROJECT_PATH:-}" ]]; then
    CMUX_XCODE_PROJECT_PATH="$CMUX_REPO_ROOT/Apps/cmux-macOS/GhosttyTabs.xcodeproj"
  fi
  if [[ -z "${CMUX_GHOSTTY_DIR:-}" ]]; then
    CMUX_GHOSTTY_DIR="$CMUX_REPO_ROOT/vendor/ghostty"
  fi
  if [[ -z "${CMUX_REMOTE_DAEMON_DIR:-}" ]]; then
    CMUX_REMOTE_DAEMON_DIR="$CMUX_REPO_ROOT/daemon/remote"
  fi
  if [[ -z "${CMUX_LOCAL_DAEMON_DIR:-}" ]]; then
    CMUX_LOCAL_DAEMON_DIR="$CMUX_REPO_ROOT/cmuxd"
  fi
  if [[ -z "${CMUX_GHOSTTYKIT_PATH:-}" ]]; then
    CMUX_GHOSTTYKIT_PATH="$CMUX_APP_ROOT/GhosttyKit.xcframework"
  fi
  if [[ -z "${CMUX_APP_SUPPORT_DIR:-}" ]]; then
    CMUX_APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
  fi
  if [[ -z "${CMUX_HOMEBREW_TAP_DIR:-}" ]]; then
    CMUX_HOMEBREW_TAP_DIR="$CMUX_REPO_ROOT/vendor/homebrew-cmux"
  fi
}
