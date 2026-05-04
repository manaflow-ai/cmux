#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TAG=""
LAUNCH=0
SOCKET_PATH=""
PACKAGE=1
PYTHON_BIN="${CMUX_PYTHON:-python3}"

usage() {
  cat <<'EOF'
Usage: ./scripts/reload-linux.sh --tag <name> [options]

Options:
  --tag <name>       Required. Short tag for isolated Linux socket/log/pid paths.
  --launch           Launch cmux Linux after verification and packaging.
  --socket <path>    Override the socket path used with --launch.
  --no-package       Skip linux/package.sh after static verification.
  -h, --help         Show this help.
EOF
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

select_python() {
  if "$PYTHON_BIN" -c 'import sys' >/dev/null 2>&1; then
    return
  fi
  if [[ -x /usr/bin/python3 ]]; then
    PYTHON_BIN=/usr/bin/python3
    return
  fi
  echo "error: python3 is required for Linux cmux reload." >&2
  exit 1
}

run_static_checks() {
  local pycache_prefix="$1"
  echo "==> Checking Python sources..."
  PYTHONPYCACHEPREFIX="$pycache_prefix" "$PYTHON_BIN" -m py_compile \
    "$ROOT_DIR"/linux/lib/cmux_linux/*.py \
    "$ROOT_DIR"/linux/tools/mock_feedback_server.py \
    "$ROOT_DIR"/linux/tools/package_manifest.py \
    "$ROOT_DIR"/linux/tools/socket_method_parity.py \
    "$ROOT_DIR"/linux/tools/socket_smoke.py \
    "$ROOT_DIR"/linux/tools/validate_linux_contract.py \
    "$ROOT_DIR"/linux/tools/validate_package.py \
    "$ROOT_DIR"/linux/tools/write_package_manifest.py

  echo "==> Checking shell scripts..."
  bash -n "$ROOT_DIR/scripts/reload.sh"
  bash -n "$ROOT_DIR/scripts/reload-linux.sh"
  bash -n "$ROOT_DIR/linux/bin/cmux-linux"
  bash -n "$ROOT_DIR/linux/bin/cmux"
  bash -n "$ROOT_DIR/linux/package.sh"
  bash -n "$ROOT_DIR/linux/package-deb.sh"
  bash -n "$ROOT_DIR/linux/package-appimage.sh"
  bash -n "$ROOT_DIR/linux/package-rpm.sh"
  bash -n "$ROOT_DIR/linux/package-flatpak.sh"

  echo "==> Checking Linux contract validators..."
  PYTHONPYCACHEPREFIX="$pycache_prefix" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_linux_contract.py" >/tmp/cmux-linux-contract.json

  echo "==> Checking socket method parity..."
  PYTHONPYCACHEPREFIX="$pycache_prefix" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/socket_method_parity.py" --strict --json >/tmp/cmux-linux-parity.json
}

build_package() {
  if [[ "$PACKAGE" != "1" ]]; then
    return
  fi
  echo "==> Building Linux package..."
  bash "$ROOT_DIR/linux/package.sh"
}

has_graphical_session() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" || -n "${MIR_SOCKET:-}" ]]
}

stop_previous_launch() {
  local pid_file="$1"
  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  local pid owner
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    rm -f "$pid_file"
    return
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$pid_file"
    return
  fi

  owner="$(ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$owner" && "$owner" != "$(id -un)" ]]; then
    echo "warning: previous cmux Linux pid $pid is owned by $owner; leaving it running." >&2
    return
  fi

  echo "==> Stopping previous Linux cmux for this tag..."
  kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -KILL "$pid" >/dev/null 2>&1 || true
    for _ in {1..10}; do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi
  rm -f "$pid_file"
}

socket_ping_ready() {
  local socket_path="$1"
  CMUX_SOCKET_PATH="$socket_path" "$ROOT_DIR/linux/bin/cmux" ping >/dev/null 2>&1
}

print_launch_failure() {
  local message="$1"
  local log_path="$2"

  echo "error: $message" >&2
  if [[ -s "$log_path" ]]; then
    echo "Log:" >&2
    sed -n '1,160p' "$log_path" >&2 || true
  else
    echo "Log is empty: $log_path" >&2
  fi
}

launch_app() {
  local slug="$1"
  local socket_path="$2"
  local pid_file="/tmp/cmux-linux-${slug}.pid"
  local log_path="/tmp/cmux-linux-${slug}.log"
  local state_path="/tmp/cmux-linux-${slug}.state.json"

  if ! has_graphical_session; then
    echo "error: --launch requires DISPLAY, WAYLAND_DISPLAY, or MIR_SOCKET." >&2
    echo "Install GTK/VTE dependencies and run inside a graphical Linux session." >&2
    exit 1
  fi

  stop_previous_launch "$pid_file"
  rm -f "$socket_path"

  echo "==> Launching Linux cmux..."
  if command -v setsid >/dev/null 2>&1; then
    CMUX_LINUX_NON_UNIQUE=1 \
    CMUX_SOCKET_PATH="$socket_path" \
    CMUX_LINUX_STATE_PATH="$state_path" \
      PYTHONPATH="$ROOT_DIR/linux/lib${PYTHONPATH:+:$PYTHONPATH}" \
      setsid "$ROOT_DIR/linux/bin/cmux-linux" --socket "$socket_path" >"$log_path" 2>&1 < /dev/null &
  else
    CMUX_LINUX_NON_UNIQUE=1 \
    CMUX_SOCKET_PATH="$socket_path" \
    CMUX_LINUX_STATE_PATH="$state_path" \
      PYTHONPATH="$ROOT_DIR/linux/lib${PYTHONPATH:+:$PYTHONPATH}" \
      nohup "$ROOT_DIR/linux/bin/cmux-linux" --socket "$socket_path" >"$log_path" 2>&1 < /dev/null &
  fi
  local pid="$!"
  echo "$pid" > "$pid_file"
  echo "$socket_path" > /tmp/cmux-linux-last-socket-path

  local ready=0
  for _ in {1..50}; do
    if socket_ping_ready "$socket_path"; then
      ready=1
      break
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      print_launch_failure "cmux Linux exited during launch." "$log_path"
      rm -f "$pid_file" "$socket_path"
      exit 1
    fi
    sleep 0.1
  done

  if [[ "$ready" != "1" ]]; then
    print_launch_failure "cmux Linux did not accept socket commands at $socket_path." "$log_path"
    kill "$pid" >/dev/null 2>&1 || true
    rm -f "$pid_file" "$socket_path"
    exit 1
  fi

  echo "Linux cmux launched:"
  echo "  pid: $pid"
  echo "  socket: $socket_path"
  echo "  log: $log_path"
  echo "  state: $state_path"
  echo
  echo "Try:"
  echo "  CMUX_SOCKET_PATH=$socket_path linux/bin/cmux ping"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --socket)
      SOCKET_PATH="${2:-}"
      if [[ -z "$SOCKET_PATH" ]]; then
        echo "error: --socket requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-package)
      PACKAGE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required" >&2
  usage >&2
  exit 1
fi

SLUG="$(sanitize_path "$TAG")"
BUILD_DIR="/tmp/cmux-linux-${SLUG}"
PYCACHE_DIR="$BUILD_DIR/pycache"
SOCKET_PATH="${SOCKET_PATH:-/tmp/cmux-linux-${SLUG}.sock}"

mkdir -p "$PYCACHE_DIR"
select_python
run_static_checks "$PYCACHE_DIR"
build_package

echo
echo "Linux reload complete:"
echo "  tag: $SLUG"
echo "  package: $ROOT_DIR/dist/cmux-linux-x86_64.tar.gz"
echo "  parity: /tmp/cmux-linux-parity.json"
echo "  socket: $SOCKET_PATH"

if [[ "$LAUNCH" == "1" ]]; then
  launch_app "$SLUG" "$SOCKET_PATH"
fi
