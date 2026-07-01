#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${CMUX_SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${CMUX_DERIVED_DATA_PATH:-$PWD/.ci-bundled-ghostty-helper}"
CONFIGURATION="${CMUX_CONFIGURATION:-Debug}"
APP_PATH="${CMUX_APP_PATH:-}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-theme-picker-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "${CMUX_SKIP_ZIG_BUILD:-0}" = "1" ]; then
  echo "SKIP: bundled Ghostty helper regression requires the real Zig-built helper"
  exit 0
fi

if [ -n "$APP_PATH" ]; then
  if [ ! -d "$APP_PATH" ]; then
    echo "FAIL: supplied app path does not exist at $APP_PATH" >&2
    exit 1
  fi
else
  case "$CONFIGURATION" in
    Debug)
      APP_NAME="cmux DEV.app"
      ;;
    Release)
      APP_NAME="cmux.app"
      ;;
    *)
      echo "FAIL: unsupported configuration $CONFIGURATION" >&2
      exit 1
      ;;
  esac

  mkdir -p "$SOURCE_PACKAGES_DIR"
  rm -rf "$DERIVED_DATA_PATH"

  xcodebuild \
    -project cmux.xcodeproj \
    -scheme cmux \
    -configuration "$CONFIGURATION" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -disableAutomaticPackageResolution \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    build

  APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
fi
HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
GHOSTTY_RESOURCES_DIR="$APP_PATH/Contents/Resources/ghostty"

if [ ! -x "$HELPER_PATH" ]; then
  echo "FAIL: bundled Ghostty theme picker helper missing at $HELPER_PATH" >&2
  exit 1
fi

if [ ! -d "$GHOSTTY_RESOURCES_DIR/themes" ]; then
  echo "FAIL: bundled Ghostty themes missing at $GHOSTTY_RESOURCES_DIR/themes" >&2
  exit 1
fi

CONFIG_PATH="$TMP_DIR/config.ghostty"
SEARCH_CONFIG_PATH="$TMP_DIR/search-config.ghostty"
CTRL_N_CONFIG_PATH="$TMP_DIR/ctrl-n-config.ghostty"
CTRL_P_CONFIG_PATH="$TMP_DIR/ctrl-p-config.ghostty"
ISOLATED_CONFIG_HOME="$TMP_DIR/xdg-config"
RESULTS_PATH="$TMP_DIR/config-paths.txt"
mkdir -p "$ISOLATED_CONFIG_HOME"
export CONFIG_PATH
export SEARCH_CONFIG_PATH
export CTRL_N_CONFIG_PATH
export CTRL_P_CONFIG_PATH
export ISOLATED_CONFIG_HOME
export RESULTS_PATH
export GHOSTTY_RESOURCES_DIR
export HELPER_PATH

python3 <<'PY'
import fcntl
import os
import pty
import select
import signal
import subprocess
import sys
import struct
import termios
import time

helper_path = os.environ["HELPER_PATH"]
config_path = os.environ["CONFIG_PATH"]
search_config_path = os.environ["SEARCH_CONFIG_PATH"]
ctrl_n_config_path = os.environ["CTRL_N_CONFIG_PATH"]
ctrl_p_config_path = os.environ["CTRL_P_CONFIG_PATH"]
isolated_config_home = os.environ["ISOLATED_CONFIG_HOME"]
results_path = os.environ["RESULTS_PATH"]
ghostty_resources_dir = os.environ["GHOSTTY_RESOURCES_DIR"]


def helper_environment(scenario_config_path):
    env = os.environ.copy()
    env.update(
        {
            "CMUX_THEME_PICKER_CONFIG": scenario_config_path,
            "CMUX_THEME_PICKER_BUNDLE_ID": "com.cmuxterm.test",
            "CMUX_THEME_PICKER_TARGET": "both",
            "CMUX_THEME_PICKER_COLOR_SCHEME": "dark",
            "GHOSTTY_RESOURCES_DIR": ghostty_resources_dir,
            "TERM": "xterm-256color",
            "XDG_CONFIG_HOME": isolated_config_home,
        }
    )
    return env


try:
    plain_result = subprocess.run(
        [helper_path, "+list-themes", "--plain"],
        check=True,
        env=helper_environment(config_path),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
except subprocess.TimeoutExpired:
    sys.stderr.write("FAIL: timed out while listing bundled themes in plain mode\n")
    sys.exit(1)
theme_names = [
    line.rsplit(" (", 1)[0]
    for line in plain_result.stdout.splitlines()
    if line.strip()
]
if len(theme_names) < 2:
    sys.stderr.write("FAIL: expected at least two themes from bundled helper\n")
    sys.stderr.write(plain_result.stderr)
    sys.exit(1)


def assert_theme_written(label, scenario_config_path, expected_theme):
    try:
        with open(scenario_config_path, "r", encoding="utf-8") as config:
            contents = config.read()
    except FileNotFoundError:
        sys.stderr.write(f"FAIL: theme picker did not write config for {label}.\n")
        sys.exit(1)

    expected_line = f"theme = light:{expected_theme},dark:{expected_theme}"
    if expected_line not in contents:
        sys.stderr.write(
            f"FAIL: expected {label} to write {expected_line!r}.\n"
        )
        sys.stderr.write(contents)
        sys.exit(1)


def run_picker(label, scenario_config_path, scripted_input, expected_theme=None):
    env = helper_environment(scenario_config_path)

    pid, master_fd = pty.fork()
    if pid == 0:
        os.execve(helper_path, [helper_path, "+list-themes"], env)

    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))

    output = bytearray()
    sent_input = False
    deadline = time.monotonic() + 10
    status = None
    master_closed = False

    try:
        while time.monotonic() < deadline:
            child_pid, child_status = os.waitpid(pid, os.WNOHANG)
            if child_pid == pid:
                status = child_status
                break

            readable, _, _ = select.select([master_fd], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    master_closed = True
                    break
                if not chunk:
                    master_closed = True
                    break
                output.extend(chunk)

            if not sent_input and b"Enter apply" in output:
                os.write(master_fd, scripted_input)
                sent_input = True

        if status is None and master_closed:
            _, status = os.waitpid(pid, 0)

        if status is None:
            try:
                os.write(master_fd, b"q")
            except OSError:
                pass
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            kill_deadline = time.monotonic() + 2
            while time.monotonic() < kill_deadline:
                child_pid, child_status = os.waitpid(pid, os.WNOHANG)
                if child_pid == pid:
                    status = child_status
                    break
                time.sleep(0.05)
            if status is None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                _, status = os.waitpid(pid, 0)
            sys.stderr.write(
                f"FAIL: theme picker did not exit after Enter in {label}.\n"
            )
            sys.stderr.write(output[-2000:].decode("utf-8", errors="replace"))
            sys.exit(1)

        exit_code = os.waitstatus_to_exitcode(status)
        if exit_code != 0:
            sys.stderr.write(f"FAIL: theme picker exited with status {exit_code} in {label}.\n")
            sys.stderr.write(output[-2000:].decode("utf-8", errors="replace"))
            sys.exit(1)
    finally:
        os.close(master_fd)

    if expected_theme is not None:
        assert_theme_written(label, scenario_config_path, expected_theme)

# The test's XDG_CONFIG_HOME starts empty and each scenario writes to a fresh
# CMUX_THEME_PICKER_CONFIG path, so the picker opens on the first listed theme.
first_theme = theme_names[0]
second_theme = theme_names[1]

run_picker("normal mode", config_path, b"\r")
run_picker("search mode", search_config_path, b"/tokyo\r")
run_picker("Ctrl-N navigation", ctrl_n_config_path, b"\x0e\r", second_theme)
run_picker("Ctrl-P navigation", ctrl_p_config_path, b"\x0e\x10\r", first_theme)

with open(results_path, "w", encoding="utf-8") as results:
    results.write(config_path + "\n")
    results.write(search_config_path + "\n")
    results.write(ctrl_n_config_path + "\n")
    results.write(ctrl_p_config_path + "\n")
PY

while IFS= read -r CONFIG_PATH; do
  if [ ! -f "$CONFIG_PATH" ]; then
    echo "FAIL: Enter did not write the cmux theme override file at $CONFIG_PATH" >&2
    exit 1
  fi

  if ! grep -qx '# cmux themes start' "$CONFIG_PATH"; then
    echo "FAIL: cmux theme override start marker missing" >&2
    cat "$CONFIG_PATH" >&2
    exit 1
  fi

  if ! grep -Eq '^theme = light:.+,dark:.+$' "$CONFIG_PATH"; then
    echo "FAIL: cmux theme override did not set both light and dark themes" >&2
    cat "$CONFIG_PATH" >&2
    exit 1
  fi

  if ! grep -qx '# cmux themes end' "$CONFIG_PATH"; then
    echo "FAIL: cmux theme override end marker missing" >&2
    cat "$CONFIG_PATH" >&2
    exit 1
  fi
done < "$RESULTS_PATH"

echo "PASS: bundled Ghostty theme picker helper applies highlighted cmux theme on Enter"
