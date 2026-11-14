#!/bin/bash
# cuenv2.sh CMD... : cuenv.sh for the truth evals: the native macOS fixtures and the thin codex wrapper
A="/Applications/$(cat ~/cub-assets/cmux-app-name)"
export CMUX_TUI_SOCKET="$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-$(id -u)/cmux-app-cu-preview.sock"
export CUEVAL_CMUX_CU_COMMAND="[\"$A/Contents/Resources/bin/cmux\", \"computer-use\", \"mcp\", \"--primary\"]"
export CUEVAL_CUA_DRIVER_BIN="$HOME/cu/evals/computer-use/.cache/cua-driver-0.38.0/macos-arm64/cua-driver"
export CUEVAL_CODEX="$HOME/cu/codex-thin.sh"
export CUEVAL_MACOS_FIXTURES="$HOME/cu/fixture-build"
export PATH="$HOME/.local/bin:$PATH"
cd ~/cu/evals/computer-use
exec "$@"
