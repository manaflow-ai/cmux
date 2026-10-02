#!/usr/bin/env bash
# Smoke test for the CLI bundled in a tagged cmux-next build
# (<app>/Contents/Resources/bin/cmux). Checks, in order:
#
#   1. `cmux --version` matches the app's CFBundleShortVersionString/CFBundleVersion.
#   2. `cmux --help` exits 0 and lists core commands (it trapped on a missing
#      SwiftPM resource bundle before bundle-cli-resources.sh existed).
#   3. CLI localization: for every .lproj in the app, `AppleLanguages=(<lang>)
#      cmux --help` prints that language's values of cli.help.topic.start and
#      cli.usage.targets.heading (the help body), read from the compiled
#      Localizable.strings of the same bundle; `cmux canvas` prints that
#      language's cli.removed.error prefix; `LC_MESSAGES=de_DE.UTF-8 cmux
#      canvas` (no AppleLanguages) prints the German one; and `LANG=de_DE.UTF-8`
#      alone leaves the output as it is without it (terminals set LANG).
#   4. `cmux action list --json` against the tagged app's socket returns
#      actions. When no app answers on /tmp/cmux-debug-<tag>.sock, the script
#      launches the tagged app in the background (clean environment,
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
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
cli_path="$app/Contents/Resources/bin/cmux"
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
    pkill -f "$app/Contents/Resources/bin/cmux-tui" 2>/dev/null || true
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

step="cmux --version"
version_out="$(cli "$cli_path" --version)"
[[ "$version_out" == "cmux $short_version ($build_version)"* ]] \
  || fail "cmux --version printed '$version_out', expected 'cmux $short_version ($build_version)...'"
echo "ok: $version_out"

step="cmux --help"
help_out="$(cli "$cli_path" --help)"
for command in ping capabilities identify list-workspaces new-workspace version; do
  grep -Eq "^[[:space:]]+${command}([[:space:]]|$)" <<<"$help_out" \
    || fail "cmux --help does not list '$command'"
done
echo "ok: --help"

step="CLI localization"
key="cli.help.topic.start"
# compiled_value <lproj> <key>: that key's value in the .lproj's CLI table.
compiled_value() {
  plutil -convert json -o - "$1/Localizable.strings" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null
}
# The text before the first placeholder of cli.removed.error.
removed_prefix() {
  compiled_value "$1" cli.removed.error | python3 -c 'import sys; print(sys.stdin.read().split("%")[0].strip())'
}
langs=()
for lproj in "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/"*.lproj; do
  [[ "$lproj" == */en.lproj && " ${langs[*]:-} " == *" en "* ]] && continue
  lang="$(basename "$lproj" .lproj)"
  strings_file="$lproj/Localizable.strings"
  [[ -f "$strings_file" ]] || fail "$lang.lproj has no Localizable.strings (CLI string table not bundled)"
  expected="$(plutil -convert json -o - "$strings_file" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$key" 2>/dev/null)" \
    || fail "$lang.lproj/Localizable.strings has no $key"
  if [[ "$lang" == en ]]; then
    english="$expected"
  elif [[ -n "${english:-}" && "$expected" == "$english" ]]; then
    fail "$lang.lproj has the English value for $key"
  fi
  out="$(cli env AppleLanguages="($lang)" "$cli_path" --help)"
  grep -Fq "  $expected:" <<<"$out" || fail "AppleLanguages=($lang) --help lacks '$expected'"
  heading="$(compiled_value "$lproj" cli.usage.targets.heading)" || fail "$lang.lproj has no cli.usage.targets.heading"
  grep -Fxq "$heading" <<<"$out" || fail "AppleLanguages=($lang) --help body lacks '$heading'"
  prefix="$(removed_prefix "$lproj")" || fail "$lang.lproj has no cli.removed.error"
  removed="$(cli env AppleLanguages="($lang)" "$cli_path" canvas 2>&1 || true)"
  grep -Fq "$prefix" <<<"$removed" || fail "AppleLanguages=($lang) cmux canvas printed '$removed', expected '$prefix'"
  langs+=("$lang")
done
(( ${#langs[@]} >= 21 )) || fail "only ${#langs[@]} localizations bundled (${langs[*]}), expected 21"
echo "ok: --help localized in ${#langs[@]} languages (${langs[*]})"

step="POSIX locale"
german="$(removed_prefix "$app/Contents/Resources/de.lproj")"
removed="$(cli env LC_MESSAGES=de_DE.UTF-8 "$cli_path" canvas 2>&1 || true)"
grep -Fq "$german" <<<"$removed" || fail "LC_MESSAGES=de_DE.UTF-8 cmux canvas printed '$removed', expected '$german'"
echo "ok: LC_MESSAGES=de_DE.UTF-8 cmux canvas: $removed"
baseline="$(cli "$cli_path" canvas 2>&1 || true)"
lang_only="$(cli env LANG=de_DE.UTF-8 "$cli_path" canvas 2>&1 || true)"
[[ "$lang_only" == "$baseline" ]] \
  || fail "LANG=de_DE.UTF-8 alone changed the language: '$lang_only' (without it: '$baseline')"
echo "ok: LANG=de_DE.UTF-8 alone keeps the macOS language: $lang_only"

step="cmux action list"
if ! cli "$cli_path" --socket "$socket" ping >/dev/null 2>&1; then
  step="launch tagged app"
  env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin \
    CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation \
    "$executable" >"$work/app.log" 2>&1 &
  app_pid=$!
  deadline=$((SECONDS + 60))
  until cli "$cli_path" --socket "$socket" ping >/dev/null 2>&1; do
    kill -0 "$app_pid" 2>/dev/null || fail "app exited before answering on $socket"
    (( SECONDS < deadline )) || fail "no answer on $socket within 60s"
    sleep 0.5
  done
  echo "ok: launched $bundle_id (pid $app_pid)"
fi
step="cmux action list"
actions_json="$(cli "$cli_path" --socket "$socket" action list --json)"
count="$(python3 -c 'import json,sys; a=json.load(sys.stdin)["actions"]; assert all(x.get("id") and x.get("cli_name") for x in a); print(len(a))' <<<"$actions_json")" \
  || fail "action list --json returned malformed output"
(( count > 0 )) || fail "action list returned no actions"
echo "ok: action list returned $count actions"

step="done"
echo "==> bundled CLI smoke OK for $bundle_id"
