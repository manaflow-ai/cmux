#!/usr/bin/env bash
# Point a running Debug, NIGHTLY or NEXT DEV cmux-next at live web code, without an app build or relaunch
# (plans/cmux-next/web-live-reload.md). It edits web-dev.json next to cmux-next.json, which the
# app watches (WebDevOverride.swift); every open page and agent pane reloads on a change.
#
#   web-overlay.sh server --local [--worktree DIR] [--port N]
#                        # the default: run the webviews Vite server from a checkout on this Mac
#                        # (this one unless --worktree) and point the app at it; edits hot reload
#   web-overlay.sh server --slot
#                        # a remote slot declared in web-dev.json ("slot": {"host": H, "port": N}):
#                        # tunnel to it; when it does not answer, fall back to --local
#   web-overlay.sh server URL | off   # any loopback server; off also stops what `server` started
#   web-overlay.sh follow PR [--port N] [--fork]
#                        # serve that pull request's head: fetch it with git into a checkout this
#                        # script keeps, run the dev server there; again moves to the newest push.
#                        # A head on no branch of the repo (a fork) runs only with --fork
#   web-overlay.sh fleet [--ref SHA | --working-tree] [--tag T] [--workspace ID] [--submitter LOGIN]
#                        # build the app on the fleet (cmux-ci; the Linux pool for cmux-next; tag
#                        # web-overlay, workspace web-overlay:$USER) and install its web bundles
#   web-overlay.sh build              # build the web bundles in this checkout and install them
#   web-overlay.sh install DIR        # install a build-web-bundles.sh --out-root DIR
#   web-overlay.sh install-app APP    # install the web bundles of a built cmux .app
#   web-overlay.sh off                # bundled pages again (keeps the overlay files)
#   web-overlay.sh status
#
# The overlay folder is $CMUX_WEB_OVERLAY_DIR, else ~/Library/Application Support/cmux-next/web-overlay.
# An install copies the bundles into a new generation folder, swaps the agent-pane, pages and
# webviews-app symlinks to it one by one (a page loading mid-swap gets its bundled files), writes
# manifest.json last (the app reloads on it) and keeps the newest generations. A server wins over
# the overlay for the files it serves; a stopped server falls back to the overlay or bundle.
#
# The bundles talk to the app over the page bridge, so serve or build them from a tree close to the
# app's commit (CMUXCommit in the app's Info.plist): a tree much newer than the app can call ops the
# app does not have yet.
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

# The comment block at the top of this file, up to `set`.
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }
# What `server --local` and `server --slot` started (pid files, the dev server's log).
state="${CMUX_WEB_SLOT_STATE_DIR:-$HOME/Library/Caches/cmux-next/web-slot}"
DEFAULT_PORT=4200

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

# Installs the bundles in $1 (agent pane), $2 (pages) and $3 (webviews app); $4 is their commit.
install_dirs() {
  local pane="$1" pages="$2" app="$3" source_commit="$4"
  local stamp gen
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  gen="$overlay/.gen-$stamp"
  mkdir -p "$gen"
  local installed=()
  if [[ -f "$pane/index.html" ]]; then cp -R "$pane" "$gen/agent-pane"; installed+=(agent-pane); fi
  if [[ -d "$pages" ]]; then cp -R "$pages" "$gen/pages"; installed+=(pages); fi
  if [[ -d "$app" ]]; then cp -R "$app" "$gen/webviews-app"; installed+=(webviews-app); fi
  if [[ ${#installed[@]} -eq 0 ]]; then
    rm -rf "$gen"
    echo "no web bundles in $pane, $pages or $app" >&2
    exit 1
  fi
  for name in "${installed[@]}"; do
    # A symlink renamed over the old one: each surface switches in one step.
    ln -sfn ".gen-$stamp/$name" "$overlay/.$name.next"  # -n: a leftover link is replaced, not entered
    mv -fh "$overlay/.$name.next" "$overlay/$name" 2>/dev/null || mv -fT "$overlay/.$name.next" "$overlay/$name"
  done
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
  echo "installed ${installed[*]} ($source_commit) into $overlay"
}

# An output root of build-web-bundles.sh --out-root, built from this checkout.
install_from() {
  install_dirs "$1/$PANE" "$1/$PAGES" "$1/$APP" "$(git -C "$ROOT" rev-parse HEAD)"
}

# A built cmux .app: its module bundles and its viewer folder hold the same files. $2 is the
# commit it was built from when known (DEV builds carry no CMUXCommit).
install_app() {
  local res="$1/Contents/Resources" commit="${2:-}"
  [[ -n "$commit" ]] || commit="$(/usr/libexec/PlistBuddy -c "Print CMUXCommit" "$1/Contents/Info.plist" 2>/dev/null || echo unknown)"
  install_dirs "$res/CmuxNext_CmuxNextAgentPane.bundle/Contents/Resources/agent-pane" \
    "$res/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages" "$res/markdown-viewer/webviews-app" "$commit"
}

# Whether a server on 127.0.0.1:$1 serves the agent pane, retrying for up to $2 seconds (a server
# that is starting).
answers() {
  curl -fsS -o /dev/null --max-time 3 --retry "${2:-0}" --retry-delay 1 --retry-connrefused --retry-all-errors \
    "http://127.0.0.1:$1/agent-pane/index.html" 2>/dev/null
}

# The pid in state file $1 (dev-server, tunnel) while that process still runs the program it
# started (bun, ssh), else empty: a pid file that outlived a reboot never names another process.
live_pid() {
  local file="$state/$1.pid" program pid
  case "$1" in dev-server) program=bun ;; tunnel) program=ssh ;; *) return 0 ;; esac
  [[ -f "$file" ]] || return 0
  pid="$(cat "$file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")" == "$program" ]] && echo "$pid"
  return 0
}

# Whether the server listening on 127.0.0.1:$1 is the dev server this script started (a process of
# its group), not another program's that answers the same paths.
ours_listens() {
  local leader pid
  leader="$(live_pid dev-server)"
  [[ -n "$leader" ]] || return 1
  for pid in $(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null); do
    [[ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" == "$leader" ]] && return 0
  done
  return 1
}

# Stops what `server` started (the local dev server, the slot tunnel).
stop_started() {
  local name pid
  for name in dev-server tunnel; do
    pid="$(live_pid "$name")"
    if [[ -n "$pid" ]]; then
      # The dev server leads its own process group (bun and its children); the tunnel is one ssh.
      if [[ "$name" == dev-server ]]; then kill -- "-$pid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
    fi
    rm -f "$state/$name.pid"
  done
  rm -f "$state/dev-server.tree" "$state/follow.pr"
}

# A field of web-dev.json's "slot" (host or port), empty when unset.
slot_field() {
  python3 - "$web_dev" "$1" <<'PY'
import json, sys
try:
    slot = json.load(open(sys.argv[1])).get("slot") or {}
except (OSError, ValueError, AttributeError):
    slot = {}
value = slot.get(sys.argv[2]) if isinstance(slot, dict) else None
print("" if value is None else value)
PY
}

# Runs checkout $1's webviews dev server on port $2, detached. Reuses a server on that port that
# this script started from the same checkout, or one it did not start at all.
start_local() {
  local tree="$1" port="$2" ours
  [[ -f "$tree/webviews/package.json" ]] || { echo "no webviews/ in $tree" >&2; exit 1; }
  ours="$(live_pid dev-server)"
  if answers "$port"; then
    if [[ -z "$ours" ]]; then
      echo "a dev server already answers on 127.0.0.1:$port; using it"
      return
    elif [[ "$(cat "$state/dev-server.tree" 2>/dev/null)" == "$tree:$port" ]]; then
      echo "dev server: http://127.0.0.1:$port/ from $tree (already running)"
      return
    fi
  fi
  # One dev server at a time: a new port or checkout replaces the one started before (and frees
  # the port when it is the same one).
  stop_started
  answers "$port" && for _ in 1 2 3 4 5; do sleep 1; answers "$port" || break; done
  mkdir -p "$state"
  [[ -d "$tree/webviews/node_modules" ]] || (cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null)
  # The generated string tables are gitignored; the dev server imports them.
  (cd "$tree/webviews" && bun scripts/pages/gen-strings.mjs --best-effort >/dev/null 2>&1)
  # Its own process group (set -m), so `server off` stops bun and its children together.
  # Every descriptor goes to the log, so the caller's pipe closes when this script exits.
  ( set -m
    ( cd "$tree/webviews" && CMUX_WEBVIEWS_DEV_PORT="$port" exec nohup bun run dev ) </dev/null >"$state/dev-server.log" 2>&1 &
    echo $! >"$state/dev-server.pid" )
  echo "$tree:$port" >"$state/dev-server.tree"
  # A server that another process holds the port for answers too; only ours, still running, counts.
  if ! answers "$port" 60 || ! ours_listens "$port"; then
    echo "the dev server did not start; see $state/dev-server.log" >&2; exit 1
  fi
  echo "dev server: http://127.0.0.1:$port/ from $tree (log: $state/dev-server.log)"
}

point_at() {
  set_key server "$(json_string "http://127.0.0.1:$1/")" enabled true
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
case "$cmd" in
  server)
    mode="${1:-}"; [[ -n "$mode" ]] || usage 1; shift
    case "$mode" in
      off)
        stop_started
        set_key server null
        ;;
      --local)
        tree="$ROOT" port="$(slot_field port)"; port="${port:-$DEFAULT_PORT}"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --worktree) tree="$(cd "$2" && pwd)"; shift 2 ;;
            --port) port="$2"; shift 2 ;;
            *) usage 1 ;;
          esac
        done
        start_local "$tree" "$port"
        point_at "$port"
        ;;
      --slot)
        host="$(slot_field host)" port="$(slot_field port)"; port="${port:-$DEFAULT_PORT}"
        if [[ -z "$host" ]]; then
          echo "no slot in $web_dev (\"slot\": {\"host\": \"<ssh host>\", \"port\": N}); using a local dev server" >&2
        elif answers "$port"; then
          echo "127.0.0.1:$port already answers; using it"
          point_at "$port"; exit 0
        else
          # The same port on both ends: the Vite client opens its HMR socket on the server's port.
          stop_started
          mkdir -p "$state"
          ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -L "$port:127.0.0.1:$port" "$host" </dev/null >"$state/tunnel.log" 2>&1 &
          echo $! >"$state/tunnel.pid"
          if answers "$port" 15; then
            echo "slot: $host:$port through a tunnel"
            point_at "$port"; exit 0
          fi
          kill "$(cat "$state/tunnel.pid")" 2>/dev/null || true; rm -f "$state/tunnel.pid"
          echo "the slot on $host:$port does not answer; using a local dev server" >&2
        fi
        start_local "$ROOT" "$port"
        point_at "$port"
        ;;
      *)
        url="$mode"
        [[ "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+(/.*)?$ ]] || {
          echo "the server must be http://127.0.0.1:PORT/" >&2; exit 1; }
        if ! curl -fsS -o /dev/null --max-time 5 "${url%/}/agent-pane/index.html"; then
          echo "warning: ${url%/}/agent-pane/index.html does not answer yet; the app uses the bundled pages until it does" >&2
        fi
        set_key server "$(json_string "$url")" enabled true
        ;;
    esac
    ;;
  follow)
    # A reviewer runs exactly the head under review: the PR's head ref comes from git (no GitHub
    # API), into one checkout of this repo that the script keeps; the dev server serves it, so a
    # later push is a checkout of the files that changed and Vite hot-reloads them.
    pr="${1:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || usage 1; shift
    port="$(slot_field port)"; port="${port:-$DEFAULT_PORT}" fork=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --port) port="$2"; shift 2 ;;
        --fork) fork=1; shift ;;
        *) usage 1 ;;
      esac
    done
    remote=origin tree="$state/follow" repo="$ROOT"
    # Fetch into the repo that owns the checkout, which another clone may have made.
    [[ -e "$tree/.git" ]] && repo="$tree"
    git -C "$repo" fetch -q "$remote" "refs/pull/$pr/head"
    head="$(git -C "$repo" rev-parse FETCH_HEAD)"
    # The dev server runs the head's own code (its Vite config and dev-server plugins) on this Mac.
    # A branch of the repo needs push access; a fork's head is anyone's code, so it needs --fork
    # after reading it.
    if [[ -z "$fork" ]] && ! git -C "$repo" ls-remote --heads "$remote" | awk '{print $1}' | grep -qx "$head"; then
      echo "#$pr's head $head is not on a branch of $remote (a fork?): its dev server would run its code here." >&2
      echo "Read its webviews/ changes, then run \`web-overlay.sh follow $pr --fork\`." >&2
      exit 1
    fi
    if [[ -e "$tree/.git" ]]; then
      # Only this script writes here; a stray edit would block the move, so the head always wins.
      git -C "$tree" checkout -q --force --detach "$head"
    else
      mkdir -p "$state"
      git -C "$ROOT" worktree prune --expire now  # a deleted checkout stays registered until pruned
      git -C "$ROOT" worktree add -q --detach "$tree" "$head"
    fi
    # The files on disk are this head now, so status names it even if a step below fails.
    echo "$pr $head" >"$state/follow.pr"
    # Another program's server on the port would serve its own files, not this head.
    if answers "$port" && ! ours_listens "$port"; then
      echo "127.0.0.1:$port answers, but not from a server this script started; stop it or use --port N" >&2
      exit 1
    fi
    # A push that changes the lockfile needs its packages (a no-op when they are current).
    [[ -d "$tree/webviews/node_modules" ]] && (cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null)
    start_local "$tree" "$port"
    echo "$pr $head" >"$state/follow.pr"  # start_local clears it when it replaces another server
    point_at "$port"
    echo "following #$pr at $head; run \`web-overlay.sh follow $pr\` again after a push"
    ;;
  install)
    [[ -n "${1:-}" ]] || usage 1
    install_from "$(cd "$1" && pwd)"
    ;;
  install-app)
    [[ -d "${1:-}" ]] || usage 1
    install_app "$(cd "$1" && pwd)"
    ;;
  build)
    out="$(mktemp -d "${TMPDIR:-/tmp}/web-overlay-build.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    "$ROOT/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$out"
    install_from "$out"
    ;;
  fleet)
    # The fleet builds the app (cmux-ci; the Linux pool for cmux-next) and the overlay takes its web
    # bundles: nothing builds on this Mac, and the job is also a dev build of the whole app.
    # The tag names the build (cmux DEV <tag>.app); a build of a pushed ref needs a workspace, and
    # a later build with the same tag and workspace supersedes a queued one.
    ref="" tag="web-overlay" workspace="web-overlay:$(id -un)" working_tree="" args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref) ref="$2"; shift 2 ;;
        --working-tree) working_tree=1; shift ;;
        --tag) tag="$2"; shift 2 ;;
        --workspace) workspace="$2"; shift 2 ;;
        --submitter) args+=("$1" "$2"); shift 2 ;;
        *) usage 1 ;;
      esac
    done
    # The overlay takes only web bundles, so the build needs no cmux backend: a remote backend
    # would also require this checkout's HEAD to be the built ref.
    args+=(--tag "$tag" --backend-mode local)
    ci="${CMUX_CI:-$HOME/.local/bin/cmux-ci}"
    [[ -x "$ci" ]] || { echo "no cmux-ci client at $ci (CMUX_CI names another)" >&2; exit 1; }
    if [[ -n "$working_tree" ]]; then
      args+=(--working-tree)
    else
      ref="${ref:-$(git -C "$ROOT" rev-parse HEAD)}"
      args+=(--ref "$ref" --workspace "$workspace")
    fi
    out="$(mktemp -d "${TMPDIR:-/tmp}/web-overlay-fleet.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    job_json="$(cd "$ROOT" && "$ci" build cmux --builder linux "${args[@]}")"
    job="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$job_json")"
    echo "fleet job $job" >&2
    "$ci" wait "$job" >&2 || { echo "job $job is not done; \`cmux-ci wait $job\` resumes, then \`web-overlay.sh install-app\`" >&2; exit 1; }
    # The per-file bundle, else the zip (artifact --bundle exits 3 when the store has no bundle).
    if "$ci" artifact "$job" "$out/bundle" --bundle >&2; then :
    else
      [[ $? -eq 3 ]] || exit 1
      "$ci" artifact "$job" "$out/app.zip" >&2
      mkdir -p "$out/bundle" && ditto -x -k "$out/app.zip" "$out/bundle"
    fi
    app="$(find "$out/bundle" -maxdepth 2 -name '*.app' -type d | head -1)"
    [[ -n "$app" ]] || { echo "job $job returned no app bundle" >&2; exit 1; }
    install_app "$app" "$ref"
    ;;
  off)
    set_key enabled false
    ;;
  status)
    for name in dev-server tunnel; do
      pid="$(live_pid "$name")"
      [[ -n "$pid" ]] && echo "running: $name (pid $pid)"
    done
    [[ -n "$(live_pid dev-server)" && -f "$state/follow.pr" ]] && echo "following: #$(cat "$state/follow.pr")"
    echo "web-dev.json: $web_dev"
    cat "$web_dev" 2>/dev/null || echo "(none: the app serves its bundled pages)"
    echo "overlay: $overlay"
    cat "$overlay/manifest.json" 2>/dev/null || echo "(no overlay installed)"
    ;;
  -h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage 1 ;;
esac
