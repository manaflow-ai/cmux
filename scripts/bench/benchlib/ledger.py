"""The results ledger: every run appends here, and compare reads from here.

Store: the `bench-ledger` branch of manaflow-ai/cmuxterm-hq (private), one JSONL file per run at
`runs/YYYY/MM/<run_id>.jsonl`. File names are unique, so concurrent writers never conflict: a push
that loses a race rebases and pushes again. Reads and writes go through git, not the GitHub API, so
they spend none of the shared API quota.

Local cache: a clone of that one branch at $CMUX_BENCH_CACHE (default ~/.cache/cmux-bench/ledger).
A run that cannot push stays committed there and goes out with the next push (`cmux-bench ledger push`).

CMUX_BENCH_LEDGER=DIR uses a plain directory instead (tests, offline work); nothing is pushed.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable

from . import schema

REMOTE = os.environ.get("CMUX_BENCH_LEDGER_REMOTE", "https://github.com/manaflow-ai/cmuxterm-hq.git")
BRANCH = os.environ.get("CMUX_BENCH_LEDGER_BRANCH", "bench-ledger")


class LedgerError(RuntimeError):
    pass


def _git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(["git", "-C", str(cwd), *args], text=True, capture_output=True)
    if check and proc.returncode != 0:
        raise LedgerError(f"git {' '.join(args)}: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


class Ledger:
    def __init__(self, root: Path | None = None, remote: str | None = None):
        plain = os.environ.get("CMUX_BENCH_LEDGER")
        if root is None and plain:
            root, remote = Path(plain), None
        elif root is None:
            root = Path(os.environ.get("CMUX_BENCH_CACHE", Path.home() / ".cache/cmux-bench/ledger"))
            remote = remote or REMOTE
        self.root = Path(root)
        self.remote = remote

    # --- sync -----------------------------------------------------------------------------------
    def _ensure_clone(self) -> None:
        if self.remote is None:
            self.root.mkdir(parents=True, exist_ok=True)
            return
        if (self.root / ".git").exists():
            return
        self.root.parent.mkdir(parents=True, exist_ok=True)
        probe = subprocess.run(["git", "ls-remote", "--exit-code", "--heads", self.remote, BRANCH],
                               text=True, capture_output=True)
        if probe.returncode == 0:
            proc = subprocess.run(["git", "clone", "-q", "--single-branch", "--branch", BRANCH, self.remote,
                                   str(self.root)], text=True, capture_output=True)
            if proc.returncode != 0:
                raise LedgerError(f"clone {self.remote} {BRANCH}: {proc.stderr.strip()}")
            return
        if probe.returncode != 2:  # 2 = reachable, no such branch
            raise LedgerError(f"ls-remote {self.remote}: {probe.stderr.strip()}")
        # First run anywhere: start the orphan branch.
        self.root.mkdir(parents=True, exist_ok=True)
        _git(self.root, "init", "-q", "-b", BRANCH)
        _git(self.root, "remote", "add", "origin", self.remote)
        (self.root / "README.md").write_text(
            "# cmux bench ledger\n\nOne JSONL file per `cmux-bench` run (schema cmux-bench/v1), written by\n"
            "manaflow-ai/cmux `scripts/bench/cmux-bench`. Never edit by hand; query with `cmux-bench compare`.\n")
        _git(self.root, "add", "README.md")
        _git(self.root, "-c", "user.name=cmux-bench", "-c", "user.email=cmux-bench@users.noreply.github.com",
             "commit", "-q", "-m", "bench ledger: start")

    def pull(self) -> None:
        self._ensure_clone()
        if self.remote is None:
            return
        if _git(self.root, "ls-remote", "--exit-code", "--heads", "origin", BRANCH, check=False).returncode != 0:
            return
        with self._lock():
            self._rebase()

    @contextlib.contextmanager
    def _lock(self):
        """One writer per local clone at a time: the write, commit, rebase and push of a run hold it."""
        self.root.mkdir(parents=True, exist_ok=True)
        with open(self.root.parent / f".{self.root.name}.lock", "w") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fh, fcntl.LOCK_UN)

    def _rebase(self) -> None:
        proc = _git(self.root, "pull", "-q", "--rebase", "origin", BRANCH, check=False)
        if proc.returncode != 0:
            # Never leave a half-done rebase: every later pull would fail on it.
            _git(self.root, "rebase", "--abort", check=False)
            raise LedgerError(f"pull {BRANCH}: {proc.stderr.strip() or proc.stdout.strip()}")

    def _commit_stranded(self) -> None:
        """Commit any run file a crashed or interrupted append wrote but never committed."""
        if self.remote is None:
            return
        _git(self.root, "add", "--", "runs")
        if _git(self.root, "diff", "--cached", "--quiet", check=False).returncode != 0:
            _git(self.root, "-c", "user.name=cmux-bench", "-c", "user.email=cmux-bench@users.noreply.github.com",
                 "commit", "-q", "-m", "runs left uncommitted by an earlier append")

    def push(self, attempts: int = 3) -> None:
        """Push local runs; raise LedgerError (the runs stay committed locally) when the remote refuses."""
        if self.remote is None:
            return
        with self._lock():
            self._push(attempts)

    def _push(self, attempts: int) -> None:
        self._commit_stranded()
        last = ""
        for _ in range(attempts):
            proc = _git(self.root, "push", "-q", "origin", f"HEAD:refs/heads/{BRANCH}", check=False)
            if proc.returncode == 0:
                return
            last = proc.stderr.strip()
            try:
                self._rebase()
            except LedgerError as err:
                last = str(err)
        raise LedgerError(f"push to {self.remote} {BRANCH} failed after {attempts} tries: {last}")

    # --- write ----------------------------------------------------------------------------------
    def append(self, rows: list[dict[str, Any]], push: bool = True) -> Path:
        if not rows:
            raise LedgerError("a run with no rows is not recorded")
        for row in rows:
            schema.validate(row)
        run_ids = {r["run_id"] for r in rows}
        if len(run_ids) != 1:
            raise LedgerError(f"one run per append, got {sorted(run_ids)}")
        run_id = run_ids.pop()
        self._ensure_clone()
        ts = rows[0]["timestamp"]
        rel = Path("runs") / ts[:4] / ts[5:7] / f"{run_id}.jsonl"
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._lock():
            # Write to a temp name and rename, so a reader never sees half a run.
            tmp = path.with_suffix(".jsonl.tmp")
            with tmp.open("x", encoding="utf-8") as fh:
                for row in rows:
                    fh.write(json.dumps(row, sort_keys=True) + "\n")
            if path.exists():
                tmp.unlink()
                raise LedgerError(f"{rel} already exists")
            os.replace(tmp, path)
            if self.remote is not None:
                self._commit_stranded()
                if push:
                    self._push(3)
        return path

    # --- read -----------------------------------------------------------------------------------
    def rows(self, bench: str | None = None) -> Iterable[dict[str, Any]]:
        base = self.root / "runs"
        if not base.exists():
            return
        for path in sorted(base.rglob("*.jsonl")):
            if bench and f"-{bench}-" not in path.name:
                continue
            for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.strip():
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        print(f"cmux-bench: ledger: skipping a bad line {path.name}:{n}", file=sys.stderr)
                        continue
                    if bench is None or row.get("bench") == bench:
                        yield row

    def runs(self, bench: str | None = None) -> list[dict[str, Any]]:
        """One summary per run, oldest first: run_id, bench, build, host, timestamp, rows."""
        by_run: dict[str, dict[str, Any]] = {}
        for row in self.rows(bench):
            run = by_run.setdefault(row["run_id"], {
                "run_id": row["run_id"], "bench": row["bench"], "build": row["build"], "host": row["host"],
                "harness": row["harness"], "timestamp": row["timestamp"], "rows": []})
            run["rows"].append(row)
        return sorted(by_run.values(), key=lambda r: (r["timestamp"], r["run_id"]))
