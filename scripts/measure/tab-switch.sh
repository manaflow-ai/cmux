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
#    dmg=https://   one DMG instead of the feed
#    rounds=N       switches per scenario and load (1 to 20, default 5)
#    load=LIST      idle,cpu,agents (default), or the instant-at-any-load modes L0 (idle), L1 (the focused chat
#                   streams 60 chunks/s and 2,000 tool-output lines/s), L2 (10 other chats streaming, 3 in a split
#                   pane), L3 (the focused chat is a 100k-row chat, streaming), L4 (every core pinned), L5 (all of
#                   them plus STRESS: 60 workspaces, 20 printing terminals; run last); also cpu-max, agents-N,
#                   chat-100k, tabs-N, and any of them joined with + (L4+tabs-40)
#    scenarios=LIST chat-long-return,terminal-return,chromium-return,new-tab,close-tab (default), or all: also
#                   webkit-return, new-workspace, switch-workspace, close-workspace, rapid-open-5, rapid-close-3,
#                   open-while-close
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

# Submodules, GhosttyKit and the pinned bun a tagged build needs (a fleet step checks out no submodules).
prepare_build() {
  local tmp="$1"
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

frames_main() {
  local build=nightly rounds=5 load=idle,cpu,agents scenarios="" gate=1 turns=200 agents=4 dmg="" config=release arg
  local record="" rows=""
  for arg in "$@"; do
    case "$arg" in
      build=*) build="${arg#build=}" ;;
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
      *) echo "tab-switch: unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "tab-switch: rounds= takes 1 to 20" >&2; exit 2; }
  [[ "$turns" =~ ^[0-9]+$ && "$agents" =~ ^[0-9]+$ ]] || { echo "tab-switch: turns= and agents= take numbers" >&2; exit 2; }
  [[ -z "$record" || "$record" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "tab-switch: record= takes seconds" >&2; exit 2; }
  [[ -z "$rows" || "$rows" =~ ^[0-9]+$ ]] || { echo "tab-switch: rows= takes a number" >&2; exit 2; }
  [[ "$load" =~ ^[A-Za-z0-9+,-]+$ && "$scenarios" =~ ^[a-z0-9,-]*$ ]] || { echo "tab-switch: load= and scenarios= take names" >&2; exit 2; }
  [[ "$build" == nightly || "$build" == head || "$build" =~ ^[0-9a-f]{40}$ ]] || { echo "tab-switch: build= is nightly, head or a 40-hex commit" >&2; exit 2; }
  [[ "$build" == nightly ]] || require_cef_read_credentials
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
  swiftc -O -o "$tmp/tab-switch-tools" scripts/measure/tab-switch-frames/tools.swift 2>&1 | tail -n 40 || true
  [ -x "$tmp/tab-switch-tools" ] || { echo "TSW the marker and decoder did not compile"; exit 3; }
  local app_args=() label=""
  if [[ "$build" == nightly ]]; then
    if [[ -z "$dmg" ]]; then
      dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors --connect-timeout 20 -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
        | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    fi
    [[ "$dmg" == https://* ]] || { echo "TSW no nightly DMG in the feed"; exit 3; }
    echo "TSW dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-tab-switch/1 -o "$tmp/in.dmg" "$dmg" || { echo "TSW download failed"; exit 3; }
    label="nightly $(basename "$dmg" .dmg)"
    app_args=(--dmg "$tmp/in.dmg")
    source scripts/ci/lib/signing-runtime-guard.sh
    cmux_signing_runtime_guard || exit 3
  else
    local src="$root"
    if [[ "$build" != head && "$build" != "$(git rev-parse HEAD)" ]]; then
      # The warm checkout has no origin: the commit comes from the explicit URL.
      git cat-file -e "$build^{commit}" 2>/dev/null \
        || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$build" \
        || { echo "TSW cannot fetch $build" >&2; exit 3; }
      src="$tmp/src"
      git worktree add --quiet --detach "$src" "$build" || exit 3
    fi
    label="$(git -C "$src" rev-parse HEAD)"
    local configuration=(--release)
    [[ "$config" == bench ]] && configuration=(--config bench)
    (cd "$src" && prepare_build "$tmp" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag tabswitch \
      --no-global-cli-links "${configuration[@]}") >"$tmp/build.log" 2>&1 || true
    local app
    app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$tmp/build.log" | tail -n 1)"
    if [[ -z "$app" || ! -d "$app" ]]; then
      echo "TSW build failed: no app path"
      grep -E "error:|BUILD FAILED" "$tmp/build.log" | head -n 60 || true
      tail -n 30 "$tmp/build.log"
      exit 3
    fi
    echo "TSW built $label $app"
    app_args=(--app "$app")
  fi
  local gate_args=()
  [[ "$gate" == 0 ]] && gate_args=(--no-gate)
  local scenario_args=()
  [[ -n "$scenarios" ]] && scenario_args=(--scenarios "$scenarios")
  [[ -n "$record" ]] && scenario_args+=(--record "$record")
  [[ -n "$rows" ]] && scenario_args+=(--chat-rows "$rows")
  local rc=0
  set +e
  GITHUB_WORKSPACE="$root" scripts/ci/frame-pacing/console-session.sh python3 -I "$root/scripts/cmux-next/bench_tab_switch.py" \
    --frames "${app_args[@]}" --build "$label" --tools "$tmp/tab-switch-tools" --rounds "$rounds" --loads "$load" \
    --chat-turns "$turns" --agents "$agents" --out "$out" ${scenario_args[@]+"${scenario_args[@]}"} \
    ${gate_args[@]+"${gate_args[@]}"} 2>&1 | tee "$out/run.log"
  rc=${PIPESTATUS[0]}
  set -e
  [[ -d "$tmp/src" ]] && git worktree remove --force "$tmp/src" >/dev/null 2>&1
  rm -f "$tmp/in.dmg"
  tar -czf "$tmp/report.tgz" -C "$out" . 2>/dev/null && mv "$tmp/report.tgz" "$out/report.tgz"
  rm -rf "$tmp"
  exit "$rc"
}

if [[ "${1:-}" =~ ^(build|rounds|load|scenarios|gate|turns|agents|dmg|config|record|rows)= ]]; then
  frames_main "$@"
fi

require_cef_read_credentials
tag="tabswitch"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'rm -rf -- "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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
