#!/usr/bin/env python3
"""Times starts of a headless cmux-tui owner on a registry (daemon-registry-start.sh).

Each start reports, from spawn: time to listen (the socket file exists), to identify (the
first identify answer) and to ready (identify says lifecycle_ready), and the laps of the
owner's startup-timings.jsonl line. A bumped start first sets the agent roster snapshot
(journal_reducer.agent_roster in meta) one version back, as after a reducer version bump,
so the owner re-folds the whole journal. One DRS {json} line per start on stdout.
"""

import argparse
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

REGISTRY = "workspace-registry.sqlite3"


def identify(path, timeout):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall(b'{"id":1,"cmd":"identify"}\n')
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    return None
                data += chunk
            return json.loads(data.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None


def session_dir(state):
    for entry in Path(state).iterdir():
        if (entry / REGISTRY).is_file():
            return entry
    raise SystemExit("no registry below " + state)


def bump_roster(registry):
    db = sqlite3.connect(registry)
    try:
        row = db.execute("SELECT value FROM meta WHERE key = 'journal_reducer.agent_roster'").fetchone()
        if row is None:
            return None
        value = json.loads(row[0])
        value["version"] = int(value["version"]) - 1
        db.execute(
            "UPDATE meta SET value = ? WHERE key = 'journal_reducer.agent_roster'", (json.dumps(value),)
        )
        db.commit()
        return value["version"]
    finally:
        db.close()


def file_size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def start(args, label, bumped):
    sdir = session_dir(args.state)
    registry = sdir / REGISTRY
    env = dict(os.environ)
    env.update(
        {
            "HOME": args.home,
            "CMUX_TUI_STATE_DIR": args.state,
            "CMUX_TUI_CONFIG": os.path.join(args.home, "config.json"),
            "CMUX_TUI_LOG_FILE": os.path.join(args.home, "client.log"),
        }
    )
    env.pop("CMUX_TUI_SOCKET", None)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    log = open(os.path.join(args.home, f"owner-{label}.log"), "wb")
    before = {"registry_bytes": file_size(registry), "wal_bytes": file_size(str(registry) + "-wal")}
    spawned_at_ms = time.time() * 1000
    started = time.monotonic()
    child = subprocess.Popen(
        [args.bin, "--headless", "--session", args.session, "--socket", args.socket],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=log,
    )
    listen = first_answer = ready = None
    deadline = started + args.ready_timeout
    while time.monotonic() < deadline and child.poll() is None:
        now = time.monotonic() - started
        if listen is None:
            if os.path.exists(args.socket):
                listen = now
            else:
                time.sleep(0.005)
                continue
        reply = identify(args.socket, 2.0)
        if reply is not None and first_answer is None:
            first_answer = time.monotonic() - started
        if reply is not None and (reply.get("data") or {}).get("lifecycle_ready") is True:
            ready = time.monotonic() - started
            break
        time.sleep(0.01)
    laps = None
    timings = sdir / "startup-timings.jsonl"
    if timings.is_file():
        lines = [line for line in timings.read_text().splitlines() if line.strip()]
        if lines:
            laps = json.loads(lines[-1])
    exited = child.poll()
    subprocess.run(
        [args.bin, "server", "stop", "--session", args.session, "--end-terminals", "--socket", args.socket],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=600,
    )
    try:
        child.wait(timeout=600)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    log.close()
    if exited is not None:
        # The daemon's own last word (an error, never row contents); the log goes with the scratch.
        lines = Path(log.name).read_text(errors="replace").splitlines()
        print(f"DRS-OWNER-EXIT {label} {exited}: {lines[-1] if lines else ''}", file=sys.stderr, flush=True)
    ms = lambda value: None if value is None else round(value * 1000, 1)  # noqa: E731
    result = {
        "label": label,
        "roster_bumped": bumped,
        "listen_ms": ms(listen),
        "identify_ms": ms(first_answer),
        "ready_ms": ms(ready),
        "exited_early": exited,
        "startup": laps,
        # From spawn to the owner's startup clock (exec and main before its first lap). The
        # owner writes at_ms (wall clock) when its clock reads total_ms.
        "before_clock_ms": None
        if not laps or "at_ms" not in laps or "total_ms" not in laps
        else round(laps["at_ms"] - laps["total_ms"] - spawned_at_ms, 1),
        **before,
    }
    print("DRS " + json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    for name in ("bin", "state", "home", "session", "socket", "generate", "report"):
        parser.add_argument("--" + name.replace("_", "-"), required=True)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--bump", type=int, default=1)
    parser.add_argument("--ready-timeout", type=float, default=3600)
    args = parser.parse_args()
    generated = json.loads(Path(args.generate).read_text())
    # The first exec of a binary just linked pays for macOS's check of it, before main and
    # without opening a registry. Two `--version` execs before the timed starts pay it and
    # show it (the first against the second), so the starts time only the owner.
    execs = []
    for _ in range(2):
        exec_started = time.monotonic()
        subprocess.run([args.bin, "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=600, check=False)
        execs.append(round((time.monotonic() - exec_started) * 1000, 1))
    print("DRS-EXEC " + json.dumps({"first_exec_ms": execs[0], "second_exec_ms": execs[1]}), flush=True)
    starts = []
    registry = session_dir(args.state) / REGISTRY
    for index in range(max(args.rounds, 1)):
        # The generator wrote the first bump; later rounds set it again.
        bumped = bool(args.bump)
        if bumped and index > 0:
            bump_roster(registry)
        starts.append(start(args, f"bumped-{index}" if bumped else f"plain-{index}", bumped))
    starts.append(start(args, "after", False))
    report = {"generate": generated, "first_exec_ms": execs[0], "second_exec_ms": execs[1], "starts": starts}
    Path(args.report).write_text(json.dumps(report, indent=2))
    return 0 if all(item["ready_ms"] is not None for item in starts) else 1


if __name__ == "__main__":
    sys.exit(main())
