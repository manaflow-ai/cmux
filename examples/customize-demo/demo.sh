#!/usr/bin/env bash
# The customization demo: turns each setup on in order, live, then puts your own setup back.
#
#   examples/customize-demo/demo.sh            # step through every setup, Enter for the next
#   examples/customize-demo/demo.sh --auto 12  # 12 s per setup, no keys (for a recording)
#   examples/customize-demo/demo.sh --nightly --auto 8  # installed NIGHTLY, all looks, then revert
#   examples/customize-demo/demo.sh --list     # the order, nothing changes
#   examples/customize-demo/demo.sh --only glass/liquid.json
#   examples/customize-demo/demo.sh reset      # put your setup back (cmux customize discard)
#
# Nothing is kept: every step is a `cmux customize use` preview, and the end (or Ctrl-C) runs
# `cmux customize discard`. CMUX names the CLI (default `cmux`); for a NIGHTLY copy point it at that
# copy's `Contents/Resources/bin/cmux` and set CMUX_BUNDLE_ID to the copy's bundle id.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cli="${CMUX:-cmux}"

# The order of the demo: the app looks first (Claude Code, Codex, studio), then the last demo's
# setups redone, glass, widgets; then every installable look in the gallery (gallery/, bundled
# from examples/looks and examples/gallery), the tabs and sidebar ones first; then the
# whole-window showcase and the Leo collection (showcase/). `steps` drops repeats, so a glob after
# a named file adds only the rest.
order=(
  looks/claude.json
  looks/codex.json
  looks/studio.json
  looks/*.json
  last-demo/*.json
  glass/*.json
  widgets/*.json
  gallery/material.json
  gallery/shadcn.json
  gallery/apple.json
  gallery/codex-sidebar.json
  gallery/codex-threads.json
  gallery/claude-code-sidebar.json
  gallery/claude-code-session-recents.json
  gallery/claude-code-project-picker.json
  gallery/claude-code-transcript.json
  gallery/claude-code-composer.json
  gallery/claude-code-session-worktree.json
  gallery/claude-code-whole.json
  gallery/rex-whole.json
  gallery/hairline.json
  gallery/*.json
  showcase/*.json
)

steps() {
  local pattern file
  for pattern in "${order[@]}"; do
    for file in "$here"/$pattern; do
      [[ -f "$file" ]] && printf '%s\n' "${file#"$here"/}"
    done
  done | awk '!seen[$0]++'
}

describe() {
  # The step's line: the look's name (a gallery look's own, else the profile's, else the file's),
  # where it comes from, and what a preview leaves to `cmux setup install` (a setup's actions and
  # extensions, which no profile carries).
  python3 -c '
import json, sys
n, total, relative, path = sys.argv[1:]
profile = json.load(open(path))
setup = profile.get("x-setup") or {}
name = setup.get("name") or profile.get("name") or relative
print("\n[%s/%s] %s  (%s)" % (n, total, name, relative))
if setup.get("source"):
    print("      from examples/" + setup["source"])
left = [key + " " + ", ".join(setup[key]) for key in ("actions", "extensions") if setup.get(key)]
if left:
    print("      its " + " and ".join(left) + " come with cmux setup install; this preview shows the rest")
' "$@"
}

reset() {
  "$cli" customize discard && "$cli" action run newTab.page --focus && "$cli" customize library status
}

finish() {
  local status=$?
  trap - EXIT
  if reset; then
    printf '\nYour setup is back.\n'
  else
    printf '\ndemo.sh: reset failed; run %q customize discard to restore your setup.\n' "$cli" >&2
    [[ $status -ne 0 ]] || status=1
  fi
  exit "$status"
}

auto=""
only=""
nightly=false
mode=demo
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nightly) nightly=true; shift ;;
    reset) mode=reset; shift ;;
    --list) mode=list; shift ;;
    --auto) auto="${2:?--auto takes seconds}"; shift 2 ;;
    --only) only="${2:?--only takes a file under examples/customize-demo}"; shift 2 ;;
    *) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 2 ;;
  esac
done
[[ "$mode" != list ]] || { steps; exit 0; }
if [[ -n "$auto" && ! "$auto" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo 'demo.sh: --auto takes a nonnegative number of seconds' >&2
  exit 2
fi
if $nightly; then
  cli='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
  # Match app_identity.rs's app routing isolation, including customize's test roots.
  # Do not let a terminal in DEV redirect the installed NIGHTLY command.
  unset CMUX_SOCKET_PATH CMUX_TAG CMUX_TUI_SOCKET CMUX_MUX_SOCKET \
    CMUX_APP_DAEMON_SOCKET CMUX_CHIEF_OWNER_SOCKET CMUX_CHIEF_HOME \
    CMUX_NEXT_CHIEF_HOME CMUX_NEXT_CHIEF_ROOT CMUX_NEXT_CHIEF_BUILD_ID \
    CMUX_NEXT_CHIEF_ACCOUNT CMUX_NEXT_MUX_HOME CMUX_NEXT_ACPMUX_ROOT \
    CMUX_NEXT_SOCKET_PATH CMUX_NEXT_CONFIG_FILE ACPMUX_HOME ACPMUX_SOCKET \
    CMUX_CUSTOMIZE_DIR CMUX_CUSTOMIZE_STATE_DIR CMUX_CUSTOMIZE_APP
  export CMUX_BUNDLE_ID=com.cmuxterm.app.nightly
fi
[[ "$mode" != reset ]] || { reset; echo "Your setup is back."; exit 0; }

# A while-read loop, not mapfile: macOS's /bin/bash is 3.2.
list=()
if [[ -n "$only" ]]; then
  steps | grep -Fx -- "$only" >/dev/null || { echo "demo.sh: unknown profile: $only" >&2; exit 2; }
  list=("$only")
else
  while IFS= read -r file; do
    list+=("$file")
  done < <(steps)
fi
[[ ${#list[@]} -gt 0 ]] || { echo "demo.sh: no setups found under $here" >&2; exit 1; }

# Before installing the cleanup trap: an existing draft belongs to the user.
# Hand edits must be settled too: a failed first import may never snapshot them.
"$cli" customize status --json | python3 -c '
import json, sys
status = json.load(sys.stdin)
if any(key not in status for key in ("draft", "try_on", "changes")):
    sys.exit("demo.sh: unrecognized customization status; nothing changed")
if status["draft"] is not None or status["try_on"] is not None or status["changes"]:
    sys.exit("demo.sh: existing customization changes or a try-on are active; keep or discard them before starting the demo")
'
"$cli" customize library status
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

n=0
for file in "${list[@]}"; do
  n=$((n + 1))
  # Profile settings compose with live settings. Reset so looks cannot leak into each other.
  if [[ $n -gt 1 ]]; then "$cli" customize discard; fi
  describe "$n" "${#list[@]}" "$file" "$here/$file"
  "$cli" customize use "$here/$file"
  # An already open page belongs to the previous profile. Show this one's page: newTab.page, not
  # newTab.default, which gives the CLI a tab of the selected tab's kind (a terminal here), never the page.
  "$cli" action run newTab.page --focus
  if [[ -n "$auto" ]]; then
    sleep "$auto"
  elif [[ $n -lt ${#list[@]} ]]; then
    read -r -p "Enter for the next one, Ctrl-C to stop " _
  else
    read -r -p "Enter to put your setup back " _
  fi
done
