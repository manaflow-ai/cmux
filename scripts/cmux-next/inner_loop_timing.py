"""Worktree-local observations; missing first-edit evidence remains unknown, never invented."""
from __future__ import annotations

import datetime
import fcntl
import json
import os
import subprocess
import tempfile
from pathlib import Path


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def record(root: Path, *, edit: bool = False, prepush: dict | None = None) -> None:
    """Best-effort metrics, serialized per worktree; a new branch starts a new observation."""
    try:
        result = subprocess.run(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
                                capture_output=True, text=True, timeout=0.3, check=True)
        directory = Path(result.stdout.strip())
        branch = subprocess.run(["git", "-C", str(root), "symbolic-ref", "--quiet", "HEAD"],
                                capture_output=True, text=True, timeout=0.3, check=True).stdout.strip()
        with (directory / "cmux-inner-loop.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = directory / "cmux-inner-loop.json"
            try:
                value = json.loads(path.read_text())
            except (OSError, ValueError):
                value = {}
            if not isinstance(value, dict) or value.get("branch") != branch:
                value = {"schema": "cmux-inner-loop/v1", "branch": branch, "first_edit_at": None}
            if edit and not value.get("first_edit_at"):
                value["first_edit_at"] = now()
                value["first_edit_head"] = subprocess.run(
                    ["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True,
                    text=True, timeout=0.3, check=True).stdout.strip()
            if prepush is not None:
                value["prepush"] = prepush
            with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as out:
                temporary = Path(out.name)
                json.dump(value, out)
                out.write("\n")
            try:
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass  # telemetry never blocks an edit or push
