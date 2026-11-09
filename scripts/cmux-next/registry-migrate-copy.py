#!/usr/bin/env python3
"""Run the registry's one-time shrink on a COPY and report before and after.

The shrink is the daemon's own output cleanup (output_cleanup.rs): it stages
the history it keeps, compressed, then swaps a rebuilt registry in at the
next start and keeps the old file as `.pre-output-cleanup`. This drives a
daemon build against a copy of a session folder and reads back:

- sizes of every file in the folder, before and after;
- `restore.snapshot` of each start (startup-timings.jsonl, the same harness
  for both numbers): the first start runs on the old registry, the second
  on the swapped one;
- the journal digest per sequence range (registry-journal-digest.py), so
  every record other than terminal output is checked to be there, unchanged.

Never point it at a live session folder: it starts and stops a daemon there.

    registry-migrate-copy.py --bin PATH/cmux-tui --state-dir COPY/tui \
        --session cmux-app-nightly-1d6bc9a9bb32a162 --out report.json
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DIGEST = HERE / "registry-journal-digest.py"
REGISTRY = "workspace-registry.sqlite3"


def sizes(folder):
    result = {}
    for entry in sorted(folder.iterdir()):
        if entry.is_file():
            result[entry.name] = entry.stat().st_size
        elif entry.is_dir():
            result[entry.name + "/"] = sum(p.stat().st_size for p in entry.rglob("*") if p.is_file())
    return result


def timings(folder):
    path = folder / "startup-timings.jsonl"
    if not path.exists():
        return []
    starts = []
    for line in path.read_text().splitlines():
        try:
            starts.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return starts


def lap(start, name):
    """One step's ms of a startup-timings.jsonl start ({"steps": [{"step", "ms"}]})."""
    for entry in start.get("steps", []):
        if entry.get("step") == name:
            return entry.get("ms")
    return None


class Daemon:
    """One headless owner of the copy; this script's own child process."""

    def __init__(self, args, label):
        env = dict(os.environ, CMUX_TUI_STATE_DIR=str(args.state_dir))
        env.pop("CMUX_TUI_SOCKET", None)
        self.socket = Path(args.work) / f"{label}.sock"
        self.lines = []
        self.changed = threading.Condition()
        self.log = open(Path(args.work) / f"{label}.log", "w")
        self.process = subprocess.Popen(
            [args.bin, "--headless", "--session", args.session, "--socket", str(self.socket)],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stderr:
            self.log.write(line)
            self.log.flush()
            with self.changed:
                self.lines.append(line.rstrip("\n"))
                self.changed.notify_all()
        with self.changed:
            self.lines.append(None)
            self.changed.notify_all()

    def wait_for(self, needles, timeout):
        deadline = time.monotonic() + timeout
        with self.changed:
            while True:
                for line in self.lines:
                    if line is None:
                        raise SystemExit(f"the daemon exited before {needles!r}; see {self.log.name}")
                    for needle in needles:
                        if needle in line:
                            return line
                left = deadline - time.monotonic()
                if left <= 0:
                    raise SystemExit(f"no {needles!r} within {timeout} s; see {self.log.name}")
                self.changed.wait(min(left, 30))

    def stop(self):
        # SIGTERM to the process group this script started, then wait.
        os.killpg(self.process.pid, signal.SIGTERM)
        try:
            self.process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()


def digest(registry, out, compare=None):
    command = [sys.executable, "-I", str(DIGEST), str(registry)]
    if compare:
        command += ["--compare", str(compare)]
    with open(out, "w") as handle:
        code = subprocess.run(command, stdout=handle).returncode
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bin", required=True, help="the cmux-tui build to run")
    parser.add_argument("--state-dir", required=True, type=Path, help="the copy's sessions folder")
    parser.add_argument("--session", required=True)
    parser.add_argument("--work", default=None, help="logs and digests (default: beside the copy)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--phase-a-timeout", type=int, default=6 * 3600)
    args = parser.parse_args()
    folder = args.state_dir / args.session
    registry = folder / REGISTRY
    if not registry.is_file():
        sys.exit(f"no {registry}")
    args.work = Path(args.work or args.state_dir.parent / "migrate-work")
    args.work.mkdir(parents=True, exist_ok=True)
    report = {"bin": args.bin, "session": args.session, "before": {"files": sizes(folder)}}
    started = time.monotonic()
    if digest(registry, args.work / "digest-before.json"):
        sys.exit("the digest of the copy failed")
    report["before"]["digest_s"] = round(time.monotonic() - started, 1)
    known = len(timings(folder))
    done = subprocess.run(
        ["sqlite3", f"file:{registry}?mode=ro", "SELECT value FROM meta WHERE key = 'output_cleanup_v1'"],
        capture_output=True, text=True,
    ).stdout.strip()
    if done:
        sys.exit(f"this registry's cleanup already ran ({done}); nothing to migrate")

    # Start 1: the old registry; the cleanup stages in the background.
    first = Daemon(args, "start-1")
    first.wait_for(["control socket at"], 6 * 3600)
    line = first.wait_for(
        ["output cleanup: phase A complete", "output cleanup: not enough free space",
         "output cleanup: staging failed", "skipped; an earlier attempt failed"],
        args.phase_a_timeout,
    )
    report["phase_a"] = line
    report["during"] = {"files": sizes(folder)}
    first.stop()

    # Start 2: the swap at open, on the same build.
    second = Daemon(args, "start-2")
    second.wait_for(["control socket at"], 6 * 3600)
    swapped = [line for line in second.lines if line and "output cleanup" in line]
    report["swap"] = swapped
    if not any("swapped the registry" in line for line in swapped):
        report["swap_missing"] = True
    second.stop()

    starts = timings(folder)[known:]
    report["restore_snapshot_ms"] = [lap(start, "restore.snapshot") for start in starts]
    report["starts"] = starts
    report["after"] = {"files": sizes(folder)}
    report["digest_compare"] = digest(registry, args.work / "digest-compare.json", args.work / "digest-before.json")
    report["digest"] = json.loads((args.work / "digest-compare.json").read_text() or "{}")
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=1)
    total = lambda files: sum(files.values())
    print(
        json.dumps(
            {
                "before_bytes": total(report["before"]["files"]),
                "after_bytes": total(report["after"]["files"]),
                "registry_before": report["before"]["files"].get(REGISTRY),
                "registry_after": report["after"]["files"].get(REGISTRY),
                "restore_snapshot_ms": report["restore_snapshot_ms"],
                "digest": report["digest"],
            }
        )
    )
    return report["digest_compare"]


if __name__ == "__main__":
    sys.exit(main())
