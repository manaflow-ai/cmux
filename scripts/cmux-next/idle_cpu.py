#!/usr/bin/env python3
"""Idle CPU and wakeups of a cmux NEXT build: the app, its acpmux and its cmux-tui, after N minutes idle.

    idle_cpu.py (--artifact sha256:HEX | --app APP) [--minutes 10] [--window 60] [--windows 3]
                [--chats 0] [--fake-agent SCRIPT] [--no-sample] [--budget-cpu 1.0] [--budget-wakeups 1.0]
                [--out DIR]

The app is ready when a window is visible and its first frame is committed (not when Home is selected).
A dogfood build must rest when nobody uses it: on 2026-11-04 Lawrence's idle Mac had acpmux daemons at
20-52 % CPU each (cmux-ad m9). This launches the build as a first install would (an empty HOME, no
defaults: scripts/ci/fresh_home_launch_smoke.py), waits for Home in its first window, optionally makes
CHATS agent chats whose first turn has ended (the acpmux test agent, as bench_memory.py --fake-agent),
then leaves the app alone for MINUTES with no call into it. It then measures every process of the
bundle over WINDOWS windows of WINDOW seconds each, from proc_pid_rusage at both ends of each window (no
call into the measured processes): CPU % of one core, package-idle plus interrupt wakeups per second
and context switches per second. A process is judged by its median window. Last, `sample PID 5` of each
acpmux and cmux-tui daemon process and of any process above the CPU budget: the heaviest stacks name the
loop that runs while idle.

Output: IDLE-CPU lines, one per process and window summary, then IDLE-CPU-VERDICT pass|fail with the
processes over budget (acpmux and cmux-tui daemon processes only: CPU % median > --budget-cpu or wakeups/s
median > --budget-wakeups). --out keeps report.json and the samples (sample-<kind>-<pid>.txt).
Exit 0: within budget. 1: over budget. 3: could not run (no app, no GUI session, Home never rendered).

Run it on a quiet fleet Mac only, through the mini scheduler (scripts/measure/idle-cpu.sh); never on a
person's Mac. It never touches another app: every process it starts runs under its own /tmp root and is
stopped by exact pid.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ci"))

import bench_memory  # noqa: E402  (scripts/cmux-next: process table, rusage, the app's CLI, test chats)
import fresh_home_launch_smoke as smoke  # noqa: E402  (scripts/ci: the first-install launch)

CONTROLLER = os.environ.get("CMUX_CI_CONTROLLER") or "http://100.89.225.106:18765"
# The processes the verdict judges: the daemons that must rest. The app and its helpers are reported too.
DAEMON_KINDS = re.compile(r"^(acpmux-.*|tui-daemon.*|terminal-host)$")
SAMPLE_KINDS = re.compile(r"^(acpmux-.*|tui-daemon.*)$")


def log(message: str) -> None:
    print(message, flush=True)


def fetch_app(digest: str, cache_root: Path) -> Path:
    """The build's app from the controller store by sha256 (checked), cached per digest."""
    hexd = digest.removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", hexd):
        raise SystemExit("idle-cpu: --artifact must be sha256:<64 hex>")
    folder = cache_root / hexd
    apps = sorted(folder.glob("x/*.app")) if (folder / "ok").exists() else []
    if apps:
        log(f"idle-cpu: app of {hexd[:12]} from the cache")
        return apps[0]
    shutil.rmtree(folder, ignore_errors=True)
    (folder / "x").mkdir(parents=True)
    archive = folder / "app.zip"
    url = ""
    try:
        with urllib.request.urlopen(f"{CONTROLLER}/v1/artifacts/sha256:{hexd}/url", timeout=60) as reply:
            url = json.load(reply).get("url") or ""
    except (OSError, ValueError):
        url = ""
    # The signed URL is a short-lived read capability: never printed. Without one, the controller serves it.
    fetched = bool(re.fullmatch(r"https://[^\s\"']+", url)) and subprocess.run(
        ["curl", "-fsS", "--retry", "3", "-o", str(archive), url], timeout=1800).returncode == 0
    if not fetched:
        subprocess.run(["curl", "-fsS", "--retry", "3", "-o", str(archive),
                        f"{CONTROLLER}/v1/artifacts/sha256:{hexd}"], check=True, timeout=1800)
    digest_now = hashlib.sha256()
    with open(archive, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest_now.update(chunk)
    if digest_now.hexdigest() != hexd:
        raise SystemExit(f"idle-cpu: the download of {hexd[:12]} has sha256 {digest_now.hexdigest()[:12]}")
    subprocess.run(["ditto", "-x", "-k", str(archive), str(folder / "x")], check=True, timeout=600)
    archive.unlink()
    apps = sorted((folder / "x").glob("*.app"))
    if not apps:
        raise SystemExit(f"idle-cpu: the artifact {hexd[:12]} holds no .app")
    (folder / "ok").touch()
    # Keep the newest four builds.
    for old in sorted((p for p in cache_root.iterdir() if p.is_dir() and p != folder),
                      key=lambda p: p.stat().st_mtime)[:-3]:
        shutil.rmtree(old, ignore_errors=True)
    return apps[0]


def switches(pid: int) -> int | None:
    """Context switches of all threads (proc_pidinfo PROC_PIDTASKINFO pti_csw), or None once the pid is gone."""
    import ctypes
    buf = (ctypes.c_int32 * 32)()
    size = ctypes.sizeof(buf)
    got = bench_memory._libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(4), ctypes.c_uint64(0),
                                             ctypes.byref(buf), ctypes.c_int(size))
    if got < 96:
        return None
    # proc_taskinfo: 6 u64 (12 i32 words), then policy, faults, pageins, cow_faults, messages_sent,
    # messages_received, syscalls_mach, syscalls_unix, csw (word 20), threadnum, numrunning, priority.
    return int(buf[20])


def measure(app_pid: int, bundle: str, windows: int, window: float, each=None) -> list[dict]:
    """Per process: kind, command and each window's CPU %, wakeups/s, switches/s, then the medians. `each(rows, index)`,
    if given, runs after each window with that window's rows (busiest first); a new window starts after it returns, so
    its own work (a `sample`) is never inside a measured window."""
    procs = bench_memory.owned(app_pid, bundle)

    def mark():
        return time.monotonic(), {pid: (bench_memory.usage(pid), switches(pid)) for pid in procs}

    spans = []
    for index in range(windows):
        start = mark()
        time.sleep(window)  # the measured idle window: no call into the app or its processes
        spans.append((start, mark()))
        if each is not None:
            each(rows_of(procs, spans[-1:]), index)
    return rows_of(procs, spans)


def rows_of(procs: dict, spans: list) -> list[dict]:
    rows = []
    for pid, (kind, cmd) in procs.items():
        per = []
        for (t0, before), (t1, after) in spans:
            (u0, c0), (u1, c1) = before.get(pid, (None, None)), after.get(pid, (None, None))
            if u0 is None or u1 is None:
                continue
            span = max(t1 - t0, 1e-3)
            per.append({"cpu_pct": round(100 * (u1[3] - u0[3]) / 1e9 / span, 3),
                        "wakeups_per_s": round((u1[4] - u0[4]) / span, 2),
                        "switches_per_s": round((c1 - c0) / span, 2) if c0 is not None and c1 is not None else None})
        if not per:
            continue

        def mid(key):
            values = sorted(w[key] for w in per if w[key] is not None)
            return values[len(values) // 2] if values else None
        rows.append({"pid": pid, "kind": kind, "command": cmd[:200], "windows": per,
                     "cpu_pct": mid("cpu_pct"), "wakeups_per_s": mid("wakeups_per_s"),
                     "switches_per_s": mid("switches_per_s")})
    rows.sort(key=lambda row: -(row["cpu_pct"] or 0))
    return rows


def top_lines(pids: list[int]) -> str:
    """`top` idle wakeups (idlew) and CPU of PIDS over one 5 s sample, as a cross-check."""
    if not pids:
        return ""
    argv = ["top", "-l", "2", "-s", "5", "-stats", "pid,command,cpu,idlew,csw,threads"]
    for pid in pids[:20]:
        argv += ["-pid", str(pid)]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as error:
        return f"(top failed: {error})"
    # The second sample is the one with rates.
    parts = out.split("PID ")
    return ("PID " + parts[-1]).rstrip() if len(parts) > 1 else out[-2000:]


def heaviest(text: str, lines: int = 45) -> str:
    """The call graph's first LINES lines and the 'Sort by top of stack' list of a `sample` report."""
    graph = text.split("Call graph:", 1)
    head = "\n".join(graph[1].splitlines()[:lines]) if len(graph) > 1 else ""
    tops = text.split("Sort by top of stack, same collapsed", 1)
    tail = "\n".join(tops[1].splitlines()[:20]) if len(tops) > 1 else ""
    return f"Call graph (first {lines} lines):\n{head}\nTop of stack:\n{tail}"


# Frames where an idle thread waits: never "the" busy frame.
WAIT_FRAMES = ("__psynch_cvwait", "semaphore_wait_trap", "semaphore_timedwait_trap", "kevent", "kevent64", "kevent_id",
               "mach_msg2_trap", "mach_msg_trap", "__workq_kernreturn", "__select", "__semwait_signal", "poll",
               "__ulock_wait", "__ulock_wait2", "read", "__read_nocancel", "accept", "__accept", "nanosleep",
               "__wait4", "waitid", "__sigsuspend", "__pselect", "__recvfrom")


def top_frame(text: str) -> str:
    """The busiest non-waiting frame of a `sample` report ('Sort by top of stack'), else its first frame."""
    tops = text.split("Sort by top of stack, same collapsed", 1)
    rows = []
    for line in (tops[1].splitlines()[1:] if len(tops) > 1 else []):
        m = re.match(r"^\s+(.+?)\s+(\d+)\s*$", line)
        if not m:
            if rows:
                break
            continue
        rows.append((m.group(1).strip(), int(m.group(2))))
    busy = [row for row in rows if row[0].split("  (in ")[0].strip() not in WAIT_FRAMES]
    pick = (busy or rows or [("", 0)])[0]
    return f"{pick[0]} x{pick[1]}" if pick[0] else ""


def sample(pid: int, kind: str, out: Path | None) -> str:
    target = (out or Path("/tmp")) / f"sample-{kind}-{pid}.txt"
    try:
        subprocess.run(["sample", str(pid), "5", "-mayDie", "-file", str(target)],
                       capture_output=True, text=True, timeout=90)
        text = target.read_text(errors="replace")
    except (OSError, subprocess.SubprocessError) as error:
        log(f"IDLE-CPU-SAMPLE {kind} pid={pid} failed: {error}")
        return ""
    log(f"IDLE-CPU-SAMPLE {kind} pid={pid} ({target.name})\n{heaviest(text)}\nIDLE-CPU-SAMPLE-END {kind} pid={pid}")
    return text


def seed_history(home: Path, chats: int, prompt_kb: int = 0) -> dict:
    """A person's agent history in HOME, as on a used Mac (a fresh home did not show the idle loop, cmux-ad m9):
    CHATS Claude Code transcripts over 40 projects, the same number of Codex rollouts, and a Codex state database in
    WAL mode whose writer was killed (its -wal and -shm stay, as after a hibernated Codex was stopped). Text only, no
    credential. Returns the counts."""
    import uuid as uuidlib
    day = time.strftime("%Y/%m/%d").split("/")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    ms = int(time.time() * 1000)
    codex = home / ".codex"
    (codex / "sessions" / day[0] / day[1] / day[2]).mkdir(parents=True, exist_ok=True)
    rows = []
    for i in range(chats):
        project = f"/Users/dev/work/p{i % 40}"
        sid = str(uuidlib.UUID(int=(0x1A << 120) + i))
        folder = home / ".claude" / "projects" / project.replace("/", "-")
        folder.mkdir(parents=True, exist_ok=True)
        lines = []
        for turn in range(6):
            lines.append({"type": "user", "isSidechain": False, "cwd": project, "sessionId": sid, "timestamp": stamp,
                          "message": {"role": "user", "content": f"chat {i} turn {turn}: fix the build"}})
            lines.append({"type": "assistant", "isSidechain": False, "cwd": project, "sessionId": sid,
                          "timestamp": stamp, "message": {"role": "assistant",
                                                          "content": [{"type": "text", "text": "done " * 40}]}})
        (folder / f"{sid}.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
        cid = str(uuidlib.UUID(int=(0x2B << 120) + i))
        rollout = codex / "sessions" / day[0] / day[1] / day[2] / f"rollout-{time.strftime('%Y-%m-%dT%H-%M-%S')}-{cid}.jsonl"
        rollout.write_text(json.dumps({"timestamp": stamp, "type": "session_meta", "payload": {
            "id": cid, "timestamp": stamp, "cwd": project, "originator": "codex_cli_rs"}}) + "\n"
            + json.dumps({"timestamp": stamp, "type": "event_msg", "payload": {
                "type": "user_message", "message": f"codex chat {i}: add a test"}}) + "\n")
        # A real Codex row keeps its first prompt three times (title, preview, first_user_message), ~29 KB each on a
        # busy Mac (#28771): --history-prompt-kb gives each Codex row a prompt of that size.
        prompt = f"codex chat {i}" + ("\ncontext line" * (prompt_kb * 80) if prompt_kb else "")
        rows.append((cid, str(rollout), ms // 1000, project, prompt, ms))
    # A child process writes the database and is killed with SIGKILL: its -wal and -shm stay with no writer.
    script = (
        "import sqlite3,sys,os,json\n"
        "c=sqlite3.connect(sys.argv[1]); c.execute('pragma journal_mode=wal')\n"
        "c.execute('create table threads (id text primary key, rollout_path text not null, created_at integer not null,"
        " updated_at integer not null, source text, cwd text not null, title text not null, has_user_event integer not"
        " null default 0, archived integer not null default 0, first_user_message text not null default \\'\\',"
        " created_at_ms integer, updated_at_ms integer, preview text not null default \\'\\', name text,"
        " originator text)')\n"
        "c.execute('create table thread_spawn_edges (parent_thread_id text not null, child_thread_id text not null"
        " primary key, status text not null)')\n"
        "for r in json.loads(sys.stdin.read()):\n"
        "  c.execute('insert into threads (id, rollout_path, created_at, updated_at, source, cwd, title, has_user_event,"
        " first_user_message, created_at_ms, updated_at_ms, preview, originator) values (?,?,?,?,\\'cli\\',?,?,1,?,?,?,?,"
        "\\'codex_cli_rs\\')', (r[0], r[1], r[2], r[2], r[3], r[4], r[4], r[5], r[5], r[4]))\n"
        "c.commit(); os.kill(os.getpid(), 9)\n")
    subprocess.run([sys.executable, "-I", "-c", script, str(codex / "state_5.sqlite")], input=json.dumps(rows),
                   text=True, timeout=600)
    left = sorted(p.name for p in codex.glob("state_5.sqlite*"))
    return {"claude_chats": chats, "codex_chats": chats, "codex_store_files": left}


WRITER = r"""
import json, os, random, sqlite3, sys, time
home, every, count_file = sys.argv[1], float(sys.argv[2]), sys.argv[3]
parent = os.getppid()
db = os.path.join(home, ".codex", "state_5.sqlite")
claude = sorted(os.path.join(r, f) for r, _, fs in os.walk(os.path.join(home, ".claude", "projects")) for f in fs
                if f.endswith(".jsonl"))
# A running Codex holds its state database open in WAL mode and writes it about once a second (#28771); a running
# Claude Code appends its transcript as it works. Both from outside cmux: no user action in the app.
conn = sqlite3.connect(db)
ids = [row[0] for row in conn.execute("select id from threads")]
n = 0
while os.getppid() == parent:   # the run that started it ended (also a SIGKILLed step): stop
    n += 1
    now = int(time.time() * 1000)
    conn.execute("update threads set updated_at = ?, updated_at_ms = ? where id = ?",
                 (now // 1000, now, random.choice(ids)))
    conn.commit()
    if claude:
        with open(random.choice(claude), "a") as f:
            f.write(json.dumps({"type": "assistant", "isSidechain": False, "timestamp": "2026-11-04T00:00:00.000Z",
                                "message": {"role": "assistant", "content": [{"type": "text", "text": f"step {n}"}]}})
                    + "\n")
    with open(count_file, "w") as f:
        f.write(str(n))
    time.sleep(every)
"""


def start_writers(home: Path, every: float, log_dir: Path) -> subprocess.Popen:
    """Agents at work outside cmux: one Codex state database write and one Claude Code transcript line every EVERY
    seconds (a stand-in for the Claude Code and Codex sessions in a person's terminals). It runs under HOME, so the
    launch smoke stops it with the app (by the run's root)."""
    log_dir.mkdir(parents=True, exist_ok=True)
    errors = open(log_dir / "writers.log", "ab")
    # Not a new session: the writer stays in the step's process group, so a step that is killed takes it along;
    # it also stops when its parent (this run) is gone.
    return subprocess.Popen([sys.executable, "-I", "-c", WRITER, str(home), str(every), str(log_dir / "writers.count")],
                            stdin=subprocess.DEVNULL, stdout=errors, stderr=errors)


def writer_writes(log_dir: Path) -> int:
    try:
        return int((log_dir / "writers.count").read_text() or 0)
    except (OSError, ValueError):
        return 0


def group_of(row: dict) -> str | None:
    """The bench's three groups: the app process, every acpmux process (also `cmux acp ...` inside cmux-tui), and
    every other cmux-tui process (daemons and terminal hosts). CEF helpers and the rest are in none."""
    if row["kind"] == "app":
        return "app"
    if row["kind"].startswith("acpmux") or " acp " in row["command"]:
        return "acpmux"
    if row["kind"].startswith("tui-daemon") or row["kind"] == "terminal-host":
        return "cmux_tui"
    return None


def bench_line(rows: list[dict], samples: dict) -> dict:
    """The DOGFOOD BENCH line (dogfood-bench/bench.py): per group, CPU % and wakeups/s summed over its processes, the
    mean over the LAST measured window; each process; and the busiest process with its top non-waiting stack frame."""
    line: dict = {}
    for name in ("app", "acpmux", "cmux_tui"):
        members = [row for row in rows if group_of(row) == name]
        last = [row["windows"][-1] for row in members]
        # A group with no process gets no numbers (never 0 %: the bench would read that as a rest).
        line[name] = {"n": 0} if not members else {
            "n": len(members), "cpu_pct": round(sum(w["cpu_pct"] for w in last), 3),
            "wakeups_per_s": round(sum(w["wakeups_per_s"] for w in last), 2)}
    line["processes"] = [{"kind": row["kind"], "pid": row["pid"], "group": group_of(row),
                          "cpu_pct": row["windows"][-1]["cpu_pct"], "wakeups_per_s": row["windows"][-1]["wakeups_per_s"]}
                         for row in rows if group_of(row)]
    if rows:
        top = rows[0]   # the process measure() ranks first and main() always samples
        line["busiest"] = {"kind": top["kind"], "pid": top["pid"], "cpu_pct": top["windows"][-1]["cpu_pct"],
                           "top_frame": top_frame(samples.get(top["pid"], ""))}
    return line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--artifact", help="sha256:HEX of a fleet build's app zip (cmux-ci status JOB: artifact)")
    source.add_argument("--app", help="an app bundle on this Mac")
    parser.add_argument("--minutes", type=float, default=10.0, help="idle time before the measure")
    parser.add_argument("--window", type=float, default=60.0, help="seconds per measured window")
    parser.add_argument("--windows", type=int, default=3, help="measured windows (median judged)")
    parser.add_argument("--chats", type=int, default=0, help="agent chats with a finished turn, made before the idle")
    parser.add_argument("--fake-agent", default=str(HERE.parent.parent / "cmux-tui/crates/acpmux/tests/fake_agent.py"))
    parser.add_argument("--history-prompt-kb", type=int, default=0,
                        help="with --history: each Codex row's prompt size in KB (a busy Mac's rows: ~29)")
    parser.add_argument("--writers", type=float, default=0.0,
                        help="with --history: agents at work outside cmux, one Codex DB write and one Claude transcript "
                             "line every this many seconds during the idle period (0: none)")
    parser.add_argument("--history", type=int, default=0,
                        help="seed the fresh home with this many Claude Code and Codex chats (a used Mac's history)")
    parser.add_argument("--no-sample", action="store_true")
    parser.add_argument("--sample-each-window", action="store_true",
                        help="after each window: one IDLE-CPU-WINDOW line per daemon and `sample` of the busiest process")
    parser.add_argument("--budget-cpu", type=float, default=1.0, help="CPU %% of one core per daemon process")
    parser.add_argument("--budget-wakeups", type=float, default=1.0, help="wakeups per second per daemon process")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    if (args.windows < 1 or args.window <= 0 or args.minutes < 0 or args.chats < 0 or args.history < 0
            or not math.isfinite(args.writers) or not math.isfinite(args.window) or not math.isfinite(args.minutes)
            or args.writers < 0 or args.history_prompt_kb < 0 or (args.writers > 0 and args.history <= 0)):
        parser.error("--windows must be >= 1, --window > 0, --minutes, --chats, --history, --history-prompt-kb and "
                     "--writers >= 0, and --writers needs --history")
    out = Path(args.out) if args.out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get("CI_SHARED_CACHE_DIR") or "/tmp") / "idle-cpu-apps"
    cache.mkdir(parents=True, exist_ok=True)
    try:
        app_source = fetch_app(args.artifact, cache) if args.artifact else Path(args.app)
    except (SystemExit, OSError, ValueError, subprocess.SubprocessError) as error:
        log(f"IDLE-CPU-VERDICT cannot-run the build could not be fetched: {error}")
        return 3
    result: dict = {"minutes": args.minutes, "window_s": args.window, "windows": args.windows, "chats": args.chats,
                    "host": os.uname().nodename, "artifact": args.artifact}
    verdict = {"status": 3, "why": "the launch did not reach the idle period"}

    def after_render(process, socket_path, env, app, out_dir, report):
        bundle = str(app)
        client = bench_memory.App(bundle, str(socket_path))
        made = 0
        if args.chats > 0:
            chats = bench_memory.FakeChats(client, bundle, args.fake_agent)
            for index in range(args.chats):
                made += chats.open(index) is not None
            log(f"idle-cpu: {made} of {args.chats} chats made, their first turn answered")
            if made < args.chats:
                verdict.update(status=3, why=f"only {made} of {args.chats} chats were made")
                return []
        result["chats_made"] = made
        log(f"idle-cpu: idle {args.minutes:g} min from now, no call into the app")
        time.sleep(args.minutes * 60)  # the idle period itself
        if process.poll() is not None:
            verdict.update(status=1, why=f"the app exited during the idle period (status {process.returncode})")
            return [verdict["why"]]
        def each(window_rows, index):
            for row in window_rows:
                if group_of(row) in ("acpmux", "cmux_tui") or row["kind"] == "app":
                    log(f"IDLE-CPU-WINDOW {index + 1}/{args.windows} {row['kind']} pid={row['pid']} "
                        f"cpu_pct={row['cpu_pct']} wakeups_per_s={row['wakeups_per_s']}")
            if window_rows and index + 1 < args.windows:
                top = window_rows[0]
                text = sample(top["pid"], f"{top['kind']}-w{index + 1}", out)
                log(f"IDLE-CPU-WINDOW {index + 1}/{args.windows} busiest {top['kind']} pid={top['pid']} "
                    f"cpu_pct={top['cpu_pct']} top_frame={top_frame(text)!r}")

        rows = measure(process.pid, bundle, args.windows, args.window,
                       each if args.sample_each_window and not args.no_sample else None)
        result["processes"] = rows
        for row in rows:
            log(f"IDLE-CPU {row['kind']} pid={row['pid']} cpu_pct={row['cpu_pct']} wakeups_per_s={row['wakeups_per_s']} "
                f"switches_per_s={row['switches_per_s']} windows={json.dumps([[w['cpu_pct'], w['wakeups_per_s']] for w in row['windows']])}")
        kinds: dict = {}
        for row in rows:
            entry = kinds.setdefault(row["kind"], {"n": 0, "cpu_pct": 0.0, "wakeups_per_s": 0.0})
            entry["n"] += 1
            entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 3)
            entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 2)
        result["kinds"] = kinds
        for kind, entry in sorted(kinds.items(), key=lambda item: -item[1]["cpu_pct"]):
            log(f"IDLE-CPU-KIND {kind} n={entry['n']} cpu_pct={entry['cpu_pct']} wakeups_per_s={entry['wakeups_per_s']}")
        top = top_lines([row["pid"] for row in rows if SAMPLE_KINDS.match(row["kind"]) or row["kind"] == "app"])
        log("IDLE-CPU-TOP\n" + top)
        samples: dict = {}
        if not args.no_sample:
            for index, row in enumerate(rows):   # rows are busiest first: the first one is always sampled
                if index == 0 or SAMPLE_KINDS.match(row["kind"]) or row["cpu_pct"] > args.budget_cpu:
                    samples[row["pid"]] = sample(row["pid"], row["kind"], out)
        result["bench"] = dict(bench_line(rows, samples), history=args.history, prompt_kb=args.history_prompt_kb,
                               writers=args.writers, writes=writer_writes(writer_dir))
        log("IDLE-CPU-JSON " + json.dumps(result["bench"], sort_keys=True))
        # The bundle's acpmux daemon: `acpmux daemon run`, or the same daemon inside cmux-tui (`cmux acp daemon run`).
        acp = [row for row in rows if row["kind"].startswith("acpmux-daemon") or " acp daemon run" in row["command"]]
        tui = [row for row in rows if row["kind"].startswith("tui-daemon") and " acp " not in row["command"]]
        if not acp or not tui:
            verdict.update(status=3, why="no " + " and no ".join(
                name for name, found in (("acpmux daemon", acp), ("cmux-tui daemon", tui)) if not found)
                + " of the bundle was measured")
            return []
        over = [row for row in rows if DAEMON_KINDS.match(row["kind"])
                and (row["cpu_pct"] > args.budget_cpu or row["wakeups_per_s"] > args.budget_wakeups)]
        result["over_budget"] = [{k: row[k] for k in ("kind", "pid", "cpu_pct", "wakeups_per_s")} for row in over]
        verdict["status"] = 1 if over else 0
        writers = state.get("writers")
        if writers is not None:
            result["writers"]["writes"] = writer_writes(writer_dir)
            if writers.poll() is not None:
                verdict.update(status=3, why=f"the outside writers stopped (status {writers.returncode}; "
                                            f"{writer_dir / 'writers.log'})")
            elif result["writers"]["writes"] < 2:
                verdict.update(status=3, why="the outside writers wrote nothing")
        return []

    smoke.AFTER_RENDER = after_render
    # Idle CPU needs a launched app with a visible window and its first frame, not Home selected: a fresh launch of
    # feat opens a New Tab tab with Home in the sidebar (tip-watcher smoke check-01.png, 2026-11-04 11:35Z).
    smoke.READY = lambda snap: smoke.visible_windows(snap) > 0
    state: dict = {}
    writer_dir = (out or Path(tempfile.mkdtemp(prefix="idle-cpu-"))) / "writers"
    if args.history > 0:
        def prepare(env):
            result["history"] = seed_history(Path(env["HOME"]), args.history, args.history_prompt_kb)
            log(f"idle-cpu: home seeded: {json.dumps(result['history'])}")
            if args.writers > 0:
                writers = start_writers(Path(env["HOME"]), args.writers, writer_dir)
                state["writers"] = writers
                result["writers"] = {"every_s": args.writers, "pid": writers.pid}
                log(f"idle-cpu: outside agents write every {args.writers:g} s (pid {writers.pid})")
        smoke.PREPARE_HOME = prepare
    try:
        status = smoke.main(["--app", str(app_source), "--seconds", "5", "--startup-timeout", "180",
                             *(["--out", str(out / "launch")] if out else [])])
    except (SystemExit, OSError, ValueError, subprocess.SubprocessError) as error:
        verdict.update(status=3, why=f"{type(error).__name__}: {error}")
        status = 3
    if status != 0 and verdict["status"] == 0:
        verdict.update(status=3, why=f"the launch smoke exited {status}")
    over = result.get("over_budget") or []
    word = {0: "pass", 1: "fail"}.get(verdict["status"], "cannot-run")
    detail = "; ".join(f"{r['kind']} pid {r['pid']} cpu {r['cpu_pct']}% wakeups {r['wakeups_per_s']}/s" for r in over)
    if verdict["status"] != 0 and not detail:
        detail = verdict.get("why", "")
    context = (f"history={args.history} prompt_kb={args.history_prompt_kb} writers={args.writers:g}"
               f"/{(result.get('writers') or {}).get('writes', 0)}writes")
    log(f"IDLE-CPU-VERDICT {word} minutes={args.minutes:g} chats={result.get('chats_made', 0)} {context} "
        f"budget cpu<={args.budget_cpu}% wakeups<={args.budget_wakeups}/s per daemon process"
        + (f": {detail}" if detail else ""))
    if out:
        (out / "report.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    return verdict["status"]


if __name__ == "__main__":
    sys.exit(main())
