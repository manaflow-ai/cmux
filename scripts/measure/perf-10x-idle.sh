#!/usr/bin/env bash
# perf-10x idle bench (msg 1628): CPU %, wakeups/s, RSS and physical
# footprint per process kind for an idle cmux-next app and an idle headless
# cmux-tui, at 1, 10 and 50 terminal workspaces, each idle for 60 s.
#   app:    builds a tagged app at this checkout (reload.sh), launches it with
#           a scratch HOME (scripts/cmux-next/bench_memory.py --measure).
#   daemon: the app bundle's cmux-tui, headless, one terminal per workspace,
#           no output (cmux-tui/scripts/bench-scale.py --busy-fraction 0).
# Run alone on a worker (it launches an app):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-10x-idle.sh --ref SHA [--arg=counts=1,10,50] [--arg=measure=60] \
#     [--arg=agents=20,100] [--arg=purge=1] [--arg=release=MINUTES] [--arg=attribute=1] [--arg=infinite=10,100]
#     [--arg=chat_renderer_crash=1] [--arg=vmmap=tui-daemon,app]
# agents: also measure that many idle agent chats (one workspace each, on the
# acpmux test agent cmux-tui/crates/acpmux/tests/fake_agent.py, its first turn
# answered), as PERF-IDLE app-agents lines (resource-efficiency-DESIGN.md).
# purge=1 (with one agents= count, e.g. agents=100): after the agent count, Chromium's memory purge of every hidden chat's renderer (no
# reload; bench_memory.py --purge-hidden), sampled again as purged-N.
# release=MINUTES (with one agents= count): agents.hiddenChats.discard on after MINUTES; the released
# chats sampled as released-N, then 10 of them shown again and timed (PERF-IDLE-RESTORE).
# chat_renderer_crash=1 (with agents=): the chat renderer crash test (scripts/cmux-next/chat_renderer_crash.py):
# every chat pinned and kept loaded, chat pages per renderer at each count, then a SIGKILL of the renderer with
# the most chat pages; it fails when more than 8 chats reload or a chat of another renderer does.
# attribute=1 (or attribute=KIND,KIND: those process kinds, default app,cef-gpu): also name what wakes the app and the Chromium GPU process in each window
# (bench_memory.py --attribute: thread CPU, the debug.wakeups ledger and main run loop timers, live
# pages, a stack sample after the window), as PERF-ATTR lines.
# infinite=COUNTS: also the infinite-items run (scripts/measure/infinite-items.py, CMUX-571) on the bundle's
# own acpmux and cmux-tui: COUNTS workspaces, each with a terminal tab and an agent chat, through simulated
# days (days=DAYS, default 3) of switches, tab cycles, streaming turns and a sleep/wake, as INFINITE lines.
# vmmap=KIND,KIND: after each app sample, vmmap --summary of every process of those kinds (bench_memory.py
# --vmmap-kinds): where its footprint is, MALLOC against frameworks and stacks.
# axes=AXIS,AXIS (chat-hidden, chat-visible, terminal-hidden, terminal-visible; axes=all for the four): what one
# more idle item costs, per process (bench_memory.py --axis, one fresh app each): idle CPU %, footprint, RSS,
# wakeups/s, disk bytes written and read per hour (proc_pid_rusage) and the GPU's utilization (ioreg; the Mac
# has no per-process GPU time or frame count there, so the GPU process's CPU is its own row). Hidden axes sample
# at items=COUNTS (default 1,10,100; each item a workspace of its own, the launch workspace shown) and again
# settled=SECONDS later (default 90: past the hidden chat pages' 30 s freeze and 60 s release); visible axes at
# visible_items=COUNTS (default 1,4,10; each item a pane of the launch workspace, as many as the window fits).
# Writes .build/perf-idle/idle-axes.json and idle-axes.md (marginal cost per item, by process group: app,
# cef-renderer, cef-gpu, acpmux, cmux-tui, terminal hosts), printed as PERF-IDLE-AXES lines. counts=none skips
# the daemon and terminal-workspace runs, e.g.:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/perf-10x-idle.sh \
#     --ref SHA --arg=counts=none --arg=axes=all --arg=measure=45
# The app run also takes settings=JSON (the launch's cmux.json settings, e.g. settings={"appearance":{"agentGlow":true}}),
# gpu=1 (the GPU's utilization per window, PERF-IDLE-GPU lines), agent_state=working|blocked (the launch workspace's
# terminal reports an agent in that state before the first window; the daemon's list-agents after each window is a
# PERF-IDLE-NOTE line) and snapshot=1 (the main window after each window, .build/perf-idle/snapshots/window-LABEL.png).
# runs=NAME;SETTINGS;STATE|NAME;SETTINGS;STATE: one fresh app run per entry on the same build and Mac (SETTINGS and STATE
# may be empty), its sample labels NAME/LABEL, e.g. runs='off;;|calm;{"appearance":{"agentGlow":true}};|glow;{"appearance":{"agentGlow":true}};blocked'.
# Output: PERF-IDLE lines (PERF-IDLE-PROC: the app's top processes with their commands, and VMMAP lines); JSON under
# .build/perf-idle.
set -euo pipefail
counts="1,10,50"
measure=60
agents=""
infinite="" days=3
axes="" items="1,10,100" visible_items="1,4,10" settled=90
reload_config=() purge=() release=() attribute=() crash_env=() vmmap=()
app_config=() gpu=() agent_report=() snapshot=() runs=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    counts=*) counts="${arg#counts=}" ;;
    measure=*) measure="${arg#measure=}" ;;
    agents=*) agents="${arg#agents=}" ;;
    infinite=*) infinite="${arg#infinite=}" ;;
    days=*) days="${arg#days=}" ;;
    purge=1) purge=(--purge-hidden) ;;
    release=*) release=(--release-hidden-chats "${arg#release=}") ;;
    attribute=1) attribute=(--attribute) ;;
    attribute=*) attribute=(--attribute --attribute-kinds "${arg#attribute=}") ;;
    chat_renderer_crash=1) crash_env=(CMUX_BENCH_CHAT_RENDERER_CRASH=1) ;;
    vmmap=*) vmmap=(--vmmap-kinds "${arg#vmmap=}") ;;
    axes=all) axes="chat-hidden,chat-visible,terminal-hidden,terminal-visible" ;;
    axes=*) axes="${arg#axes=}" ;;
    items=*) items="${arg#items=}" ;;
    visible_items=*) visible_items="${arg#visible_items=}" ;;
    settled=*) settled="${arg#settled=}" ;;
    settings=*) app_config=(--config "${arg#settings=}") ;;
    gpu=1) gpu=(--gpu) ;;
    agent_state=*) agent_report=(--agent-report "${arg#agent_state=}") ;;
    snapshot=1) snapshot=(1) ;;
    runs=*) runs="${arg#runs=}" ;;
    *) echo "perf-10x-idle.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/perf-idle"
rm -rf "$work"
mkdir -p "$work"
echo "PERF-IDLE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
tag="perfidle"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf-10x-idle: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
tui="$app/Contents/Resources/bin/cmux-tui"
[ -x "$tui" ] || { echo "perf-10x-idle: no bundled cmux-tui at $tui" >&2; exit 1; }
status=0

state_root="$(mktemp -d /private/tmp/pidl.XXXXXX)"
trap 'rm -rf "$state_root"' EXIT
if [[ "$counts" != none ]]; then
echo "PERF-IDLE-LOAD daemon $(uptime | sed 's/.*load averages*: //')"
# One daemon per count: bench-scale makes every workspace (one terminal each)
# before its first step, so a single run with several counts measures the
# largest count at every step.
IFS=, read -r -a daemon_counts <<< "$counts"
for n in "${daemon_counts[@]}"; do
  python3 cmux-tui/scripts/bench-scale.py --bin "$tui" --counts "$n" --busy-fraction 0 \
    --per-workspace 1 --fill sequential --idle-seconds "$measure" --settle-seconds-min 15 \
    --latency-samples 20 --latency-terminals 5 --topology-samples 20 \
    --root-dir "$state_root" --out "$work/daemon-$n.json" > "$work/daemon-$n.log" 2>&1 || status=$?
done
python3 - "$work"/daemon-*.json <<'PY' || status=$?
import json, sys
for path in sys.argv[1:]:
  data = json.load(open(path))
  for step in data.get("steps", []):
    for role, t in (step.get("roles") or {}).items():
      print(f"PERF-IDLE daemon N={step.get('target')} role={role} n={t.get('count')} cpu_pct={t.get('cpu_pct_window')} "
            f"wakeups_per_s={t.get('wakeups_per_s')} rss_each_mb={round((t.get('rss_per') or 0) / 1048576, 2)} "
            f"footprint_each_mb={round((t.get('pss_per') or 0) / 1048576, 2)} threads={t.get('threads')}")
  print(f"PERF-IDLE-STOP daemon {path} {data.get('stopped')} teardown={json.dumps(data.get('teardown') or {})[:300]}")
PY

# One app run, or one per runs= entry (NAME;SETTINGS_JSON;AGENT_STATE, |-separated), each a fresh launch of the
# same build on the same Mac; a run's sample labels are NAME/LABEL.
if [[ -n "$runs" ]]; then IFS='|' read -r -a run_list <<< "$runs"; else run_list=(""); fi
for run in "${run_list[@]}"; do
  run_name="" run_args=()
  if [[ -n "$run" ]]; then
    IFS=';' read -r run_name run_settings run_state <<< "$run"
    [[ -n "${run_settings:-}" ]] && run_args+=(--config "$run_settings")
    [[ -n "${run_state:-}" ]] && run_args+=(--agent-report "$run_state")
  else
    run_args=(${app_config[@]+"${app_config[@]}"} ${agent_report[@]+"${agent_report[@]}"})
  fi
  out="app${run_name:+-$run_name}"
  shots=()
  (( ${#snapshot[@]} )) && shots=(--window-snapshot "$work/snapshots${run_name:+/$run_name}")
  echo "PERF-IDLE-LOAD app${run_name:+ $run_name} $(uptime | sed 's/.*load averages*: //')"
  python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces "$counts" --mix terminal \
    --settle 20 --measure "$measure" --top 8 ${attribute[@]+"${attribute[@]}"} ${vmmap[@]+"${vmmap[@]}"} \
    ${run_args[@]+"${run_args[@]}"} ${gpu[@]+"${gpu[@]}"} ${shots[@]+"${shots[@]}"} \
    --out "$work/$out.json" > "$work/$out.log" 2>&1 || { status=$?; tail -n 60 "$work/$out.log"; }
  # Which process is which (the top list names each command) and, with vmmap=, where each one's footprint is.
  grep -E '^ +[0-9.]+ MB  RSS|^VMMAP ' "$work/$out.log" | sed 's/^ */PERF-IDLE-PROC app /' || true
  grep '^PERF-ATTR ' "$work/$out.log" | sed 's/^PERF-ATTR /PERF-ATTR app /' || true
  grep -E '^== (agent report|agents after|window snapshot)' "$work/$out.log" | sed "s|^== |PERF-IDLE-NOTE app ${run_name:+$run_name }|" || true
  python3 - "$work/$out.json" "$run_name" <<'PY' || status=$?
import json, sys
data = json.load(open(sys.argv[1]))
prefix = f"{sys.argv[2]}/" if sys.argv[2] else ""
for s in data.get("samples", []):
    label = prefix + s["label"]
    for kind, e in s["kinds"].items():
        print(f"PERF-IDLE app {label} workspaces={s['workspaces']} kind={kind} n={e['count']} cpu_pct={e.get('cpu_pct')} "
              f"wakeups_per_s={e.get('wakeups_per_s')} rss_mb={e['rss_mb']} footprint_mb={e['footprint_mb']} "
              f"disk_write_mb_per_h={e.get('disk_write_mb_per_h')} disk_read_mb_per_h={e.get('disk_read_mb_per_h')}")
    if s.get("gpu"):
        print(f"PERF-IDLE-GPU app {label} workspaces={s['workspaces']} {json.dumps(s['gpu'])}")
PY
done
fi
if [[ -n "$axes" ]]; then
  # One fresh app per axis, so each starts from an idle launch (0 items).
  IFS=, read -r -a axis_list <<< "$axes"
  axis_reports=()
  for axis in "${axis_list[@]}"; do
    echo "PERF-IDLE-LOAD axis-$axis $(uptime | sed 's/.*load averages*: //')"
    axis_args=(--axis "$axis" --items "$items")
    case "$axis" in
      *-hidden) axis_args+=(--settled-wait "$settled") ;;
      *-visible) axis_args=(--axis "$axis" --items "$visible_items") ;;
    esac
    case "$axis" in
      chat-*) axis_args+=(--fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py) ;;
    esac
    python3 scripts/cmux-next/bench_memory.py --app "$app" "${axis_args[@]}" --gpu \
      --settle 20 --measure "$measure" --top 8 \
      --out "$work/axis-$axis.json" > "$work/axis-$axis.log" 2>&1 || { status=$?; tail -n 60 "$work/axis-$axis.log"; }
    [ -f "$work/axis-$axis.json" ] && axis_reports+=("$work/axis-$axis.json")
  done
  if (( ${#axis_reports[@]} )); then
    python3 scripts/cmux-next/idle_axes_report.py --json "$work/idle-axes.json" --markdown "$work/idle-axes.md" \
      --machine "$(git rev-parse HEAD) on $(scutil --get ComputerName 2>/dev/null || hostname), measure=${measure}s settled=${settled}s" \
      "${axis_reports[@]}" | sed 's/^/PERF-IDLE-AXES /' || status=$?
  fi
fi
if [[ -n "$agents" ]]; then
  echo "PERF-IDLE-LOAD agents $(uptime | sed 's/.*load averages*: //')"
  env ${crash_env[@]+"${crash_env[@]}"} python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces "$agents" --mix terminal+chat \
    --fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py \
    --settle 20 --measure "$measure" --top 8 ${purge[@]+"${purge[@]}"} ${release[@]+"${release[@]}"} \
    ${attribute[@]+"${attribute[@]}"} --out "$work/agents.json" > "$work/agents.log" 2>&1 || { status=$?; tail -n 60 "$work/agents.log"; }
  grep '^PERF-ATTR ' "$work/agents.log" | sed 's/^PERF-ATTR /PERF-ATTR app-agents /' || true
  python3 - "$work/agents.json" <<'PY' || status=$?
import json, sys
data = json.load(open(sys.argv[1]))
for s in data.get("samples", []):
    for kind, e in s["kinds"].items():
        print(f"PERF-IDLE app-agents {s['label']} agents={s['workspaces']} kind={kind} n={e['count']} cpu_pct={e.get('cpu_pct')} "
              f"wakeups_per_s={e.get('wakeups_per_s')} rss_mb={e['rss_mb']} footprint_mb={e['footprint_mb']}")
    if "chat_renderers" in s:
        print(f"CHAT-RENDERERS {s['label']} agents={s['workspaces']} {json.dumps(s['chat_renderers'])}")
    if "cef_pages" in s:
        print(f"PERF-IDLE-RELEASED {s['label']} cmux_pages={json.dumps(s['cef_pages'])}")
if "chat_renderer_crash" in data:
    print(f"CHAT-RENDERERS-CRASH {json.dumps(data['chat_renderer_crash'])}")
if "restore" in data:
    print(f"PERF-IDLE-RESTORE {json.dumps({k: v for k, v in data['restore'].items() if k != 'opens'})}")
    # Each restored chat's trace (marks, surface changes, note): why a restore has no first-content time.
    for o in data["restore"].get("opens", []):
        print(f"PERF-IDLE-RESTORE-OPEN {json.dumps(o)}")
PY
fi
if [[ -n "$infinite" ]]; then
  echo "PERF-IDLE-LOAD infinite $(uptime | sed 's/.*load averages*: //')"
  python3 scripts/measure/infinite-items.py --acpmux "$app/Contents/Resources/bin/acpmux" --tui "$tui" \
    --counts "$infinite" --days "$days" --root-dir "$state_root" --out "$work/infinite.json" \
    2> "$work/infinite.log" || { status=$?; tail -n 40 "$work/infinite.log"; }
fi
exit "$status"
