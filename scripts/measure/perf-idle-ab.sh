#!/usr/bin/env bash
# Idle A/B in ONE measure step: the base commit's app and the head commit's app, each built once (a tagged
# bench build, as perf-10x-idle.sh makes), then launched at rest in interleaved rounds (base, head, head,
# base, ...) on the same worker, so both arms see the same host state and one step holds the bench Mac.
#   cmux-ci run --class exclusive --measurement --label measure --label bench --target-worker cmux20-bench \
#     --script scripts/measure/perf-idle-ab.sh --ref <this script's sha> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=5] [--arg=chats=0,1,10] [--arg=measure=60] \
#     [--arg=trace=10] [--arg=kinds=app,cef-gpu] --artifact .build/perf-idle-ab/report.tgz --timeout 14400
#   base=SHA, head=SHA  the two commits (40 hex)
#   rounds=N            launches per arm and chat count (default 5, at most 8)
#   chats=0,1,10        idle chat counts: 0 is one terminal workspace (no chat); N is N agent chats on the
#                       acpmux test agent, each answered once, plus the launch workspace (no chat)
#   measure=S           seconds of each idle window (default 60)
#   trace=S             seconds of System Trace per attributed process after each window: each thread's
#                       wakeups per second with its name (bench_memory.py --attribute-trace); 0 for none
#   kinds=K,K           the process kinds to attribute (default app,cef-gpu)
# The harness (bench_memory.py, thread_wakes.py, tag_teardown.py, the test agent) is this script's checkout's,
# copied before the arms are checked out, so a base that predates it runs the same harness.
# Each arm is built in this checkout (its warm DerivedData, so the second arm builds incrementally), the
# checkout is put back at this script's commit at the end, and the tagged apps, their daemons and every
# temporary folder are removed on exit, also on a cancel (TERM). Prints:
#   IDLE-AB run <arm> <round> chats <N> kind <K> wakeups_per_s <w> cpu_pct <c>
#   IDLE-AB median chats <N> kind <K> base <med> [<min>-<max>] head <med> [<min>-<max>] delta <d>
#   IDLE-AB thread chats <N> kind <K> name '<thread>' base <med> head <med> delta <d>   (wakeups/s by thread)
# The verdict: exit 0 every run passed, 1 a run failed, 3 an arm could not be built.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
own_sha="$(git rev-parse HEAD)"
base="" head="" rounds=5 chats="0,1,10" measure=60 trace=10 kinds="app,cef-gpu"
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    chats=*) chats="${arg#chats=}" ;;
    measure=*) measure="${arg#measure=}" ;;
    trace=*) trace="${arg#trace=}" ;;
    kinds=*) kinds="${arg#kinds=}" ;;
    *) echo "perf-idle-ab.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 8 )) || { echo "rounds= must be 1 to 8" >&2; exit 2; }
[[ "$chats" =~ ^[0-9]+(,[0-9]+)*$ && "$measure" =~ ^[0-9]+$ && "$trace" =~ ^[0-9]+$ ]] || { echo "bad chats=, measure= or trace=" >&2; exit 2; }
disk() { echo "IDLE-AB disk $1 $(df -h "$here" | tail -n 1)"; }
disk start
out="$here/.build/perf-idle-ab"
rm -rf "$out" && mkdir -p "$out/runs" "$out/harness"
for f in scripts/cmux-next/bench_memory.py scripts/cmux-next/thread_wakes.py scripts/cmux-next/tag_teardown.py \
         cmux-tui/crates/acpmux/tests/fake_agent.py; do
  cp "$f" "$out/harness/" || { echo "perf-idle-ab: no $f in this checkout" >&2; exit 3; }
done
harness="$out/harness"
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

# The account's tools: steps run with a per-step HOME (as fresh-home-launch.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
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
  CMUX_DEV_BACKEND_MODE=local \
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
attribute=(--attribute --attribute-kinds "$kinds" --attribute-trace "$trace")
status=0
run_arm() {  # run_arm ARM ROUND
  local arm="$1" i="$2" app rc
  app="$(app_of "$1")"
  echo "IDLE-AB round $i $arm load $(uptime | sed 's/.*load averages*: //')"
  if $terminal; then
    python3 "$harness/bench_memory.py" --app "$app" --workspaces 1 --mix terminal --settle 20 --measure "$measure" \
      --top 8 "${attribute[@]}" --out "$out/runs/$arm-$i-terminal.json" > "$out/runs/$arm-$i-terminal.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-terminal.log"; }
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  fi
  if [ -n "$agent_counts" ]; then
    python3 "$harness/bench_memory.py" --app "$app" --workspaces "$agent_counts" --mix terminal+chat \
      --fake-agent "$harness/fake_agent.py" --settle 20 --measure "$measure" --top 8 "${attribute[@]}" \
      --out "$out/runs/$arm-$i-agents.json" > "$out/runs/$arm-$i-agents.log" 2>&1
    rc=$?; (( rc )) && { status=1; tail -n 30 "$out/runs/$arm-$i-agents.log"; }
    python3 "$harness/tag_teardown.py" "$app" >/dev/null 2>&1
  fi
  grep -h '^PERF-ATTR .* wakes ' "$out/runs/$arm-$i-"*.log 2>/dev/null | head -n 80 | sed "s/^/IDLE-AB $arm $i /"
}
for i in $(seq 1 "$rounds"); do
  # ABBA order: a drift across the step falls on both arms alike.
  if (( i % 2 )); then run_arm base "$i"; run_arm head "$i"; else run_arm head "$i"; run_arm base "$i"; fi
done

python3 -I - "$out/runs" "$rounds" <<'PY' || status=1
import collections, glob, json, os, statistics, sys
runs, rounds = sys.argv[1], int(sys.argv[2])
# values[(chats, kind)][arm] = [wakeups per run]; threads[(chats, kind)][arm][name] = [wakeups/s per run]
values = collections.defaultdict(lambda: collections.defaultdict(list))
threads = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
seen = collections.defaultdict(lambda: collections.defaultdict(int))
summary = []
for path in sorted(glob.glob(os.path.join(runs, "*.json"))):
    arm, i, mode = os.path.basename(path)[:-5].split("-")
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    for s in data.get("samples", []):
        if not s["label"].startswith("idle-") or s["label"] == "idle-launch":
            continue
        # N+1 workspaces, the launch one without a chat (run_arm): N chats.
        chats = 0 if mode == "terminal" else int(s["label"][5:]) - 1
        for kind, e in s["kinds"].items():
            if e.get("wakeups_per_s") is None:
                continue
            values[(chats, kind)][arm].append(e["wakeups_per_s"])
            summary.append({"arm": arm, "round": int(i), "chats": chats, "kind": kind,
                            "wakeups_per_s": e["wakeups_per_s"], "cpu_pct": e.get("cpu_pct")})
            print(f"IDLE-AB run {arm} {i} chats {chats} kind {kind} wakeups_per_s {e['wakeups_per_s']} cpu_pct {e.get('cpu_pct')}")
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
def stat(xs):
    return (round(statistics.median(xs), 2), round(min(xs), 2), round(max(xs), 2)) if xs else (None, None, None)
for (chats, kind) in sorted(values):
    b, h = stat(values[(chats, kind)]["base"]), stat(values[(chats, kind)]["head"])
    delta = round(h[0] - b[0], 2) if None not in (b[0], h[0]) else None
    print(f"IDLE-AB median chats {chats} kind {kind} base {b[0]} [{b[1]}-{b[2]}] n {len(values[(chats, kind)]['base'])} "
          f"head {h[0]} [{h[1]}-{h[2]}] n {len(values[(chats, kind)]['head'])} delta {delta}")
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
        print(f"IDLE-AB thread chats {chats} kind {kind} name {name!r} base {b} head {h} delta {delta}")
json.dump(summary, open(os.path.join(os.path.dirname(runs), "summary.json"), "w"), indent=1)
PY
echo "IDLE-AB verdict exit $status base $base head $head rounds $rounds"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" runs summary.json build-base.log build-head.log 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
exit $status
