#!/usr/bin/env bash
# The stop of the cmux-tui session daemon under load, at two commits: how often a thread of the
# stopped daemon did not end before the daemon gave up its session, and what the stop and the next
# start cost.
#   cmux-ci run --class exclusive --measurement --script scripts/measure/daemon-stop-swap.sh \
#     --ref SHA --os macos --arg=old=SHA --arg=new=SHA [--arg=rounds=30] [--arg=budget=10] \
#     --artifact .build/daemon-stop-swap/report.json --timeout 7200
# It builds release `cmux-tui` and `cmux-tui-host` of each commit (a scratch copy of the commit's
# tree and one scratch target directory, all removed after the builds), then runs the swap check
# rounds times: scripts/cmux-next/daemon-swap-check.py --drill (24 terminals, a flood, two typists,
# a swap and a swap back). A round stops two daemons by SIGTERM under that load, one of each build:
# odd rounds start with old, even rounds with new, so each build is the first stop in half of the
# rounds. The round's last daemon ends by the check's own shutdown command (kind=end: no clock
# pair, not in the sums).
# Output:
#   DSS build old|new SHA: start, then: built in S s
#   DSS-ROUND {json}  one per round: the check's exit and verdict, its error, the stops it gave,
#                     the processes that it left
#   DSS-STOP {json}   one per stopped daemon:
#     alive             lines of that daemon's log that say that a thread did not end (ALIVE_TEXTS
#                       below); alive_by has the count of each text
#     shutdown_ms       the N of that daemon's own line `shutdown began at MS (unix ms), N ms ...`
#     exit_s            SIGTERM to the process's end, by the check's clock (old_daemon_exit_secs)
#     after_shutdown_s  the shutdown's end to the process's end (after_shutdown_to_exit_secs)
#     next_start_s      the process's end to the first answer of the next daemon, which is the
#                       other build (new_daemon_answers_secs - old_daemon_exit_secs)
#     swap_s            SIGTERM to the last terminal's check, which the check holds against budget
#   DSS-RAW ...       each log line that counted in alive, whole
#   DSS-SUM {json}    one per build: stops, stops with alive above 0, median and maximum of the times
#   DSS-OTHER {json}  the logs of daemons that no SIGTERM of the check stopped
#   DSS-KILL, DSS-DISK, DSS-END  the cleanup (finish below)
# and .build/daemon-stop-swap/report.json with all of them. Exit 0 when each round gave two stops,
# else 1. A round that the check failed, or that was slower than budget, still counts its stops.
# Three rounds in a row that gave no stop end the run there (exit 1): a broken run does not hold
# its host for all the rounds.
# A stop from outside (SIGTERM, SIGINT, SIGHUP: a step's time limit, a cancel) ends the build or
# the check that runs, then cleans up as each other exit does.
#
# What it cannot show: the check starts the next daemon only after the old process is gone, so no
# start here meets a daemon that gave up its session and still runs. The drill's session is new and
# small: a thread that is slow only on a large store does not show.
# Both commits must pin the ghostty-next commit of this checkout.
#
# summary_of=DIR: the rows and sums of the round folders DIR/w1, DIR/w2, ... (a made or a kept
# run), with no build and no daemon; the report goes to DIR/report.json.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
old="" new="" rounds=30 budget=10 summary_of=""
for kv in "$@"; do
  case "$kv" in
    old=*) old="${kv#*=}" ;;
    new=*) new="${kv#*=}" ;;
    rounds=*) rounds="${kv#*=}" ;;
    budget=*) budget="${kv#*=}" ;;
    summary_of=*) summary_of="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
if [[ ! "$rounds" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: rounds= needs a count of 1 or more" >&2; exit 2
fi
if [[ ! "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: budget= needs seconds" >&2; exit 2
fi
out="$root/.build/daemon-stop-swap"

# summary rows NUMBER FOLDER LEFT: the stops of one round, from the check's report, its exit and
# the daemons' logs in FOLDER; appended to $out/stops.jsonl and $out/rounds.jsonl; exit 3 when the
# round gave no stop.
# summary sums OLD NEW ROUNDS: the sums of those files and $out/report.json; exit 1 unless each of
# ROUNDS rounds gave two stops.
summary() {
  python3 - "$out" "$budget" "$@" <<'PY'
import json
import re
import statistics
import sys
from pathlib import Path

out, budget, mode = Path(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
# A thread of the stopped daemon that did not end in the shutdown's wait for it. The last text is
# of a daemon that, because of such a thread, keeps its session until its process ends.
ALIVE_TEXTS = {
    "journal_writer": "session journal writer did not stop before the shutdown deadline",
    "output_cleanup": "output cleanup: the worker did not stop within",
    "agent_roster": "the agent roster worker did not stop within",
    "journal_hooks": "journal hook workers did not stop before the shutdown deadline",
    "keeps_session": "this daemon keeps its session until it exits:",
}
SHUTDOWN = re.compile(r"shutdown began at (\d+) \(unix ms\), (\d+) ms with (\d+) surfaces")
KINDS = {"terminals": "first", "terminals-swap-2": "second"}
# The check ends a daemon that still runs 20 s after its SIGTERM.
CHECK_KILLS_AFTER_SECS = 20


def emit(tag, row):
    print(f"{tag} {json.dumps(row, sort_keys=True)}", flush=True)


def side(binary):
    return {"bin-old": "old", "bin-new": "new"}.get(Path(str(binary)).parent.name, "unknown")


def started_ms(log):
    return int(log.stem.rsplit("-", 1)[1])


def log_facts(log):
    lines = log.read_text(errors="replace").splitlines() if log else []
    raw = [line for line in lines if any(text in line for text in ALIVE_TEXTS.values())]
    alive_by = {name: sum(1 for line in raw if text in line) for name, text in ALIVE_TEXTS.items()}
    shut = [found for found in map(SHUTDOWN.search, lines) if found]
    facts = {"alive": len(raw), "alive_by": {name: n for name, n in alive_by.items() if n},
             "shutdown_ms": int(shut[-1].group(2)) if shut else None,
             "surfaces": int(shut[-1].group(3)) if shut else None,
             "log": log.name if log else None}
    return facts, raw


def read(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def round_rows(number, folder, left):
    report = read(folder / "report.json", {})
    if not isinstance(report, dict):
        report = {}
    try:
        code = int((folder / "exit").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        code = None
    logs = sorted((log for log in folder.glob("*/terminals/daemon-*.log")
                   if log.stem.rsplit("-", 1)[-1].isdigit()), key=started_ms)
    phases = [phase for phase in report.get("phases") or [] if isinstance(phase, dict)]
    rows, used = [], set()
    for phase in phases:
        stop_wall = (phase.get("marks_wall") or {}).get("stop")
        exit_s = phase.get("old_daemon_exit_secs")
        if phase.get("phase") not in KINDS or stop_wall is None or exit_s is None:
            continue
        # The daemon that got the SIGTERM: the last one that started before it.
        before = [log for log in logs if started_ms(log) <= stop_wall * 1000 + 1]
        log = before[-1] if before else None
        used.add(log)
        facts, raw = log_facts(log)
        start = phase.get("new_daemon_start") or {}
        answers = phase.get("new_daemon_answers_secs")
        load = start.get("load_at_stop") or []
        rows.append(({
            "round": number, "kind": KINDS[phase["phase"]], "build": side(phase.get("old_binary")),
            "next_build": side(phase.get("new_binary")), **facts, "exit_s": exit_s,
            "after_shutdown_s": (start.get("old_daemon_stop") or {}).get("after_shutdown_to_exit_secs"),
            "next_start_s": round(answers - exit_s, 3) if answers is not None else None,
            "swap_s": phase.get("swap_secs"), "passed": bool(phase.get("passed")),
            "killed_by_check": exit_s >= CHECK_KILLS_AFTER_SECS, "load1": load[0] if load else None,
        }, raw))
    stops = len(rows)
    # With both stops found, each other daemon of the round is of the build that the round began
    # with: the one that the check's shutdown command ends, and its fallback.
    rest = ("end", side(phases[0].get("old_binary"))) if stops == 2 else ("unmatched", "unknown")
    for log in logs:
        if log not in used:
            facts, raw = log_facts(log)
            rows.append(({"round": number, "kind": rest[0], "build": rest[1], **facts}, raw))
    error = report.get("error") or next((phase["error"] for phase in phases if phase.get("error")), None)
    try:
        said = (folder / "check.err").read_text(errors="replace").strip().splitlines()[-1][:300]
    except (OSError, IndexError):
        said = None
    summary = {"round": number, "exit": code, "passed": report.get("passed"), "stops": stops,
               "logs": len(logs), "left": left, "error": str(error)[:300] if error else None,
               "said": said}
    emit("DSS-ROUND", summary)
    with open(out / "rounds.jsonl", "a") as file:
        file.write(json.dumps(summary, sort_keys=True) + "\n")
    with open(out / "stops.jsonl", "a") as file:
        for row, raw in rows:
            emit("DSS-STOP", row)
            for line in raw:
                print(f"DSS-RAW round={number} kind={row['kind']} build={row['build']}: {line[:400]}",
                      flush=True)
            file.write(json.dumps(row, sort_keys=True) + "\n")
    return stops


def spread(rows, key):
    values = [row[key] for row in rows if row.get(key) is not None]
    if not values:
        return {"n": 0}
    return {"n": len(values), "median": round(statistics.median(values), 3), "max": max(values)}


def lines_of(name):
    try:
        return [json.loads(line) for line in (out / name).read_text().splitlines() if line.strip()]
    except OSError:
        return []


def sums(old, new, asked):
    rows, rounds = lines_of("stops.jsonl"), lines_of("rounds.jsonl")
    totals = []
    for build, commit in (("old", old), ("new", new)):
        mine = [row for row in rows if row["build"] == build and row["kind"] in KINDS.values()]
        total = {
            "build": build, "commit": commit, "stops": len(mine),
            "stops_alive": sum(1 for row in mine if row["alive"]),
            "stops_alive_by": {name: n for name in ALIVE_TEXTS
                               if (n := sum(1 for row in mine if row["alive_by"].get(name)))},
            "stops_without_shutdown_line": sum(1 for row in mine if row["shutdown_ms"] is None),
            "stops_killed_by_check": sum(1 for row in mine if row["killed_by_check"]),
            "swaps_not_passed": sum(1 for row in mine if not row["passed"]),
            "swaps_at_or_over_budget": sum(1 for row in mine
                                           if row["swap_s"] is None or row["swap_s"] >= budget),
            **{key: spread(mine, key)
               for key in ("shutdown_ms", "exit_s", "after_shutdown_s", "next_start_s", "swap_s")},
        }
        emit("DSS-SUM", total)
        totals.append(total)
    rest = [row for row in rows if row["kind"] not in KINDS.values()]
    other = {kind: {"logs": sum(1 for row in rest if row["kind"] == kind),
                    "alive": sum(1 for row in rest if row["kind"] == kind and row["alive"])}
             for kind in ("end", "unmatched")}
    emit("DSS-OTHER", other)
    whole = 0 < asked == len(rounds) and all(row["stops"] == 2 for row in rounds)
    report = {"schema": "daemon-stop-swap/v1", "old": old, "new": new, "rounds_asked": asked,
              "budget_s": budget, "each_round_gave_two_stops": whole, "sums": totals, "other": other,
              "rounds": rounds, "stops": rows}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if whole else 1


if mode == "rows":
    sys.exit(0 if round_rows(int(sys.argv[4]), Path(sys.argv[5]), int(sys.argv[6])) else 3)
else:
    sys.exit(sums(sys.argv[4], sys.argv[5], int(sys.argv[6])))
PY
}

if [[ -n "$summary_of" ]]; then
  if [[ ! -d "$summary_of" ]]; then
    echo "error: summary_of= needs a folder" >&2; exit 2
  fi
  out="$summary_of"
  rm -f "$out/stops.jsonl" "$out/rounds.jsonl" "$out/report.json"
  count=0
  for folder in "$summary_of"/w*/; do
    number="${folder%/}"
    number="${number##*/w}"
    [[ -d "$folder" && "$number" =~ ^[0-9]+$ ]] || continue
    summary rows "$number" "${folder%/}" 0 || [[ $? == 3 ]]
    count=$((count + 1))
  done
  summary sums "$old" "$new" "$count"
  exit 0
fi

if [[ -z "$old" || -z "$new" ]]; then
  echo "error: old=SHA and new=SHA are needed" >&2; exit 2
fi
rm -rf "$out" && mkdir -p "$out"
# ghostty-vt-sys builds libghostty-vt from the ghostty-next submodule (as cmux-tui-rust-check.sh).
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
# A depth only in a checkout that is already shallow (a CI one): never turn a full clone shallow.
depth=""
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" != true ]] || depth=--depth=1
# A fleet step's checkout has no `origin` remote: a commit that it does not hold then comes from
# the repository's URL (as app-at-commit.sh).
fetch_url="${CMUX_MEASURE_FETCH_URL:-https://github.com/manaflow-ai/cmux.git}"
resolve() {
  git -C "$root" cat-file -e "$1^{commit}" 2>/dev/null \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules $depth origin "$1" \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules $depth "$fetch_url" "$1" \
    || { echo "error: cannot fetch $1 from origin or from $fetch_url" >&2; return 1; }
  git -C "$root" rev-parse "$1^{commit}"
}
old_sha="$(resolve "$old")"
new_sha="$(resolve "$new")"
if [[ "$old_sha" == "$new_sha" ]]; then
  echo "error: old and new are the same commit" >&2; exit 2
fi
here_ghostty="$(git -C "$root" rev-parse HEAD:ghostty-next)"
for sha in "$old_sha" "$new_sha"; do
  if [[ "$(git -C "$root" rev-parse "$sha:ghostty-next")" != "$here_ghostty" ]]; then
    echo "error: $sha pins another ghostty-next commit than this checkout" >&2; exit 2
  fi
done

# One new folder for all that this run makes. It stays short: the check's daemon socket is
# SCRATCH/wN/cmux-swap-XXXXXXXX/terminals/mux.sock, and a socket path has at most 104 bytes on
# macOS.
scratch="$(mktemp -d "${CMUX_DSS_SCRATCH:-/tmp}/cmux-dss.XXXXXX")"
stage=setup rounds_done=0 left_count=0 empty_rounds=0
# The pid of the long child that runs now (a build or a round's check); empty between them.
child_pid=""

# The processes whose command line has DIR/, where DIR is the folder that this run made, or one
# round's folder in it. No other pattern: a process of another run never has this path.
left_of() { ps -A -ww -o pid= -o command= | DSS_DIR="$1/" awk 'index($0, ENVIRON["DSS_DIR"])'; }
# Prints each of them (DSS-KILL) and sends SIGTERM, then SIGKILL to those still there once all
# have exited or 5 s have passed.
end_left() {
  local pid cmd
  left_count=0
  while read -r pid cmd; do
    [[ -n "$pid" && "$pid" != "$$" ]] || continue
    echo "DSS-KILL pid=$pid SIGTERM cmd=${cmd:0:400}"
    kill -TERM "$pid" 2>/dev/null || true
    left_count=$((left_count + 1))
  done < <(left_of "$1" || true)
  (( left_count > 0 )) || return 0
  # Until every one of them has exited, 5 s at most (then the rest get SIGKILL).
  for _ in $(seq 50); do
    left_of "$1" 2>/dev/null | awk -v me="$$" '$1 != me' | grep -q . || break
    sleep 0.1
  done
  while read -r pid cmd; do
    [[ -n "$pid" && "$pid" != "$$" ]] || continue
    echo "DSS-KILL pid=$pid SIGKILL cmd=${cmd:0:400}"
    kill -KILL "$pid" 2>/dev/null || true
  done < <(left_of "$1" || true)
}
# A long child runs as a job and the script waits for it with `wait`: bash runs a trap at once
# when a signal comes in `wait`, but only after the child's end when the child is in the
# foreground. The child's exit is the function's exit.
wait_child() {
  local code=0
  wait "$child_pid" || code=$?
  child_pid=""
  return "$code"
}
# A job of a shell with no job control starts with SIGINT and SIGQUIT ignored, and a process keeps
# an ignored signal through each exec: the compilers, the daemons and their shells would have it.
# This prefix runs the command with both signals at their default: as a background job's simple
# command, bash's job process becomes python, which then becomes the command. It is a command prefix,
# not a function that execs: an exec in the script would drop its EXIT trap (mktemp-trap.test.py).
with_plain_signals=(python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])')
# PID and each process below it. Read before a signal: a process whose parent ended has another
# parent.
tree_of() {
  ps -A -o pid= -o ppid= | awk -v top="$1" '
    { parent[$1] = $2 }
    END {
      below[top] = 1; print top
      do {
        more = 0
        for (pid in parent) if (!(pid in below) && (parent[pid] in below)) { below[pid] = 1; print pid; more = 1 }
      } while (more)
    }'
}
# A process that runs (one that ended and waits for its parent's read does not).
runs() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  [[ -n "$state" && "$state" != Z* ]]
}
# Ends the long child that still runs, and each process below it (a build's compilers have no
# path of this run in their command line, or not all of them): DSS-KILL and SIGTERM for each, then
# SIGKILL to those still there 3 s later.
end_child() {
  local pids pid sent=0
  [[ -n "$child_pid" ]] || return 0
  pids="$(tree_of "$child_pid" || true)"
  for pid in $pids; do
    runs "$pid" || continue
    echo "DSS-KILL pid=$pid SIGTERM cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null | cut -c1-400)"
    kill -TERM "$pid" 2>/dev/null || true
    sent=1
  done
  if (( sent )); then
    sleep 3
    for pid in $pids; do
      runs "$pid" || continue
      echo "DSS-KILL pid=$pid SIGKILL cmd=$(ps -ww -o command= -p "$pid" 2>/dev/null | cut -c1-400)"
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi
  wait "$child_pid" 2>/dev/null || true
  child_pid=""
}
# The copies of the two commits and the target directory: their sizes (DSS-DISK), then gone.
drop_builds() {
  local dir
  for dir in "$scratch/src-old" "$scratch/src-new" "$scratch/target"; do
    [[ -d "$dir" ]] || continue
    echo "DSS-DISK ${dir##*/} $(du -sk "$dir" 2>/dev/null | cut -f1) KiB, removed"
    rm -rf "$dir"
  done
}
# Each exit: no process of this run stays, nothing of it stays on the disk, and the last line
# says where the run ended. A second signal does not cut the cleanup short.
finish() {
  local code=$?
  trap - EXIT
  trap '' TERM INT HUP
  set +e
  end_child
  end_left "$scratch"
  drop_builds
  if [[ -s "$out/rounds.jsonl" && ! -f "$out/report.json" ]]; then
    summary sums "$old_sha" "$new_sha" "$rounds"
  fi
  echo "DSS-DISK scratch $(du -sk "$scratch" 2>/dev/null | cut -f1) KiB, removed"
  rm -rf "$scratch"
  echo "DSS-END stage=$stage exit=$code rounds_done=$rounds_done"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
if (( ${#scratch} + ${#rounds} + 41 > 100 )); then
  echo "error: $scratch is too long for the check's socket path" >&2; exit 2
fi

# One target directory for both builds: the second build takes the crates of other packages from
# the first. Each commit's own crates are built from its own copy (no worktree: nothing is written
# to this checkout's git folder, and this checkout's target directory keeps no output of a scratch
# path).
build_at() {
  local side="$1" sha="$2" started
  stage="build-$side"
  mkdir -p "$scratch/src-$side" "$scratch/bin-$side"
  git -C "$root" archive "$sha" | tar -x -C "$scratch/src-$side"
  echo "DSS build $side $sha: start"
  started=$(date +%s)
  (
    cd "$scratch/src-$side/cmux-tui"
    export CMUX_GHOSTTY_SRC="$root/ghostty-next" CARGO_TARGET_DIR="$scratch/target"
    export CMUX_TUI_BUILD_COMMIT="$sha" CMUX_TUI_GHOSTTY_COMMIT="$here_ghostty"
    "${with_plain_signals[@]}" cargo build --release --locked -p cmux-tui --bin cmux-tui --bin cmux-tui-host
  ) &
  child_pid=$!
  wait_child
  cp "$scratch/target/release/cmux-tui" "$scratch/target/release/cmux-tui-host" "$scratch/bin-$side/"
  echo "DSS build $side $sha: built in $(( $(date +%s) - started )) s"
}
echo "DSS host $(hostname -s) $(uname -sm) rounds=$rounds budget=$budget old=$old_sha new=$new_sha"
build_at old "$old_sha"
build_at new "$new_sha"
drop_builds

for ((r = 1; r <= rounds; r++)); do
  stage="round-$r"
  work="$scratch/w$r"
  mkdir -p "$work"
  if (( r % 2 )); then
    first="$scratch/bin-old/cmux-tui" second="$scratch/bin-new/cmux-tui"
  else
    first="$scratch/bin-new/cmux-tui" second="$scratch/bin-old/cmux-tui"
  fi
  "${with_plain_signals[@]}" python3 "$root/scripts/cmux-next/daemon-swap-check.py" --old "$first" \
    --new "$second" --phases terminals --drill --keep --budget "$budget" --work-root "$work" \
    > "$work/report.json" 2> "$work/check.err" &
  child_pid=$!
  code=0
  wait_child || code=$?
  echo "$code" > "$work/exit"
  # A process that the round left does not load the next round.
  end_left "$work"
  code=0
  summary rows "$r" "$work" "$left_count" || code=$?
  rounds_done=$r
  case "$code" in
    0) empty_rounds=0 ;;
    3) empty_rounds=$((empty_rounds + 1)) ;;
    *) exit "$code" ;;
  esac
  if (( empty_rounds >= 3 )); then
    echo "DSS early end: $empty_rounds rounds in a row gave no stop (the last one is round $r of $rounds)"
    exit 1
  fi
done
stage=sums
summary sums "$old_sha" "$new_sha" "$rounds"
stage=done
