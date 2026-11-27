#!/usr/bin/env bash
# Fleet entry for tab switching. Two modes, by the shape of the arguments:
#
# 1. key=value arguments: the frame-judged harness (scripts/cmux-next/tab_switch_frames.py, through
#    bench_tab_switch.py --frames) on a display Mac. A long chat, a terminal and a Chromium page switched away and
#    back, a new tab and a close, idle, under CPU load and with agents streaming; every switch judged from the
#    screen's own frames (CuaDriver's display recording, synced by a marker window: tab_switch_capture.py) against
#    the frame it must end on, with budgets (content within one display frame, 0 blank, 0 wrong, 0 px shift, the new
#    tab's insert and its animation's end right). Works on a shipped NIGHTLY (no debug.* commands needed):
#      cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#        --script scripts/measure/tab-switch.sh --ref <feat-cmux-next sha> \
#        [--arg=build=nightly|SHA|head] [--arg=rounds=5] [--arg=load=idle,cpu,agents] [--arg=gate=0] \
#        --artifact .build/tab-switch/report.tgz --timeout 7200
#    build=nightly  the newest app the NIGHTLY feed offers (as nightly-fresh-launch.sh dmg=nightly; default)
#    build=SHA      an app built at SHA (40 hex; fetched from GitHub when this checkout lacks it), Release
#                   (config=bench: Release with the debug.* commands, so the content rect comes from debug.pane_chrome)
#    build=head     an app built at this checkout
#    app=PATH       an extracted tagged app from cmux-ci build (no native app build or CEF credentials here).
#                   Download with cmux-ci artifact JOB cmux.app.zip; extract on the GUI worker with
#                   ditto -x -k cmux.app.zip DEST, then pass app=DEST/<tagged name>.app.
#                   build=SHA additionally checks its CMUXCommit; the report labels the actual bundle commit.
#                   Use a dedicated test tag: the harness launches this bundle directly, without copying it.
#    dmg=https://   one DMG instead of the feed
#    rounds=N       switches per scenario and load (1 to 20, default 5)
#    load=LIST      idle,cpu,agents (default), or the instant-at-any-load modes L0 (idle), L1 (the focused chat
#                   streams 60 chunks/s and 2,000 tool-output lines/s), L2 (10 other chats streaming, 3 in a split
#                   pane), L3 (the focused chat is a 100k-row chat, streaming), L4 (every core pinned), L5 (all of
#                   them plus STRESS: 60 workspaces, 20 printing terminals; run last); also cpu-max, agents-N,
#                   chat-100k, tabs-N, and any of them joined with + (L4+tabs-40)
#    scenarios=LIST chat-long-return,terminal-return,chromium-return,new-tab,close-tab (default), or all: also
#                   webkit-return, new-workspace, switch-workspace, close-workspace, rapid-open-5, rapid-close-3,
#                   open-while-close; or matrix: the settle matrix (scripts/cmux-next/tab_switch_matrix.py), trigger to
#                   truly settled over the window, the page side and the sidebar for workspace switches cold and warm,
#                   new workspace and chat, split, resize, tab move, unsplit, window resize, pane to a new window, a
#                   10k-row chat and a relaunch that restores (SETTLE lines, matrix.md). The settle matrix at Leo's
#                   scale, one command:
#                     ... --arg=build=nightly --arg=scenarios=matrix --arg=scale=leo --arg=load=idle --arg=record=3 \
#                       --arg=gate=0
#    scale=NAME     leo (10,789 daemon sessions written into the app's fresh ~/.acpmux before its first launch by
#                   cmux-tui acpmux `examples/scale_home.rs`, built here; 205 of them opened as workspaces, 206 in
#                   all), SESSIONSxWORKSPACES, or none (default)
#    launch_record=S  seconds recorded after each launch-restore relaunch (default 8)
#    chat_perf=1    the settle matrix also runs the chat page's own capture (agent.chat.perf) over each step
#    record=S       seconds recorded after each action (default 1.2); settled needs 300 ms still inside it
#    rows=N         rows of the 100k-row chat (default 100000)
#    turns=N        answered turns in the long chat (default 200); agents=N streaming chats (default 4)
#    gate=0         exit 0 once the report is written, budgets or not (an artifact comes back only from a passing step)
#    Every action also gets settled_ms (the window still for 300 ms) and an oddity log (tab_switch_settle.py),
#    printed as TSW-ODD lines, with a summary table (TSW-TABLE, table.md).
#    Writes .build/tab-switch/report.json (schema tab-switch/v1), contact sheets of failing switches in
#    .build/tab-switch/sheets/, and both in .build/tab-switch/report.tgz. Prints TSW and TSW-FAIL lines.
#    Exit: 0 every budget held (or gate=0), 1 a budget failed, 3 could not measure.
#
# 2. --flag arguments (or none): the per-stage tab switch timing (tab-switch-fast): builds a tagged cmux-next app at
#    this checkout, then runs scripts/cmux-next/tab-switch-stages.py against it (terminal, Chromium, WebKit and
#    Markdown tabs in one pane; Ctrl-Tab, Ctrl-Shift-Tab and strip clicks; per-stage ms):
#      cmux-ci run --class exclusive --label measure --script scripts/measure/tab-switch.sh --ref <sha> [--arg=--rounds=12]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# A build here (build=SHA, build=head, or the --flag mode) fetches pinned assets whose last source is the private
# cmux-cef R2 bucket, read with the CMUX_CEF_R2_* read credentials (cmux-remote-dev.pin.json in a Release build that
# embeds cmux Remote, the Chromium engine when the store has no copy). Without them the build ran 7 to 13 minutes under
# the host lock and then failed (cmux19, 2026-11-16 22:28Z, 22:42Z and 00:04Z), so they are checked first: the
# environment, else CMUX_CEF_R2_ENV_FILE, else ~/.secrets/cmux-cef.env of this HOME or of the account (a fleet step
# has its own HOME). The file found is exported, so the build reads the same one. The controller sends these steps
# only to workers that advertise cef-r2 (cmuxterm-hq build-fleet); build-fleet/mini-ops/cef-r2-key.sh installs the key.
cef_read_file_ok() {
  local file="$1" name
  [[ -n "$file" && -r "$file" ]] || return 1
  for name in CMUX_CEF_R2_ACCOUNT_ID CMUX_CEF_R2_ACCESS_KEY_ID CMUX_CEF_R2_SECRET_ACCESS_KEY; do
    grep -Eq "^(export )?$name=[\"']?[^\"'[:space:]]" "$file" || return 1
  done
}
require_cef_read_credentials() {
  if [[ -n "${CMUX_CEF_R2_ACCESS_KEY_ID:-}" && -n "${CMUX_CEF_R2_SECRET_ACCESS_KEY:-}" &&
    -n "${CMUX_CEF_R2_ACCOUNT_ID:-}${CMUX_CEF_R2_ENDPOINT:-}" ]]; then
    return 0
  fi
  local account_home="${TSW_ACCOUNT_HOME-$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')}"
  local file
  for file in "${CMUX_CEF_R2_ENV_FILE:-}" "$HOME/.secrets/cmux-cef.env" "${account_home:+$account_home/.secrets/cmux-cef.env}"; do
    if cef_read_file_ok "$file"; then
      export CMUX_CEF_R2_ENV_FILE="$file"
      return 0
    fi
  done
  echo "TSW no CMUX_CEF_R2_* read credentials on this Mac (none in the environment, ${CMUX_CEF_R2_ENV_FILE:+$CMUX_CEF_R2_ENV_FILE, }$HOME/.secrets/cmux-cef.env${account_home:+ or $account_home/.secrets/cmux-cef.env}): a build here would fail after minutes fetching its pinned assets. Not building. Measure build=nightly, or run on a worker labeled cef-r2 (cmuxterm-hq build-fleet/mini-ops/cef-r2-key.sh HOST installs the read key)."
  exit 3
}

# Each submodule commit the build checks out must be fetchable before the build starts: a pointer to a ghostty commit
# its fork lacks, or a host mirror (url.*.insteadOf) older than the pointer, failed with "cannot fetch" only after the
# step had taken the host (a fleet Mac, 2026-11-16). One commit object is fetched (--depth 1 --filter=tree:0, under a second)
# into a scratch bare repository under DIR; on a miss the line says which: a stale mirror, an unreachable remote, or a
# commit the fork never received (push it there first). Exit 3, could not measure.
require_submodule_refs() { # SRC DIR [PREFIX]
  local src="$1" dir="$2" prefix="${3:-TSW}" sub sha url probe effective why
  # A stalled transfer (under 1 byte/s for 20 s) gives up: macOS has no timeout(1).
  local stall=(-c http.lowSpeedLimit=1 -c http.lowSpeedTime=20)
  for sub in ghostty ghostty-next; do
    sha="$(git -C "$src" rev-parse --verify --quiet "HEAD:$sub" 2>/dev/null)" || continue
    [ -e "$src/$sub/.git" ] && continue # prepare_build reuses a checked-out submodule as it is
    url="$(git -C "$src" config -f .gitmodules "submodule.$sub.url" 2>/dev/null)" || continue
    probe="$dir/submodule-probe-$sub"
    rm -rf -- "$probe" && git init --quiet --bare "$probe"
    if git "${stall[@]}" -C "$probe" fetch --quiet --no-tags --depth 1 --filter=tree:0 "$url" "$sha" 2>/dev/null; then
      rm -rf -- "$probe"
      continue
    fi
    effective="$(git ls-remote --get-url "$url")" || effective="$url" # reads config only, never the remote
    if [[ "$effective" != "$url" ]] && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git "${stall[@]}" -C "$probe" fetch --quiet --no-tags --depth 1 --filter=tree:0 "$url" "$sha" 2>/dev/null; then
      why="this host's mirror $effective lacks it but $url has it: refresh the mirror"
    elif ! git "${stall[@]}" ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
      why="$effective cannot be reached from this host"
    else
      why="$url does not have it: the cmux commit records a $sub pointer that was never pushed to the fork"
    fi
    rm -rf -- "$probe"
    echo "$prefix cannot fetch submodule $sub at $sha: $why. Not building."
    return 3
  done
}

# Each long step runs through tsw_step, with its own bound, and says it is alive while it runs. The controller stops a
# step that prints nothing for 45 min (CMUX_CI_MEASURE_SILENT_MAX) and names no cause: both chat-long-return runs on
# #47553 (base and head, two display Macs, 2026-11-19) went silent after "TSW recorder ready" while the app build
# wrote only to build.log, and each was stopped with nothing to say which step it was. macOS has no timeout(1).
TSW_STEP_EVERY=${TSW_STEP_EVERY:-60}
# tsw_stop_tree PID: TERM to PID and every process under it (listed first, so none escapes by being reparented), KILL
# to any left after 10 s.
tsw_stop_tree() {
  local pids=("$1") i=0 child pid left
  while ((i < ${#pids[@]})); do
    for child in $(pgrep -P "${pids[i]}" 2>/dev/null); do pids+=("$child"); done
    i=$((i + 1))
  done
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for ((i = 0; i < 10; i++)); do
    left=0
    for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && left=1; done
    ((left)) || return 0
    sleep 1
  done
  kill -KILL "${pids[@]}" 2>/dev/null || true
}
# follow_log LOG DONE: print LOG from its start as it grows, and end at its end once the file DONE exists, so the
# caller waits for the follower itself to have printed every last line.
follow_log() {
  python3 -I -c 'import os, sys, time
log, done = sys.argv[1], sys.argv[2]
with open(log, "rb") as f:
    while True:
        finished = os.path.exists(done)  # before the read: what was written before DONE is read
        chunk = f.read(65536)
        if chunk:
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        elif finished:
            break
        else:
            time.sleep(0.1)' "$1" "$2"
}
# tsw_step PREFIX NAME LIMIT LOG [--stream] -- COMMAND...: runs COMMAND with its output in LOG, shown as it comes
# with --stream; without it, every TSW_STEP_EVERY seconds a line gives the elapsed time and LOG's last line. Past
# LIMIT seconds it stops COMMAND and everything under it, prints "PREFIX step NAME ran past LIMIT s" with LOG's tail
# and returns 3 (could not measure); otherwise COMMAND's own status.
tsw_step() {
  local prefix="$1" name="$2" limit="$3" log="$4" stream=0 follow="" rc=0
  shift 4
  [[ "${1:-}" == --stream ]] && { stream=1; shift; }
  [[ "${1:-}" == -- ]] && shift
  : >"$log"
  rm -f "$log.done"
  "$@" >"$log" 2>&1 &
  local pid=$! started=$SECONDS next=$((SECONDS + TSW_STEP_EVERY))
  if [[ "$stream" == 1 ]]; then
    follow_log "$log" "$log.done" &
    follow=$!
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS - started >= limit)); then
      [[ -n "$follow" ]] && { kill "$follow" 2>/dev/null; wait "$follow" 2>/dev/null || true; }
      echo "$prefix step $name ran past $limit s: stopped. Its log's last lines:"
      tsw_stop_tree "$pid"
      wait "$pid" 2>/dev/null || true
      tail -n 30 "$log"
      return 3
    fi
    if [[ "$stream" == 0 ]] && ((SECONDS >= next)); then
      echo "$prefix step $name: $((SECONDS - started)) s, last: $(tail -n 1 "$log" | cut -c1-200)"
      next=$((SECONDS + TSW_STEP_EVERY))
    fi
    sleep 1
  done
  wait "$pid" || rc=$?
  if [[ -n "$follow" ]]; then
    # Until the follower has printed the log's last lines and ended, 10 s.
    : >"$log.done"
    for _ in $(seq 1 100); do kill -0 "$follow" 2>/dev/null || break; sleep 0.1; done
    kill "$follow" 2>/dev/null || true
    wait "$follow" 2>/dev/null || true
    rm -f "$log.done"
  fi
  return "$rc"
}
# The bounds, each well past the step's slowest pass seen and overridable: a cold Release build on a light mini takes
# about 45 min.
TSW_PREFLIGHT_MAX=${TSW_PREFLIGHT_MAX:-300}
TSW_TOOLS_MAX=${TSW_TOOLS_MAX:-600}
TSW_SEEDER_MAX=${TSW_SEEDER_MAX:-1800}
TSW_BUILD_MAX=${TSW_BUILD_MAX:-5400}
TSW_RUN_MAX=${TSW_RUN_MAX:-7200}

# Submodules, GhosttyKit and the pinned bun a tagged build needs (a fleet step checks out no submodules).
prepare_build() {
  local tmp
  tmp="$(cd "$1" && pwd)" || return 3 # absolute: the bun dir goes on PATH, and the web builders cd into webviews/
  for sub in ghostty ghostty-next; do
    [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh
  fi
  # Steps run with a per-step HOME; the account's user-level tools (bun and node for the web bundles) live under its
  # real home (as perf-bench.sh).
  local account_home tool_dir
  account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
    [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
  done
  # The web bundles need the bun webviews/package.json pins; the step gets its own checked copy, first on PATH.
  RUNNER_TEMP="$tmp" GITHUB_PATH="$tmp/bun-path" ./scripts/cmux-next/private-bun.sh
  PATH="$(tail -n 1 "$tmp/bun-path"):$PATH"
  export PATH
}

# The app build in SRC with scratch folder TMP and reload tag TAG; the rest goes to reload.sh. Run by tsw_step, in
# its own subshell, so the cd stays there.
tsw_build_app() { # SRC TMP TAG RELOAD-ARGS...
  local src="$1" tmp="$2" tag="$3"
  shift 3
  cd "$src" && prepare_build "$tmp" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links "$@"
}
# The settle matrix's scale seeder, from this checkout's cmux-tui (its target folder stays warm between steps).
tsw_build_seeder() {
  cd cmux-tui && cargo build --release --quiet -p acpmux --example scale_home
}

# The app a key=value run measures (launch-capture-probe.sh sources this file for it): build=nightly downloads DMG,
# or the NIGHTLY feed's newest, into TMP; build=head or a 40-hex commit builds the app there (in TMP/src for another
# commit, which the caller's EXIT trap removes) with CONFIG (release, or bench: Release with the debug.* commands) and
# reload tag TAG. Optional eighth argument is an extracted tagged app; its actual commit labels the run.
# Sets APP_ARGS (--dmg FILE or --app PATH) and APP_LABEL, prints PREFIX lines, returns 3 when it cannot.
app_under_test() {
  local build="$1" config="$2" dmg="$3" tmp="$4" root="$5" tag="$6" prefix="${7:-TSW}"
  local prebuilt="${8:-}"
  APP_ARGS=() APP_LABEL=""
  if [[ -n "$prebuilt" ]]; then
    [[ -z "$dmg" ]] || { echo "$prefix app= and dmg= are mutually exclusive" >&2; return 3; }
    [[ -d "$prebuilt" ]] || { echo "$prefix prebuilt app does not exist: $prebuilt" >&2; return 3; }
    prebuilt="$(cd "$prebuilt" && pwd -P)" || return 3
    local expected="$build" commit
    [[ "$expected" != head ]] || expected="$(git -C "$root" rev-parse HEAD)" || return 3
    commit="$(python3 - "$prebuilt" "$expected" <<'PY_APP'
import os, pathlib, plistlib, re, sys
app, expected = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    bundle = info.get("CFBundleIdentifier", "")
    if not bundle.startswith("com.cmuxterm.app.debug.") or bundle == "com.cmuxterm.app.debug.":
        raise ValueError("app= requires a dedicated tagged DEV bundle")
    executable = info.get("CFBundleExecutable", "")
    if not executable or pathlib.Path(executable).name != executable or not os.access(app / "Contents/MacOS" / executable, os.X_OK):
        raise ValueError("prebuilt app executable is missing")
    commit = info.get("CMUXCommit", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or info.get("CMUXCommitDirty", False):
        raise ValueError("prebuilt app needs a clean full CMUXCommit")
    if expected != "nightly" and commit != expected:
        raise ValueError(f"prebuilt app commit {commit} does not match build={expected}")
except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
    sys.exit(f"prebuilt app: {error}")
print(commit)
PY_APP
)" || return 3
    APP_ARGS=(--app "$prebuilt")
    APP_LABEL="prebuilt $commit"
    echo "$prefix prebuilt $commit $prebuilt"
    return 0
  fi
  if [[ "$build" == nightly ]]; then
    if [[ -z "$dmg" ]]; then
      dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors --connect-timeout 20 -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
        | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    fi
    [[ "$dmg" == https://* ]] || { echo "$prefix no nightly DMG in the feed"; return 3; }
    echo "$prefix dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-tab-switch/1 -o "$tmp/in.dmg" "$dmg" || { echo "$prefix download failed"; return 3; }
    APP_LABEL="nightly $(basename "$dmg" .dmg)"
    APP_ARGS=(--dmg "$tmp/in.dmg")
    source scripts/ci/lib/signing-runtime-guard.sh
    cmux_signing_runtime_guard || return 3
  else
    local src="$root"
    if [[ "$build" != head && "$build" != "$(git rev-parse HEAD)" ]]; then
      # The warm checkout has no origin: the commit comes from the explicit URL. Never into submodules: a warm
      # checkout whose ghostty an earlier build populated made git fetch ghostty's new pointer too, which GitHub
      # refuses ("upload-pack: not our ref"), so every step on two display Macs exited 3 (2026-11-16).
      git cat-file -e "$build^{commit}" 2>/dev/null \
        || git -c submodule.recurse=false fetch --quiet --no-recurse-submodules https://github.com/manaflow-ai/cmux.git "$build" \
        || { echo "$prefix cannot fetch $build" >&2; return 3; }
      src="$tmp/src"
      git -c submodule.recurse=false worktree add --quiet --detach "$src" "$build" || return 3
    fi
    require_submodule_refs "$src" "$tmp" "$prefix" || return 3
    APP_LABEL="$(git -C "$src" rev-parse HEAD)" || return 3
    local configuration=(--release)
    [[ "$config" == bench ]] && configuration=(--config bench)
    # A failed or stopped build falls through to the app path check below, which says why.
    tsw_step "$prefix" app-build "$TSW_BUILD_MAX" "$tmp/build.log" -- \
      tsw_build_app "$src" "$tmp" "$tag" "${configuration[@]}" || true
    local app
    app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$tmp/build.log" | tail -n 1)"
    if [[ -z "$app" || ! -d "$app" ]]; then
      echo "$prefix build failed: no app path"
      grep -E "error:|BUILD FAILED" "$tmp/build.log" | head -n 60 || true
      tail -n 30 "$tmp/build.log"
      return 3
    fi
    echo "$prefix built $APP_LABEL $app"
    APP_ARGS=(--app "$app")
  fi
}

frames_main() {
  local build=nightly rounds=5 load=idle,cpu,agents scenarios="" gate=1 turns=200 agents=4 dmg="" config=release arg
  local record="" rows="" scale=none launch_record="" chat_perf=0 app=""
  for arg in "$@"; do
    case "$arg" in
      build=*) build="${arg#build=}" ;;
      app=*) app="${arg#app=}"; [[ -n "$app" ]] || { echo "tab-switch: app= takes a bundle path" >&2; exit 2; } ;;
      rounds=*) rounds="${arg#rounds=}" ;;
      load=*) load="${arg#load=}" ;;
      scenarios=*) scenarios="${arg#scenarios=}" ;;
      gate=0|gate=1) gate="${arg#gate=}" ;;
      turns=*) turns="${arg#turns=}" ;;
      agents=*) agents="${arg#agents=}" ;;
      dmg=https://*) dmg="${arg#dmg=}" ;;
      config=release|config=bench) config="${arg#config=}" ;;
      record=*) record="${arg#record=}" ;;
      rows=*) rows="${arg#rows=}" ;;
      scale=*) scale="${arg#scale=}" ;;
      launch_record=*) launch_record="${arg#launch_record=}" ;;
      chat_perf=0|chat_perf=1) chat_perf="${arg#chat_perf=}" ;;
      *) echo "tab-switch: unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "tab-switch: rounds= takes 1 to 20" >&2; exit 2; }
  [[ "$turns" =~ ^[0-9]+$ && "$agents" =~ ^[0-9]+$ ]] || { echo "tab-switch: turns= and agents= take numbers" >&2; exit 2; }
  [[ -z "$record" || "$record" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "tab-switch: record= takes seconds" >&2; exit 2; }
  [[ -z "$rows" || "$rows" =~ ^[0-9]+$ ]] || { echo "tab-switch: rows= takes a number" >&2; exit 2; }
  [[ "$scale" =~ ^(none|leo|[0-9]+x[0-9]+)$ ]] || { echo "tab-switch: scale= is none, leo or SESSIONSxWORKSPACES" >&2; exit 2; }
  [[ -z "$launch_record" || "$launch_record" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "tab-switch: launch_record= takes seconds" >&2; exit 2; }
  [[ "$load" =~ ^[A-Za-z0-9+,-]+$ && "$scenarios" =~ ^[a-z0-9,-]*$ ]] || { echo "tab-switch: load= and scenarios= take names" >&2; exit 2; }
  [[ "$build" == nightly || "$build" == head || "$build" =~ ^[0-9a-f]{40}$ ]] || { echo "tab-switch: build= is nightly, head or a 40-hex commit" >&2; exit 2; }
  if [[ -n "$app" ]]; then
    app_under_test "$build" "$config" "$dmg" "" "$PWD" tabswitch TSW "$app" || exit 3
  elif [[ "$build" != nightly ]]; then
    require_cef_read_credentials
  fi
  local root="$PWD" out="$PWD/.build/tab-switch" tmp
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  tmp="$(mktemp -d)"
  # Every exit (a failed build, a missing tool, a TERM) removes this folder and the worktree in it: the build
  # holds 13 to 18 GB, and leaked ones filled a bench Mac's disk. By its own path, never by name or glob.
  TSW_ROOT="$root" TSW_TMP="$tmp"
  trap 'git -C "$TSW_ROOT" worktree remove --force "$TSW_TMP/src" >/dev/null 2>&1 || true; rm -rf -- "$TSW_TMP"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  chmod 0755 "$tmp" # the harness runs as the console user (console-session.sh): it reads the tools and the DMG here
  echo "TSW host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) load=\"$(sysctl -n vm.loadavg)\""
  # The pixels come from CuaDriver, the recorder the fleet grants Screen Recording to (a binary compiled here never holds
  # that grant); the marker and the decoder below need none.
  [ -x /Applications/CuaDriver.app/Contents/MacOS/cua-driver ] || { echo "TSW no CuaDriver on this Mac: cannot record"; exit 3; }
  # Before the build, as the console user the harness records as: a Mac whose CuaDriver cannot start or has no Screen
  # Recording grant exits 3 in seconds, not after an hour-long build on an exclusive display worker (2026-11-16:
  # three display Macs built every pull request's app, then died in cua-driver's `initialize`).
  GITHUB_WORKSPACE="$root" tsw_step TSW preflight "$TSW_PREFLIGHT_MAX" "$tmp/preflight.log" --stream -- \
    scripts/ci/frame-pacing/console-session.sh python3 -I "$root/scripts/cmux-next/tab_switch_capture.py" preflight || exit 3
  tsw_step TSW tools-compile "$TSW_TOOLS_MAX" "$tmp/tools.log" -- \
    swiftc -O -o "$tmp/tab-switch-tools" scripts/measure/tab-switch-frames/tools.swift || tail -n 40 "$tmp/tools.log"
  [ -x "$tmp/tab-switch-tools" ] || { echo "TSW the marker and decoder did not compile"; exit 3; }
  if [[ "$scale" != none ]]; then
    # The settle matrix's daemon home at scale is written by acpmux's own store (god_fixture::write_scale_home), so
    # the seeder is built from this checkout's cmux-tui; its target folder stays warm between steps.
    local account_home
    account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    PATH="${account_home:+$account_home/.cargo/bin:}$PATH" tsw_step TSW seeder-build "$TSW_SEEDER_MAX" "$tmp/seeder.log" -- \
      tsw_build_seeder || { echo "TSW the scale seeder did not build"; tail -n 30 "$tmp/seeder.log"; exit 3; }
    cp "${CARGO_TARGET_DIR:-$root/cmux-tui/target}/release/examples/scale_home" "$tmp/scale_home" && chmod 0755 "$tmp/scale_home"
  fi
  if [[ -z "$app" ]]; then
    app_under_test "$build" "$config" "$dmg" "$tmp" "$root" tabswitch TSW || exit 3
  fi
  local app_args=(${APP_ARGS[@]+"${APP_ARGS[@]}"}) label="$APP_LABEL"
  local gate_args=()
  [[ "$gate" == 0 ]] && gate_args=(--no-gate)
  local scenario_args=()
  [[ -n "$scenarios" ]] && scenario_args=(--scenarios "$scenarios")
  [[ -n "$record" ]] && scenario_args+=(--record "$record")
  [[ -n "$rows" ]] && scenario_args+=(--chat-rows "$rows")
  [[ "$scale" != none ]] && scenario_args+=(--scale "$scale" --seeder "$tmp/scale_home")
  [[ -n "$launch_record" ]] && scenario_args+=(--launch-record "$launch_record")
  [[ "$chat_perf" == 1 ]] && scenario_args+=(--chat-perf)
  local rc=0
  set +e
  GITHUB_WORKSPACE="$root" tsw_step TSW bench "$TSW_RUN_MAX" "$out/run.log" --stream -- \
    scripts/ci/frame-pacing/console-session.sh python3 -I "$root/scripts/cmux-next/bench_tab_switch.py" \
    --frames "${app_args[@]}" --build "$label" --tools "$tmp/tab-switch-tools" --rounds "$rounds" --loads "$load" \
    --chat-turns "$turns" --agents "$agents" --out "$out" ${scenario_args[@]+"${scenario_args[@]}"} \
    ${gate_args[@]+"${gate_args[@]}"}
  rc=$?
  set -e
  [[ -d "$tmp/src" ]] && git worktree remove --force "$tmp/src" >/dev/null 2>&1
  rm -f "$tmp/in.dmg"
  tar -czf "$tmp/report.tgz" -C "$out" . 2>/dev/null && mv "$tmp/report.tgz" "$out/report.tgz"
  rm -rf "$tmp"
  exit "$rc"
}

# Sourced (launch-capture-probe.sh): the functions only.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

if [[ "${1:-}" =~ ^(app|build|rounds|load|scenarios|gate|turns|agents|dmg|config|record|rows)= ]]; then
  frames_main "$@"
fi

require_cef_read_credentials
tag="tabswitch"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
require_submodule_refs "$PWD" "$out" || exit 3
prepare_build "$out"
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "tab-switch: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
python3 scripts/cmux-next/tab-switch-stages.py --tag "$tag" --app "$app" --out "$out" "$@"
