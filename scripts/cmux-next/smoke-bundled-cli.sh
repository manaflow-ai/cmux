#!/usr/bin/env bash
# Smoke test for the CLI bundled in a tagged cmux-next build. The CLI is the
# cmux-tui binary at <app>/Contents/Resources/bin/cmux, with bin/cmux-tui and
# bin/acpmux as relative symlinks to it (plans/cmux-next/cli.md). Checks, in
# order:
#
#   1. bin/cmux is a regular file; bin/cmux-tui and bin/acpmux are symlinks
#      to `cmux`, and `acpmux --version` runs acpmux through argv[0].
#   2. `cmux --version` prints `cmux <version>`, and `cmux --help` and
#      `cmux acp --help` exit 0 with output.
#   3. `cmux --app-socket <tagged socket> action list --json` returns actions.
#      When no app answers on /tmp/cmux-debug-<tag>.sock, the script launches
#      the tagged app in the background (clean environment,
#      CMUX_NEXT_NO_ACTIVATE=1, CMUX_NEXT_SOCKET_MODE=automation) and quits it,
#      and the cmux-tui daemon it spawned, at exit.
#
# Usage: scripts/cmux-next/smoke-bundled-cli.sh --tag <tag> [--app <path>]
#   --app  the tagged .app (default: the Debug product in
#          ~/Library/Developer/Xcode/DerivedData/cmux-<tag>).
# Never targets the default socket or the user's running cmux.
set -euo pipefail

tag=""
app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:?--tag needs a value}"; shift 2 ;;
    --app) app="${2:?--app needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$tag" ]] || { echo "error: --tag is required" >&2; exit 2; }
slug="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[[ -n "$slug" ]] || { echo "error: tag '$tag' has no usable characters" >&2; exit 2; }

if [[ -z "$app" ]]; then
  products="$HOME/Library/Developer/Xcode/DerivedData/cmux-$slug/Build/Products/Debug"
  for candidate in "$products/cmux DEV $slug.app" "$products"/*.app; do
    [[ -d "$candidate/Contents" ]] && { app="$candidate"; break; }
  done
fi
[[ -d "$app/Contents" ]] || { echo "error: no tagged app for '$slug' (pass --app)" >&2; exit 1; }

plist="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
case "$bundle_id" in
  com.cmuxterm.app|com.cmuxterm.app.nightly|com.cmuxterm.app.rc|com.cmuxterm.app.staging)
    echo "error: $bundle_id is a release identity; this smoke only drives tagged builds" >&2
    exit 1 ;;
esac
executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
bin_dir="$app/Contents/Resources/bin"
cli_path="$bin_dir/cmux"
socket="/tmp/cmux-debug-$slug.sock"
[[ -x "$cli_path" ]] || { echo "error: bundled CLI missing at $cli_path" >&2; exit 1; }
[[ -x "${cli_path%/*}/cmux-code-mode-runner" ]] || { echo "error: bundled code-mode runner missing" >&2; exit 1; }
[[ -x "${cli_path%/*}/cmux-code-mode-macos-profile" ]] || { echo "error: bundled macOS code-mode profile helper missing" >&2; exit 1; }

work="$(mktemp -d /tmp/cmux-next-cli-smoke.XXXXXX)"
app_pid=""
step="setup"
cleanup() {
  local status=$?
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 25); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$app_pid" 2>/dev/null || true
    # The app leaves its cmux-tui daemon running by design; this run started it.
    # Stop it by its socket, never by pattern (a pattern also kills the hosts).
    # shellcheck source=SCRIPTDIR/../lib/stop-cmux-tui-owners.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/stop-cmux-tui-owners.sh"
    cmux_stop_cmux_tui_owners "$bin_dir"
  fi
  if [[ $status -ne 0 ]]; then
    echo "FAIL during step: $step" >&2
    [[ -s "$work/app.log" ]] && { echo "--- app log (last 40 lines) ---" >&2; tail -n 40 "$work/app.log" >&2; }
  fi
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Clean environment: no caller CMUX_* context, no inherited language override.
cli() {
  env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin "$@"
}

step="symlinks"
[[ -f "$cli_path" && ! -L "$cli_path" ]] || fail "$cli_path must be the cmux-tui binary itself, not a symlink"
for alias in cmux-tui acpmux; do
  target="$(readlink "$bin_dir/$alias" || true)"
  [[ "$target" == cmux ]] || fail "bin/$alias points at '$target', expected cmux"
done
acpmux_version="$(cli "$bin_dir/acpmux" --version)"
[[ "$acpmux_version" == "acpmux "* ]] || fail "bin/acpmux --version printed '$acpmux_version'"
echo "ok: bin/cmux-tui and bin/acpmux link to bin/cmux ($acpmux_version)"

step="cmux --version"
version_out="$(cli "$cli_path" --version)"
[[ "$version_out" == "cmux "* ]] || fail "cmux --version printed '$version_out', expected 'cmux <version>'"
echo "ok: $version_out"

step="cmux --help"
[[ -n "$(cli "$cli_path" --help)" ]] || fail "cmux --help printed nothing"
echo "ok: cmux --help"

step="cmux acp --help"
[[ -n "$(cli "$cli_path" acp --help)" ]] || fail "cmux acp --help printed nothing"
echo "ok: cmux acp --help"

step="cmux app ping"
if ! cli "$cli_path" --app-socket "$socket" app ping >/dev/null 2>&1; then
  step="launch tagged app"
  env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin \
    CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation \
    "$executable" >"$work/app.log" 2>&1 &
  app_pid=$!
  deadline=$((SECONDS + 60))
  until cli "$cli_path" --app-socket "$socket" app ping >/dev/null 2>&1; do
    kill -0 "$app_pid" 2>/dev/null || fail "app exited before answering on $socket"
    (( SECONDS < deadline )) || fail "no answer on $socket within 60s"
    sleep 0.5
  done
  echo "ok: launched $bundle_id (pid $app_pid)"
fi

step="cmux action list"
actions_json="$(cli "$cli_path" --app-socket "$socket" --json action list)"
count="$(python3 -c '
import json, sys
value = json.load(sys.stdin)
actions = value.get("actions", value) if isinstance(value, dict) else value
assert isinstance(actions, list) and all(isinstance(a, dict) and a.get("id") for a in actions)
print(len(actions))
' <<<"$actions_json")" || fail "action list --json returned malformed output: $actions_json"
(( count > 0 )) || fail "action list returned no actions"
echo "ok: action list returned $count actions"

step="done"
echo "==> bundled CLI smoke OK for $bundle_id"
