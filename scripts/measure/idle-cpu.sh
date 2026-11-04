#!/usr/bin/env bash
# Idle CPU and wakeups of one fleet build: the app, its acpmux and its cmux-tui, after N minutes with no
# user action (scripts/cmux-next/idle_cpu.py). The build is a finished `cmux-ci build cmux` job's app zip,
# from the controller store by sha256; nothing is built here. Run alone on a quiet worker:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/idle-cpu.sh --ref SHA --arg=artifact=sha256:HEX \
#     [--arg=minutes=10] [--arg=window=60] [--arg=windows=3] [--arg=chats=0] [--arg=history=0] [--arg=prompt_kb=0] [--arg=writers=0] [--arg=sample=1|0|each] \
#     [--arg=budget_cpu=1.0] [--arg=budget_wakeups=1.0] --artifact .build/idle-cpu/report.tgz --timeout 3600
# On a fleet host, scripts/cmux-next/idle-cpu-run.py makes this step for a build job or tag through the
# mini scheduler. Output: IDLE-CPU lines and IDLE-CPU-VERDICT. Exit 0 within budget, 1 over, 3 not run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
artifact="" history=0 prompt_kb=0 writers=0 minutes=10 window=60 windows=3 chats=0 sample=1 budget_cpu=1.0 budget_wakeups=1.0
for arg in "$@"; do
  case "$arg" in
    artifact=*) artifact="${arg#artifact=}" ;;
    minutes=*) minutes="${arg#minutes=}" ;;
    window=*) window="${arg#window=}" ;;
    windows=*) windows="${arg#windows=}" ;;
    chats=*) chats="${arg#chats=}" ;;
    history=*) history="${arg#history=}" ;;
    prompt_kb=*) prompt_kb="${arg#prompt_kb=}" ;;
    writers=*) writers="${arg#writers=}" ;;
    sample=*) sample="${arg#sample=}" ;;
    budget_cpu=*) budget_cpu="${arg#budget_cpu=}" ;;
    budget_wakeups=*) budget_wakeups="${arg#budget_wakeups=}" ;;
    *) echo "idle-cpu.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$artifact" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "idle-cpu.sh: artifact=sha256:<64 hex> is required" >&2; exit 2; }
for n in "$minutes" "$window" "$windows" "$chats" "$history" "$prompt_kb" "$writers" "$budget_cpu" "$budget_wakeups"; do
  [[ "$n" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "idle-cpu.sh: $n is not a number" >&2; exit 2; }
done
[[ "$prompt_kb" =~ ^[0-9]+$ ]] || { echo "idle-cpu.sh: prompt_kb= must be a whole number" >&2; exit 2; }
[[ "$windows" =~ ^[1-9][0-9]*$ ]] || { echo "idle-cpu.sh: windows= must be a whole number >= 1" >&2; exit 2; }
[[ "$window" =~ ^0*([.]0*)?$ ]] && { echo "idle-cpu.sh: window= must be > 0" >&2; exit 2; }
out="$PWD/.build/idle-cpu"
rm -rf "$out" && mkdir -p "$out"
echo "IDLE-CPU-MACHINE host=$(hostname -s) macos=$(sw_vers -productVersion) sha=$(git rev-parse HEAD) load=\"$(uptime | sed 's/.*load averages*: //')\""
flags=()
[[ "$sample" == 0 ]] && flags+=(--no-sample)
[[ "$sample" == each ]] && flags+=(--sample-each-window)
python3 -I scripts/cmux-next/idle_cpu.py --artifact "$artifact" --minutes "$minutes" --window "$window" \
  --windows "$windows" --chats "$chats" --history "$history" --history-prompt-kb "$prompt_kb" --writers "$writers" --budget-cpu "$budget_cpu" --budget-wakeups "$budget_wakeups" \
  ${flags[@]+"${flags[@]}"} --out "$out"
status=$?
echo "IDLE-CPU-LOAD after load=\"$(uptime | sed 's/.*load averages*: //')\""
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit $status
