#!/usr/bin/env python3
"""Terminal output throughput and cost per byte, PTY to pixels (HOT PATH AUDIT area B, path id terminal-output).

  fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
           --ref SHA --artifact artifacts/split-spring/report.json \\
           --arg=--config=bench --arg=--vdisplay=120 --arg=--app-cache --arg=--suite=terminal-flood
  by hand: bench-terminal-flood.py --app "/path/cmux DEV <tag>.app" --out DIR [--panes 1,4,12] [--mib 16]

Launches the tagged app (no activation, automation socket, scratch config), then for each pane count P
(1, 4, 12: a 1x1, 2x2 and 4x3 grid in one new workspace, every pane shown) and each workload W, all P
terminals produce at once:

  cat   `cat` of a generated log file (--mib MiB per pane: lines of 20-120 printable characters, one in 8
        with an SGR color): a build log or `git log` flood.
  yes   `yes | head -c BYTES`: 2-byte lines, the worst case for scroll per byte.

Per round it records:
  producer_s  each producer's wall time, from `/usr/bin/time -p` inside the shell: how long the PTY took to
              take every byte (the holder, the daemon and, through back-pressure, the app pace it);
  shown_s     from the round's start to the moment every pane's viewport shows the round's end marker
              (`debug.surfaces {text: true}`, read only after every producer ended, so the poll costs the
              flood nothing);
  mib_per_s   P * bytes / shown_s, the throughput a person sees;
  cpu_ms_per_mib  per process kind (app, daemon, holder), from proc_pid_rusage before and after the round:
              the CPU each byte costs in each process, which is what this audit ranks;
  wakeups_per_mib per process kind;
  frames      the app's display frames over the round (`debug.frames`): dropped frames, interval p95/max,
              main-thread ms per frame p95/max (`debug.main_cpu`);
  hangs       `debug.hangs` over the round;
  resyncs     per pane, the change of the terminal's restored snapshots (an overflowed attach resyncs).

Host models (--host-models default,holder) run interleaved in one step: --passes times A B (A B A B for 2),
one app launch per model per pass, so both models see the same host drift; compare them pass by pass.

Floors on the same host (no app), with the same bytes and the same P at once:
  floor_copy  `cat FILE > /dev/null` (the memory floor);
  floor_pty   the file through a PTY into a reader that does one read(2) of 64 KiB into one reused buffer per
              wakeup and drops the bytes: the kernel PTY floor of any terminal.

--profile also samples the app, the daemon and one holder (`/usr/bin/sample`, 1 ms) during one extra cat round
at the largest P, and keeps the reports (sample-<kind>.txt) with the top frames of each.

Writes OUT/terminal-flood.json (and --json PATH). Exit 0 always: a bench, not a gate.
"""
import argparse, json, os, random, re, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402
from bench_idle import usage  # noqa: E402  proc_pid_rusage: (cpu_ns, wakeups, footprint)

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--tag", help="the app's tag (split-spring.sh passes it; the bundle names it too)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/bench-terminal-flood")
parser.add_argument("--json", help="also write the report here (split-spring.sh's artifact)")
parser.add_argument("--panes", default="1,4,12")
parser.add_argument("--workloads", default="cat,yes")
parser.add_argument("--mib", type=float, default=16.0, help="MiB each pane produces per round")
parser.add_argument("--rounds", type=int, default=1, help="rounds per workload in each pass")
parser.add_argument("--passes", type=int, default=2,
                    help="interleaved passes over the host models (A B A B ...), one app launch per model per pass")
parser.add_argument("--timeout", type=float, default=600.0, help="seconds one round may take")
parser.add_argument("--profile", action="store_true", help="sample app, daemon and a holder in one extra round")
parser.add_argument("--host-models", default="default,holder",
                    help="terminal host models, one app launch each: default (a `__terminal-host` per terminal) and "
                         "holder (CMUX_NEXT_TUI_TERMINAL_HOST_MODEL=holder: one cmux-holder)")
opts, _unknown = parser.parse_known_args()
os.makedirs(opts.out, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="terminal-flood-")
BYTES = int(opts.mib * 1048576)
GRIDS = {1: (1, 1), 2: (2, 1), 4: (2, 2), 6: (3, 2), 8: (4, 2), 12: (4, 3)}
REPORT = {"bench": "terminal-flood", "path_id": "terminal-output", "mib_per_pane": opts.mib, "rounds": [], "floors": [],
          "profile": None, "notes": []}


def note(text):
    REPORT["notes"].append(text)
    print(f"terminal-flood: {text}", flush=True)


def payload(path, size):
    """A deterministic log-like file of `size` bytes: printable lines of 20-120 characters, 1 in 8 colored."""
    rng = random.Random(20261103)
    words = ["error", "warning", "Compiling", "src/terminal/page.zig", "0x7f3a", "ok", "test", "PASS", "==>",
             "[INFO]", "renderer", "frame", "commit", "a1b2c3d", "deadbeef", "|", "->", "...", "42", "lorem", "ipsum"]
    out, total = [], 0
    while total < size:
        n = rng.randint(20, 120)
        line = ""
        while len(line) < n:
            line += rng.choice(words) + " "
        line = line[:n]
        if rng.random() < 0.125:
            line = f"\x1b[3{rng.randint(1, 6)}m{line}\x1b[0m"
        out.append(line + "\n")
        total += len(line) + 1
    data = "".join(out).encode()[:size]
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


# -- processes ---------------------------------------------------------------------------------------------

def processes(app):
    """{pid: kind} for the app, its cmux-tui daemon and every PTY holder (exclusive host: they are this run's)."""
    kinds = {app.process.pid: "app"}
    tui = os.path.join(app.app, "Contents/Resources/bin/cmux-tui")
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines()
    for line in rows:
        parts = line.strip().split(None, 2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        pid, command = int(parts[0]), parts[2]
        if "cmux-holder" in command or "__terminal-host" in command or "__holder" in command:
            kinds[pid] = "holder"
        elif command.startswith(tui):
            kinds[pid] = "daemon"
    return kinds


def sample_usage(kinds):
    return {pid: usage(pid) for pid in kinds}


def usage_delta(kinds, before, after, mib):
    """Per kind: CPU ms, CPU ms per MiB, wakeups per MiB, process count."""
    per = {}
    for pid, kind in kinds.items():
        a, b = before.get(pid), after.get(pid)
        if a is None or b is None:
            continue
        row = per.setdefault(kind, {"processes": 0, "cpu_ms": 0.0, "wakeups": 0})
        row["processes"] += 1
        row["cpu_ms"] += (b[0] - a[0]) / 1e6
        row["wakeups"] += b[1] - a[1]
    for row in per.values():
        row["cpu_ms"] = round(row["cpu_ms"], 1)
        row["cpu_ms_per_mib"] = round(row["cpu_ms"] / mib, 2) if mib else None
        row["wakeups_per_mib"] = round(row["wakeups"] / mib, 1) if mib else None
    return per


# -- app -----------------------------------------------------------------------------------------------------

def row_of(rows, pane, tab):
    return rows.get(tab) or rows.get(pane) or {}


class Flood:
    def __init__(self, app):
        self.app = app

    def rpc(self, method, params=None, timeout=60):
        reply = self.app.rpc(method, params, timeout=timeout)
        return reply

    def action(self, name, args=None, target=None, focus=True, timeout=120):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def topology(self):
        reply = self.rpc("snapshot.get") or {}
        return (reply.get("topology") or {}) if isinstance(reply, dict) else {}

    def workspace(self, wid):
        return next((w for w in self.topology().get("workspaces") or [] if w.get("id") == wid), None)

    @staticmethod
    def panes(workspace):
        return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]

    def wait(self, check, seconds, step=0.1):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:  # bounded poll of the app's socket state in a test script
            try:
                value = check()
            except Exception:  # the app may not answer yet
                value = None
            if value:
                return value
            time.sleep(step)  # test script: the poll interval
        return None

    def new_workspace(self):
        before = {w.get("id") for w in self.topology().get("workspaces") or []}
        self.action("workspace.newAtBottom")
        wid = self.wait(lambda: next((w["id"] for w in self.topology().get("workspaces") or []
                                      if w.get("id") and w["id"] not in before), None), 30)
        if wid:
            self.action("goToWorkspace", {"workspace": wid})
        return wid

    def split(self, wid, pane, verb):
        before = {p["id"] for p in self.panes(self.workspace(wid))}
        self.action(verb, target=f"pane:{pane}")
        return self.wait(lambda: next((p["id"] for p in self.panes(self.workspace(wid)) if p["id"] not in before), None),
                         15)

    def grid(self, count):
        """A new workspace of `count` panes (columns x rows), each with its first terminal; [(pane, tab)]."""
        columns, rows = GRIDS[count]
        wid = self.new_workspace()
        first = self.panes(self.workspace(wid))[0]["id"]
        tops = [first]
        while len(tops) < columns:
            made = self.split(wid, tops[-1], "splitRight")
            if not made:
                break
            tops.append(made)
        for top in tops:
            chain = [top]
            while len(chain) < rows:
                made = self.split(wid, chain[-1], "splitDown")
                if not made:
                    break
                chain.append(made)
        self.action("equalizeSplits", target=f"pane:{first}")

        def terminals():
            out = []
            for pane in self.panes(self.workspace(wid)):
                tab = next((t.get("id") for t in pane.get("tabs") or [] if t.get("kind") == "terminal"
                            and not str(t.get("id", "")).startswith("pending_tab_")), None)
                if not tab:
                    return None
                out.append((pane["id"], tab))
            return out if len(out) >= count else None
        made = self.wait(terminals, 30) or []
        if len(made) != count:
            note(f"grid {count}: made {len(made)} panes")
        return wid, made

    def send(self, tab, text):
        return self.action("terminal.sendText", {"text": text}, target=f"tab:{tab}", focus=False)

    def surfaces(self, text=False):
        reply = self.rpc("debug.surfaces", {"text": text}, timeout=60) or {}
        rows = {}
        for window in reply.get("windows") or []:
            for pane in window.get("panes") or []:
                if isinstance(pane, dict):
                    # By pane id and by the shown tab's id: a row is found by either.
                    for key in (pane.get("pane"), pane.get("shown_tab"), pane.get("selected_tab")):
                        if key:
                            rows.setdefault(key, pane)
        return rows


def shell_ready(flood, tabs, nonce):
    """Each pane runs `printf` of a ready marker; True when every viewport shows it."""
    for _, tab in tabs:
        flood.send(tab, f"clear; printf 'READY-%s\\n' {nonce}\r")

    def ready():
        rows = flood.surfaces(text=True)
        return all(f"READY-{nonce}" in (row_of(rows, pane, tab).get("text") or "") for pane, tab in tabs)
    return bool(flood.wait(ready, 60, 0.25))


MODEL = {"name": "default", "pass": 0}


def run_round(flood, app, tabs, workload, file_path, round_index):
    nonce = f"{workload}{len(tabs)}r{round_index}t{int(time.time() * 1000) % 100000}"
    if not shell_ready(flood, tabs, nonce):
        note(f"{nonce}: a shell did not show its ready marker; round measured anyway")
    times = []
    for index, _ in enumerate(tabs):
        t = os.path.join(SCRATCH, f"{nonce}-{index}.time")
        times.append(t)
    if workload == "cat":
        producer = f"cat '{file_path}'"
    else:
        producer = f"yes | head -c {BYTES}"
    rows_before = flood.surfaces()
    snapshots_before = {pane: (row_of(rows_before, pane, tab).get("snapshots") or 0) for pane, tab in tabs}
    kinds = processes(app)
    flood.rpc("debug.hangs", {"clear": True})
    flood.rpc("debug.frames", {"action": "start"})
    flood.rpc("debug.main_cpu", {"action": "start"})
    before = sample_usage(kinds)
    start = time.monotonic()
    for index, (_, tab) in enumerate(tabs):
        # The time goes to a file (stderr of `time`), the bytes to the terminal; the marker ends the round.
        flood.send(tab, f"/usr/bin/time -p sh -c \"{producer}\" 2> '{times[index]}.tmp'; mv '{times[index]}.tmp' "
                        f"'{times[index]}'; printf '\\nEND-%s\\n' {nonce}\r")
    sent = time.monotonic() - start
    deadline = start + opts.timeout
    while time.monotonic() < deadline and not all(os.path.exists(t) for t in times):
        time.sleep(0.05)  # test script: wait for the producers' time files
    produced = time.monotonic() - start

    def shown():
        rows = flood.surfaces(text=True)
        return all(f"END-{nonce}" in (row_of(rows, pane, tab).get("text") or "") for pane, tab in tabs)
    ok = bool(flood.wait(shown, max(5.0, deadline - time.monotonic()), 0.05))
    shown_s = time.monotonic() - start
    after = sample_usage(kinds)
    cpu = flood.rpc("debug.main_cpu", {"action": "stop"}) or {}
    frames = flood.rpc("debug.frames", {"action": "stop"}) or {}
    hangs = flood.rpc("debug.hangs") or {}
    rows_after = flood.surfaces()
    snapshots_after = {pane: (row_of(rows_after, pane, tab).get("snapshots") or 0) for pane, tab in tabs}
    render = render_delta(tabs, rows_before, rows_after)
    producer_s = []
    for t in times:
        try:
            m = re.search(r"real\s+([\d.]+)", open(t).read())
            producer_s.append(float(m.group(1)) if m else None)
        except OSError:
            producer_s.append(None)
    total_mib = len(tabs) * BYTES / 1048576
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    row = {
        "model": MODEL["name"], "pass": MODEL["pass"], "workload": workload, "panes": len(tabs), "round": round_index, "complete": ok,
        "mib_total": round(total_mib, 2), "send_s": round(sent, 3),
        "producer_s_p50": pct(producer_s, 0.5), "producer_s_max": pct(producer_s, 1.0),
        "all_produced_s": round(produced, 3), "shown_s": round(shown_s, 3),
        "app_lag_s": round(shown_s - produced, 3),
        "mib_per_s": round(total_mib / shown_s, 2) if shown_s else None,
        "mib_per_s_per_pane": round(total_mib / shown_s / len(tabs), 2) if shown_s else None,
        "processes": usage_delta(kinds, before, after, total_mib),
        "frames": frames.get("frames"), "dropped": frames.get("missed"), "refresh_ms": frames.get("refresh_ms"),
        "frame_p95_ms": frames.get("p95_ms"), "frame_max_ms": frames.get("max_ms"),
        "main_ms_total": cpu.get("main_ms_total", frames.get("main_ms_total")),
        "main_ms_p95": cpu.get("main_ms_p95", frames.get("main_ms_p95")),
        "main_ms_max": cpu.get("main_ms_max", frames.get("main_ms_max")),
        "hangs": len(hang_list) if isinstance(hang_list, list) else (hangs.get("count") if isinstance(hangs, dict) else None),
        "resyncs": sum(max(0, snapshots_after.get(p, 0) - snapshots_before.get(p, 0)) for p, _ in tabs),
        # Ghostty's renderer counters summed over the round's panes: frame updates (updateFrame runs) against
        # frames drawn, and full rebuilds (every row) that are not a resize, swap, palette, font or config.
        "render": render,
        "frame_updates_per_frame": round(render["frame_updates"] / render["frames"], 2) if render.get("frames") else None,
        "full_rebuilds_per_update": round(render["full_other"] / render["frame_updates"], 2) if render.get("frame_updates") else None,
        "frame_updates_per_s_per_pane": round(render["frame_updates"] / shown_s / len(tabs), 1) if shown_s else None,
    }
    REPORT["rounds"].append(row)
    per = row["processes"]
    print(f"terminal-flood: {MODEL['name']:<7} p{MODEL['pass']} {workload:<3} P={len(tabs):<2} r{round_index} shown {row['shown_s']:.2f}s "
          f"({row['mib_per_s']} MiB/s; producer max {row['producer_s_max']}s; lag {row['app_lag_s']}s) cpu ms/MiB "
          + " ".join(f"{k} {v['cpu_ms_per_mib']}" for k, v in sorted(per.items()))
          + f" | dropped {row['dropped']} main p95 {row['main_ms_p95']} hangs {row['hangs']} resyncs {row['resyncs']}"
          + f" | updates/frame {row['frame_updates_per_frame']} full/update {row['full_rebuilds_per_update']}",
          flush=True)
    return row


RENDER_KEYS = ("frames", "frame_updates", "cell_rebuilds", "full_other", "full_resize", "full_swap", "full_palette")


def render_delta(tabs, before, after):
    total = {k: 0 for k in RENDER_KEYS}
    for pane, tab in tabs:
        a = (row_of(after, pane, tab).get("surface") or {}).get("render_counters") or {}
        b = (row_of(before, pane, tab).get("surface") or {}).get("render_counters") or {}
        for k in RENDER_KEYS:
            if k in a:
                total[k] += int(a[k]) - int(b.get(k, 0))
    return total


def profile_round(flood, app, tabs, file_path):
    """One cat round with /usr/bin/sample on the app, the daemon and the busiest holder."""
    kinds = processes(app)
    targets = {}
    for pid, kind in kinds.items():
        if kind not in targets:
            targets[kind] = pid
    samplers = []
    for kind, pid in targets.items():
        path = os.path.join(opts.out, f"sample-{MODEL['name']}-{kind}.txt")
        samplers.append((kind, path, subprocess.Popen(["/usr/bin/sample", str(pid), "8", "1", "-mayDie", "-file", path],
                                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)))
    time.sleep(0.5)  # test script: the samplers attach
    run_round(flood, app, tabs, "cat", file_path, 99)
    summary = {}
    for kind, path, proc in samplers:
        try:
            proc.wait(60)
        except subprocess.TimeoutExpired:
            proc.kill()  # the sampler this script started
        summary[kind] = top_frames(path)
    REPORT.setdefault("profile", {})
    REPORT["profile"] = {**(REPORT["profile"] or {}), MODEL["name"]: summary}


def top_frames(path, limit=25):
    """The heaviest symbols of a sample report (its 'Sort by top of stack' table)."""
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return None
    part = text.split("Sort by top of stack, same collapsed", 1)[-1].splitlines()[1:limit + 1]
    return [l.strip()[:160] for l in part if l.strip()]


# -- floors --------------------------------------------------------------------------------------------------

PTY_READER = r"""
import os, pty, sys, time
path = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execv('/bin/cat', ['cat', path])
buf = bytearray(65536)
view = memoryview(buf)
total = reads = 0
while True:
    try:
        n = os.readv(fd, [view])
    except OSError:
        break
    if n <= 0:
        break
    total += n
    reads += 1
os.waitpid(pid, 0)
print(total, reads)
"""


def floors(file_path, counts):
    reader = os.path.join(SCRATCH, "pty_reader.py")
    with open(reader, "w") as f:
        f.write(PTY_READER)
    for count in counts:
        for name, argv in (("floor_copy", ["/bin/sh", "-c", f"cat '{file_path}' > /dev/null"]),
                           ("floor_pty", ["/usr/bin/python3", reader, file_path])):
            t0 = time.monotonic()
            procs = [subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) for _ in range(count)]
            outs = [p.communicate()[0].decode() for p in procs]
            wall = time.monotonic() - t0
            reads = [int(o.split()[1]) for o in outs if len(o.split()) == 2]
            total_mib = count * BYTES / 1048576
            row = {"floor": name, "panes": count, "wall_s": round(wall, 3), "mib_per_s": round(total_mib / wall, 1),
                   "reads_per_mib": round(sum(reads) / total_mib, 1) if reads else None}
            REPORT["floors"].append(row)
            print(f"terminal-flood: {name} P={count} {row['wall_s']}s {row['mib_per_s']} MiB/s reads/MiB "
                  f"{row['reads_per_mib']}", flush=True)


def main():
    if not opts.app:
        raise SystemExit("terminal-flood: --app is required")
    file_path = os.path.join(SCRATCH, "flood.txt")
    payload(file_path, BYTES)
    counts = [int(c) for c in opts.panes.split(",") if c.strip()]
    for count in counts:
        if count not in GRIDS:
            raise SystemExit(f"terminal-flood: no grid for {count} panes ({sorted(GRIDS)})")
    floors(file_path, counts)
    REPORT["host"] = os.uname().nodename
    models = [m for m in opts.host_models.split(",") if m]
    # Interleaved arms (A B A B): each pass launches every model once, in the same order, so drift of the host
    # (thermal, background work) falls on both models alike. Compare models only across matching passes.
    for index in range(opts.passes):
        for model in models:
            MODEL["name"], MODEL["pass"] = model, index
            env = {"CMUX_NEXT_TUI_TERMINAL_HOST_MODEL": "holder"} if model == "holder" else {}
            app = BenchApp(opts.app, out=opts.out, env=env, window=(40, 40, 1600, 1000),
                           log_name=f"app-{model}-p{index}.log")
            try:
                measure_model(app, counts, file_path, profile=opts.profile and index == opts.passes - 1)
            except LaunchError as error:
                note(f"{model} pass {index}: launch failed: {error}")
            finally:
                app.stop()
    REPORT["arm_order"] = [f"{m}-p{i}" for i in range(opts.passes) for m in models]
    write_report()


def measure_model(app, counts, file_path, profile=False):
    app.launch()
    flood = Flood(app)
    for count in counts:
        wid, tabs = flood.grid(count)
        REPORT.setdefault("grids", []).append({"model": MODEL["name"], "panes": count, "workspace": wid, "made": len(tabs)})
        if not tabs:
            continue
        # Warm: one small round so the first measured one does not pay first-output costs.
        for _, tab in tabs:
            flood.send(tab, "seq 1 2000\r")
        time.sleep(1.0)  # test script: the warm output lands
        kinds = sorted(set(processes(app).values()))
        REPORT.setdefault("process_kinds", {})[MODEL["name"]] = kinds
        for workload in [w for w in opts.workloads.split(",") if w]:
            for r in range(opts.rounds):
                run_round(flood, app, tabs, workload, file_path, r)
        if profile and count == max(counts):
            profile_round(flood, app, tabs, file_path)


def write_report():
    out = json.dumps(REPORT, indent=1)
    with open(os.path.join(opts.out, "terminal-flood.json"), "w") as f:
        f.write(out)
    if opts.json:
        with open(opts.json, "w") as f:
            f.write(out)
    summary = {}
    for row in REPORT["rounds"]:
        key = f"{row['model']}-{row['workload']}-{row['panes']}"
        summary.setdefault(key, []).append(row["mib_per_s"])
    print("TERMINAL-FLOOD " + json.dumps({k: statistics.median([v for v in vs if v] or [0]) for k, vs in summary.items()}),
          flush=True)


if __name__ == "__main__":
    main()
