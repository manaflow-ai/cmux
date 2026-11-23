#!/usr/bin/env python3
"""The daemon_restart loop of goal dev-loop-ceiling, measured stage by stage (daemon_restart.sh runs it).

The real path is `cmux live start --rust` building here: scripts/cmux-next/rust-live.py's own Loop,
Builder and Swapper (imported, not copied) watch cmux-tui/, build the daemons the changed crates reach
with the same cargo command, and swap the running daemon (`server restart`, else `server stop` +
`server ensure`) with its terminals kept. The daemon is a scratch one: its socket, state and home in a
short temporary folder, never the host's, with N shells in it.

Each round writes a one-line edit into `identify` in cmux-tui-core (a field the daemon's `identify`
answer then carries) and times, on one clock (time.time()):
  fs_event      the save's mtime -> the loop seeing it (rust-live's poll + settle)
  compile       the first rustc cargo starts -> the daemon binary's linker starting (every crate rebuilt)
  link          the linker's run (rustc_wrap.py stands in as the linker and runs the configured one)
  swap          the loop's Swapper.swap (owner lookup, restart or stop + ensure, adoption)
  first_answer  one `identify` round trip that answers with the edit
  unattributed  the rest: cargo's start before the first rustc, the build's tail after the link,
                the copy of the binary, the loop's bookkeeping, the wake to ask
Then floors (see notes in the json) and the report OUT/daemon_restart.json (schema dev-loop-ceiling/loop/v1).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
from safe_log import safe_print  # noqa: E402

spec = importlib.util.spec_from_file_location("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
rl = importlib.util.module_from_spec(spec)
sys.modules["rust_live"] = rl  # its dataclasses look their module up by name
spec.loader.exec_module(rl)

BIN_FILE = "cmux-tui/crates/cmux-tui/src/bin/cmux-tui.rs"  # the daemon binary crate's root (link floor)
EDITED_CRATE = "cmux_tui_core"
STAGES = ["fs_event", "compile", "link", "swap", "first_answer"]


def log(message: str) -> None:
    safe_print(f"daemon_restart {time.strftime('%H:%M:%SZ', time.gmtime())} {message}", file=sys.stderr, flush=True)


def ms(seconds: float) -> float:
    return round(seconds * 1000.0, 1)


def records(log_dir: Path, since: float, until: float) -> list[dict]:
    found = []
    for path in log_dir.glob("*.json"):
        try:
            entry = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if since <= entry.get("start", 0) <= until:
            found.append(entry)
    return sorted(found, key=lambda e: e["start"])


class TimedBuilder(rl.Builder):
    """rust-live's Builder, with the wall time of each build and copy kept for the round."""

    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.marks: dict[str, float] = {}

    def build(self, daemons):
        self.marks["build_start"] = time.time()
        result = super().build(daemons)
        self.marks["build_end"] = time.time()
        return result

    def fetch(self, daemons, generation):
        self.marks["fetch_start"] = time.time()
        result = super().fetch(daemons, generation)
        self.marks["fetch_end"] = time.time()
        return result


class TimedSwapper(rl.Swapper):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.marks: dict[str, float] = {}

    def swap(self, built):
        self.marks["swap_start"] = time.time()
        result = super().swap(built)
        self.marks["swap_end"] = time.time()
        return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--terminals", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=900, help="seconds one round may take")
    ap.add_argument("--fs-event-bin", default="", help="the compiled fs_event_latency helper")
    args = ap.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    tree = ROOT
    commit = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    report: dict = {
        "schema": "dev-loop-ceiling/loop/v1", "loop": "daemon_restart", "commit": commit,
        "host": socket.gethostname(), "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "target": ("one-line edit in cmux-tui-core `identify` (crates/cmux-tui-core/src/server/cmd_server.rs) through "
                   "`cmux live start --rust`'s own loop (scripts/cmux-next/rust-live.py Loop/Builder/Swapper, "
                   "building here, profile " + rl.PROFILE + "), to a scratch daemon with "
                   f"{args.terminals} shells answering `identify` with the edit"),
        "error": None, "rounds": [], "floors_ms": {s: [] for s in STAGES},
        "graph": {"fs_event": [], "compile": ["fs_event"], "link": ["compile"], "swap": ["link"],
                  "first_answer": ["swap"]},
        "notes": [], "detail": {"rounds": [], "floors": {}},
    }
    notes = report["notes"]
    # Short: Unix socket addresses are 104 bytes on macOS, and the daemon keeps its hosts' sockets in
    # its state folder. Everything of the daemon's lives here, not in the host's sessions or home.
    work = Path(tempfile.mkdtemp(prefix="dlc-dr-", dir="/tmp"))
    work.chmod(0o700)
    state = work / "loop"
    rustc_log = work / "rustc-log"
    rustc_log.mkdir()
    edit_path = tree / rl.EDIT_FILE
    bin_path = tree / BIN_FILE
    original = edit_path.read_text()
    bin_original = bin_path.read_bytes()
    if rl.EDIT_ANCHOR not in original:
        report["error"] = f"{rl.EDIT_FILE} no longer has rust-live's edit anchor"
        (out / "daemon_restart.json").write_text(json.dumps(report, indent=2) + "\n")
        return 1

    # The build environment: rust-live's own, with rustc_wrap.py in front of rustc (chaining the
    # sccache rust-live would have added itself).
    inner = os.environ.get("RUSTC_WRAPPER") or (shutil.which("sccache") or "")
    os.environ["DLC_INNER_WRAPPER"] = inner
    os.environ["RUSTC_WRAPPER"] = str(HERE / "rustc_wrap.py")
    os.environ["DLC_LOG_DIR"] = str(rustc_log)
    notes.append(f"Builds are rust-live.py's command ({' '.join(rl.cargo_args(['cmux-tui'], None))}) with "
                 f"RUSTC_WRAPPER=rustc_wrap.py (inner wrapper: {inner or 'none'}), which only times each rustc "
                 "and the daemon binary's link; its python start (~30 ms per crate) is inside compile.")

    sock = work / "mux.sock"
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ACPMUX_", "CMUX_", "DLC_", "RUSTC_")) and k not in ("ENV", "BASH_ENV")}
    for folder in ("acpmux", "xdg", "home"):
        (work / folder).mkdir(mode=0o700)
    env.update(ACPMUX_HOME=str(work / "acpmux"), XDG_CONFIG_HOME=str(work / "xdg"), HOME=str(work / "home"),
               CMUX_TUI_STATE_DIR=str(work / "sessions"), CMUX_TUI_HOST_EXE_DIR=str(work / "host-exe"),
               CMUX_TUI_SHELL_INTEGRATION="none", SHELL="/bin/sh")
    builder = TimedBuilder(tree, state, None, None)
    swapper = TimedSwapper("dev-loop-daemon-restart", str(sock), env)
    swaps: list[dict] = []
    swapped = threading.Condition()

    def on_swap(entry: dict) -> None:
        with swapped:
            entry["_marks"] = {**builder.marks, **swapper.marks}
            swaps.append(entry)
            swapped.notify_all()

    loop = rl.Loop(tree, state, builder, swapper, on_swap=on_swap, only=("cmux-tui",))

    def interrupted(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    request = rl.request
    wait_until = rl.wait_until
    started_hosts: dict[str, int] = {}
    watcher: threading.Thread | None = None
    terms: list[dict] = []
    ok_rounds = 0

    def identify_with(token: str | None, deadline: float) -> tuple[float, float, dict]:
        """One identify round trip (repeated until it carries `token`); returns its request and answer times."""
        while True:
            t0 = time.time()
            ident = request(sock, {"cmd": "identify"})
            t1 = time.time()
            if token is None or ident.get("live_probe") == token or time.monotonic() > deadline:
                return t0, t1, ident

    def check_terminals(tag: str, deadline: float) -> list[dict]:
        checks = []
        for t_ in terms:
            try:
                r = wait_until("adopted", deadline, lambda t_=t_: (
                    x := request(sock, {"cmd": "resolve-terminal", "terminal_id": t_["terminal_id"]}))
                    and x.get("lifecycle") == "running" and x.get("terminal_incarnation") == t_["incarnation"]
                    and x.get("surface"))
                t_["surface"] = r
                request(sock, {"cmd": "send", "surface": r, "text": f"echo {tag}=$$\n"})
                screen = wait_until("echo", deadline, lambda r=r, tag=tag: (
                    s := request(sock, {"cmd": "read-screen", "surface": r}).get("text") or "")
                    and rl.shell_pid(s, tag) and s)
                checks.append({"same_shell": rl.shell_pid(screen, tag) == t_["shell_pid"],
                               "scrollback_kept": t_["marker"] in screen})
            except TimeoutError as error:
                checks.append({"same_shell": False, "error": str(error)})
        return checks

    def mark_terminals(token: str) -> None:
        for t_ in terms:
            t_["surface"] = wait_until("terminal", time.monotonic() + 30, lambda t_=t_: (
                x := request(sock, {"cmd": "resolve-terminal", "terminal_id": t_["terminal_id"]}))
                and x.get("lifecycle") == "running" and x.get("surface"))
            t_["marker"] = f"before-{token}-{t_['terminal_id']}"
            request(sock, {"cmd": "send", "surface": t_["surface"], "text": f"clear; echo {t_['marker']}\n"})
        for t_ in terms:
            wait_until("marker", time.monotonic() + 15, lambda t_=t_: t_["marker"] in (
                request(sock, {"cmd": "read-screen", "surface": t_["surface"]}).get("text") or "").replace(
                f"echo {t_['marker']}", ""))

    try:
        # Warm build (not timed): a fresh checkout's first build is a full one.
        log("warm build")
        t = time.time()
        ok, output = builder.build(["cmux-tui"])
        if not ok:
            raise RuntimeError("warm build failed: " + output.strip()[-3000:])
        report["detail"]["warm_build_s"] = round(time.time() - t, 1)
        first = builder.fetch(["cmux-tui"], state / "builds" / "0-warm")["cmux-tui"]
        ensure = swapper.cli(first, "server", "ensure")
        if ensure.returncode != 0:
            raise RuntimeError(f"server ensure: {(ensure.stderr or ensure.stdout).strip()}")
        wait_until("daemon", time.monotonic() + 30, lambda: request(sock, {"cmd": "identify"}))
        for i in range(args.terminals):
            created = request(sock, {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
            terms.append({"terminal_id": created["terminal_id"], "surface": created["surface"],
                          "incarnation": created["terminal_incarnation"], "marker": f"dlc-{os.getpid()}-{i}"})
        for t_ in terms:
            request(sock, {"cmd": "send", "surface": t_["surface"], "text": f"echo {t_['marker']}; echo PID$((0))=$$\n"})
        for t_ in terms:
            screen = wait_until("marker", time.monotonic() + 15, lambda t_=t_: (
                s := request(sock, {"cmd": "read-screen", "surface": t_["surface"]}).get("text") or "")
                and t_["marker"] in s and rl.shell_pid(s, "PID0") and s)
            t_["shell_pid"] = rl.shell_pid(screen, "PID0")
        started_hosts.update(rl.host_pids(work))

        watcher = threading.Thread(target=loop.run, daemon=True, name="rust-live-watcher")
        watcher.start()
        if not loop.watching.wait(timeout=120):
            raise RuntimeError("rust-live's loop did not start watching in 120 s")
        for run_index in range(args.runs):
            token = f"r{run_index}-{os.getpid()}"
            mark_terminals(token)
            time.sleep(0.3)  # the terminals' echoes are not inside the round
            seen = len(swaps)
            edit_path.write_text(original.replace(rl.EDIT_ANCHOR, rl.EDIT_ANCHOR + f'        "live_probe": "{token}",\n', 1))
            saved_at = edit_path.stat().st_mtime_ns / 1e9
            with swapped:
                swapped.wait_for(lambda: len(swaps) > seen, timeout=args.timeout)
            entry = swaps[seen] if len(swaps) > seen else {"outcome": "timed_out"}
            detail: dict = {"run": run_index, "outcome": entry.get("outcome"), "swap": entry.get("swap"),
                            "errors": entry.get("errors"), "error": entry.get("error")}
            report["detail"]["rounds"].append(detail)
            if entry.get("outcome") != "swapped":
                raise RuntimeError(f"round {run_index}: {entry.get('outcome')}: {entry.get('errors') or entry.get('error')}")
            q0, q1, ident = identify_with(token, time.monotonic() + 30)
            if ident.get("live_probe") != token:
                raise RuntimeError(f"round {run_index}: the swapped daemon does not answer with the edit")
            m = entry["_marks"]
            detected = entry["saved_at"] + entry["detect_secs"]
            rustc = records(rustc_log, m["build_start"], m["build_end"])
            compiles = [r for r in rustc if r["kind"] not in ("link", "probe")]
            links = [r for r in rustc if r["kind"] == "link"]
            if not compiles or not links:
                raise RuntimeError(f"round {run_index}: no rustc or link record (rustc_wrap.py): {len(compiles)} {len(links)}")
            c0, l0, l1 = compiles[0]["start"], links[-1]["start"], links[-1]["end"]
            e2e = q1 - saved_at
            stages = {"fs_event": detected - saved_at, "compile": l0 - c0, "link": l1 - l0,
                      "swap": m["swap_end"] - m["swap_start"], "first_answer": q1 - q0}
            stages["unattributed"] = e2e - sum(stages.values())
            detail.update({
                "crates": [{"crate": r["crate"], "kind": r["kind"], "s": round(r["end"] - r["start"], 3),
                            "starts_at_s": round(r["start"] - c0, 3)} for r in compiles],
                "unattributed_parts_ms": {
                    "detect_to_cargo": ms(m["build_start"] - detected),
                    "cargo_to_first_rustc": ms(c0 - m["build_start"]),
                    "link_end_to_cargo_exit": ms(m["build_end"] - l1),
                    "cargo_exit_to_swap": ms(m["swap_start"] - m["build_end"]),
                    "copy_binary": ms(m["fetch_end"] - m["fetch_start"]),
                    "swapped_to_ask": ms(q0 - m["swap_end"])},
            })
            # The edit's own rustc, captured for the compile floor's replay.
            core = [r for r in compiles if r["crate"] == EDITED_CRATE]
            if core:
                (work / "core-rustc.json").write_text(json.dumps(core[-1]))
            checks = check_terminals(f"PID{run_index + 1}", time.monotonic() + 30)
            detail["terminals"] = checks
            survived = all(c.get("same_shell") and c.get("scrollback_kept") for c in checks)
            detail["terminals_survived"] = survived
            report["rounds"].append({"end_to_end_ms": ms(e2e), "stages_ms": {k: ms(v) for k, v in stages.items()}})
            log(f"round {run_index}: {ms(e2e)} ms {json.dumps(report['rounds'][-1]['stages_ms'])} "
                f"crates {[c['crate'] for c in detail['crates']]} terminals kept {survived}")
            if not survived:
                raise RuntimeError(f"round {run_index}: a terminal did not survive the swap: {checks}")
            ok_rounds += 1

        # ---- floors (the watcher stops first: nothing below is a save it should build)
        loop.stop_event.set()
        watcher.join(timeout=120)
        floors = report["floors_ms"]
        current = swapper.previous or first

        # link: a no-op change to the binary crate (its root's mtime), then the live build command;
        # only the cmux-tui binary crate recompiles, and the linker's run is the sample.
        log("link floor")
        link_crates = set()
        for i in range(args.runs):
            os.utime(bin_path, None)
            t0 = time.time()
            ok, output = builder.build(["cmux-tui"])
            t1 = time.time()
            if not ok:
                raise RuntimeError("link floor build failed: " + output.strip()[-2000:])
            recs = records(rustc_log, t0, t1)
            link_crates.update(f"{r['crate']}:{r['kind']}" for r in recs if r["kind"] not in ("link", "probe"))
            links = [r for r in recs if r["kind"] == "link"]
            if links:
                floors["link"].append(ms(links[-1]["end"] - links[-1]["start"]))
        notes.append("link floor: the binary crate's root (src/bin/cmux-tui.rs) touched with no content change, "
                     "then rust-live's build command; the sample is the linker's run alone. Crates rustc ran then: "
                     + ", ".join(sorted(link_crates)))

        # swap: `server stop` + `server ensure` of the build already running (no code change), terminals kept.
        log("swap floor")
        for i in range(args.runs):
            t0 = time.time()
            stop = swapper.cli(current, "server", "stop")
            ensure = swapper.cli(current, "server", "ensure")
            t1 = time.time()
            if ensure.returncode != 0:
                raise RuntimeError(f"swap floor: server ensure: {(ensure.stderr or ensure.stdout).strip()} "
                                   f"(stop: {(stop.stderr or stop.stdout).strip()})")
            floors["swap"].append(ms(t1 - t0))
            checks = check_terminals(f"SW{i}", time.monotonic() + 30)
            if not all(c.get("same_shell") for c in checks):
                raise RuntimeError(f"swap floor: a terminal did not survive stop + ensure: {checks}")
        notes.append("swap floor: `server stop` then `server ensure` of the running build (no code change), "
                     "both CLI calls timed together; after each, every shell checked to be the same process. The "
                     "real swap is rust-live's Swapper.swap: it also asks `server status` and finds the owner's "
                     "executable (lsof on macOS) before `server restart` (or stop + ensure).")

        # first_answer: one identify round trip on the idle daemon.
        log("first_answer floor")
        for i in range(max(args.runs, 20)):
            q0, q1, _ = identify_with(None, time.monotonic() + 5)
            floors["first_answer"].append(ms(q1 - q0))
        notes.append("first_answer floor: one `identify` request/answer on the daemon's Unix socket, idle.")

        # fs_event: the kernel's own file event latency (FSEvents on macOS, inotify on Linux), one process.
        log("fs_event floor")
        if args.fs_event_bin:
            watch = work / "fswatch"
            watch.mkdir()
            res = subprocess.run([args.fs_event_bin, str(watch), str(max(args.runs, 20))],
                                 capture_output=True, text=True, timeout=300)
            floors["fs_event"] = [round(float(x), 3) for x in res.stdout.split()]
            if res.returncode != 0:
                notes.append(f"fs_event floor helper: {res.stderr.strip()[-500:]}")
        notes.append("fs_event floor: fs_event_latency.c, a write to a watched folder to its event in one process "
                     + ("(FSEvents, per-file events, latency 0, NoDefer)" if sys.platform == "darwin" else "(inotify)")
                     + f". The real path does not use file events: rust-live.py polls every {rl.POLL_SECS} s and "
                     f"waits {rl.SETTLE_SECS} s for the save to settle.")

        # compile: the edited crate alone, its deps fresh: the exact rustc cargo ran for cmux-tui-core in the
        # last round (argv, cwd, environment), replayed after a new one-line edit.
        log("compile floor")
        capture = work / "core-rustc.json"
        if not capture.is_file():
            raise RuntimeError("compile floor: no cmux-tui-core rustc was captured in the rounds")
        core = json.loads(capture.read_text())
        renv = {k: v for k, v in os.environ.items() if not k.startswith("CARGO")}
        renv.update(core["env"])
        renv.pop("CARGO_MAKEFLAGS", None)  # cargo's jobserver is not there for a replay
        renv["DLC_LOG_DIR"] = str(rustc_log)
        for i in range(args.runs):
            edit_path.write_text(original.replace(rl.EDIT_ANCHOR, rl.EDIT_ANCHOR + f'        "live_probe": "floor{i}",\n', 1))
            t0 = time.time()
            res = subprocess.run([sys.executable, str(HERE / "rustc_wrap.py"), *core["argv"]], cwd=core["cwd"],
                                 env=renv, capture_output=True, text=True, timeout=900)
            t1 = time.time()
            if res.returncode != 0:
                raise RuntimeError("compile floor: replayed rustc failed: " + (res.stderr or res.stdout).strip()[-2000:])
            recs = [r for r in records(rustc_log, t0, t1) if r["crate"] == EDITED_CRATE]
            floors["compile"].append(ms(recs[-1]["end"] - recs[-1]["start"]) if recs else ms(t1 - t0))
        notes.append("compile floor: cmux-tui-core alone, its dependencies fresh: the rustc invocation cargo ran for it "
                     "in the last round (same argv, incremental folder, environment; cargo's jobserver dropped) replayed "
                     "after a new one-line edit in `identify`. The real path's compile stage also rebuilds every crate "
                     "that depends on it on the way to the daemon (detail.rounds[].crates).")
        notes.append("graph: a plain chain. rustc already pipelines the dependent crates on cmux-tui-core's metadata "
                     "inside compile; the swap cannot start before the link, nor the answer before the swap.")
    except KeyboardInterrupt:
        report["error"] = "interrupted (SIGINT or SIGTERM)"
    except Exception as error:  # noqa: BLE001 - the report says what failed
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        loop.stop_event.set()
        loop.builder.cancel()
        if watcher is not None:
            watcher.join(timeout=120)
        edit_path.write_text(original)
        if bin_path.read_bytes() != bin_original:
            bin_path.write_bytes(bin_original)
        try:
            ident = request(sock, {"cmd": "identify"})
            request(sock, {"cmd": "shutdown-daemon", "pid": ident.get("pid"),
                           "generation": ident.get("generation"), "end_terminals": True})
        except (OSError, RuntimeError, ValueError):
            pass
        started_hosts.update(rl.host_pids(work))
        time.sleep(0.5)
        for pid in started_hosts.values():  # only the terminal hosts this measurement started
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        if (state / "history.jsonl").exists():
            shutil.copy2(state / "history.jsonl", out / "rust-live-history.jsonl")
        shutil.rmtree(work, ignore_errors=True)

    if report["error"] is None:
        short = [s for s in STAGES if len(report["floors_ms"][s]) < args.runs]
        if ok_rounds < args.runs:
            report["error"] = f"{ok_rounds} of {args.runs} rounds measured"
        elif short:
            report["error"] = f"floors with fewer than {args.runs} samples: {short}"
    rounds = report["rounds"]
    if rounds:
        summary = {"end_to_end_ms": statistics.median(r["end_to_end_ms"] for r in rounds)}
        for stage in [*STAGES, "unattributed"]:
            summary[stage] = statistics.median(r["stages_ms"][stage] for r in rounds)
        for stage in STAGES:
            if report["floors_ms"][stage]:
                summary[f"floor_{stage}"] = statistics.median(report["floors_ms"][stage])
        report["detail"]["p50_ms"] = summary
        log("p50 " + json.dumps(summary))
    (out / "daemon_restart.json").write_text(json.dumps(report, indent=2) + "\n")
    log(f"wrote {out / 'daemon_restart.json'} (error: {report['error']})")
    return 0 if report["error"] is None else 1


if __name__ == "__main__":
    sys.exit(main())
