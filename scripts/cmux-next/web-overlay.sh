#!/usr/bin/env bash
# Point a running Debug or NIGHTLY cmux-next at live web code, without an app build or relaunch
# (plans/cmux-next/web-live-reload.md). It edits web-dev.json next to cmux-next.json, which the
# app watches (WebDevOverride.swift); every open page and agent pane reloads on a change.
#
#   web-overlay.sh server http://127.0.0.1:4181/   # load pages and the agent pane from a Vite
#                                                   # server (fastloop slot, `bun run dev`): hot reload
#   web-overlay.sh server off                       # stop using the server
#   web-overlay.sh build [--on HOST:WORKTREE]       # build the web bundles (here, or on HOST in
#                                                   # WORKTREE and copy them back), then install them;
#                                                   # WEB_OVERLAY_REMOTE_PATH=DIR puts DIR first on HOST's PATH
#   web-overlay.sh install DIR                      # install bundles built with
#                                                   # build-web-bundles.sh --out-root DIR
#   web-overlay.sh off                              # bundled pages again (keeps the overlay files)
#   web-overlay.sh status
#
# The overlay folder is $CMUX_WEB_OVERLAY_DIR, else ~/Library/Application Support/cmux-next/web-overlay.
# An install copies the bundles into a new generation folder, swaps the agent-pane, pages and
# webviews-app symlinks to it one by one (a page loading mid-swap gets its bundled files), writes
# manifest.json last (the app reloads on it) and keeps the two newest generations. A server wins
# over the overlay for the files it serves; a stopped server falls back to the overlay or bundle.
#
# The bundles talk to the app over the page bridge, so build them from a tree close to the app's
# commit (`cmux --version` or CMUXCommit in the app's Info.plist): an overlay much newer than the
# app can call ops the app does not have yet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
config_file="${CMUX_NEXT_CONFIG_FILE:-$HOME/.config/cmux/cmux-next.json}"
config_dir="$(dirname "$config_file")"
web_dev="$config_dir/web-dev.json"
overlay="${CMUX_WEB_OVERLAY_DIR:-$HOME/Library/Application Support/cmux-next/web-overlay}"

# The bundles inside a build-web-bundles.sh output root, and their overlay names.
PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
APP="Resources/markdown-viewer/webviews-app"

usage() { sed -n 2,24p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Sets keys of web-dev.json to JSON values in one write (`null` removes a key), keeping the others:
# set_key KEY VALUE [KEY VALUE]...
set_key() {
  mkdir -p "$config_dir"
  python3 - "$web_dev" "$@" <<'PY'
import json, os, sys, tempfile
path, pairs = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
for key, raw in zip(pairs[::2], pairs[1::2]):
    value = json.loads(raw)
    if value is None:
        data.pop(key, None)
    else:
        data[key] = value
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".web-dev.")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)  # one rename, so the app never reads half a file (and reloads once)
print(f"{path}: {json.dumps(data)}")
PY
}

json_string() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

install_from() {
  local from="$1"
  [[ -d "$from" ]] || { echo "no such directory: $from" >&2; exit 1; }
  local stamp gen
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  gen="$overlay/.gen-$stamp"
  mkdir -p "$gen"
  local installed=()
  if [[ -f "$from/$PANE/index.html" ]]; then cp -R "$from/$PANE" "$gen/agent-pane"; installed+=(agent-pane); fi
  if [[ -d "$from/$PAGES" ]]; then cp -R "$from/$PAGES" "$gen/pages"; installed+=(pages); fi
  if [[ -d "$from/$APP" ]]; then cp -R "$from/$APP" "$gen/webviews-app"; installed+=(webviews-app); fi
  if [[ ${#installed[@]} -eq 0 ]]; then
    rm -rf "$gen"
    echo "$from holds none of $PANE, $PAGES, $APP" >&2
    exit 1
  fi
  for name in "${installed[@]}"; do
    # A symlink renamed over the old one: each surface switches in one step.
    ln -sfn ".gen-$stamp/$name" "$overlay/.$name.next"  # -n: a leftover link is replaced, not entered
    mv -fh "$overlay/.$name.next" "$overlay/$name" 2>/dev/null || mv -fT "$overlay/.$name.next" "$overlay/$name"
  done
  local source_commit
  # The tree the bundles were built from: a remote build leaves .commit, a local one is this tree.
  source_commit="$(cat "$from/.commit" 2>/dev/null || git -C "$ROOT" rev-parse HEAD)"
  python3 - "$overlay" "$stamp" "$source_commit" "${installed[@]}" <<'PY'
import json, os, sys, tempfile
overlay, stamp, commit, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
fd, tmp = tempfile.mkstemp(dir=overlay, prefix=".manifest.")
with os.fdopen(fd, "w") as f:
    json.dump({"stamp": stamp, "commit": commit, "surfaces": names}, f)
    f.write("\n")
os.replace(tmp, os.path.join(overlay, "manifest.json"))
PY
  # Keep the two newest generations (a page that started loading the previous one finishes) and any
  # a surface still points at (an install of only some surfaces leaves the others where they were).
  local live=" "
  for name in agent-pane pages webviews-app; do
    target="$(readlink "$overlay/$name" 2>/dev/null || true)"
    [[ -n "$target" ]] && live+="${target%%/*} "
  done
  ls -1d "$overlay"/.gen-* 2>/dev/null | sort -r | tail -n +3 | while read -r old; do
    [[ "$live" == *" ${old##*/} "* ]] || rm -rf "$old"
  done
  set_key overlay "$(json_string "$overlay")" enabled true
  echo "installed ${installed[*]} from $from ($source_commit) into $overlay"
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
case "$cmd" in
  server)
    url="${1:-}"; [[ -n "$url" ]] || usage 1
    if [[ "$url" == off ]]; then set_key server null; exit 0; fi
    [[ "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+(/.*)?$ ]] || {
      echo "the server must be http://127.0.0.1:PORT/ (forward a remote slot with ssh -L PORT:127.0.0.1:PORT)" >&2; exit 1; }
    if ! curl -fsS -o /dev/null --max-time 5 "${url%/}/agent-pane/index.html"; then
      echo "warning: ${url%/}/agent-pane/index.html does not answer yet; the app uses the bundled pages until it does" >&2
    fi
    set_key server "$(json_string "$url")" enabled true
    ;;
  install)
    [[ -n "${1:-}" ]] || usage 1
    install_from "$(cd "$1" && pwd)"
    ;;
  build)
    out="$(mktemp -d "${TMPDIR:-/tmp}/web-overlay-build.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    if [[ "${1:-}" == --on ]]; then
      target="${2:-}"; [[ "$target" == *:* ]] || usage 1
      host="${target%%:*}"; tree="${target#*:}"
      # `~/x` is the remote home's; the path goes to the remote shell double-quoted, so no `"`, `$` or `\``.
      [[ "$tree" == "~/"* ]] && tree="\$HOME/${tree#\~/}"
      [[ "$tree" != *[\"\`]* && "${tree#\$HOME/}" != *'$'* ]] || { echo "unsupported characters in $tree" >&2; exit 1; }
      remote_out="/tmp/web-overlay-build-$$"
      # Built where the CPU is (big-red, a fleet box); nothing compiles on this Mac.
      # WEB_OVERLAY_REMOTE_PATH goes first on the remote PATH (a bun matching the webviews pin).
      ssh "$host" "${WEB_OVERLAY_REMOTE_PATH:+PATH=$WEB_OVERLAY_REMOTE_PATH:\$PATH; }cd \"$tree\" && rm -rf '$remote_out' && \
        \$(command -v heavy >/dev/null && echo 'heavy --mem 6G') ./scripts/cmux-next/build-web-bundles.sh --force --out-root '$remote_out' >&2 && \
        git rev-parse HEAD > '$remote_out/.commit'"
      rsync -a --delete "$host:$remote_out/" "$out/"
      ssh "$host" "rm -rf '$remote_out'"
    else
      "$ROOT/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$out"
    fi
    install_from "$out"
    ;;
  off)
    set_key enabled false
    ;;
  status)
    echo "web-dev.json: $web_dev"
    cat "$web_dev" 2>/dev/null || echo "(none: the app serves its bundled pages)"
    echo "overlay: $overlay"
    cat "$overlay/manifest.json" 2>/dev/null || echo "(no overlay installed)"
    ;;
  -h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage 1 ;;
esac
