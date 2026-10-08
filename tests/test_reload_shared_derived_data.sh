#!/usr/bin/env bash
# reload.sh gives every tag its own DerivedData unless the checkout's owner names a warm
# one through CMUX_DERIVED_DATA. A tag is not a compiler input, so tags that share a warm
# DerivedData do not recompile; a fresh per-tag directory is always a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real functions, not copies.
eval "$(awk '/^tagged_derived_data_path\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^resolve_tagged_derived_data\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F resolve_tagged_derived_data >/dev/null || fail "resolve_tagged_derived_data not found in reload.sh"

unset CMUX_DERIVED_DATA
[[ "$(resolve_tagged_derived_data one 0 "")" == "$HOME/Library/Developer/Xcode/DerivedData/cmux-one" ]] \
  || fail "without CMUX_DERIVED_DATA the default must stay one directory per tag"
[[ "$(resolve_tagged_derived_data one 0 "")" != "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "two tags must not share a DerivedData by default"

export CMUX_DERIVED_DATA="/tmp/cmux warm/DerivedData"
[[ "$(resolve_tagged_derived_data one 0 "")" == "/tmp/cmux warm/DerivedData" ]] || fail "CMUX_DERIVED_DATA ignored"
[[ "$(resolve_tagged_derived_data one 0 "")" == "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "tags must share the warm DerivedData when CMUX_DERIVED_DATA is set"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must win over CMUX_DERIVED_DATA"

export CMUX_DERIVED_DATA="relative/DerivedData"
if output="$(resolve_tagged_derived_data one 0 "" 2>&1)"; then
  fail "a relative CMUX_DERIVED_DATA must be rejected, got: $output"
fi
[[ "$output" == *"must be an absolute path"* ]] || fail "unclear error for a relative path: $output"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must not be blocked by an invalid CMUX_DERIVED_DATA"
unset CMUX_DERIVED_DATA

# The parser must record --derived-data and the tag default must go through the resolver with it.
awk '/^    --derived-data\)/,/;;/' "$ROOT/scripts/reload.sh" | grep -q 'DERIVED_SET=1' \
  || fail "the --derived-data parser no longer sets DERIVED_SET=1"
grep -Fq 'DERIVED_DATA="$(resolve_tagged_derived_data "$TAG_SLUG" "$DERIVED_SET" "${DERIVED_DATA:-}")"' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not resolve the tag's DerivedData through resolve_tagged_derived_data"

# cmux-debug-cli.sh must look for the tagged CLI where reload.sh built it.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sock="/tmp/cmux-debug-ddtest-$$.sock"
command -v python3 >/dev/null || fail "python3 is required for the test listener"
mkfifo "$tmp/ready"
# The listener accepts until the EXIT trap kills it, and reports readiness through the FIFO.
python3 - "$sock" "$tmp/ready" <<'PY' &
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
finally:
    open(sys.argv[2], "w").close()
while True:
    connection, _ = s.accept()
    connection.close()
PY
server=$!
disown "$server" 2>/dev/null || true
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock"; rm -rf "$tmp"' EXIT
read -r _ < "$tmp/ready" || true
[[ -S "$sock" ]] || fail "test socket was not created"
cli_dir="$tmp/dd/Build/Products/Debug/cmux DEV ddtest-$$.app/Contents/Resources/bin"
mkdir -p "$cli_dir"
printf '#!/bin/sh\necho shared-cli "$@"\n' > "$cli_dir/cmux"; chmod +x "$cli_dir/cmux"
out="$(CMUX_TAG="ddtest-$$" CMUX_DERIVED_DATA="$tmp/dd" "$ROOT/scripts/cmux-debug-cli.sh" ping 2>&1)" \
  || fail "cmux-debug-cli.sh did not find the CLI in CMUX_DERIVED_DATA: $out"
[[ "$out" == *"shared-cli"* ]] || fail "cmux-debug-cli.sh ran something else: $out"

# A relative --derived-data would build relative to the caller's cwd. --help keeps a
# reload.sh that accepts the path from going on to build.
if out="$(cd "$tmp" && "$ROOT/scripts/reload.sh" --derived-data relative/dd --help 2>&1)"; then
  fail "a relative --derived-data must be rejected"
fi
[[ "$out" == *"--derived-data must be an absolute path"* ]] || fail "unclear error for a relative --derived-data: $out"

# The cmux shim must run the CLI from the DerivedData the tag was built into, even when
# a stale build of the same tag sits in the default per-tag directory.
tag="ddtest-$$"
link="/tmp/cmux-$tag"
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock" "$link" "/tmp/cmux-ddstale-$$"; rm -rf "$tmp"' EXIT
eval "$(awk '/^reload_socket_is_live\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
# The shim body is a heredoc with its own top-level braces, so the function ends at the first "}" after it.
eval "$(awk '/^write_dev_cli_shim\(\) \{/ { on = 1 } on { print } on && /<<EOF$/ { doc = 1 } on && /^EOF$/ { doc = 0 } on && !doc && /^}/ { exit }' "$ROOT/scripts/reload.sh")"
declare -F write_dev_cli_shim >/dev/null || fail "write_dev_cli_shim not found in reload.sh"
fake_home="$tmp/home"
stale_app="$fake_home/Library/Developer/Xcode/DerivedData/cmux-$tag/Build/Products/Debug/cmux DEV $tag.app"
shared_app="$tmp/dd/Build/Products/Debug/cmux DEV $tag.app"
mkdir -p "$stale_app/Contents/Resources/bin"
printf '#!/bin/sh\necho stale-cli "$@"\n' > "$stale_app/Contents/Resources/bin/cmux"
chmod +x "$stale_app/Contents/Resources/bin/cmux"
for app in "$stale_app" "$shared_app"; do
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>LSEnvironment</key><dict><key>CMUX_SOCKET_PATH</key><string>$sock</string></dict></dict></plist>
PLIST
done
ln -s "$tmp/dd" "$link"
write_dev_cli_shim "$tmp/bin/cmux" "$tmp/no-fallback" "$tmp/no-pointer"
out="$(env -u CMUX_SOCKET -u CMUX_SOCKET_PATH -u CMUX_BUNDLED_CLI_PATH HOME="$fake_home" \
  "$tmp/bin/cmux" --socket "$sock" ping 2>&1)" || fail "the shim found no CLI for a shared DerivedData: $out"
[[ "$out" == "shared-cli --socket $sock ping" ]] || fail "the shim did not run the CLI built into the shared DerivedData: $out"

# The cleanup reminder must name what holds the tag's build, and never a directory other tags share.
eval "$(awk '/^tag_build_cleanup_paths\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^print_tag_cleanup_commands\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$ROOT/scripts/lib/mobile-attach.sh"
eval "$(awk '/^sanitize_bundle\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
SCRIPT_DIR="$ROOT/scripts"
eval "$(awk '/^print_tag_cleanup_reminder\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
sandbox="$tmp/sandbox"
mkdir -p "$sandbox"
# Reads this test's commands out of a reminder the way a shell would after a paste, with
# bash (the app quit line) and rm recording their arguments, one per line, instead of
# running.
reminder_args() {
  local output="$1" record="$2" line=""
  : > "$record"
  (
    cd "$sandbox"
    bash() { printf '%s\n' "$@" >> "$record"; }
    rm() { printf '%s\n' "$@" >> "$record"; }
    while IFS= read -r line; do
      [[ "$line" == *"-$$"* ]] || continue
      case "$line" in
        "  bash "*|"  rm "*) eval "$line" || true ;;
      esac
    done <<< "$output"
  ) >/dev/null 2>&1 || true
}
has_arg() { grep -Fxq -- "$1" "$2"; }
args="$tmp/args"
ln -s "$tmp/dd" "/tmp/cmux-ddstale-$$"
out="$(HOME="$fake_home" print_tag_cleanup_reminder "$tag" "$tmp/dd")"
reminder_args "$out" "$args"
has_arg "$shared_app" "$args" || fail "the reminder does not remove the current tag's app from the shared DerivedData: $out"
has_arg "$tmp/dd/Build/Products/Debug/cmux DEV ddstale-$$.app" "$args" \
  || fail "the reminder does not remove a stale tag's app from the shared DerivedData: $out"
! has_arg "$tmp/dd" "$args" || fail "the reminder suggests deleting a shared DerivedData: $out"
out="$(HOME="$fake_home" print_tag_cleanup_reminder "$tag" "$fake_home/Library/Developer/Xcode/DerivedData/cmux-$tag")"
reminder_args "$out" "$args"
has_arg "$fake_home/Library/Developer/Xcode/DerivedData/cmux-$tag" "$args" \
  || fail "the reminder must still remove a per-tag DerivedData: $out"
# Deleting a tag's bundle leaves its detached cmux-tui owner running from the deleted
# executable. The reminder stops the OWNER through the bundle's own binary before any rm.
# It never ends terminals: a pasted command cannot check that no terminal runs a job, and
# terminals end only through their owner (never a signal); their hosts keep running.
own_app="$fake_home/Library/Developer/Xcode/DerivedData/cmux-$tag/Build/Products/Debug/cmux DEV $tag.app"
stop_line="$(printf '%s\n' "$out" | grep -F -- "--session cmux-app-$tag server stop" || true)"
[[ -n "$stop_line" ]] || fail "the reminder does not stop the tag's cmux-tui owner: $out"
[[ "$stop_line" == *"$(printf '%q' "$own_app/Contents/Resources/bin/cmux-tui")"* ]] \
  || fail "the stop does not run the tag bundle's own cmux-tui: $stop_line"
[[ "$out" != *"--end-terminals"* ]] || fail "the reminder must never force the tag's terminals: $out"
first_rm="$(printf '%s\n' "$out" | grep -n '^  rm ' | head -1 | cut -d: -f1)"
stop_at="$(printf '%s\n' "$out" | grep -nF -- "server stop" | head -1 | cut -d: -f1)"
(( stop_at < first_rm )) || fail "the owner must be stopped before the bundle is removed: $out"

# The reminder is pasted into a shell, so a path carrying shell syntax must come back out
# as that literal path and must never run.
evil_dd="$tmp/dd \"warm\" \$(touch pwned-subst) \`touch pwned-tick\`"
evil_home="$tmp/home \"two\" \$(touch pwned-home)"
evil_tag_dir="/tmp/cmux-ddbad-$$-\$(touch pwned-tag)"
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock" "$link" "/tmp/cmux-ddstale-$$" "/tmp/cmux-ddevil-$$"; rm -rf "$tmp" "$evil_tag_dir"' EXIT
mkdir -p "$evil_dd/Build/Products/Debug" "$evil_tag_dir/Build/Products/Debug"
ln -s "$evil_dd" "/tmp/cmux-ddevil-$$"
out="$(HOME="$evil_home" print_tag_cleanup_reminder "$tag" "$evil_dd")"
reminder_args "$out" "$args"
pwned="$(cd "$sandbox" && ls)"
[[ -z "$pwned" ]] || fail "pasting the reminder ran shell syntax from a path ($pwned): $out"
has_arg "$evil_dd/Build/Products/Debug/cmux DEV $tag.app" "$args" \
  || fail "the current tag's app in a DerivedData with shell syntax does not parse back to its path: $out"
has_arg "$evil_dd/Build/Products/Debug/cmux DEV ddevil-$$.app" "$args" \
  || fail "a stale tag's app behind a symlink target with shell syntax does not parse back to its path: $out"
has_arg "$evil_home/Library/Application Support/cmux/cmuxd-dev-$tag.sock" "$args" \
  || fail "a HOME with shell syntax does not parse back to its path: $out"
has_arg "cmux DEV $tag.app/Contents/MacOS/cmux DEV" "$args" || fail "the app quit line does not parse back to the app's executable: $out"
has_arg "com.cmuxterm.app.debug.$(sanitize_bundle "$tag")" "$args" || fail "the app quit line does not name the tag's bundle id: $out"
# Never a pattern kill (rule c, cx-6so.49): the reminder quits the app through
# cmux_stop_app_instances, which signals exact PIDs only.
! printf '%s\n' "$out" | grep -Eq '(^|[[:space:];&|(])(pkill|killall)[[:space:]]' \
  || fail "the reminder must never pkill or killall: $out"
quit_line="$(printf '%s\n' "$out" | grep -F 'cmux_stop_app_instances' | head -1)"
[[ -n "$quit_line" ]] || fail "the reminder does not quit the app through cmux_stop_app_instances: $out"
spy="$tmp/spy"; mkdir -p "$spy"
for tool in pkill killall; do
  printf '#!/bin/sh\necho %s "$@" >> %q\n' "$tool" "$tmp/signals" > "$spy/$tool"; chmod +x "$spy/$tool"
done
(cd "$sandbox" && PATH="$spy:$PATH" eval "$quit_line") >/dev/null 2>&1 || true
[[ ! -s "$tmp/signals" ]] || fail "the app quit line ran pkill or killall: $(cat "$tmp/signals")"
[[ "$out" != *"pwned-tag"* ]] || fail "the reminder offers cleanup for a /tmp name that is not a tag slug: $out"

echo "PASS: reload.sh shared DerivedData default"
