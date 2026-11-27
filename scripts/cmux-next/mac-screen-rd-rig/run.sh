#!/bin/zsh
# The Mac Screen rig's app on one Mac (see live.py): the tagged app, signed in as the agent
# test account, started from this Mac's own cmux so it inherits cmux's Screen Recording and
# Accessibility grants. ROLE host also starts InputProbe, which logs the clicks it receives.
#   run.sh TAG host|viewer [WINDOW_FRAME] [--open]
set -u
dir=~/rd-hub-rig
tag=$1 role=$2 frame=${3:-0,0,1500,950}
app="$dir/$tag/cmux DEV $tag.app"
mkdir -p "$dir/state-$tag"
[[ -f "$dir/state-$tag/cmux.json" ]] || echo "{}" > "$dir/state-$tag/cmux.json"
if [[ $role == host ]]; then
  "$dir/InputProbe" "$dir/probe-$tag.jsonl" > "$dir/probe-$tag.log" 2>&1 &
fi
if [[ ${4:-} == --open ]]; then
  # From SSH on a Mac without cmux: LaunchServices starts the app in the GUI session (not
  # frontmost); it is its own responsible process, which a viewer needs no grants for.
  exec open -g -n --stdout "$dir/app-$tag.log" --stderr "$dir/app-$tag.log" \
    --env CMUX_NEXT_NO_ACTIVATE=1 --env CMUX_NEXT_SOCKET_MODE=automation --env CMUX_NEXT_TEST_WINDOW_SCREEN=last \
    --env CMUX_AUTH_CREDENTIALS_FILE="$dir/private/creds.env" \
    --env CMUX_NEXT_CONFIG_FILE="$dir/state-$tag/cmux.json" --env CMUX_NEXT_TEST_WINDOW_FRAME="$frame" "$app"
fi
exec env CMUX_NEXT_NO_ACTIVATE=1 CMUX_NEXT_SOCKET_MODE=automation CMUX_NEXT_TEST_WINDOW_SCREEN=last \
  CMUX_AUTH_CREDENTIALS_FILE="$dir/private/creds.env" \
  CMUX_NEXT_CONFIG_FILE="$dir/state-$tag/cmux.json" CMUX_NEXT_TEST_WINDOW_FRAME="$frame" \
  "$app/Contents/MacOS/cmux DEV" > "$dir/app-$tag.log" 2>&1
