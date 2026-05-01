#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/zig-build-env.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/launch-tagged-automation.sh <tag> [options]

Options:
  --mode <mode>       Socket mode override. Default: automation
  --shell-log <path>  Set GHOSTTY_ZSH_INTEGRATION_LOG for shells in the tagged app.
  --wait-socket <s>   Wait for the tagged socket to appear. Default: 10
  --env KEY=VALUE     Extra environment variable to inject at launch. Repeatable.
  -h, --help          Show this help.
EOF
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\\.+//; s/\\.+$//; s/\\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  echo "$cleaned"
}

wait_for_process_pattern_exit() {
  local pattern="$1"
  local timeout_s="${2:-10}"
  local deadline=$((SECONDS + timeout_s))
  while (( SECONDS < deadline )); do
    if ! pgrep -f "$pattern" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

TAG=""
MODE="automation"
SHELL_LOG=""
WAIT_SOCKET="10"
EXTRA_ENV=()
EXTRA_ENV_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      if [[ -z "$MODE" ]]; then
        echo "error: --mode requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --env)
      if [[ -z "${2:-}" ]]; then
        echo "error: --env requires KEY=VALUE" >&2
        exit 1
      fi
      EXTRA_ENV+=("${2}")
      EXTRA_ENV_COUNT=$((EXTRA_ENV_COUNT + 1))
      shift 2
      ;;
    --shell-log)
      SHELL_LOG="${2:-}"
      if [[ -z "$SHELL_LOG" ]]; then
        echo "error: --shell-log requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    --wait-socket)
      WAIT_SOCKET="${2:-}"
      if [[ -z "$WAIT_SOCKET" ]]; then
        echo "error: --wait-socket requires seconds" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$TAG" ]]; then
        TAG="$1"
        shift
      else
        echo "error: unexpected argument $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: tag is required" >&2
  usage
  exit 1
fi

TAG_ID="$(sanitize_bundle "$TAG")"
TAG_SLUG="$(sanitize_path "$TAG")"
APP="$HOME/Library/Developer/Xcode/DerivedData/cmux-${TAG_SLUG}/Build/Products/Debug/cmux DEV ${TAG}.app"
BID="com.cmuxterm.app.debug.${TAG_ID}"
SOCK="/tmp/cmux-debug-${TAG_SLUG}.sock"
DSOCK="$HOME/Library/Application Support/cmux/cmuxd-dev-${TAG_SLUG}.sock"
LOG="/tmp/cmux-debug-${TAG_SLUG}.log"
DAEMON_BIN="$PWD/daemon/remote/zig/zig-out/bin/cmuxd-remote"

if [[ ! -d "$APP" ]]; then
  echo "error: tagged app not found at $APP" >&2
  exit 1
fi

if [[ -d "$PWD/daemon/remote/zig" ]]; then
  (cd "$PWD/daemon/remote/zig" && cmux_run_zig build -Doptimize=ReleaseFast)
fi

pkill -f "cmux DEV ${TAG}.app/Contents/MacOS/cmux DEV" || true
wait_for_process_pattern_exit "cmux DEV ${TAG}.app/Contents/MacOS/cmux DEV" 10 || true
pkill -f "cmuxd-remote serve --unix --socket ${DSOCK}" || true
wait_for_process_pattern_exit "cmuxd-remote serve --unix --socket ${DSOCK}" 10 || true
rm -f "$SOCK" "$DSOCK"

OPEN_ENV=(
  env
  -u CMUX_SOCKET_PATH
  -u CMUX_SOCKET_MODE
  -u CMUX_TAB_ID
  -u CMUX_PANEL_ID
  -u CMUX_SURFACE_ID
  -u CMUX_WORKSPACE_ID
  -u CMUXD_UNIX_PATH
  -u CMUX_REMOTE_DAEMON_BINARY
  -u CMUX_TAG
  -u CMUX_PORT
  -u CMUX_PORT_END
  -u CMUX_PORT_RANGE
  -u CMUX_DEBUG_LOG
  -u CMUX_BUNDLE_ID
  -u CMUX_SHELL_INTEGRATION
  -u CMUX_SHELL_INTEGRATION_DIR
  -u CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION
  -u CMUX_LOAD_GHOSTTY_BASH_INTEGRATION
  -u CMUX_BUNDLED_CLI_PATH
  -u GHOSTTY_BIN_DIR
  -u GHOSTTY_RESOURCES_DIR
  -u GHOSTTY_SHELL_FEATURES
  -u GHOSTTY_ZSH_INTEGRATION_LOG
  -u GIT_PAGER
  -u GH_PAGER
  -u TERM
  -u TERM_PROGRAM
  -u TERM_PROGRAM_VERSION
  -u COLORTERM
  -u TERMINFO
  -u MANPATH
  -u XDG_DATA_DIRS
  "CMUX_SOCKET_MODE=${MODE}"
  "CMUX_SOCKET_PATH=${SOCK}"
  "CMUXD_UNIX_PATH=${DSOCK}"
  "CMUX_DEBUG_LOG=${LOG}"
)
if [[ -x "$DAEMON_BIN" ]]; then
  OPEN_ENV+=("CMUX_REMOTE_DAEMON_BINARY=${DAEMON_BIN}")
fi

if (( EXTRA_ENV_COUNT > 0 )); then
  for kv in "${EXTRA_ENV[@]}"; do
    OPEN_ENV+=("${kv}")
  done
fi
if [[ -n "$SHELL_LOG" ]]; then
  OPEN_ENV+=("GHOSTTY_ZSH_INTEGRATION_LOG=${SHELL_LOG}")
fi

"${OPEN_ENV[@]}" open -g "$APP"

if [[ "$WAIT_SOCKET" != "0" ]]; then
  deadline=$((SECONDS + WAIT_SOCKET))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCK" ]]; then
      break
    fi
    sleep 0.1
  done
fi

echo "app: $APP"
echo "bundle_id: $BID"
echo "socket: $SOCK"
echo "cmuxd_socket: $DSOCK"
echo "log: $LOG"
echo "mode: $MODE"
echo "socket_ready: $(if [[ -S "$SOCK" ]]; then echo yes; else echo no; fi)"
if [[ -n "$SHELL_LOG" ]]; then
  echo "shell_log: $SHELL_LOG"
fi
if (( EXTRA_ENV_COUNT > 0 )); then
  echo "extra_env:"
  for kv in "${EXTRA_ENV[@]}"; do
    echo "  $kv"
  done
fi
