#!/usr/bin/env bash
# Point a running cmux at live web code, without an app build or relaunch (docs/cmux-next/hot-reload.md,
# plans/cmux-next/web-live-reload.md). It edits web-dev.json next to cmux-next.json, which every
# build watches while Settings > General > cmux Live (updates.liveWebReload) is on, the
# default (WebDevOverride.swift); every open page and agent pane, WebKit or Chromium, reloads on a change.
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
#   web-overlay.sh install DIR [--commit SHA]
#                        # install a build-web-bundles.sh --out-root DIR; manifest.json records
#                        # SHA, else DIR's .web-overlay-source (`build` writes it), else unknown
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
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".web-dev.")  # 0600: it holds the token
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
  # The native interface the bundles need (their pages/web-abi.json): the app refuses an overlay
  # whose abi is not its own (WebDevOverride.refusal), as it refuses such a web update.
  python3 - "$overlay" "$stamp" "$source_commit" "$pages/web-abi.json" "${installed[@]}" <<'PY'
import json, os, sys, tempfile
overlay, stamp, commit, abi_file, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
manifest = {"stamp": stamp, "commit": commit, "surfaces": names}
try:
    with open(abi_file) as f:
        manifest["abi"] = int(json.load(f)["abi"])
except (OSError, ValueError, KeyError, TypeError):
    pass  # bundles with no web-abi.json: the app checks nothing, as before
fd, tmp = tempfile.mkstemp(dir=overlay, prefix=".manifest.")
with os.fdopen(fd, "w") as f:
    json.dump(manifest, f)
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

# The file in an output root that names the commit it was built from (`build` writes it).
SOURCE_FILE=".web-overlay-source"

# An output root of build-web-bundles.sh --out-root; $2 is the commit it was built from, else its
# $SOURCE_FILE, else unknown. Never this checkout's HEAD: the root may come from another tree.
install_from() {
  local commit="${2:-}"
  [[ -n "$commit" ]] || commit="$(head -n 1 "$1/$SOURCE_FILE" 2>/dev/null || true)"
  install_dirs "$1/$PANE" "$1/$PAGES" "$1/$APP" "${commit:-unknown}"
}

# This checkout's HEAD, with -dirty when the tree it builds from has changes.
checkout_commit() {
  local head
  head="$(git -C "$ROOT" rev-parse HEAD)"
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then head+="-dirty"; fi
  echo "$head"
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
  rm -f "$state/dev-server.tree" "$state/follow.pr" "$state/dev-server.token"
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
  # Each module's React Compiler output, kept across starts (webviews/reactCompiler.mjs keys it by
  # the file's text, path and bun.lock), so a second start serves the agent pane in seconds, not
  # half a minute. About 50 MB per tree; entries older than 14 days go at each start.
  local transforms="${CMUX_VITE_TRANSFORM_CACHE:-$state/transforms}"
  [[ -d "$transforms" ]] && find "$transforms" -type f -mtime +14 -delete 2>/dev/null
  rm -f "$state/dev-server.exit"
  # Its own process group (set -m), so `server off` stops bun and its children together, and the
  # exit watch with them. Every descriptor goes to the log, so the caller's pipe closes when this
  # script exits.
  ( set -m
    ( cd "$tree/webviews"
      self="$(exec sh -c 'echo $PPID')"
      watch_exit "$self" "$port" &
      CMUX_WEBVIEWS_DEV_PORT="$port" CMUX_VITE_TRANSFORM_CACHE="$transforms" exec nohup bun run dev
    ) </dev/null >"$state/dev-server.log" 2>&1 &
    echo $! >"$state/dev-server.pid" )
  echo "$tree:$port" >"$state/dev-server.tree"
  # A server that another process holds the port for answers too; only ours, still running, counts.
  if ! answers "$port" 60 || ! ours_listens "$port"; then
    echo "the dev server did not start; see $state/dev-server.log" >&2; exit 1
  fi
  echo "dev server: http://127.0.0.1:$port/ from $tree (log: $state/dev-server.log)"
}

# Waits beside the dev server (pid $1, port $2), in its process group: `stop_started` ends both.
# When the server exits on its own (a crash, a kill of bun alone), the app goes back to its shipped
# web UI at once (web-dev.json loses `server`, and the app reloads every page), and
# `$state/dev-server.exit` says when and why for `cmux live status`. Ends when the server does.
watch_exit() {
  local pid="$1" port="$2"
  trap '' HUP
  while kill -0 "$pid" 2>/dev/null; do sleep 2; done
  # A server this script started since (another port or checkout) is not this one's to clear.
  [[ "$(cat "$state/dev-server.pid" 2>/dev/null)" == "$pid" ]] || return 0
  rm -f "$state/dev-server.pid"
  # Nor is a server picked since (`server URL`, a slot): only web-dev.json still naming this one, with
  # the token `point_at` wrote for it, is cleared.
  points_here "http://127.0.0.1:$port/" "$(cat "$state/dev-server.token" 2>/dev/null)" || return 0
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) the dev server on port $port stopped on its own; the app shows the web UI it shipped with (log: $state/dev-server.log)" >"$state/dev-server.exit"
  set_key server null >/dev/null
}

# Whether web-dev.json's server is $1 with token $2 (a non-empty one).
points_here() {
  [[ -n "$2" ]] || return 1
  python3 - "$web_dev" "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if isinstance(data, dict) and data.get("server") == sys.argv[2] and data.get("token") == sys.argv[3] else 1)
PY
}

# A fresh token for web-dev.json on every `server`: the app sends each request a random nonce and
# loads only answers proving HMAC-SHA256(token, nonce) (webviews/dev-server/plugins.ts reads the token
# from the same 0600 file, per request), so a process that takes the port of a stopped server serves
# the app nothing. $1, when long enough, is used instead (a slot's server's token).
ensure_token() {
  local token="${1:-}"
  [[ ${#token} -ge 32 ]] || token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  echo "$token"
}

# Points the app at a server on port $1; $2 is the token its answers carry (default: ours).
# The token is kept in the state folder too, so a dev server's exit watch clears only its own pick.
point_at() {
  local token
  token="$(ensure_token "${2:-}")"
  mkdir -p "$state"
  (umask 077 && echo "$token" >"$state/dev-server.token")
  set_key server "$(json_string "http://127.0.0.1:$1/")" token "$(json_string "$token")" enabled true
}

# The first lines of `status`: what the app loads its web UI from right now, and why, in the order
# the app decides (WebDevOverride.swift): the cmux Live setting ($1, `cmux settings get`'s answer),
# then web-dev.json, then whether its server answers with the proof of its token (a server that
# does not answer, or answers without the proof, is skipped for the overlay, else the shipped UI).
# $2 is the pid of the dev server `cmux live start` runs, empty when none runs.
explain() {
  python3 - "$1" "$2" "$web_dev" "$state" <<'PY'
import hashlib, hmac, json, os, secrets, sys, urllib.request

setting_raw, pid, web_dev, state = sys.argv[1:5]
SHIPPED = "the web UI it shipped with"

def setting(raw):
    raw = raw.strip()
    try:
        value = json.loads(raw)
    except ValueError:
        # Human output: the value is its last word.
        value = raw.split()[-1].strip(".,'\"").lower() if raw else raw
    if isinstance(value, dict):
        value = value.get("value")
    if value in (True, "true"):
        return True
    if value in (False, "false"):
        return False
    return None

def read(path):
    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return None

def say(source, why=()):
    print(f"cmux loads its web UI from {source}.")
    for line in why:
        print(f"  {line}")

on = setting(setting_raw)
switch = {True: "on", False: "off", None: "unknown (`cmux settings get updates.liveWebReload` did not answer)"}[on]
print(f"cmux Live (Settings > General, updates.liveWebReload): {switch}")
if on is False:
    say(SHIPPED, ["Why: cmux Live is off, so the app ignores web-dev.json.",
                  "Turn it on in Settings > General, or: cmux settings set updates.liveWebReload true"])
    sys.exit(0)

raw = read(web_dev)
if raw is None:
    say(SHIPPED, [f"Why: there is no {web_dev}. `cmux live start` writes it."])
    sys.exit(0)
try:
    config = json.loads(raw)
except ValueError:
    config = None
if not isinstance(config, dict):
    say(SHIPPED, [f"Why: {web_dev} is not a JSON object."])
    sys.exit(0)
if config.get("enabled", True) is False:
    say(SHIPPED, [f'Why: {web_dev} says "enabled": false. `cmux live start` turns it back on.'])
    sys.exit(0)

def overlay_or_shipped(why):
    overlay = config.get("overlay")
    if isinstance(overlay, str) and overlay:
        folder = os.path.expanduser(overlay)
        try:
            commit = json.load(open(os.path.join(folder, "manifest.json"))).get("commit") or "unknown"
        except (OSError, ValueError, AttributeError):
            commit = "unknown"
        why.append("So the app uses the overlay web-dev.json names, where it has the files.")
        say(f"the overlay at {folder} (commit {commit})", why)
    else:
        say(SHIPPED, why)

server = config.get("server")
if not isinstance(server, str) or not server:
    overlay_or_shipped([f"Why: {web_dev} names no dev server. `cmux live start` runs one."])
    sys.exit(0)
token = config.get("token")
if not isinstance(token, str) or len(token) < 32:
    overlay_or_shipped([f"Why: {web_dev} names {server} but no token, so the app does not trust it.",
                        "`cmux live start` writes a fresh one."])
    sys.exit(0)

root = server if server.endswith("/") else server + "/"
tree = read(os.path.join(state, "dev-server.tree"))
checkout = None
if pid and tree and ":" in tree:
    path, _, port = tree.rpartition(":")
    if root.rstrip("/").endswith(":" + port):
        checkout = path

nonce = secrets.token_hex(16)
request = urllib.request.Request(root + "agent-pane/index.html", headers={"X-Cmux-Dev-Nonce": nonce})
try:
    with urllib.request.urlopen(request, timeout=3) as response:
        proof = response.headers.get("X-Cmux-Dev-Proof")
    answered = True
except Exception:
    answered, proof = False, None

if not answered:
    why = [f"Why: the dev server web-dev.json names, {root}, does not answer."]
    stopped = read(os.path.join(state, "dev-server.exit")) if not pid else None
    if stopped:
        when, _, reason = stopped.partition(" ")
        why.append(f"It stopped on its own at {when}" + (f": {reason}" if reason else "") + ".")
        why.append(f"Its log: {os.path.join(state, 'dev-server.log')}")
    why.append("`cmux live start` starts it again.")
    overlay_or_shipped(why)
    sys.exit(0)

want = hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest()
if not proof or not hmac.compare_digest(proof.strip().lower(), want):
    overlay_or_shipped([
        f"Why: something answers on {root}, but not with the token in web-dev.json"
        + (" (it sent no proof)." if not proof else "."),
        "Another checkout's dev server or another program holds the port. `cmux live start` replaces it.",
    ])
    sys.exit(0)

source = f"the dev server at {root}" + (f", from the checkout {checkout}" if checkout else "")
why = ["Why: cmux Live is on, web-dev.json names this server, and it answers with its token."]
if not checkout:
    why.append("`cmux live start` did not start it here, so its checkout is unknown.")
say(source, why)
PY
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
            # The slot's server sends the token of web-dev.json on its own machine.
            remote_token="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    print(json.load(open(os.path.expanduser("~/.config/cmux/web-dev.json"))).get("token") or "")
except Exception:
    print("")
PY
)"
            if [[ ${#remote_token} -lt 32 ]]; then
              echo "warning: $host has no token in ~/.config/cmux/web-dev.json; start its server with CMUX_WEB_DEV_TOKEN set to the \"token\" in $web_dev, or the app keeps the bundled pages" >&2
            fi
            point_at "$port" "$remote_token"; exit 0
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
        set_key server "$(json_string "$url")" token "$(json_string "$(ensure_token)")" enabled true
        echo "a webviews dev server on this Mac sends this token itself; any other server needs CMUX_WEB_DEV_TOKEN set to the \"token\" in $web_dev"
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
    dir="$1"; shift
    commit=""
    if [[ "${1:-}" == "--commit" ]]; then
      [[ -n "${2:-}" ]] || usage 1
      commit="$2"
    elif [[ -n "${1:-}" ]]; then usage 1; fi
    install_from "$(cd "$dir" && pwd)" "$commit"
    ;;
  install-app)
    [[ -d "${1:-}" ]] || usage 1
    install_app "$(cd "$1" && pwd)"
    ;;
  build)
    out="$(mktemp -d "${TMPDIR:-/tmp}/web-overlay-build.XXXXXX")"
    trap 'rm -rf "$out"' EXIT
    "$ROOT/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$out"
    checkout_commit > "$out/$SOURCE_FILE"
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
    # First the answer (what the app loads its web UI from, and why), then the details.
    setting=unknown
    if command -v cmux >/dev/null 2>&1; then
      setting="$(cmux settings get updates.liveWebReload 2>/dev/null || echo unknown)"
    fi
    explain "$setting" "$(live_pid dev-server)"
    echo
    for name in dev-server tunnel; do
      pid="$(live_pid "$name")"
      [[ -n "$pid" ]] && echo "running: $name (pid $pid)"
    done
    [[ -n "$(live_pid dev-server)" && -f "$state/follow.pr" ]] && echo "following: #$(cat "$state/follow.pr")"
    echo "web-dev.json: $web_dev"
    cat "$web_dev" 2>/dev/null || echo "(none: the app serves its bundled pages)"
    echo "overlay: $overlay"
    cat "$overlay/manifest.json" 2>/dev/null || echo "(no overlay installed)"
    # The app's bridge check (WebDevOverride.refusal): an overlay for another web ABI is not served.
    # CMUX_WEB_OVERLAY_APP names the app; else the installed NEXT builds.
    apps=("/Applications/cmux NIGHTLY.app" "/Applications/cmux NEXT.app")
    [[ -z "${CMUX_WEB_OVERLAY_APP:-}" ]] || apps=("$CMUX_WEB_OVERLAY_APP")
    for app in "${apps[@]}"; do
      [[ -f "$overlay/manifest.json" && -d "$app" ]] || continue
      python3 - "$overlay/manifest.json" "$app" <<'PY'
import json, sys
manifest, app = sys.argv[1], sys.argv[2]
try:
    want = json.load(open(manifest)).get("abi")
    have = json.load(open(app + "/Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"))["abi"]
except (OSError, ValueError, KeyError):
    sys.exit(0)
if want is not None and want != have:
    print(f"refused by {app}: the overlay needs web ABI {want}, the app has {have} (build it from a tree at the app's ABI)")
elif want is not None:
    print(f"served by {app}: web ABI {have}")
PY
    done
    ;;
  -h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage 1 ;;
esac
