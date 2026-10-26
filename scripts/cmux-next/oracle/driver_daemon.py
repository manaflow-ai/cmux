#!/usr/bin/env python3
"""The daemon product's driver for oracle.py (driver protocol: oracle.py module docstring).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, tasks 023 (the session: an isolated cmux-tui
per case through hermetic_env.py, steps over the Python SDK, the I6 teardown proof) and 236
(I16). This file holds the I16 part the session calls:

- `require_lock_ranks(binary)` when a session opens: the binary must have the lock-rank checker
  (cmux-tui-core/src/lock_rank.rs), which only builds with debug assertions, so a case never
  runs on a release or bench daemon that would hide a lock-order bug. linux_run.sh builds the
  oracle profile, which keeps them.
- `require_case_local_panic_logs(env, case_root)` before the daemon starts: the owner's and the
  acpmux daemon's panic logs resolve under the case root from the case env, so I16 reads this
  case's panics and no other's.
- `finish_case(result, case_root)` after the daemon has exited, so a panic during shutdown is
  in the log: each panic log line fails the case with its message and location (invariants.py
  check_i16). A Crash or Timeout keeps its status and gains the panic text, which usually says
  why the daemon died.

Stdlib only, Python 3.9+, safe under `python3 -I`.
"""

from __future__ import annotations

import functools
import os
import platform
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import invariants  # noqa: E402

SESSION_TASK = "p15-oracle-023"


class DriverError(Exception):
    """The driver cannot run a case as asked; oracle.py records the case as a Crash."""


def open_session(session_ctx: Dict[str, Any]) -> Any:
    raise DriverError(f"the daemon session is {SESSION_TASK}; this branch has only its I16 checks")


@functools.lru_cache(maxsize=16)
def _lock_ranks_in(path: str, size: int, mtime_ns: int) -> bool:
    return invariants.lock_ranks_compiled_in(Path(path))


def require_lock_ranks(binary: Path) -> None:
    """Refuses a cmux-tui binary built without the lock-rank checker. Cached per file version."""
    try:
        stat = binary.stat()
    except OSError as error:
        raise DriverError(f"cannot read the daemon binary {binary}: {error}") from error
    if not _lock_ranks_in(str(binary.resolve()), stat.st_size, stat.st_mtime_ns):
        raise DriverError(
            f"{binary} has no lock-rank checker (built without debug assertions); "
            "build it with scripts/cmux-next/oracle/linux_run.sh build (--profile oracle --features oracle)"
        )


def _env_path(env: Mapping[str, str], name: str) -> Optional[Path]:
    value = env.get(name)
    return Path(value) if value else None


def panic_log_dirs(env: Mapping[str, str], *, system: Optional[str] = None) -> List[Path]:
    """Where the daemon processes of `env` write panic logs, as their Rust code resolves them.

    Owner: the parent of the sessions dir (owner_panic.rs log_path over
    cmux-tui-platform workspace_state_dir). acpmux: ACPMUX_HOME, else HOME/.acpmux
    (acpmux config.rs home).
    """
    system = system or platform.system()
    home = _env_path(env, "HOME")
    sessions = _env_path(env, "CMUX_TUI_STATE_DIR")
    if sessions is None and system == "Darwin" and home is not None:
        sessions = home / "Library" / "Application Support" / "cmux-tui" / "sessions"
    elif sessions is None:
        state = _env_path(env, "XDG_STATE_HOME") or (home / ".local" / "state" if home else None)
        sessions = state / "cmux-tui" / "sessions" if state else None
    acpmux = _env_path(env, "ACPMUX_HOME") or (home / ".acpmux" if home else None)
    dirs = []
    if sessions is not None:
        dirs.append(sessions.parent)
    if acpmux is not None:
        dirs.append(acpmux)
    return dirs


def _inside(path: Path, root: Path) -> bool:
    try:
        Path(os.path.abspath(path)).relative_to(os.path.abspath(root))
    except ValueError:
        return False
    return True


def require_case_local_panic_logs(env: Mapping[str, str], case_root: Path, *, system: Optional[str] = None) -> None:
    dirs = panic_log_dirs(env, system=system)
    if len(dirs) < 2:
        raise DriverError("the case env sets neither HOME nor the state dirs; the panic logs have no home")
    outside = [str(d) for d in dirs if not _inside(d, case_root)]
    if outside:
        raise DriverError(f"panic logs would land outside the case root {case_root}: {', '.join(outside)}")


def finish_case(result: Dict[str, Any], case_root: Path) -> Dict[str, Any]:
    """Applies I16 to a finished case's result. Call after the daemon processes have exited."""
    try:
        violations = invariants.check_i16(case_root)
    except OSError as error:
        raise DriverError(f"cannot read the panic logs under {case_root}: {error}") from error
    if not violations:
        return result
    text = invariants.failure_message(violations)
    status = result.get("status")
    previous = str(result.get("message") or "")
    out = dict(result)
    out["invariants"] = list(result.get("invariants") or ()) + [v.to_json() for v in violations]
    if status in ("Crash", "Timeout"):
        out["message"] = f"{previous}; {text}" if previous else text
    else:
        out["status"] = "Failure"
        out["message"] = f"{text}; {previous}" if previous else text
    return out
