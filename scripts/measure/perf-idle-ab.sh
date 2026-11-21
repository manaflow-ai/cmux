#!/usr/bin/env bash
# Idle A/B in ONE measure step: the base commit's app and the head commit's app, each built once (a tagged
# bench build, as perf-10x-idle.sh makes), then launched at rest in interleaved rounds (base, head, head,
# base, ...) on the same worker, so both arms see the same host state and one step holds the bench Mac.
#   cmux-ci run --class exclusive --measurement --label measure --label bench --target-worker cmux20-bench \
#     --script scripts/measure/perf-idle-ab.sh --ref <this script's sha> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=5] [--arg=chats=0,1,10] [--arg=measure=60] \
#     [--arg=trace=10] [--arg=kinds=app,cef-gpu] [--arg=cells=1:small:rest,1:none:rest] [--arg=unfocused=300] \
#     [--arg=relaunch=1] [--arg=env=NAME=VALUE] \
#     --artifact .build/perf-idle-ab/report.tgz --timeout 14400
#   base=SHA, head=SHA  the two commits (40 hex)
#   rounds=N            launches per arm and chat count (default 5, at most 8)
#   chats=0,1,10        idle chat counts: 0 is one terminal workspace (no chat); N is N agent chats on the
#                       acpmux test agent, each answered once, plus the launch workspace (no chat)
#   measure=S           seconds of each idle window (default 60)
#   trace=S             seconds of System Trace per attributed process after each window: each thread's
#                       wakeups per second with its name (bench_memory.py --attribute-trace); 0 for none
#   kinds=K,K           the process kinds to attribute (default app,cef-gpu)
#   settings_open=N     after the idle rounds, N launches per arm of bench-settings-open.py (Cmd-, 4 times, the first
#                       cold) on the same builds; prints IDLE-AB settings-open <arm> cold_median .. warm_p90 .. (0: none)
#   relaunch=1          chats=0: the terminal launch is a returning user's (bench_memory.py --relaunch-restored):
#                       one terminal workspace opened and shown, the app quit (the session saves), what outlived
#                       the quit ended, and the app relaunched into the same scratch, checked to show that
#                       workspace and not Home; that relaunch is settled and sampled. A plain launch shows Home
#                       (FirstWorkspace.swift). relaunch=warm keeps what outlived the quit; 0 (default) is as before.
#   env=NAME=VALUE      an environment variable for both arms' app (repeatable; chats=, cells= and home=1 runs), e.g.
#                       env=CMUX_NEXT_CHIEF_START=visible: a base that does not read it ignores it
#   cells=C,C           in the place of chats= (the two together are refused): each cell is CHATS:REPOSITORY:MOTION, one launch for each arm and
#                       round. CHATS agent chats at rest (1 or more); REPOSITORY small or large is a visible
#                       diff tab on a repository of that size with uncommitted changes (bench_memory.py
#                       --diff-tab, diff_tab_cells.py), none is no diff tab; MOTION rest, or scroll (wheel
#                       events on the diff page for the whole window). Each cell also reads the CPU of the
#                       children that ended in the window (--child-time: the daemon's git runs; the whole
#                       CPU of each such child, also its part from before the window). A none cell is a
#                       control of the same chats with no diff tab and no repository of the tool: it
#                       differs from a diff cell by the tab, its repository and the page's reads.
#   unfocused=S         cells=: the window of a diff tab whose page does not say that it has the focus
#                       (default 300; its timer is then 30 s, not 4 s). measure=S is its window with the focus.
#                       With cells=, measure= is a multiple of 4 and unfocused= a multiple of 30 (the page's
#                       2 timers), so each window holds a whole count of reads.
#   home=1              after each arm's idle launches of a round, one more fresh launch of that arm
#                       (scripts/cmux-next/chief-start-probe.py): at rest, whether the Chief's brain host runs and
#                       which Home view asked for it; then Home's first open and the first Chief reply after it.
#                       Prints IDLE-AB home <arm> <round> ... and IDLE-AB home median <metric> base ... head ...
# The harness (bench_memory.py, thread_wakes.py, tag_teardown.py, the test agent) is this script's checkout's,
# copied before the arms are checked out, so a base that predates it runs the same harness.
# Each arm is built in this checkout (its warm DerivedData, so the second arm builds incrementally), the
# checkout is put back at this script's commit at the end, and the tagged apps, their daemons and every
# temporary folder are removed on exit, also on a cancel (TERM). Prints:
#   IDLE-AB run <arm> <round> chats <N> kind <K> wakeups_per_s <w> cpu_pct <c>
#   IDLE-AB median chats <N> kind <K> base <med> [<min>-<max>] head <med> [<min>-<max>] delta <d>
#   IDLE-AB thread chats <N> kind <K> name '<thread>' base <med> head <med> delta <d>   (wakeups/s by thread)
#   IDLE-AB footprint chats <N> kind <K> base <med> [<min>-<max>] n <n> head <med> [<min>-<max>] n <n> delta <d>
#       (MB of the kind's processes in each idle window, a run without the kind counting 0; kind `total`
#       is every process; `present` is in how many runs of each arm the kind ran)
# With cells= the word `chats <N>` of these lines is `cell <C>`, and it also prints:
#   IDLE-AB window <arm> <round> cell <C> measure_s <s> focus <True|False|None> focus_after <True|False|None>
#       reads_expected <n> scroll_events <e> scroll_errors <e>
#   IDLE-AB child_time_check <arm> <round> cell <C> ok <True|False> seen_ms <ms>
#   IDLE-AB cpu cell <C> kind <K> base <med> [<min>-<max>] n <n> head <med> [<min>-<max>] n <n> delta <d>
#       (CPU % of the kind's processes; the kind `children:<K>` is the CPU % of that kind's children that
#       ended in the window; the kind `total` is the sum of each kind and of each kind's children)
#   IDLE-AB fault cell <C> <what>     a cell whose medians are not to be read; the verdict is then exit 1:
#       the run's own check of the child time read failed (no children CPU is written then); the page's
#       focus was not the same in each run of the cell, before and after the window (one median would
#       mix the 4 s and the 30 s timer); a scroll cell sent less than half of its wheel events, or one
#       failed. The tool does not read where the page is: sent events are not proof of a moved page.
# With cells= the first part is the unit test of the diff tab cells and of the summary below
# (scripts/cmux-next/tests/test_diff_tab_cells.py, at this script's commit): a red ends the step before an arm
# is built. A run with no cells= does not run it and is as before.
# The verdict: exit 0 every run passed, 1 a run failed or a cell has a fault, 3 an arm could not be built,
# 4 the unit test is red.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
own_sha="$(git rev-parse HEAD)"
base="" head="" rounds=5 chats="0,1,10" measure=60 trace=10 kinds="app,cef-gpu" cells="" unfocused=300 settings_open=0 chats_given=false home=0
relaunch=0 app_env=()
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    chats=*) chats="${arg#chats=}"; chats_given=true ;;
    measure=*) measure="${arg#measure=}" ;;
    trace=*) trace="${arg#trace=}" ;;
    kinds=*) kinds="${arg#kinds=}" ;;
    cells=*) cells="${arg#cells=}" ;;
    unfocused=*) unfocused="${arg#unfocused=}" ;;
    settings_open=*) settings_open="${arg#settings_open=}" ;;
    home=*) home="${arg#home=}" ;;
    relaunch=*) relaunch="${arg#relaunch=}" ;;
    env=*) app_env+=(--env "${arg#env=}") ;;
    *) echo "perf-idle-ab.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 8 )) || { echo "rounds= must be 1 to 8" >&2; exit 2; }
[[ "$chats" =~ ^[0-9]+(,[0-9]+)*$ && "$measure" =~ ^[0-9]+$ && "$trace" =~ ^[0-9]+$ ]] || { echo "bad chats=, measure= or trace=" >&2; exit 2; }
cell_form='[1-9][0-9]*:(none:rest|(small|large):(rest|scroll))'
[[ -z "$cells" || "$cells" =~ ^$cell_form(,$cell_form)*$ ]] || { echo "cells= must be CHATS:none:rest or CHATS:small|large:rest|scroll, joined by commas" >&2; exit 2; }
[[ "$unfocused" =~ ^[0-9]+$ ]] || { echo "bad unfocused=" >&2; exit 2; }
[[ "$relaunch" =~ ^(0|1|cold|warm)$ ]] || { echo "relaunch= must be 0, 1 (cold) or warm" >&2; exit 2; }
for ((k = 1; k < ${#app_env[@]}; k += 2)); do
  [[ "${app_env[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "env= must be NAME=VALUE" >&2; exit 2; }
done
relaunch_args=()
case "$relaunch" in 1|cold) relaunch_args=(--relaunch-restored cold) ;; warm) relaunch_args=(--relaunch-restored warm) ;; esac
# relaunch= changes only the terminal launch (chats= with 0): refuse it where it would be silently ignored.
if [ "$relaunch" != 0 ] && { [ -n "$cells" ] || ! [[ ",$chats," == *",0,"* ]]; }; then
  echo "relaunch= needs chats= with 0 and no cells= (it changes only the terminal launch)" >&2; exit 2
fi
if [ -n "$cells" ]; then
  $chats_given && { echo "cells= is in the place of chats=: give one of the two" >&2; exit 2; }
  (( measure >= 4 && measure % 4 == 0 && unfocused >= 30 && unfocused % 30 == 0 )) || {
    echo "with cells=, measure= must be a multiple of 4 and unfocused= a multiple of 30" >&2; exit 2; }
  if ! python3 -I scripts/cmux-next/tests/test_diff_tab_cells.py; then
    echo "perf-idle-ab: the unit test of the tool is red: no arm is built" >&2
    exit 4
  fi
  echo "IDLE-AB unit test passed"
fi
disk() { echo "IDLE-AB disk $1 $(df -h "$here" | tail -n 1)"; }
disk start
out="$here/.build/perf-idle-ab"
rm -rf "$out" && mkdir -p "$out/runs" "$out/harness"
for f in scripts/cmux-next/bench_memory.py scripts/cmux-next/thread_wakes.py scripts/cmux-next/diff_tab_cells.py \
         scripts/cmux-next/tag_teardown.py scripts/cmux-next/chief-start-probe.py \
         cmux-tui/crates/acpmux/tests/fake_agent.py; do
  cp "$f" "$out/harness/" || { echo "perf-idle-ab: no $f in this checkout" >&2; exit 3; }
done
harness="$out/harness"
[[ "$settings_open" =~ ^[0-9]+$ ]] && (( settings_open <= 10 )) || { echo "settings_open= must be 0 to 10" >&2; exit 2; }
if (( settings_open )); then
  # bench-settings-open.py and the modules it loads from its own folder (bench-stalls, bench-startup and theirs).
  mkdir -p "$harness/next" && cp scripts/cmux-next/*.py "$harness/next/" || { echo "perf-idle-ab: no scripts/cmux-next" >&2; exit 3; }
fi
app_base="" app_head=""
scratch=""
app_of() { if [ "$1" = base ]; then echo "$app_base"; else echo "$app_head"; fi; }
cleanup() {
  for arm in base head; do
    a="$(app_of "$arm")"
    [ -n "$a" ] && [ -d "$a" ] && { python3 "$harness/tag_teardown.py" "$a" >/dev/null 2>&1; rm -rf "$a"; }
  done
  [ -n "$scratch" ] && rm -rf "$scratch"
  # Back to this script's commit, so the warm checkout is left as the step found it.
  git -C "$here" checkout --quiet --detach -f "$own_sha" >/dev/null 2>&1
  git -C "$here" submodule update --quiet --init --depth 1 ghostty ghostty-next >/dev/null 2>&1
  disk end
}
# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
trap cleanup EXIT
scratch="$(mktemp -d)"

# The account's tools, after the step's own: steps run with a per-step HOME, and the worker puts its pinned
# bun first on PATH, which an older ~/.bun/bin must not shadow (webviews refuses bun under its devEngines pin).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$PATH:$tool_dir"
done
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi

build_arm() {  # build_arm ARM SHA: checks the commit out here and builds its tagged bench app
  local arm="$1" sha="$2" log="$out/build-$1.log"
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    local depth=() remote
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$sha" 2>/dev/null && break
    done
  fi
  git checkout --quiet --detach -f "$sha" || return 3
  local ghostty_before
  ghostty_before="$(cat GhosttyKit.xcframework/.cmux-ghostty-sha 2>/dev/null || true)"
  for sub in ghostty ghostty-next; do
    git submodule update --quiet --init --depth 1 "$sub" || return 3
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ] || [ "$ghostty_before" != "$(git rev-parse HEAD:ghostty)" ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh || return 3
    git rev-parse HEAD:ghostty > GhosttyKit.xcframework/.cmux-ghostty-sha
  fi
  # A PR head's cmux-tui tree is never published: build the client set here (as fresh-home-launch.sh).
  local client_local=""
  if ! ./scripts/cmux-next/pin-cmux-tui.sh probe 2>/dev/null | grep -q ': ready ('; then
    echo "IDLE-AB $arm: cmux-tui tree not published, building the client set on this host"
    export CMUX_TUI_CLIENT_TARGET_DIR="${CI_SHARED_CACHE_DIR:-/Users/Shared/cmux-build-fleet/cache}/perf-idle-ab/cmux-tui-target"
    mkdir -p "$CMUX_TUI_CLIENT_TARGET_DIR" cmux-tui/target
    client_local="$(CI=1 ./scripts/cmux-next/build-cmux-tui-client.sh --print-path 2> >(tee "$out/cmux-tui-$arm.log" >&2))" || return 3
  fi
  # Its progress goes to the step's log as well: a silent step looks hung.
  if [ -n "$client_local" ]; then export CMUX_TUI_CLIENT_LOCAL="$client_local"; else unset CMUX_TUI_CLIENT_LOCAL; fi
  # The web bundles need the bun this commit's webviews/package.json pins; a host's ~/.bun may hold another.
  # Each arm gets its own checked copy, first on PATH (as action-signposts.sh and cef-helpers.sh).
  RUNNER_TEMP="$scratch" GITHUB_PATH="$scratch/bun-path-$arm" ./scripts/cmux-next/private-bun.sh || return 3
  local bun_path
  bun_path="$(tail -n 1 "$scratch/bun-path-$arm")"
  CMUX_DEV_BACKEND_MODE=local PATH="$bun_path:$PATH" \
    ./scripts/reload.sh --tag "idleab-$arm" --config bench --no-global-cli-links 2>&1 | tee "$log" | grep -E '^(==>|error:|App path)' || true
  local app
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$log" | tail -n 1)"
  [[ -n "$app" && -d "$app" ]] || { echo "IDLE-AB $arm: no app path" >&2; grep -E "error:|BUILD FAILED" "$log" | head -n 40 >&2; return 3; }
  eval "app_$arm=\"\$app\""
  echo "IDLE-AB built $arm $sha $app"
}
build_arm base "$base" || exit 3
build_arm head "$head" || exit 3
disk built

IFS=, read -r -a chat_counts <<< "$chats"
agent_counts=""
terminal=false
for n in "${chat_counts[@]}"; do
  # bench_memory counts workspaces, and the launch workspace has no chat: N chats is N+1 workspaces.
  if [ "$n" = 0 ]; then terminal=true; else agent_counts="${agent_counts:+$agent_counts,}$((n + 1))"; fi
done
cell_list=()
if [ -n "$cells" ]; then
  # cells= is in the place of chats=: each launch is one cell.
  IFS=, read -r -a cell_list <<< "$cells"
  terminal=false agent_counts=""
fi
attribute=(--attribute --attribute-kinds "$kinds" --attribute-trace "$trace")
status=0
run_arm() {  # run_arm ARM ROUND
  local arm="$1" i="$2" app rc
  app="$(app_of "$1")"
  echo "IDLE-AB round $i $arm load $(uptime | sed 's/.*load averages*: //')"
  if $terminal; then
    python3 "$harness/bench_memory.py" --app "$app" --workspaces 1 --mix terminal --settle 20 --measure "$measure" \
      --top 8 "${attribute[@]}" ${relaunch_args[@]+"${relaunch_args[@]}"} ${app_env[@]+"${app_env[@]}"} \
      --out "$out/runs/$arm-$i-terminal.json" > "$out/runs/$arm-$i-terminal.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-terminal.log"; }
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  fi
  if [ -n "$agent_counts" ]; then
    python3 "$harness/bench_memory.py" --app "$app" --workspaces "$agent_counts" --mix terminal+chat \
      --fake-agent "$harness/fake_agent.py" --settle 20 --measure "$measure" --top 8 "${attribute[@]}" \
      ${app_env[@]+"${app_env[@]}"} --out "$out/runs/$arm-$i-agents.json" > "$out/runs/$arm-$i-agents.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-agents.log"; }
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  fi
  local cell k=0 n size motion extra
  for cell in ${cell_list[@]+"${cell_list[@]}"}; do
    k=$((k + 1))
    IFS=: read -r n size motion <<< "$cell"
    extra=(--child-time --diff-unfocused-measure "$unfocused")
    [ "$size" != none ] && extra+=(--diff-tab "$size")
    [ "$motion" = scroll ] && extra+=(--diff-scroll)
    # N chats is N+1 workspaces, as above; the diff tab opens in the workspace that is shown last.
    python3 "$harness/bench_memory.py" --app "$app" --workspaces "$((n + 1))" --mix terminal+chat \
      --fake-agent "$harness/fake_agent.py" --settle 20 --measure "$measure" --top 8 "${attribute[@]}" "${extra[@]}" \
      ${app_env[@]+"${app_env[@]}"} \
      --out "$out/runs/$arm-$i-cell$k.json" > "$out/runs/$arm-$i-cell$k.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-cell$k.log"; }
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  done
  if [ "$home" = 1 ]; then
    # Not a .json: the summary below reads every runs/*.json as a bench_memory report.
    python3 "$harness/chief-start-probe.py" --app "$app" ${app_env[@]+"${app_env[@]}"} --out "$out/runs/$arm-$i-home.probe" > "$out/runs/$arm-$i-home.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-home.log"; }
    grep -h '^CHIEF-START ' "$out/runs/$arm-$i-home.log" | sed "s/^CHIEF-START /IDLE-AB home $arm $i /"
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  fi
  grep -h '^PERF-ATTR .* wakes ' "$out/runs/$arm-$i-"*.log 2>/dev/null | head -n 80 | sed "s/^/IDLE-AB $arm $i /"
}
for i in $(seq 1 "$rounds"); do
  # ABBA order: a drift across the step falls on both arms alike.
  if (( i % 2 )); then run_arm base "$i"; run_arm head "$i"; else run_arm head "$i"; run_arm base "$i"; fi
done

if (( settings_open )); then
  # Cmd-, on the same builds and host as the idle RAM: settings_open= launches per arm, interleaved by the bench
  # (base, head, base, ...), 4 opens each; the first open of a launch is cold, the others warm.
  echo "IDLE-AB settings-open load $(uptime | sed 's/.*load averages*: //')"
  python3 "$harness/next/bench-settings-open.py" --app "$app_base" --app "$app_head" --runs "$settings_open" \
    --json "$out/settings-open.json" > "$out/settings-open.log" 2>&1 || status=1
  sed 's/^/IDLE-AB settings-open /' "$out/settings-open.log"
  python3 -I - "$out/settings-open.json" "$(basename "$app_base")" "$(basename "$app_head")" <<'PY' || status=1
import json, statistics, sys
data = json.load(open(sys.argv[1]))
def tag(name):
    return name.removeprefix("cmux DEV ").removesuffix(".app").lower()
def p90(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(0.9 * (len(xs) - 1))))] if xs else None
for arm, name in (("base", sys.argv[2]), ("head", sys.argv[3])):
    runs = data.get(tag(name), [])
    cold = [r[0]["visible_ms"] for r in runs if r and not r[0].get("already_open") and r[0].get("visible_ms") is not None]
    warm = [o["visible_ms"] for r in runs for o in r[1:] if not o.get("already_open") and o.get("visible_ms") is not None]
    claims = sorted({str(o.get("claim")) for r in runs for o in r})
    print(f"IDLE-AB settings-open {arm} cold_median {statistics.median(cold) if cold else None} cold_max {max(cold) if cold else None} "
          f"n {len(cold)} warm_median {statistics.median(warm) if warm else None} warm_p90 {p90(warm)} n {len(warm)} claims {claims}")
PY
fi

python3 -I - "$out/runs" "$rounds" "$cells" <<'PY' || status=1
import collections, glob, json, os, statistics, sys
runs, rounds = sys.argv[1], int(sys.argv[2])
cells = [c for c in sys.argv[3].split(",") if c]
# The group of a sample: its chat count, or with cells= its cell.
word = "cell" if cells else "chats"
cpu = collections.defaultdict(lambda: collections.defaultdict(list))
# values[(chats, kind)][arm] = [wakeups per run]; threads[(chats, kind)][arm][name] = [wakeups/s per run]
values = collections.defaultdict(lambda: collections.defaultdict(list))
threads = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
seen = collections.defaultdict(lambda: collections.defaultdict(int))
# footprints[chats][arm] = [{kind: MB} per run]: a kind absent from a run counts 0 MB there.
footprints = collections.defaultdict(lambda: collections.defaultdict(list))
summary = []
# With cells=: focus[cell] = each (before, after) of its runs; faults = the cells whose medians are not to be read.
focus = collections.defaultdict(set)
faults = []
for path in sorted(glob.glob(os.path.join(runs, "*.json"))):
    arm, i, mode = os.path.basename(path)[:-5].split("-")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    if mode.startswith("cell"):
        cell = cells[int(mode[4:]) - 1]
        check = data.get("child_time_check") or {}
        print(f"IDLE-AB child_time_check {arm} {i} cell {cell} ok {check.get('ok')} seen_ms {check.get('seen_ms')}")
        if check.get("ok") is not True:
            faults.append((cell, f"{arm} {i}: the check of the child time read failed, no children CPU"))
    for s in data.get("samples", []):
        if not s["label"].startswith("idle-") or s["label"] == "idle-launch":
            continue
        # N+1 workspaces, the launch one without a chat (run_arm): N chats.
        chats = 0 if mode == "terminal" else int(s["label"][5:]) - 1
        if mode.startswith("cell"):
            chats = cells[int(mode[4:]) - 1]
            tab = s.get("diff_tab") or {}
            scroll = tab.get("scroll") or {}
            before, after = (tab.get("page") or {}).get("focus"), (tab.get("page_after") or {}).get("focus")
            print(f"IDLE-AB window {arm} {i} cell {chats} measure_s {s.get('measure_s')} focus {before} focus_after {after} "
                  f"reads_expected {tab.get('reads_expected')} scroll_events {scroll.get('events')} scroll_errors {scroll.get('errors')}")
            focus[chats].add((before, after))
            if before != after:
                faults.append((chats, f"{arm} {i}: the focus of the page changed in the window ({before} to {after})"))
            if chats.endswith(":scroll"):
                wanted = (scroll.get("rate_per_s") or 0) * (s.get("measure_s") or 0) / 2
                if not scroll or scroll.get("errors") or not scroll.get("events") or scroll["events"] < wanted:
                    faults.append((chats, f"{arm} {i}: scroll events {scroll.get('events')} errors {scroll.get('errors')}, "
                                          f"at least {int(wanted)} and no error expected"))
            total = 0.0
            for kind, e in s["kinds"].items():
                for name, key in ((kind, "cpu_pct"), (f"children:{kind}", "child_cpu_pct")):
                    if e.get(key) is not None:
                        cpu[(chats, name)][arm].append(e[key])
                        total += e[key]
            cpu[(chats, "total")][arm].append(round(total, 3))
        # Only the footprints the sample measured: one with none (an older sampler) prints no footprint line.
        run = {kind: e["footprint_mb"] or 0.0 for kind, e in s["kinds"].items() if "footprint_mb" in e}
        if "total_footprint_mb" in s:
            run["total"] = s["total_footprint_mb"] or 0.0
        footprints[chats][arm].append(run)
        for kind, e in s["kinds"].items():
            if e.get("wakeups_per_s") is None:
                continue
            values[(chats, kind)][arm].append(e["wakeups_per_s"])
            summary.append({"arm": arm, "round": int(i), word: chats, "kind": kind,
                            "wakeups_per_s": e["wakeups_per_s"], "cpu_pct": e.get("cpu_pct"),
                            **({"child_cpu_pct": e.get("child_cpu_pct")} if cells else {})})
            print(f"IDLE-AB run {arm} {i} {word} {chats} kind {kind} wakeups_per_s {e['wakeups_per_s']} cpu_pct {e.get('cpu_pct')}")
        for key, got in ((s.get("attribution") or {}).get("thread_wakes") or {}).items():
            if got.get("error"):
                continue
            kind = key.rsplit(":", 1)[0]
            per = collections.Counter()
            for row in got["threads"]:
                per[row["label"]] += row["wakes_per_s"]
            seen[(chats, kind)][arm] += 1
            for name, w in per.items():
                threads[(chats, kind)][arm][name].append(w)
def stat(xs, digits=2):
    return (round(statistics.median(xs), digits), round(min(xs), digits), round(max(xs), digits)) if xs else (None, None, None)
for (chats, kind) in sorted(values):
    b, h = stat(values[(chats, kind)]["base"]), stat(values[(chats, kind)]["head"])
    delta = round(h[0] - b[0], 2) if None not in (b[0], h[0]) else None
    print(f"IDLE-AB median {word} {chats} kind {kind} base {b[0]} [{b[1]}-{b[2]}] n {len(values[(chats, kind)]['base'])} "
          f"head {h[0]} [{h[1]}-{h[2]}] n {len(values[(chats, kind)]['head'])} delta {delta}")
for chats in sorted(footprints, key=str):
    arms = footprints[chats]
    for kind in sorted({k for arm in arms.values() for run in arm for k in run}):
        got = {arm: [run.get(kind, 0.0) for run in arms[arm]] for arm in ("base", "head")}
        b, h = stat(got["base"], 1), stat(got["head"], 1)
        delta = round(h[0] - b[0], 1) if None not in (b[0], h[0]) else None
        present = {arm: sum(1 for run in arms[arm] if kind in run) for arm in ("base", "head")}
        print(f"IDLE-AB footprint {word} {chats} kind {kind} base {b[0]} [{b[1]}-{b[2]}] n {len(got['base'])} "
              f"head {h[0]} [{h[1]}-{h[2]}] n {len(got['head'])} delta {delta} "
              f"present base {present['base']}/{len(got['base'])} head {present['head']}/{len(got['head'])}")
for (chats, kind) in sorted(threads):
    arms = threads[(chats, kind)]
    rows = []
    for name in set(arms["base"]) | set(arms["head"]):
        # A thread absent from a run woke 0 times in it.
        med = {arm: statistics.median(arms[arm][name] + [0.0] * (seen[(chats, kind)][arm] - len(arms[arm][name])))
               if seen[(chats, kind)][arm] else 0.0 for arm in ("base", "head")}
        rows.append((round(med["head"] - med["base"], 2), name, round(med["base"], 2), round(med["head"], 2)))
    rows.sort(key=lambda r: -abs(r[0]))
    for delta, name, b, h in rows[:15]:
        print(f"IDLE-AB thread {word} {chats} kind {kind} name {name!r} base {b} head {h} delta {delta}")
for (cell, kind) in sorted(cpu):
    # 3 digits: a children CPU of some hundredths of a percent is the thing that a cell measures.
    b, h = stat(cpu[(cell, kind)]["base"], 3), stat(cpu[(cell, kind)]["head"], 3)
    delta = round(h[0] - b[0], 3) if None not in (b[0], h[0]) else None
    print(f"IDLE-AB cpu cell {cell} kind {kind} base {b[0]} [{b[1]}-{b[2]}] n {len(cpu[(cell, kind)]['base'])} "
          f"head {h[0]} [{h[1]}-{h[2]}] n {len(cpu[(cell, kind)]['head'])} delta {delta}")
json.dump(summary, open(os.path.join(os.path.dirname(runs), "summary.json"), "w"), indent=1)
for cell in sorted(focus):
    if len(focus[cell]) > 1:
        faults.append((cell, f"the focus of the page was not the same in each run: {sorted(focus[cell], key=str)}"))
for cell, what in faults:
    print(f"IDLE-AB fault cell {cell} {what}")
sys.exit(1 if faults else 0)
PY
# The memory of each sample (phys_footprint summed over the app's processes, bench_memory's
# total_footprint_mb) and, with home=1, the probe's times: medians per arm.
python3 -I - "$out/runs" <<'PY' || status=1
import collections, glob, json, os, statistics, sys
runs = sys.argv[1]
mem = collections.defaultdict(lambda: collections.defaultdict(list))
for path in sorted(glob.glob(os.path.join(runs, "*.json"))):
    arm, i, mode = os.path.basename(path)[:-5].split("-")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    for s in data.get("samples", []):
        brains = sum(1 for p in s.get("processes", []) if "optchat-chief" in p.get("command", ""))
        print(f"IDLE-AB footprint {arm} {i} {mode} {s['label']} total_mb {s.get('total_footprint_mb')} chief_processes {brains}")
        mem[(mode, s["label"])][arm].append(s.get("total_footprint_mb"))
home = collections.defaultdict(lambda: collections.defaultdict(list))
for path in sorted(glob.glob(os.path.join(runs, "*-home.probe"))):
    arm = os.path.basename(path).split("-")[0]
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    for key in ("home_open_ms", "brain_after_open_ms", "brain_logged_ms", "typing_ms", "first_text_ms", "reply_ms"):
        if data.get(key) is not None:
            home[key][arm].append(data[key])
    home["brain_at_rest"][arm].append(1 if data.get("brain_at_rest") else 0)
def med(xs):
    xs = [x for x in xs if x is not None]
    return f"{round(statistics.median(xs), 1)} [{min(xs)}-{max(xs)}] n {len(xs)}" if xs else "none"
for (mode, label), arms in sorted(mem.items()):
    print(f"IDLE-AB footprint median {mode} {label} base {med(arms['base'])} head {med(arms['head'])}")
for key, arms in home.items():
    print(f"IDLE-AB home median {key} base {med(arms['base'])} head {med(arms['head'])}")
PY
echo "IDLE-AB verdict exit $status base $base head $head rounds $rounds"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" runs summary.json build-base.log build-head.log $( (( settings_open )) && echo settings-open.json settings-open.log) 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
exit $status
