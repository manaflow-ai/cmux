#!/usr/bin/env python3
"""Check a checkout on the build fleet as soon as a file is saved, not when the branch is pushed.

    scripts/cmux-next/check-on-save.py [--checkout DIR] [--tag TAG] [--debounce S] [--once]

It watches the checkout's tracked edits and non-ignored untracked files. When they change and
stay unchanged for --debounce seconds, it sends the tree to a warm fleet slot with
`cmux-ci build cmux --working-tree` (HEAD plus every edit as one patch: no commit, no push) and
follows that build while the agent keeps editing. A newer save cancels the build before it
(`cmux-ci cancel`) and sends the new tree, so the fleet only ever works on the latest save.

Two lines on stdout per save:
    CHECK-ON-SAVE compiled save_to_compile_s=S submit_s=S queue_s=S job=ID tree=DIGEST
    CHECK-ON-SAVE result=ok|failed|superseded save_to_result_s=S submit_s=S queue_s=S job=ID tree=DIGEST
`compiled` is the app executable's compile passing on the slot (the build log's next phase
starts), which an agent can act on; `result` is the check's verdict. Times count
from the newest saved file's mtime; submit_s is the part spent snapshotting and uploading the tree,
queue_s the part the job waited for a free slot.
By default a save's check ends at the compile verdict and the rest of the build is cancelled;
--full follows the whole tagged build. --once checks the tree as it is now and exits with the
check's code (a bench, or a hook).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

# The cmux recipe logs a timed phase line, "==> app executable (N s)", when the Swift compile
# starts, and the next timed phase ("==> components (N s)") once it passed. Untimed "==> " lines
# in between (cache switches, import sets) are part of the compile.
COMPILE_START = re.compile(r"^==> app executable \(\d+ s\)$", re.M)
NEXT_PHASE = re.compile(r"^==> (?!app executable\b)[a-z][a-z -]* \(\d+ s\)$", re.M)
LOG_POLL_S = 3.0


def git(checkout: Path, *args: str) -> str:
    return subprocess.run(("git", "-C", str(checkout), *args), check=True, capture_output=True,
                          text=True).stdout


def tree_state(checkout: Path) -> tuple[str, float]:
    """(digest of HEAD and every changed path's size and mtime, newest changed mtime)."""
    head = git(checkout, "rev-parse", "HEAD").strip()
    names = git(checkout, "ls-files", "-m", "-o", "-d", "--exclude-standard", "-z").split("\0")
    digest = hashlib.sha256(head.encode())
    newest = 0.0
    for name in sorted(set(filter(None, names))):
        try:
            st = (checkout / name).stat()
        except FileNotFoundError:
            digest.update(f"{name}\0deleted\0".encode())
            continue
        digest.update(f"{name}\0{st.st_size}\0{st.st_mtime_ns}\0".encode())
        newest = max(newest, st.st_mtime)
    return digest.hexdigest()[:16], newest


def job_queue_seconds(job: str) -> float | None:
    """Seconds the fleet job waited for a slot (created to started), or None when unknown."""
    try:
        status = json.loads(subprocess.run(("cmux-ci", "status", job), capture_output=True, text=True,
                                           timeout=60).stdout)
        created, started = (datetime.fromisoformat(status[k].replace("Z", "+00:00"))
                            for k in ("created_at", "started_at"))
    except (subprocess.SubprocessError, KeyError, ValueError, TypeError):
        return None
    return max(0.0, (started - created).total_seconds())


def compiled(log: str) -> bool:
    """Whether the log shows the app executable's compile done: a later phase line follows it."""
    m = COMPILE_START.search(log)
    return bool(m) and bool(NEXT_PHASE.search(log, m.end()))


class Build:
    """One `cmux-ci build cmux --working-tree` this process started, followed to its verdict."""

    def __init__(self, checkout: Path, tag: str, tree: str, saved_at: float):
        self.tree, self.saved_at, self.job = tree, saved_at, ""
        self.started = time.time()
        self.submitted_at = 0.0
        self.compiled_at = 0.0
        self.log_checked = 0.0
        self.queue_s: float | None = None
        self.waiting = self.cancelled = False
        # Submit (snapshot, upload, queue; prints the job as JSON), then `cmux-ci wait` for its verdict.
        # A check needs no backend: local mode skips provisioning the shared dev VM.
        self.proc = self._start(("cmux-ci", "build", "cmux", "--working-tree", "--backend-mode", "local",
                                 "--tag", tag, "--reason", f"check-on-save {tree}"), checkout)

    def _start(self, argv: tuple[str, ...], cwd: Path, stdout=subprocess.PIPE) -> subprocess.Popen:
        proc = subprocess.Popen(argv, cwd=cwd, stdout=stdout, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)

        def forward() -> None:
            for line in proc.stderr:
                sys.stderr.write(f"  [{self.tree}] {line}")
        threading.Thread(target=forward, daemon=True).start()
        return proc

    def _check_compile(self) -> None:
        if self.compiled_at or time.time() - self.log_checked < LOG_POLL_S:
            return
        self.log_checked = time.time()
        log = subprocess.run(("cmux-ci", "log", self.job), capture_output=True, text=True, timeout=60).stdout
        if compiled(log):
            self.compiled_at = time.time()
            self.queue_s = job_queue_seconds(self.job)
            self.line("compiled", "save_to_compile_s", self.compiled_at)

    def poll(self, until_compiled: bool = False) -> int | None:
        """None while the build runs; then its exit code (0 passed). With until_compiled, 0 once
        the compile passed: the rest of the build (bundling, the cmux-tui client) is cancelled."""
        code = self.proc.poll()
        if self.waiting:
            if code is None:
                self._check_compile()
                if until_compiled and self.compiled_at:
                    self.cancel(reason="check-on-save: compiled; the rest of the build is not needed")
                    return 0
            return code
        if code is None:
            return None
        out = self.proc.stdout.read()
        if code != 0:
            return code
        try:
            self.job = json.loads(out.strip().splitlines()[-1])["id"]
        except (IndexError, KeyError, ValueError):
            sys.stderr.write(f"  [{self.tree}] check-on-save: no job in the submit output\n")
            return 1
        self.submitted_at, self.waiting = time.time(), True
        if self.cancelled:
            return code
        self.proc = self._start(("cmux-ci", "wait", self.job, "--interval", "5"), Path.cwd(), sys.stderr)
        return None

    def cancel(self, reason: str = "check-on-save: a newer save") -> None:
        """A newer save replaces this build: stop our own client, then cancel its fleet job."""
        self.cancelled = True
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)  # our own child's process group, by PID
            self.proc.wait(timeout=30)
        self.poll()
        if self.job:
            subprocess.run(("cmux-ci", "cancel", self.job, "--reason", reason),
                           capture_output=True, text=True, timeout=60)

    def line(self, what: str, key: str, at: float) -> None:
        submit = (self.submitted_at or at) - self.started
        queue = "-" if self.queue_s is None else f"{self.queue_s:.1f}"
        print(f"CHECK-ON-SAVE {what} {key}={at - self.saved_at:.1f} submit_s={submit:.1f} "
              f"queue_s={queue} job={self.job or '-'} tree={self.tree}", flush=True)

    def report(self, result: str) -> None:
        self.line(f"result={result}", "save_to_result_s", time.time())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--checkout", type=Path, default=Path.cwd())
    ap.add_argument("--tag", default="", help="the DEV tag the fleet builds (default: cos-<checkout name>)")
    ap.add_argument("--debounce", type=float, default=1.0, help="seconds a save must stay unchanged")
    ap.add_argument("--interval", type=float, default=0.25, help="seconds between looks at the tree")
    ap.add_argument("--once", action="store_true", help="check the tree as it is now, then exit")
    ap.add_argument("--full", action="store_true",
                    help="follow the whole tagged build (an installable DEV app), not just the compile")
    args = ap.parse_args()
    checkout = Path(git(args.checkout, "rev-parse", "--show-toplevel").strip())
    tag = args.tag or "cos-" + re.sub(r"[^a-z0-9-]+", "-", checkout.name.lower()).strip("-")[:40]

    if args.once:
        tree, newest = tree_state(checkout)
        build = Build(checkout, tag, tree, newest or time.time())
        while (code := build.poll(not args.full)) is None:
            time.sleep(args.interval)
        build.report("ok" if code == 0 else "failed")
        return code

    checked, build = tree_state(checkout)[0], None
    pending, pending_since = "", 0.0
    print(f"check-on-save: watching {checkout} (tag {tag}); save a file to check it", file=sys.stderr)
    try:
        while True:
            if build and (code := build.poll(not args.full)) is not None:
                build.report("ok" if code == 0 else "failed")
                build = None
            tree, newest = tree_state(checkout)
            if tree == checked:
                pending = ""
            elif tree != pending:
                pending, pending_since = tree, time.time()
            elif time.time() - pending_since >= args.debounce:
                if build:
                    build.cancel()
                    build.report("superseded")
                build, checked, pending = Build(checkout, tag, tree, newest or pending_since), tree, ""
            time.sleep(args.interval)
    except KeyboardInterrupt:
        if build:
            build.cancel()
        return 130


if __name__ == "__main__":
    sys.exit(main())
