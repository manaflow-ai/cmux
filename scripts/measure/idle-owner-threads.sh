#!/usr/bin/env bash
# Idle owner, thread by thread (issue 23087): a headless cmux-tui built from
# this checkout (cargo --release with line tables, so `sample` names frames),
# one terminal running `cat`, no acpmux, and the streams the app keeps open.
# For each phase (streams attached, then all closed) it prints the process CPU
# and wakeups and each thread's CPU and runs over a quiet window, then a
# `sample` of the owner. Run alone on an idle worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/idle-owner-threads.sh \
#     --ref SHA [--arg=window=60] [--arg=sample=10]
# Output: IDLE-OWNER lines.
set -euo pipefail
window=60
sample_seconds=10
for arg in "$@"; do
  case "$arg" in
    window=*) window="${arg#window=}" ;;
    sample=*) sample_seconds="${arg#sample=}" ;;
    *) echo "idle-owner-threads.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ -n "${CMUX_CI_STEP_KEY:-}" ]] || { echo "idle-owner-threads.sh runs cargo and runs only as a fleet step" >&2; exit 2; }
umask 022
root="$(git rev-parse --show-toplevel)"
cd "$root"
export CARGO_TARGET_DIR="$root/.build/idle-owner-target"
if [[ -z "$(git submodule status ghostty-next 2>/dev/null || true)" && -f ghostty-next/build.zig ]]; then
  echo "ghostty-next: synced copy"
else
  git submodule update --init --depth 1 ghostty-next
fi
toolchain_cargo="$(cd cmux-tui && rustup which cargo)"
export PATH="$(dirname "$toolchain_cargo"):$PATH"
echo "IDLE-OWNER-SHA $(git rev-parse HEAD)"
echo "IDLE-OWNER-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
t0=$(date +%s)
(cd cmux-tui && CARGO_PROFILE_RELEASE_DEBUG=line-tables-only cargo build --release --locked -p cmux-tui --bin cmux-tui 2>&1 | tail -n 3)
echo "IDLE-OWNER-BUILD seconds=$(( $(date +%s) - t0 ))"
bin="$CARGO_TARGET_DIR/release/cmux-tui"
work="$(mktemp -d /private/tmp/idlo.XXXXXX)"
trap 'rm -rf "$work"' EXIT
python3 - "$bin" "$work" "$window" "$sample_seconds" <<'PY'
import ctypes, json, os, signal, socket, subprocess, sys, threading, time
from collections import defaultdict

bin_path, work, window, sample_seconds = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
lib = ctypes.CDLL("/usr/lib/libproc.dylib")

class ThreadInfo(ctypes.Structure):
    _fields_ = [("user", ctypes.c_uint64), ("system", ctypes.c_uint64)] + [
        (name, ctypes.c_int32) for name in
        ("cpu", "policy", "run_state", "flags", "sleep", "curpri", "pri", "maxpri")] + [
        ("name", ctypes.c_char * 64)]

class Rusage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64),
                ("pkg_idle_wkups", ctypes.c_uint64), ("interrupt_wkups", ctypes.c_uint64),
                ("rest", ctypes.c_uint64 * 15)]

class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

timebase = Timebase()
ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(timebase))

def threads(pid):
    handles = (ctypes.c_uint64 * 4096)()
    count = lib.proc_pidinfo(pid, 6, ctypes.c_uint64(0), handles, ctypes.sizeof(handles)) // 8
    out = {}
    for index in range(count):
        info = ThreadInfo()
        if lib.proc_pidinfo(pid, 5, ctypes.c_uint64(handles[index]), ctypes.byref(info), ctypes.sizeof(info)) > 0:
            out[handles[index]] = (info.name.decode(errors="replace") or "<unnamed>", info.user + info.system)
    return out

def process(pid):
    usage = Rusage()
    lib.proc_pid_rusage(pid, 2, ctypes.byref(usage))
    cpu = (usage.user + usage.system) * timebase.numer / max(timebase.denom, 1)
    return cpu, usage.pkg_idle_wkups + usage.interrupt_wkups

home = os.path.join(work, "home")
os.makedirs(home)
sock = os.path.join(work, "m.sock")
open(os.path.join(work, "cmux-next.json"), "w").write("{}\n")
env = dict(os.environ, HOME=home, CMUX_TUI_CONFIG=os.path.join(work, "config.json"),
           CMUX_NEXT_CONFIG_FILE=os.path.join(work, "cmux-next.json"),
           ACPMUX_SOCKET=os.path.join(work, "acpmux", "acpmux.sock"))
log = open(os.path.join(work, "daemon.log"), "w")
daemon = subprocess.Popen([bin_path, "--headless", "--socket", sock, "--state", os.path.join(work, "state"),
                           "--terminal-reap-grace-seconds", "30"], env=env, stdout=log, stderr=log)

def connect():
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock)
    return s

deadline = time.time() + 60
while True:
    try:
        connect().close()
        break
    except OSError:
        assert time.time() < deadline, "the owner never listened"
        time.sleep(0.05)

def request(value):
    s = connect()
    f = s.makefile("rwb")
    f.write((json.dumps(value) + "\n").encode()); f.flush()
    for line in f:
        msg = json.loads(line)
        if msg.get("id") == value["id"]:
            s.close()
            return msg

def stream(value):
    s = connect()
    f = s.makefile("rwb")
    f.write((json.dumps(value) + "\n").encode()); f.flush()
    for line in f:
        if json.loads(line).get("id") == value["id"]:
            break
    threading.Thread(target=lambda: [None for _ in f], daemon=True).start()
    return s

assert request({"id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": True, "name": "idle"})["ok"]
tree = request({"id": 2, "cmd": "list-workspaces"})["data"]
surface = next(t["surface"] for w in tree["workspaces"] for sc in w.get("screens", [])
               for p in sc.get("panes", []) for t in p.get("tabs", []) if isinstance(t.get("surface"), int))
streams = [stream({"id": 3, "cmd": "subscribe", "tree_events": "deltas"}),
           stream({"id": 4, "cmd": "attach-surface", "surface": surface, "mode": "bytes", "cols": 120, "rows": 40})]

def measure(phase):
    time.sleep(10)
    slices = max(1, int(window // 10))
    marks = [threads(daemon.pid)]
    before = process(daemon.pid)
    for _ in range(slices):
        time.sleep(window / slices)
        marks.append(threads(daemon.pid))
    after = process(daemon.pid)
    cpu_ms = (after[0] - before[0]) / 1e6
    wakeups = after[1] - before[1]
    print(f"IDLE-OWNER {phase} window_s={window:.0f} cpu_ms={cpu_ms:.1f} cpu_pct={cpu_ms / window / 10:.3f} "
          f"wakeups={wakeups} wakeups_per_s={wakeups / window:.2f} threads={len(marks[-1])}", flush=True)
    # Per thread: CPU over the window and in how many of its slices it ran
    # (a thread on a timer runs in every slice).
    per_name = defaultdict(lambda: [0, 0.0, 0])
    for handle, (name, total) in marks[-1].items():
        series = [mark.get(handle, (name, None))[1] for mark in marks]
        if series[0] is None:
            continue
        ran = sum(1 for a, b in zip(series, series[1:]) if a is not None and b is not None and b > a)
        key = name if not name.startswith("surface-") else "surface-*-" + name.rsplit("-", 1)[-1]
        entry = per_name[key]
        entry[0] += 1
        entry[1] += (total - series[0]) / 1e6
        entry[2] = max(entry[2], ran)
    for name, (count, used, ran) in sorted(per_name.items(), key=lambda item: -item[1][1]):
        if ran:
            print(f"IDLE-OWNER {phase} thread={name} x{count} ran_in={ran}/{slices}_slices cpu_ms={used:.3f}", flush=True)
    out = os.path.join(work, f"sample-{phase}.txt")
    subprocess.run(["sample", str(daemon.pid), sample_seconds, "-mayDie", "-file", out],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists(out):
        lines = open(out).read().splitlines()
        start = next((i for i, line in enumerate(lines) if line.startswith("Call graph:")), 0)
        print(f"IDLE-OWNER {phase} sample (call graph, first 80 lines):")
        for line in lines[start:start + 80]:
            print("  " + line[:200])
        top = next((i for i, line in enumerate(lines) if line.startswith("Sort by top of stack")), None)
        if top is not None:
            print(f"IDLE-OWNER {phase} sample (top of stack):")
            for line in lines[top:top + 25]:
                print("  " + line[:200])

measure("attached")
for s in streams:
    s.close()
measure("no-clients")
request({"id": 9, "cmd": "close-workspace", "key": tree["workspaces"][0]["key"], "end_terminals": True})
daemon.send_signal(signal.SIGTERM)
try:
    daemon.wait(timeout=20)
except subprocess.TimeoutExpired:
    daemon.kill()
PY
