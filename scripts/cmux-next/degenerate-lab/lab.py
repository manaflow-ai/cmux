#!/usr/bin/env python3
"""The degenerate lab: Leo's god chats, restarts, streaming, connectivity storms and load, small
against god in one harness, idle against loaded, and whether every number comes back once the
load is lifted.

Leo, 2026-11-12: "are you guys able to simulate my god-chats? like a true gb-level history sample
and stuff, and also simulate restarts? and simulate fps under load for stuff? and simulate
streaming text and acpmux along with lots of connectivity? like truly degenerated cases/states and
seeing where we can identify more perf to tackle". The goal: "even if a chat is long, there should
be no percievable difference" (cmuxterm-hq#9776).

Parts (each a subcommand; `matrix` runs them all):

- `fixtures`: seeded transcripts at each --scale (gen_transcript.py: Claude Code and Codex, the
  coordinator's measured line types, sizes and blocks).
- `daemon`: the real acpmux daemon over a small and a god home (acpmux `tests/god_daemon.rs`, lane
  W0's fixture: 527 chats, the god chat's 1 GB log and JSONL, 26+ peers of 400 rows): startup to
  first list frame, peers listed, attach, send to first token, reconnect, RSS, and the daemon's
  own gauges. --churn SECS adds fleet load (every peer link cut every --flap seconds, --streams
  chats streaming, an app connection that reconnects its list watch) and samples RSS over time.
- `chat`: one god chat restarted, opened and streamed into with 32 watchers, one stalled (acpmux
  `stress::god_chat`, W0): bytes read and milliseconds, small against god.
- `webview`: the agent chat pane on the Linux web UI (webviews/bench/degenerate-chat-frames.bench.ts):
  frame intervals, long tasks and FPS for cold open, scroll, fling and streaming at --tps.

Each runs under a --load: `idle`, `cpu` (load average --cpu-load, 100 by default: stress-ng when it
is installed, else burner processes this script owns), or `mem` (memory pressure: a hog that holds
all but --mem-headroom of the machine's available memory, into swap where there is swap). A loaded
run is followed by the same run with the load lifted, `recovered`, so a number that stays bad after
the load is gone shows.

--profile: `perf record` of the daemon while it runs, when perf can (kernel.perf_event_paranoid
at most 1, or root), and the webview bench's Chrome trace; dhat heap sites with --heap.

Output under --out: one JSON per run, `results.json` (every run), `god-small.json` (the rows the
nightly report's `--god-small` reads: {"rows": [{"name", "small_p95", "god_p95"}]}), and
`summary.md`.

    lab.py matrix --out /tmp/lab [--preset nightly|full] [--profile]
    lab.py daemon --scale 0.1 --load cpu --churn 600 --out /tmp/lab
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TUI = ROOT / "cmux-tui"
WEBVIEWS = ROOT / "webviews"

PRESETS = {
    # The nightly: every part at 0.1x and 1x, idle and loaded, about an hour on a 16-core runner.
    "nightly": {"scales": [0.1, 1.0], "loads": ["idle", "cpu", "mem"], "churn": 300, "tps": "50,500"},
    # The slope: 0.1x, 1x and 3x (3x writes about 7 GB of fixtures).
    "full": {"scales": [0.1, 1.0, 3.0], "loads": ["idle", "cpu", "mem"], "churn": 900, "tps": "50,500"},
    # A check that the harness runs, in minutes.
    "smoke": {"scales": [0.02], "loads": ["idle"], "churn": 30, "tps": "50"},
}


def log(msg: str) -> None:
    print(f"[lab {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


# --- loads -------------------------------------------------------------------------------------


class Load:
    """A load this script starts and stops by its own process group, never by name."""

    def __init__(self, kind: str, cpu_load: int, mem_headroom_mb: int):
        self.kind = kind
        self.cpu_load = cpu_load
        self.mem_headroom_mb = mem_headroom_mb
        self.procs: list[subprocess.Popen] = []
        self.detail: dict = {"kind": kind}

    def start(self) -> None:
        if self.kind == "cpu":
            if shutil.which("stress-ng"):
                cmd = ["stress-ng", "--cpu", str(self.cpu_load), "--cpu-load", "100", "--timeout", "0"]
                self.detail["tool"] = "stress-ng"
            else:
                burner = "import os\nos.nice(0)\nwhile True: pass\n"
                cmd = None
                for _ in range(self.cpu_load):
                    self.procs.append(subprocess.Popen([sys.executable, "-I", "-c", burner], start_new_session=True))
                self.detail["tool"] = f"{self.cpu_load} burner processes"
            if cmd:
                self.procs.append(subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL))
        elif self.kind == "mem":
            avail = meminfo("MemAvailable")
            swap = meminfo("SwapTotal")
            hold = max(0, avail - self.mem_headroom_mb * 1024 * 1024)
            # The hog touches every page it holds, then sleeps holding them.
            hog = (
                "import sys,time\nn=int(sys.argv[1])\nchunks=[]\nstep=64<<20\n"
                "while n>0:\n b=bytearray(min(step,n))\n for i in range(0,len(b),4096): b[i]=1\n"
                " chunks.append(b); n-=len(b)\nprint('held',flush=True)\nwhile True: time.sleep(60)\n"
            )
            p = subprocess.Popen([sys.executable, "-I", "-c", hog, str(hold)], start_new_session=True, stdout=subprocess.PIPE, text=True)
            p.stdout.readline()
            self.procs.append(p)
            self.detail.update({"heldBytes": hold, "availableBefore": avail, "swapTotal": swap})
        if self.procs:
            time.sleep(5)  # let the load reach its level
        self.detail["loadavg1"] = os.getloadavg()[0]

    def stop(self) -> None:
        for p in self.procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
        self.procs.clear()


def meminfo(field: str) -> int:
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith(field + ":"):
            return int(line.split()[1]) * 1024
    return 0


# --- parts -------------------------------------------------------------------------------------


def run_logged(cmd: list[str], env: dict, cwd: Path, out: Path, timeout: int) -> tuple[int, str]:
    """Runs `cmd`, its output to `out` and back as text; the exit code, or 124 past `timeout`."""
    log("run: " + " ".join(cmd))
    with out.open("w") as f:
        p = subprocess.Popen(cmd, env=env, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            code = 124
    return code, out.read_text(errors="replace")


def cargo_env(args) -> dict:
    env = dict(os.environ)
    env.setdefault("CARGO_PROFILE_RELEASE_DEBUG", "line-tables-only")
    if args.target_dir:
        env["CARGO_TARGET_DIR"] = args.target_dir
    # The store refuses a state folder under a writable, non-sticky shared folder: a private TMPDIR.
    tmp = Path(args.out) / "tmp"
    tmp.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp.chmod(0o700)
    env["TMPDIR"] = str(tmp)
    return env


def missing(path: Path, what: str) -> str | None:
    """Why a part cannot run on this tree: its harness is not in it yet (lane W0's, cmux#41882, #41833)."""
    return None if path.exists() else f"{what} is not in this tree ({path.relative_to(ROOT)})"


def part_daemon(args, scale: float, load: str, out: Path) -> dict:
    why = missing(TUI / "crates/acpmux/tests/god_daemon.rs", "the daemon god bench")
    if why:
        return {"part": "daemon", "scale": scale, "load": load, "exit": 0, "skipped": why}
    env = cargo_env(args)
    env.update({"ACPMUX_GOD_SHAPES": "small,god", "ACPMUX_GOD_SCALE": str(min(scale, 1.0)),
                "ACPMUX_GOD_CHURN_SECS": str(args.churn), "ACPMUX_GOD_FLAP_SECS": str(args.flap),
                "ACPMUX_GOD_STREAMS": str(args.streams)})
    features = ["--features", "dhat-heap"] if args.heap else []
    if args.heap:
        env["ACPMUX_GOD_DHAT"] = "1"
    cmd = ["cargo", "test", "-p", "acpmux", "--release", *features, "--test", "god_daemon", "--", "--ignored", "--nocapture"]
    perf = start_perf_watch(args, out) if args.profile else None
    code, text = run_logged(cmd, env, TUI, out / "daemon.log", args.timeout)
    if perf:
        perf.stop()
    runs = [json.loads(m) for m in re.findall(r"^GOD-BASELINE (\{.*\})$", text, re.M)]
    ratio = re.findall(r"^GOD-RATIO (\{.*\})$", text, re.M)
    churn = [json.loads(m) for m in re.findall(r"^CHURN (\{.*\})$", text, re.M)]
    return {"part": "daemon", "scale": scale, "load": load, "exit": code, "runs": runs,
            "ratio": json.loads(ratio[-1]) if ratio else None, "churnSamples": churn,
            "perf": perf.detail if perf else None}


def part_chat(args, scale: float, load: str, out: Path) -> dict:
    why = missing(TUI / "crates/acpmux/src/stress/god_chat.rs", "the god chat stress")
    if why:
        return {"part": "chat", "scale": scale, "load": load, "exit": 0, "skipped": why}
    env = cargo_env(args)
    env["ACPMUX_STRESS_GOD_MB"] = str(max(8, int(1024 * scale)))
    cmd = ["cargo", "test", "-p", "acpmux", "--release", "--lib", "stress::god_chat", "--", "--ignored", "--nocapture"]
    code, text = run_logged(cmd, env, TUI, out / "chat.log", args.timeout)
    rows = [line for line in text.splitlines() if line.startswith("STRESS")]
    return {"part": "chat", "scale": scale, "load": load, "exit": code, "stress": rows}


def part_webview(args, scale: float, load: str, out: Path) -> dict:
    report = out / "webview.json"
    bun = shutil.which("bun") or str(Path.home() / ".bun/bin/bun")
    cmd = [bun, "bench/degenerate-chat-frames.bench.ts", "--tps", args.tps, "--out", str(report)]
    if args.profile:
        cmd += ["--trace", str(out / "traces")]
    code, _ = run_logged(cmd, dict(os.environ), WEBVIEWS, out / "webview.log", args.timeout)
    data = json.loads(report.read_text()) if report.exists() else None
    return {"part": "webview", "scale": scale, "load": load, "exit": code, "report": data}


def part_fixtures(args, scale: float, out: Path) -> dict:
    made = {}
    for fmt in ("claude", "codex"):
        path = Path(args.fixtures) / f"{fmt}-{scale:g}.jsonl"
        if not path.exists():
            text = subprocess.run([sys.executable, "-I", str(HERE / "gen_transcript.py"), "--out", str(path), "--scale", str(scale),
                                   "--format", fmt], check=True, capture_output=True, text=True).stdout
            (out / f"{fmt}-{scale:g}.summary.json").write_text(text)
        made[fmt] = str(path)
    return {"part": "fixtures", "scale": scale, "files": made}


class PerfWatch:
    """`perf record` of every acpmux daemon this run starts, when the kernel lets this user."""

    def __init__(self, out: Path):
        self.out = out
        self.proc: subprocess.Popen | None = None
        self.detail: dict = {}

    def stop(self) -> None:
        if self.proc:
            os.killpg(self.proc.pid, signal.SIGINT)
            self.proc.wait()
            report = self.out / "perf-report.txt"
            with report.open("w") as f:
                subprocess.run(["perf", "report", "-i", str(self.out / "perf.data"), "--no-children", "--percent-limit", "0.5",
                                "--stdio", "--sort", "symbol,srcline"], stdout=f, stderr=subprocess.DEVNULL)
            self.detail["report"] = str(report)


def perf_allowed() -> str | None:
    if not shutil.which("perf"):
        return "perf is not installed"
    if os.geteuid() == 0:
        return None
    level = int(Path("/proc/sys/kernel/perf_event_paranoid").read_text().strip() or 4)
    return None if level <= 1 else f"kernel.perf_event_paranoid is {level}"


def start_perf_watch(args, out: Path) -> PerfWatch | None:
    w = PerfWatch(out)
    why = perf_allowed()
    if why:
        w.detail["skipped"] = why
        return w
    # System-wide with call graphs, filtered to the daemon in the report: the daemon is a child of
    # cargo's test process and starts after this does.
    w.proc = subprocess.Popen(["perf", "record", "-F", "199", "-g", "-a", "-o", str(out / "perf.data"), "--", "sleep", str(args.timeout)],
                              start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    w.detail["data"] = str(out / "perf.data")
    return w


# --- matrix ------------------------------------------------------------------------------------


def god_small_rows(results: list[dict]) -> list[dict]:
    """The rows the nightly report reads: god p95 against small p95, one harness, idle runs."""
    rows = []
    for r in results:
        if r["part"] == "daemon" and len(r.get("runs") or []) == 2:
            small, god = r["runs"]
            for key, path in (("first_list_ms", ("firstListMs",)), ("peers_listed_ms", ("peersMs",)),
                              ("attach_us", ("attachUs", "p95")), ("send_first_token_us", ("sendFirstTokenUs", "p95")),
                              ("rss_bytes", ("rss",))):
                s, g = dig(small, path), dig(god, path)
                if isinstance(s, (int, float)) and isinstance(g, (int, float)):
                    rows.append({"name": f"daemon.{key}.{r['load']}.x{r['scale']:g}", "small_p95": s, "god_p95": g})
        if r["part"] == "webview" and r.get("report"):
            for row in r["report"].get("rows", []):
                rows.append({**row, "name": f"{row['name']}.{r['load']}"})
    return rows


def dig(d, path):
    for k in path:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def summary_md(results: list[dict], rows: list[dict]) -> str:
    lines = ["# Degenerate lab", "", "| row | small p95 | god p95 | god/small |", "|---|---:|---:|---:|"]
    for r in rows:
        ratio = r["god_p95"] / r["small_p95"] if r["small_p95"] else (1.0 if not r["god_p95"] else float("inf"))
        flag = " **over 1.2x**" if ratio > 1.2 else ""
        lines.append(f"| {r['name']} | {r['small_p95']:,} | {r['god_p95']:,} | {ratio:.2f}{flag} |")
    lines += ["", "| part | scale | load | exit |", "|---|---:|---|---:|"]
    for r in results:
        lines.append(f"| {r['part']} | {r.get('scale', '')} | {r.get('load', '')} | {r.get('skipped') or r.get('exit', '')} |")
    return "\n".join(lines) + "\n"


def run_part(args, part: str, scale: float, load: str, out_root: Path) -> list[dict]:
    """`part` under `load`, then once more with the load lifted (`recovered`)."""
    phases = [load] if load == "idle" else [load, "recovered"]
    results = []
    held = Load(load, args.cpu_load, args.mem_headroom) if load != "idle" else None
    for phase in phases:
        out = out_root / f"{part}-x{scale:g}-{phase}"
        out.mkdir(parents=True, exist_ok=True)
        if held and phase == load:
            held.start()
        try:
            fn = {"daemon": part_daemon, "chat": part_chat, "webview": part_webview}[part]
            r = fn(args, scale, phase, out)
        finally:
            if held and phase == load:
                r_load = dict(held.detail)
                held.stop()
        if held and phase == load:
            r["loadDetail"] = r_load
        (out / "result.json").write_text(json.dumps(r, indent=1))
        results.append(r)
    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["matrix", "fixtures", "daemon", "chat", "webview"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--preset", choices=sorted(PRESETS), default="nightly")
    ap.add_argument("--scale", type=float, action="append", help="scales (repeatable); default: the preset's")
    ap.add_argument("--load", action="append", choices=["idle", "cpu", "mem"], help="loads (repeatable); default: the preset's")
    ap.add_argument("--churn", type=int, help="seconds of fleet load in the daemon run")
    ap.add_argument("--flap", type=int, default=15, help="seconds between peer link cuts while churning")
    ap.add_argument("--streams", type=int, default=6, help="chats streaming while churning")
    ap.add_argument("--tps", help="webview streaming rates, tokens per second")
    ap.add_argument("--cpu-load", type=int, default=100)
    ap.add_argument("--mem-headroom", type=int, default=2048, help="MB the memory hog leaves available")
    ap.add_argument("--profile", action="store_true", help="perf record of the daemon, Chrome trace of the pane")
    ap.add_argument("--heap", action="store_true", help="dhat heap sites of the daemon (a dhat-heap build)")
    ap.add_argument("--fixtures", default=os.environ.get("DEGENERATE_LAB_FIXTURES", "/tmp/degenerate-lab-fixtures"))
    ap.add_argument("--target-dir", default=os.environ.get("CARGO_TARGET_DIR"))
    ap.add_argument("--timeout", type=int, default=3600, help="seconds any one run may take")
    args = ap.parse_args()
    # acpmux refuses a state folder under a group- or world-writable one, and tempfile folders take the umask.
    os.umask(0o022)
    preset = PRESETS[args.preset]
    scales = args.scale or preset["scales"]
    loads = args.load or preset["loads"]
    args.churn = preset["churn"] if args.churn is None else args.churn
    args.tps = args.tps or preset["tps"]
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)
    Path(args.fixtures).mkdir(parents=True, exist_ok=True)

    parts = ["daemon", "chat", "webview"] if args.command == "matrix" else [args.command]
    results: list[dict] = []
    if args.command in ("matrix", "fixtures"):
        for scale in scales:
            results.append(part_fixtures(args, scale, out_root))
    for part in (p for p in parts if p != "fixtures"):
        for scale in (scales if part != "webview" else scales[:1]):
            for load in loads:
                results.extend(run_part(args, part, scale, load, out_root))
    rows = god_small_rows(results)
    (out_root / "results.json").write_text(json.dumps(results, indent=1))
    (out_root / "god-small.json").write_text(json.dumps({"rows": rows}, indent=1))
    (out_root / "summary.md").write_text(summary_md(results, rows))
    print((out_root / "summary.md").read_text())
    return 0 if all(r.get("exit", 0) == 0 for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
