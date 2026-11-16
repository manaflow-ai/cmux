#!/usr/bin/env bash
# launch-ready.sh's quiesce counts only the processes running from the app copy's Contents/MacOS and
# Contents/Frameworks. With the paths given to `ps` instead of `awk`, awk read empty strings, macOS awk's
# index($0, "") matched every line, and every launch waited the full 60 s (LR-SETTLE left=877-898).
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launch-ready.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
app="$root/side a/cmux NEXT.app"

# A stand-in process table: two lines from the copy, three that are not (another copy, the daemon this
# check leaves alone, and an unrelated process).
ps() {
  printf '%s\n' \
    "$app/Contents/MacOS/cmux NEXT -ApplePersistenceIgnoreState YES" \
    "$app/Contents/Frameworks/cmux NEXT Helper (Renderer).app/Contents/MacOS/cmux NEXT Helper (Renderer)" \
    "$root/side b/cmux NEXT.app/Contents/MacOS/cmux NEXT" \
    "$app/Contents/Resources/bin/cmux-tui daemon" \
    "/usr/sbin/cfprefsd agent"
}

# shellcheck source=../launch-ready.sh
source "$script"
left="$(quiesce_left "$app")"
[[ "$left" == 2 ]] || { echo "launch-ready quiesce: counted $left processes of the copy, want 2" >&2; exit 1; }

ps() { echo "/usr/sbin/cfprefsd agent"; }
left="$(quiesce_left "$app")"
[[ "$left" == 0 ]] || { echo "launch-ready quiesce: counted $left with none of the copy running, want 0" >&2; exit 1; }
echo 'launch-ready quiesce: counts only the copy'"'"'s processes'
