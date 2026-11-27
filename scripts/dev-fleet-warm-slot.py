#!/usr/bin/env python3
"""Machine-local warm build slots for cmux dev-fleet tasks.

Warm state is acceleration only. Every task still executes a native build, and
callers retain their ordinary clean-checkout cold-build path.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from typing import Any, Iterator, Sequence

SCHEMA = 1
TERM_GRACE_SECONDS = 10.0
CLEANUP_TERM_GRACE_SECONDS = 1.0
EVENT_JOURNAL_MAX_BYTES = 16 * 1024 * 1024
IDENTIFIER_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@+-"
)


def closed_identifier(value: str, label: str, max_length: int) -> str:
    """Validate one controller identity before it can become local state."""
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= max_length
        or not value[0].isalnum()
        or not value[0].isascii()
        or any(character not in IDENTIFIER_CHARS for character in value)
    ):
        raise ValueError(f"{label} must be a closed ASCII identifier")
    return value


def slot_id(value: str) -> str:
    try:
        return closed_identifier(value, "slot", 64)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def task_id(value: str) -> str:
    try:
        return closed_identifier(value, "task id", 160)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def log_token(value: str) -> str:
    """Return a filesystem-safe correlation token without trusting source syntax."""
    if len(value) == 40 and all(character in "0123456789abcdef" for character in value):
        return value[:12]
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def digest(value: Any) -> str:
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def git(checkout: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(checkout), *args],
        check=check,
        capture_output=True,
        text=True,
        timeout=60,
    )


def gout(checkout: Path, *args: str) -> str:
    return git(checkout, *args).stdout.strip()


def exists(checkout: Path, commit: str) -> bool:
    return git(checkout, "cat-file", "-e", f"{commit}^{{commit}}", check=False).returncode == 0


def clean(checkout: Path) -> bool:
    return gout(checkout, "status", "--porcelain=v1", "--untracked-files=all") == ""


def head(checkout: Path) -> str:
    return gout(checkout, "rev-parse", "HEAD")


def tree(checkout: Path, commit: str) -> str:
    return gout(checkout, "rev-parse", f"{commit}^{{tree}}")


def ancestor(checkout: Path, older: str, newer: str) -> bool:
    return git(checkout, "merge-base", "--is-ancestor", older, newer, check=False).returncode == 0


def distance(checkout: Path, older: str, newer: str) -> int | None:
    if older == newer:
        return 0
    if not ancestor(checkout, older, newer):
        return None
    try:
        return int(gout(checkout, "rev-list", "--count", f"{older}..{newer}"))
    except ValueError:
        return None


def first_parent_distance(checkout: Path, older: str, newer: str) -> int | None:
    """Count the authoritative line only, excluding merged side-branch commits."""
    if older == newer:
        return 0
    if not ancestor(checkout, older, newer):
        return None
    try:
        return int(gout(checkout, "rev-list", "--count", "--first-parent", f"{older}..{newer}"))
    except ValueError:
        return None


def changed_paths(checkout: Path, older: str, newer: str) -> list[str]:
    raw = gout(checkout, "diff", "--name-only", "--diff-filter=ACMRDTUXB", f"{older}..{newer}")
    return [line for line in raw.splitlines() if line]


def classify(checkout: Path, older: str, newer: str) -> dict[str, Any]:
    """Conservative source classifier. Uncertainty means rebuild."""
    if older == newer:
        return {"decision": "reuse", "reason": "same_source", "paths": []}
    try:
        if not exists(checkout, older) or not exists(checkout, newer):
            return {"decision": "rebuild", "reason": "missing_commit", "paths": []}
        if not ancestor(checkout, older, newer):
            return {"decision": "rebuild", "reason": "source_not_fast_forward", "paths": []}
        paths = changed_paths(checkout, older, newer)
    except (OSError, subprocess.SubprocessError):
        return {"decision": "rebuild", "reason": "classification_error", "paths": []}
    if not paths:
        return {"decision": "reuse", "reason": "tree_equivalent", "paths": []}
    return {"decision": "rebuild", "reason": "source_tree_changed", "paths": paths}


def input_fingerprint(checkout: Path, commit: str) -> str:
    """Conservative complete-tree fingerprint.

    The worker intentionally treats every tracked source-tree change as a build
    input until a stronger project-owned input proof exists. This may warm more
    often; it cannot silently skip an uncertain macOS input.
    """
    return hashlib.sha256(tree(checkout, commit).encode()).hexdigest()


def probe(argv: Sequence[str]) -> str:
    result = subprocess.run(list(argv), check=True, capture_output=True, text=True, timeout=20)
    return result.stdout.strip() or result.stderr.strip()


def toolchain() -> dict[str, Any]:
    injected = os.environ.get("CMUX_WARM_SLOT_TOOLCHAIN_JSON")
    if injected:
        value = json.loads(injected)
        if not isinstance(value, dict):
            raise ValueError("CMUX_WARM_SLOT_TOOLCHAIN_JSON must be an object")
        return value
    if sys.platform != "darwin":
        return {"available": False, "platform": sys.platform, "arch": platform.machine()}
    try:
        return {
            "available": True,
            "platform": "darwin",
            "arch": platform.machine(),
            "developer_dir": os.environ.get("DEVELOPER_DIR") or probe(["/usr/bin/xcode-select", "-p"]),
            "xcode": probe(["/usr/bin/xcodebuild", "-version"]),
            "swift": probe(["/usr/bin/xcrun", "swift", "--version"]),
            "sdk_path": probe(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]),
            "sdk_version": probe(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        }
    except (OSError, subprocess.SubprocessError) as error:
        return {"available": False, "platform": "darwin", "arch": platform.machine(), "error": str(error)}


def alive(pid: int) -> bool:
    """Return whether a process ID currently exists."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def process_identity(pid: int) -> str | None:
    """Return a start-time identity used to reject PID reuse."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    value = " ".join(result.stdout.split())
    return value or None


def same_process(pid: int, identity: Any) -> bool:
    """Validate both PID liveness and its recorded process-start identity."""
    return isinstance(identity, str) and bool(identity) and process_identity(pid) == identity


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def disk_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return total
    for root, _dirs, files in os.walk(path, followlinks=False):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except FileNotFoundError:
                pass
    return total


class Layout:
    def __init__(self, machine: Path, slot: str):
        self.machine = machine
        self.slot_id = closed_identifier(slot, "slot", 64)
        self.slot = machine / "slots" / self.slot_id
        self.record = self.slot / "slot.json"
        self.slot_lock = self.slot / "slot.lock"
        self.lease = self.slot / "lease.json"
        self.inflight = self.slot / "inflight.json"
        self.recovery = self.slot / "recovery"
        self.cache = self.slot / "cache"
        self.logs = self.slot / "logs"
        self.warmer_lock = machine / "warmer.lock"
        self.foreground = machine / "foreground"
        self.foreground_gate = machine / "foreground.lock"
        self.preempt_fifo = machine / "warmer-preempt.fifo"
        self.checkout_locks = machine / "checkout-locks"
        self.events = machine / "events.jsonl"
        self.events_archive = machine / "events.jsonl.1"
        self.events_lock = machine / "events.lock"
        self.cleanup_lock = machine / "cold-cleanup.lock"
        self.retired_cold_tasks = self.cache / "retired-cold-tasks"


@contextlib.contextmanager
def locked(path: Path, blocking: bool = True) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = path.open("a+")
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
    finally:
        try:
            fcntl.flock(stream, fcntl.LOCK_UN)
        finally:
            stream.close()


def cold_task_generation_id(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 32
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ValueError("cold task generation id must be 32 lowercase hex characters")
    return value


def cold_task_root(layout: Layout, generation_id: str) -> Path:
    return layout.cache / "cold-tasks" / cold_task_generation_id(generation_id)


def retired_cold_task_root(layout: Layout, generation_id: str) -> Path:
    return layout.retired_cold_tasks / cold_task_generation_id(generation_id)


_DIRECTORY_OPEN_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
)
_PATH_CONFUSION_ERRNOS = {errno.ELOOP, errno.ENOTDIR}


def _directory_error_state(error: OSError) -> str:
    return "path_confusion" if error.errno in _PATH_CONFUSION_ERRNOS else "unavailable"


def _open_cache_directory_fd(
    layout: Layout,
    directory: Path,
    *,
    create: bool,
) -> tuple[str, int | None]:
    """Open a fixed slot-cache directory chain without following symlinks."""
    try:
        relative = directory.relative_to(layout.cache)
    except ValueError:
        return "path_confusion", None

    try:
        current_fd = os.open(layout.machine, _DIRECTORY_OPEN_FLAGS)
    except FileNotFoundError:
        return "absent", None
    except OSError as error:
        return _directory_error_state(error), None

    try:
        for component in ("slots", layout.slot_id, "cache", *relative.parts):
            while True:
                try:
                    child_fd = os.open(
                        component,
                        _DIRECTORY_OPEN_FLAGS,
                        dir_fd=current_fd,
                    )
                    break
                except FileNotFoundError:
                    if not create:
                        os.close(current_fd)
                        return "absent", None
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=current_fd)
                    except FileExistsError:
                        continue
                    except OSError as error:
                        os.close(current_fd)
                        return _directory_error_state(error), None
                except OSError as error:
                    os.close(current_fd)
                    return _directory_error_state(error), None
            os.close(current_fd)
            current_fd = child_fd
        return "ready", current_fd
    except BaseException:
        with contextlib.suppress(OSError):
            os.close(current_fd)
        raise


def _same_directory(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _directory_entry_state(
    parent_fd: int,
    name: str,
) -> tuple[str, os.stat_result | None]:
    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return "absent", None
    except OSError as error:
        return _directory_error_state(error), None
    if not stat.S_ISDIR(info.st_mode):
        return "path_confusion", info
    return "ready", info


def _open_child_directory_fd(
    parent_fd: int,
    name: str,
) -> tuple[str, int | None, os.stat_result | None]:
    state, before = _directory_entry_state(parent_fd, name)
    if state != "ready" or before is None:
        return state, None, before
    try:
        child_fd = os.open(name, _DIRECTORY_OPEN_FLAGS, dir_fd=parent_fd)
    except FileNotFoundError:
        return "absent", None, None
    except OSError as error:
        return _directory_error_state(error), None, None
    after = os.fstat(child_fd)
    if not _same_directory(before, after):
        os.close(child_fd)
        return "path_confusion", None, None
    return "ready", child_fd, after


def _directory_bytes_fd(directory_fd: int) -> int:
    total = 0
    for name in os.listdir(directory_fd):
        try:
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(info.st_mode):
            state, child_fd, _ = _open_child_directory_fd(directory_fd, name)
            if state == "absent":
                continue
            if state != "ready" or child_fd is None:
                raise OSError(errno.ELOOP, "directory changed during byte measurement", name)
            try:
                total += _directory_bytes_fd(child_fd)
            finally:
                os.close(child_fd)
        else:
            total += int(info.st_size)
    return total


def _remove_tree_contents_fd(directory_fd: int) -> None:
    """Recursively empty one already-open directory without pathname traversal."""
    for name in os.listdir(directory_fd):
        try:
            info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue

        if not stat.S_ISDIR(info.st_mode):
            try:
                os.unlink(name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            continue

        state, child_fd, opened = _open_child_directory_fd(directory_fd, name)
        if state == "absent":
            continue
        if state != "ready" or child_fd is None or opened is None:
            raise OSError(errno.ELOOP, "directory changed during cleanup", name)
        try:
            _remove_tree_contents_fd(child_fd)
            try:
                current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if not stat.S_ISDIR(current.st_mode) or not _same_directory(opened, current):
                raise OSError(errno.ELOOP, "directory changed during cleanup", name)
            os.rmdir(name, dir_fd=directory_fd)
        finally:
            os.close(child_fd)


def _launch_cleanup_worker(
    generation_fd: int,
    generation: str,
) -> subprocess.Popen:
    del generation  # correlation is for tests/logging; authority is the inherited fd.
    return subprocess.Popen(
        [
            sys.executable,
            str(Path(__file__).resolve()),
            "_cleanup-generation",
            "--directory-fd",
            str(generation_fd),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        pass_fds=(generation_fd,),
    )


def retire_cold_task(layout: Layout, generation_id: Any) -> dict[str, Any]:
    try:
        generation = cold_task_generation_id(generation_id)
    except ValueError:
        return {"status": "invalid_identity"}

    active_namespace = layout.cache / "cold-tasks"
    active_state, active_fd = _open_cache_directory_fd(
        layout,
        active_namespace,
        create=False,
    )
    if active_state == "absent":
        return {"status": "absent", "cold_task_generation_id": generation}
    if active_state != "ready" or active_fd is None:
        reason = (
            "active_namespace_path_confusion"
            if active_state == "path_confusion"
            else "active_namespace_unavailable"
        )
        event(
            layout,
            "cold_task_retirement_deferred",
            cold_task_generation_id=generation,
            reason=reason,
        )
        return {
            "status": "invalid_namespace" if active_state == "path_confusion" else "deferred",
            "reason": reason,
            "cold_task_generation_id": generation,
        }

    retired_fd: int | None = None
    try:
        retired_state, retired_fd = _open_cache_directory_fd(
            layout,
            layout.retired_cold_tasks,
            create=True,
        )
        if retired_state != "ready" or retired_fd is None:
            reason = (
                "retired_namespace_path_confusion"
                if retired_state == "path_confusion"
                else "retired_namespace_unavailable"
            )
            event(
                layout,
                "cold_task_retirement_deferred",
                cold_task_generation_id=generation,
                reason=reason,
            )
            return {
                "status": "invalid_namespace" if retired_state == "path_confusion" else "deferred",
                "reason": reason,
                "cold_task_generation_id": generation,
            }

        active_generation_state, _ = _directory_entry_state(active_fd, generation)
        retired_generation_state, _ = _directory_entry_state(retired_fd, generation)

        if retired_generation_state == "path_confusion":
            event(
                layout,
                "cold_task_retirement_deferred",
                cold_task_generation_id=generation,
                reason="retired_generation_path_confusion",
            )
            return {
                "status": "invalid_namespace",
                "reason": "retired_generation_path_confusion",
                "cold_task_generation_id": generation,
            }
        if retired_generation_state == "unavailable":
            return {
                "status": "deferred",
                "reason": "retired_generation_unreadable",
                "cold_task_generation_id": generation,
            }
        if active_generation_state == "path_confusion":
            event(
                layout,
                "cold_task_retirement_deferred",
                cold_task_generation_id=generation,
                reason="active_generation_path_confusion",
            )
            return {
                "status": "invalid_namespace",
                "reason": "active_generation_path_confusion",
                "cold_task_generation_id": generation,
            }
        if active_generation_state == "unavailable":
            return {
                "status": "deferred",
                "reason": "active_generation_unreadable",
                "cold_task_generation_id": generation,
            }

        if retired_generation_state == "ready":
            return {
                "status": "already_retired" if active_generation_state == "absent" else "conflict",
                "cold_task_generation_id": generation,
            }
        if active_generation_state == "absent":
            return {"status": "absent", "cold_task_generation_id": generation}

        try:
            os.rename(
                generation,
                generation,
                src_dir_fd=active_fd,
                dst_dir_fd=retired_fd,
            )
        except OSError:
            event(
                layout,
                "cold_task_retirement_deferred",
                cold_task_generation_id=generation,
                reason="rename_failed",
            )
            return {
                "status": "deferred",
                "reason": "rename_failed",
                "cold_task_generation_id": generation,
            }

        post_state, _ = _directory_entry_state(retired_fd, generation)
        if post_state != "ready":
            reason = (
                "retired_generation_path_confusion"
                if post_state == "path_confusion"
                else "retired_generation_unreadable"
            )
            event(
                layout,
                "cold_task_retirement_deferred",
                cold_task_generation_id=generation,
                reason=reason,
            )
            return {
                "status": "invalid_namespace" if post_state == "path_confusion" else "deferred",
                "reason": reason,
                "cold_task_generation_id": generation,
            }

        event(layout, "cold_task_retired", cold_task_generation_id=generation)
        return {"status": "retired", "cold_task_generation_id": generation}
    finally:
        os.close(active_fd)
        if retired_fd is not None:
            os.close(retired_fd)


def _wait_cleanup_process(
    proc: subprocess.Popen,
    preempt_fd: int | None,
) -> bool:
    """Wait for cleanup completion while allowing foreground work to preempt it."""
    if preempt_fd is None:
        proc.wait()
        return False

    done_read, done_write = os.pipe()
    waiter_error: list[BaseException] = []

    def wait_for_exit() -> None:
        try:
            proc.wait()
        except BaseException as error:
            waiter_error.append(error)
        finally:
            with contextlib.suppress(OSError):
                os.write(done_write, b"1")
            with contextlib.suppress(OSError):
                os.close(done_write)

    waiter = threading.Thread(
        target=wait_for_exit,
        name="cmux-cold-cleanup-waiter",
        daemon=True,
    )
    waiter.start()
    try:
        while True:
            ready, _, _ = select.select([done_read, preempt_fd], [], [])
            if done_read in ready:
                with contextlib.suppress(OSError):
                    os.read(done_read, 1)
                waiter.join()
                if waiter_error:
                    raise waiter_error[0]
                return False
            if preempt_fd in ready and consume_preempt(preempt_fd):
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGTERM)
                waiter.join(CLEANUP_TERM_GRACE_SECONDS)
                if waiter.is_alive():
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(proc.pid, signal.SIGKILL)
                    waiter.join()
                if waiter_error:
                    raise waiter_error[0]
                return True
    finally:
        with contextlib.suppress(OSError):
            os.close(done_read)


def cleanup_retired_cold_tasks(
    layout: Layout,
    *,
    preempt_fd: int | None = None,
    max_generations: int = 1,
    measure_bytes: bool = False,
) -> dict[str, Any]:
    """Reclaim bounded retired cold-task generations outside foreground locks."""
    started = time.monotonic()
    reclaimed_bytes = 0

    def finished(result: dict[str, Any]) -> dict[str, Any]:
        result["wall_seconds"] = round(time.monotonic() - started, 6)
        if measure_bytes:
            result["reclaimed_bytes"] = reclaimed_bytes
        return result

    if max_generations <= 0 or max_generations > 32:
        return finished({
            "status": "failed",
            "reason": "invalid_cleanup_budget",
            "reclaimed": 0,
        })
    try:
        cleanup_lock = locked(layout.cleanup_lock, blocking=False)
        cleanup_lock.__enter__()
    except BlockingIOError:
        event(layout, "cold_task_cleanup_deferred", reason="cleanup_already_running")
        return finished({"status": "deferred", "reason": "cleanup_already_running", "reclaimed": 0})

    reclaimed = 0
    failures: list[dict[str, str]] = []
    attempts = 0
    retired_fd: int | None = None
    try:
        retired_state, retired_fd = _open_cache_directory_fd(
            layout,
            layout.retired_cold_tasks,
            create=False,
        )
        if retired_state == "absent":
            return finished({"status": "idle", "reclaimed": 0})
        if retired_state != "ready" or retired_fd is None:
            reason = (
                "retired_namespace_path_confusion"
                if retired_state == "path_confusion"
                else "retired_namespace_unreadable"
            )
            event(layout, "cold_task_cleanup_failed", reason=reason)
            return finished({"status": "failed", "reason": reason, "reclaimed": 0})

        try:
            retired_entries = sorted(os.listdir(retired_fd))
        except OSError:
            event(layout, "cold_task_cleanup_failed", reason="retired_namespace_unreadable")
            return finished({
                "status": "failed",
                "reason": "retired_namespace_unreadable",
                "reclaimed": 0,
            })

        for generation in retired_entries:
            if reclaimed >= max_generations or attempts >= 32:
                break
            try:
                cold_task_generation_id(generation)
            except ValueError:
                continue

            attempts += 1
            generation_state, generation_fd, generation_info = _open_child_directory_fd(
                retired_fd,
                generation,
            )
            if generation_state == "absent":
                continue
            if generation_state != "ready" or generation_fd is None or generation_info is None:
                failure = {
                    "cold_task_generation_id": generation,
                    "reason": (
                        "cleanup_generation_path_confusion"
                        if generation_state == "path_confusion"
                        else "cleanup_generation_unreadable"
                    ),
                }
                failures.append(failure)
                event(layout, "cold_task_cleanup_failed", **failure)
                continue

            try:
                try:
                    candidate_bytes = _directory_bytes_fd(generation_fd) if measure_bytes else 0
                except OSError:
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_generation_path_confusion",
                    }
                    failures.append(failure)
                    event(layout, "cold_task_cleanup_failed", **failure)
                    continue

                try:
                    proc = _launch_cleanup_worker(generation_fd, generation)
                except OSError:
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_launch_failed",
                    }
                    failures.append(failure)
                    event(layout, "cold_task_cleanup_failed", **failure)
                    continue

                try:
                    preempted = _wait_cleanup_process(proc, preempt_fd)
                except (OSError, RuntimeError) as error:
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_wait_failed",
                    }
                    failures.append(failure)
                    event(
                        layout,
                        "cold_task_cleanup_failed",
                        **failure,
                        detail=str(error),
                    )
                    continue

                if preempted:
                    event(
                        layout,
                        "cold_task_cleanup_preempted",
                        cold_task_generation_id=generation,
                    )
                    result: dict[str, Any] = {
                        "status": "preempted",
                        "reclaimed": reclaimed,
                        "cold_task_generation_id": generation,
                    }
                    if failures:
                        result["failures"] = failures
                    return finished(result)

                if proc.returncode != 0:
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_failed",
                    }
                    failures.append(failure)
                    event(layout, "cold_task_cleanup_failed", **failure)
                    continue

                current_state, current_info = _directory_entry_state(retired_fd, generation)
                if (
                    current_state != "ready"
                    or current_info is None
                    or not _same_directory(generation_info, current_info)
                ):
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_generation_path_confusion",
                    }
                    failures.append(failure)
                    event(layout, "cold_task_cleanup_failed", **failure)
                    continue

                try:
                    os.rmdir(generation, dir_fd=retired_fd)
                except OSError:
                    failure = {
                        "cold_task_generation_id": generation,
                        "reason": "cleanup_failed",
                    }
                    failures.append(failure)
                    event(layout, "cold_task_cleanup_failed", **failure)
                    continue

                reclaimed += 1
                reclaimed_bytes += candidate_bytes
                event(
                    layout,
                    "cold_task_reclaimed",
                    cold_task_generation_id=generation,
                    reclaimed_bytes=candidate_bytes if measure_bytes else None,
                )
            finally:
                os.close(generation_fd)

        result = {
            "status": "reclaimed" if reclaimed else ("failed" if failures else "idle"),
            "reclaimed": reclaimed,
        }
        if failures:
            result["failures"] = failures
            if not reclaimed:
                result["reason"] = failures[0]["reason"]
                if "cold_task_generation_id" in failures[0]:
                    result["cold_task_generation_id"] = failures[0]["cold_task_generation_id"]
        return finished(result)
    finally:
        if retired_fd is not None:
            os.close(retired_fd)
        cleanup_lock.__exit__(None, None, None)


def checkout_lock_path(layout: Layout, checkout: Path) -> Path:
    """Return one machine-local lock path for a physical checkout."""
    key = hashlib.sha256(str(checkout.resolve()).encode()).hexdigest()[:32]
    return layout.checkout_locks / f"{key}.lock"


@contextlib.contextmanager
def warm_slot_lock(layout: Layout, checkout: Path) -> Iterator[None]:
    """Acquire a slot and its checkout without waiting behind foreground work."""
    with locked(layout.slot_lock, blocking=False):
        with locked(checkout_lock_path(layout, checkout), blocking=False):
            yield


def _trim_partial_event_tail(fd: int, size: int) -> int:
    """Discard one crash-torn JSONL tail before appending new telemetry."""
    if size <= 0 or os.pread(fd, 1, size - 1) == b"\n":
        return max(size, 0)
    offset = size
    while offset > 0:
        start = max(0, offset - 65536)
        chunk = os.pread(fd, offset - start, start)
        newline = chunk.rfind(b"\n")
        if newline >= 0:
            complete = start + newline + 1
            os.ftruncate(fd, complete)
            return complete
        offset = start
    os.ftruncate(fd, 0)
    return 0


def _append_event_line(layout: Layout, payload: bytes) -> None:
    """Append advisory telemetry without a foreground durability barrier."""
    if len(payload) > EVENT_JOURNAL_MAX_BYTES:
        raise OSError("event journal row exceeds retention limit")
    flags = os.O_RDWR | os.O_CREAT | os.O_APPEND
    fd = os.open(layout.events, flags, 0o600)
    try:
        size = _trim_partial_event_tail(fd, os.lseek(fd, 0, os.SEEK_END))
        if size and size + len(payload) > EVENT_JOURNAL_MAX_BYTES:
            os.close(fd)
            fd = -1
            os.replace(layout.events, layout.events_archive)
            fd = os.open(layout.events, flags, 0o600)

        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("event journal write made no progress")
            view = view[written:]
    finally:
        if fd >= 0:
            os.close(fd)


def event(layout: Layout, kind: str, **fields: Any) -> None:
    """Best-effort observational telemetry; lease/inflight state owns recovery."""
    row = {"schema_version": SCHEMA, "event": kind, "at": now_iso(), "slot_id": layout.slot_id, **fields}
    payload = (json.dumps(row, sort_keys=True) + "\n").encode("utf-8")
    try:
        with locked(layout.events_lock):
            layout.events.parent.mkdir(parents=True, exist_ok=True)
            _append_event_line(layout, payload)
    except OSError as error:
        print(f"warning: warm-slot telemetry event dropped: {error}", file=sys.stderr)


def live_foreground(layout: Layout, prune: bool = True) -> list[dict[str, Any]]:
    """Inspect diagnostic foreground request records outside the warmer hot path."""
    layout.foreground.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    for path in layout.foreground.glob("*.json"):
        try:
            row = read_json(path) or {}
            pid = int(row.get("pid", -1))
        except (OSError, ValueError, json.JSONDecodeError):
            rows.append({"state": "unreadable", "path": str(path)})
            continue
        if pid > 0 and same_process(pid, row.get("process_identity")):
            rows.append({**row, "state": "live", "path": str(path)})
        elif prune:
            path.unlink(missing_ok=True)
        else:
            rows.append({**row, "state": "stale", "path": str(path)})
    return rows


def signal_warmer(layout: Layout) -> bool:
    """Notify the one machine warmer through its FIFO without PID signalling."""
    try:
        fd = os.open(layout.preempt_fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        os.write(fd, b"1")
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


@contextlib.contextmanager
def foreground_request(layout: Layout, task_id: str, target: str) -> Iterator[None]:
    """Publish foreground demand and hold the machine gate for its lifetime."""
    task_id = closed_identifier(task_id, "task id", 160)
    layout.foreground.mkdir(parents=True, exist_ok=True)
    layout.foreground_gate.parent.mkdir(parents=True, exist_ok=True)
    gate = layout.foreground_gate.open("a+")
    fcntl.flock(gate, fcntl.LOCK_SH)
    path = layout.foreground / f"{uuid.uuid4().hex}.json"
    atomic_json(path, {
        "schema_version": SCHEMA,
        "task_id": task_id,
        "target_commit": target,
        "pid": os.getpid(),
        "process_identity": process_identity(os.getpid()),
        "requested_at": now_iso(),
    })
    signal_warmer(layout)
    try:
        yield
    finally:
        path.unlink(missing_ok=True)
        try:
            fcntl.flock(gate, fcntl.LOCK_UN)
        finally:
            gate.close()


def current_slot_lease(layout: Layout, prune_expired: bool = True) -> dict[str, Any] | None:
    try:
        lease = read_json(layout.lease)
    except (OSError, ValueError, json.JSONDecodeError):
        return {"kind": "unreadable", "reason": "lease_unreadable"}
    if not lease:
        return None
    if lease.get("kind") != "reserved-task":
        return lease
    expires = lease.get("expires_epoch")
    if not isinstance(expires, (int, float)):
        return lease
    if expires > time.time():
        return lease
    if prune_expired:
        layout.lease.unlink(missing_ok=True)
        event(layout, "task_reservation_expired", lease_id=lease.get("lease_id"), task_id=lease.get("task_id"))
    return None


@contextlib.contextmanager
def visible_lease(
    layout: Layout,
    kind: str,
    owner: str,
    target: str,
    lease_id: str | None = None,
    **extra: Any,
) -> Iterator[None]:
    atomic_json(layout.lease, {
        "schema_version": SCHEMA,
        "lease_id": lease_id or uuid.uuid4().hex,
        "kind": kind,
        "owner": owner,
        "pid": os.getpid(),
        "process_identity": process_identity(os.getpid()),
        "target_commit": target,
        "acquired_at": now_iso(),
        **extra,
    })
    try:
        yield
    finally:
        layout.lease.unlink(missing_ok=True)


def annotate_lease(layout: Layout, **fields: Any) -> None:
    """Durably bind native-run identity to the visible lease before exec."""
    try:
        lease = read_json(layout.lease)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("lease_unreadable_during_native_launch") from error
    if not lease:
        raise RuntimeError("lease_missing_during_native_launch")
    lease.update(fields)
    atomic_json(layout.lease, lease)


def open_preempt_channel(layout: Layout) -> int:
    """Create the machine-local FIFO used for task-first warmer cancellation."""
    layout.preempt_fifo.parent.mkdir(parents=True, exist_ok=True)
    try:
        info = layout.preempt_fifo.lstat()
    except FileNotFoundError:
        info = None
    if info is not None:
        if not stat.S_ISFIFO(info.st_mode):
            raise RuntimeError("preempt_path_not_fifo")
        layout.preempt_fifo.unlink()
    os.mkfifo(layout.preempt_fifo, 0o600)
    return os.open(layout.preempt_fifo, os.O_RDWR | os.O_NONBLOCK)


def close_preempt_channel(layout: Layout, fd: int | None) -> None:
    """Close and remove the warmer FIFO owned by this process."""
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    layout.preempt_fifo.unlink(missing_ok=True)


def consume_preempt(fd: int) -> bool:
    """Drain a pending foreground preemption notification if one exists."""
    ready, _, _ = select.select([fd], [], [], 0)
    if not ready:
        return False
    consumed = False
    while True:
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            break
        if not data:
            break
        consumed = True
        if len(data) < 4096:
            break
    return consumed


def notify_ready(fd: int | None) -> None:
    """Signal an owning benchmark that the warmer lease is visible."""
    if fd is None:
        return
    try:
        os.write(fd, b"1")
    except OSError:
        pass
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def generation(record: dict[str, Any] | None) -> dict[str, Any] | None:
    value = (record or {}).get("generation")
    return value if isinstance(value, dict) else None


def save(layout: Layout, record: dict[str, Any]) -> None:
    record.update({"schema_version": SCHEMA, "slot_id": layout.slot_id, "updated_at": now_iso()})
    atomic_json(layout.record, record)


def quarantine(layout: Layout, record: dict[str, Any] | None, reason: str) -> None:
    gen = generation(record)
    if not gen:
        return
    gen.update({"quarantined": True, "warm_ready": False, "quarantine_reason": reason, "quarantined_at": now_iso()})
    save(layout, record or {})
    event(layout, "lineage_quarantined", reason=reason, generation_id=gen.get("generation_id"))


def generation_id(source: str, toolchain_fp: str, input_fp: str | None, lineage: str) -> str:
    return digest({"source": source, "toolchain": toolchain_fp, "inputs": input_fp, "lineage": lineage})[:24]


def plan(layout: Layout, checkout: Path, target: str) -> dict[str, Any]:
    tc = toolchain()
    tc_fp = digest(tc)
    out: dict[str, Any] = {
        "schema_version": SCHEMA,
        "slot_id": layout.slot_id,
        "target_commit": target,
        "decision": "cold",
        "reason": "uninitialized",
        "toolchain": tc,
        "toolchain_fingerprint": tc_fp,
    }
    try:
        record = read_json(layout.record)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        return {**out, "decision": "fallback", "reason": "state_unreadable", "error": str(error)}
    gen = generation(record)
    try:
        out["head_commit"] = head(checkout)
        out["source_clean"] = clean(checkout)
    except (OSError, subprocess.SubprocessError):
        return {**out, "decision": "fallback", "reason": "source_unavailable"}
    if not out["source_clean"]:
        return {**out, "decision": "fallback", "reason": "dirty_source"}
    if not exists(checkout, target):
        return {**out, "decision": "fallback", "reason": "target_missing"}
    try:
        inflight = read_json(layout.inflight)
    except (OSError, ValueError, json.JSONDecodeError):
        inflight = {"unreadable": True}
    if inflight:
        return {**out, "decision": "fallback", "reason": "recovery_required", "inflight": inflight}
    if not gen:
        return out
    out["generation"] = gen
    if gen.get("quarantined"):
        return {**out, "reason": "lineage_quarantined"}
    if gen.get("toolchain_fingerprint") != tc_fp:
        return {**out, "reason": "toolchain_changed"}
    if gen.get("warm_ready") is not True:
        return {**out, "decision": "rebuild", "reason": "slot_needs_rewarm"}
    source = str(gen.get("source_commit", ""))
    if not source or not exists(checkout, source):
        return {**out, "reason": "generation_source_missing"}
    if not ancestor(checkout, source, target):
        return {**out, "decision": "fallback", "reason": "generation_not_ancestor"}
    classification = classify(checkout, source, target)
    try:
        target_fp = input_fingerprint(checkout, target)
    except (OSError, subprocess.SubprocessError, ValueError):
        target_fp = None
    same_inputs = bool(target_fp and target_fp == gen.get("build_input_fingerprint"))
    return {
        **out,
        "decision": "reuse" if same_inputs else "rebuild",
        "reason": classification["reason"],
        "classification": classification,
        "distance": distance(checkout, source, target),
        "target_build_input_fingerprint": target_fp,
    }


def switch_exact(checkout: Path, target: str) -> None:
    if not clean(checkout):
        raise RuntimeError("dirty_source")
    if not exists(checkout, target):
        raise RuntimeError("target_missing")
    if head(checkout) != target:
        git(checkout, "switch", "--detach", target)
    if not clean(checkout):
        raise RuntimeError("source_became_dirty")


def switch_from_warm(checkout: Path, source: str, target: str) -> None:
    if not clean(checkout):
        raise RuntimeError("dirty_source")
    if not ancestor(checkout, source, target):
        raise RuntimeError("source_not_fast_forward")
    if head(checkout) != source:
        git(checkout, "switch", "--detach", source)
    if source != target:
        git(checkout, "switch", "--detach", target)
    if not clean(checkout):
        raise RuntimeError("source_became_dirty")


def swift_compile_count(log: Path) -> int:
    if not log.exists():
        return 0
    with log.open(errors="replace") as stream:
        return sum(1 for line in stream if "SwiftCompile" in line)


def build_command(checkout: Path, tag: str, override: Sequence[str]) -> list[str]:
    if override:
        return list(override)
    return [str(checkout / "scripts/reload.sh"), "--tag", tag, "--no-global-cli-links"]


def build_env(derived: Path, tag: str) -> dict[str, str]:
    env = os.environ.copy()
    env["CMUX_DERIVED_DATA"] = str(derived)
    env["CMUX_FLEET_BUILD_TAG"] = tag
    return env


def run_native(
    layout: Layout,
    checkout: Path,
    argv: Sequence[str],
    env: dict[str, str],
    log: Path,
    operation: str,
    preemptible: bool,
    low_priority: bool,
    preempt_fd: int | None = None,
    cold_task_generation_id: str | None = None,
) -> dict[str, Any]:
    """Execute one native build with durable launch and event-driven cancellation."""
    log.parent.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    started = time.time()
    started_iso = dt.datetime.fromtimestamp(started, dt.timezone.utc).isoformat()
    command_identity = digest({"argv": list(argv), "derived": env.get("CMUX_DERIVED_DATA")})
    before = time.monotonic()

    if preemptible and preempt_fd is not None and consume_preempt(preempt_fd):
        return {
            "run_id": run_id,
            "outcome": "yielded",
            "returncode": 130,
            "wall_seconds": round(time.monotonic() - before, 6),
            "swift_compile_count": 0,
            "log": str(log),
            "command_identity": command_identity,
            "started_at": started_iso,
            "force_killed": False,
        }

    inflight = {
        "schema_version": SCHEMA,
        "run_id": run_id,
        "operation": operation,
        "helper_pid": os.getpid(),
        "helper_process_identity": process_identity(os.getpid()),
        "child_pid": None,
        "process_group": None,
        "launch_guard": "pipe_v1",
        "started_at": started_iso,
        "command_identity": command_identity,
    }
    if cold_task_generation_id is not None:
        inflight["cold_task_generation_id"] = cold_task_generation_id
    atomic_json(layout.inflight, inflight)

    preexec = None
    if low_priority and os.name == "posix":
        def lower_priority() -> None:
            try:
                os.nice(15)
            except OSError:
                pass
        preexec = lower_priority

    guard_r, guard_w = os.pipe()
    launch_guard = (
        "import os,sys\n"
        "fd=int(sys.argv[1])\n"
        "argv=sys.argv[2:]\n"
        "token=os.read(fd,1)\n"
        "os.close(fd)\n"
        "if token != b'G':\n"
        "    raise SystemExit(125)\n"
        "os.execvpe(argv[0], argv, os.environ)\n"
    )
    with log.open("wb") as stream:
        try:
            proc = subprocess.Popen(
                [sys.executable, "-c", launch_guard, str(guard_r), *argv],
                cwd=checkout,
                env=env,
                stdout=stream,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                preexec_fn=preexec,
                pass_fds=(guard_r,),
            )
        finally:
            os.close(guard_r)

        inflight.update({"child_pid": proc.pid, "process_group": proc.pid})
        try:
            atomic_json(layout.inflight, inflight)
            annotate_lease(
                layout,
                native_run_id=run_id,
                native_process_group=proc.pid,
                native_launch_guard="pipe_v1",
            )
        except BaseException:
            os.close(guard_w)
            try:
                proc.wait(timeout=TERM_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            layout.inflight.unlink(missing_ok=True)
            raise

        done = threading.Event()
        yielded = threading.Event()
        forwarded: list[int | None] = [None]
        force_killed = [False]
        force_threads: list[threading.Thread] = []
        prior: dict[int, Any] = {}

        def reap() -> None:
            proc.wait()
            done.set()

        reaper = threading.Thread(target=reap, name=f"cmux-native-reap-{run_id[:8]}", daemon=True)

        def force_after_grace() -> None:
            if done.wait(TERM_GRACE_SECONDS):
                return
            try:
                os.killpg(proc.pid, signal.SIGKILL)
                force_killed[0] = True
            except ProcessLookupError:
                pass

        def request_termination(kind: str, signum: int | None = None) -> None:
            if kind == "preempt":
                yielded.set()
            elif signum is not None:
                forwarded[0] = signum
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            thread = threading.Thread(
                target=force_after_grace,
                name=f"cmux-native-kill-{run_id[:8]}",
                daemon=True,
            )
            force_threads.append(thread)
            thread.start()

        def forward(signum: int, _frame: Any) -> None:
            request_termination("signal", signum)

        if threading.current_thread() is threading.main_thread():
            for signum in (signal.SIGINT, signal.SIGTERM):
                prior[signum] = signal.getsignal(signum)
                signal.signal(signum, forward)

        stop_r = stop_w = None
        watcher = None
        try:
            reaper.start()
            try:
                os.write(guard_w, b"G")
            except BrokenPipeError:
                pass
            finally:
                os.close(guard_w)

            if preemptible and preempt_fd is not None:
                stop_r, stop_w = os.pipe()

                def watch_preempt() -> None:
                    ready, _, _ = select.select([preempt_fd, stop_r], [], [])
                    if stop_r in ready:
                        return
                    if preempt_fd in ready and consume_preempt(preempt_fd):
                        request_termination("preempt")

                watcher = threading.Thread(
                    target=watch_preempt,
                    name=f"cmux-native-preempt-{run_id[:8]}",
                    daemon=True,
                )
                watcher.start()

            done.wait()
        finally:
            if stop_w is not None:
                try:
                    os.write(stop_w, b"1")
                except OSError:
                    pass
                os.close(stop_w)
            if watcher is not None:
                watcher.join()
            if stop_r is not None:
                os.close(stop_r)
            reaper.join()
            for thread in force_threads:
                thread.join()
            for signum, handler in prior.items():
                signal.signal(signum, handler)

    if (yielded.is_set() or forwarded[0] is not None) and group_alive(proc.pid):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            force_killed[0] = True
        except ProcessLookupError:
            pass

    # SIGKILL is an action, not settlement evidence. Re-observe the exact
    # process group even after a forced kill; a surviving descendant keeps the
    # durable inflight record and requires explicit recovery.
    descendants = group_alive(proc.pid)
    if descendants:
        outcome = "recovery_required"
    elif forwarded[0] is not None:
        outcome = "interrupted"
    elif yielded.is_set():
        outcome = "yielded"
    else:
        outcome = "success" if proc.returncode == 0 else "failed"
    if not descendants:
        layout.inflight.unlink(missing_ok=True)
    return {
        "run_id": run_id,
        "outcome": outcome,
        "returncode": proc.returncode,
        "wall_seconds": round(time.monotonic() - before, 6),
        "swift_compile_count": swift_compile_count(log),
        "log": str(log),
        "command_identity": command_identity,
        "started_at": started_iso,
        "force_killed": force_killed[0],
    }


def native_available(tc: dict[str, Any]) -> bool:
    return bool(tc.get("available") or os.environ.get("CMUX_WARM_SLOT_ALLOW_FAKE_TOOLCHAIN"))


def warm(args: argparse.Namespace) -> dict[str, Any]:
    checkout = args.checkout.resolve()
    layout = Layout(args.machine_state.resolve(), args.slot)
    layout.slot.mkdir(parents=True, exist_ok=True)
    layout.logs.mkdir(parents=True, exist_ok=True)
    try:
        warmer_lock = locked(layout.warmer_lock, blocking=False)
        warmer_lock.__enter__()
    except BlockingIOError:
        return {"status": "deferred", "reason": "warmer_already_running"}
    preempt_fd: int | None = None
    try:
        try:
            preempt_fd = open_preempt_channel(layout)
        except (OSError, RuntimeError) as error:
            return {"status": "deferred", "reason": str(error)}
        try:
            gate = locked(layout.foreground_gate, blocking=False)
            gate.__enter__()
        except BlockingIOError:
            return {"status": "deferred", "reason": "foreground_waiting"}
        else:
            gate.__exit__(None, None, None)

        cleanup = cleanup_retired_cold_tasks(layout, preempt_fd=preempt_fd, max_generations=1)
        if cleanup.get("status") == "preempted":
            return {"status": "deferred", "reason": "foreground_waiting_during_cleanup"}

        try:
            slot_lock = warm_slot_lock(layout, checkout)
            slot_lock.__enter__()
        except BlockingIOError:
            return {"status": "deferred", "reason": "slot_leased"}
        try:
            existing_lease = current_slot_lease(layout)
            if existing_lease:
                return {
                    "status": "deferred",
                    "reason": "slot_reserved" if existing_lease.get("kind") == "reserved-task" else "lease_present",
                    "lease": existing_lease,
                }
            with visible_lease(layout, "warmer", args.owner, args.target):
                notify_ready(args.ready_fd)
                p = plan(layout, checkout, args.target)
                try:
                    record = read_json(layout.record) or {"lineage_ordinal": -1}
                except (OSError, ValueError, json.JSONDecodeError):
                    return {"status": "deferred", "reason": "state_unreadable"}
                gen = generation(record)
                if p["reason"] == "dirty_source":
                    quarantine(layout, record, "dirty_source_observed")
                    return {"status": "deferred", "reason": "dirty_source", "plan": p}
                if p["reason"] in {"target_missing", "source_unavailable", "recovery_required", "generation_not_ancestor"}:
                    return {"status": "deferred", "reason": p["reason"], "plan": p}
                if not native_available(p["toolchain"]):
                    return {"status": "deferred", "reason": "native_apple_toolchain_unavailable", "plan": p}

                source_commit = str(gen.get("source_commit", "")) if gen else ""
                reusable_source = bool(
                    gen
                    and gen.get("warm_ready") is True
                    and not gen.get("quarantined")
                    and gen.get("toolchain_fingerprint") == p["toolchain_fingerprint"]
                    and source_commit
                    and exists(checkout, source_commit)
                    and ancestor(checkout, source_commit, args.target)
                )
                old_source = source_commit if reusable_source else None
                try:
                    switch_from_warm(checkout, old_source, args.target) if old_source else switch_exact(checkout, args.target)
                    target_fp = input_fingerprint(checkout, args.target)
                except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as error:
                    return {"status": "deferred", "reason": str(error), "plan": p}

                tc_fp = p["toolchain_fingerprint"]
                if (
                    gen
                    and gen.get("warm_ready") is True
                    and not gen.get("quarantined")
                    and gen.get("toolchain_fingerprint") == tc_fp
                    and gen.get("build_input_fingerprint") == target_fp
                ):
                    gen.update({
                        "source_commit": args.target,
                        "source_tree": tree(checkout, args.target),
                        "accepted_at": now_iso(),
                        "acceptance": "source_only_no_build",
                    })
                    gen["generation_id"] = generation_id(args.target, tc_fp, target_fp, str(gen["lineage_id"]))
                    save(layout, record)
                    event(layout, "warm_accepted_without_build", generation=gen)
                    return {"status": "accepted", "reason": "build_inputs_unchanged", "generation": gen}

                new_lineage = bool(
                    not gen
                    or gen.get("quarantined")
                    or gen.get("toolchain_fingerprint") != tc_fp
                )
                if new_lineage:
                    ordinal = int(record.get("lineage_ordinal", -1)) + 1
                    record["lineage_ordinal"] = ordinal
                    lineage = f"{tc_fp[:16]}-{ordinal}"
                    derived = layout.cache / "lineages" / lineage / "DerivedData"
                else:
                    lineage = str(gen["lineage_id"])
                    derived = Path(str(gen["derived_data_path"]))

                tag = args.tag or f"warm-{args.slot}-{args.target[:8]}"
                argv = build_command(checkout, tag, args.command)
                env = build_env(derived, tag)
                before_bytes = disk_bytes(layout.cache) if args.measure_disk else None
                receipt = {
                    "schema_version": SCHEMA,
                    "kind": "warm",
                    "slot_id": args.slot,
                    "target_commit": args.target,
                    "toolchain": p["toolchain"],
                    "toolchain_fingerprint": tc_fp,
                    "build_input_fingerprint": target_fp,
                    "lineage_id": lineage,
                    "derived_data_path": str(derived),
                }
                receipt.update(run_native(
                    layout, checkout, argv, env,
                    layout.logs / f"warm-{int(time.time())}-{log_token(args.target)}.log",
                    "warm", True, True, preempt_fd,
                ))
                if before_bytes is not None:
                    receipt["disk_bytes_before"] = before_bytes
                    receipt["disk_bytes_after"] = disk_bytes(layout.cache)
                    receipt["disk_growth_bytes"] = receipt["disk_bytes_after"] - before_bytes
                atomic_json(layout.slot / "last-warm-receipt.json", receipt)
                event(layout, "warm_finished", receipt=receipt)

                if receipt["outcome"] != "success":
                    if not gen or new_lineage:
                        record["generation"] = {
                            "generation_id": generation_id(args.target, tc_fp, target_fp, lineage),
                            "source_commit": args.target,
                            "source_tree": tree(checkout, args.target),
                            "native_validated_commit": None,
                            "toolchain": p["toolchain"],
                            "toolchain_fingerprint": tc_fp,
                            "build_input_fingerprint": target_fp,
                            "lineage_id": lineage,
                            "derived_data_path": str(derived),
                            "quarantined": True,
                            "warm_ready": False,
                            "quarantine_reason": f"warm_{receipt['outcome']}",
                        }
                        save(layout, record)
                    else:
                        quarantine(layout, record, f"warm_{receipt['outcome']}")
                    return {"status": receipt["outcome"], "receipt": receipt}

                record["generation"] = {
                    "generation_id": generation_id(args.target, tc_fp, target_fp, lineage),
                    "source_commit": args.target,
                    "source_tree": tree(checkout, args.target),
                    "native_validated_commit": args.target,
                    "toolchain": p["toolchain"],
                    "toolchain_fingerprint": tc_fp,
                    "build_input_fingerprint": target_fp,
                    "lineage_id": lineage,
                    "derived_data_path": str(derived),
                    "accepted_at": now_iso(),
                    "acceptance": "native_build",
                    "quarantined": False,
                    "warm_ready": True,
                    "last_swift_compile_count": receipt["swift_compile_count"],
                    "last_build_wall_seconds": receipt["wall_seconds"],
                }
                save(layout, record)
                return {"status": "warmed", "generation": record["generation"], "receipt": receipt}
        finally:
            slot_lock.__exit__(None, None, None)
    finally:
        close_preempt_channel(layout, preempt_fd)
        warmer_lock.__exit__(None, None, None)


def task_base(args: argparse.Namespace) -> dict[str, Any]:
    layout = Layout(args.machine_state.resolve(), args.slot)
    checkout = args.checkout.resolve()
    layout.slot.mkdir(parents=True, exist_ok=True)

    def persist(result: dict[str, Any]) -> dict[str, Any]:
        if args.receipt:
            atomic_json(args.receipt, result)
        return result

    if args.lease_seconds <= 0 or args.lease_seconds > 7200:
        return persist({"status": "cold", "reason": "invalid_lease_seconds"})
    if args.max_main_distance < 0:
        return persist({"status": "cold", "reason": "invalid_max_main_distance"})

    with foreground_request(layout, args.task_id, args.authoritative_main):
        with locked(layout.slot_lock), locked(checkout_lock_path(layout, checkout)):
            existing = current_slot_lease(layout)
            if existing:
                if existing.get("kind") == "reserved-task" and existing.get("task_id") == args.task_id:
                    return persist({
                        "status": "warm_base",
                        "base_commit": existing.get("base_commit"),
                        "warm_generation_id": existing.get("warm_generation_id"),
                        "lease_id": existing.get("lease_id"),
                        "authoritative_main": existing.get("authoritative_main"),
                        "distance_to_main": existing.get("distance_to_main"),
                        "toolchain_fingerprint": existing.get("toolchain_fingerprint"),
                        "build_input_fingerprint": existing.get("build_input_fingerprint"),
                        "expires_at": existing.get("expires_at"),
                        "recorded_at": now_iso(),
                        "reservation_reused": True,
                    })
                return persist({"status": "cold", "reason": "slot_reserved", "lease": existing})

            p = plan(layout, checkout, args.authoritative_main)
            gen = p.get("generation")
            if (
                not isinstance(gen, dict)
                or gen.get("warm_ready") is not True
                or gen.get("quarantined")
                or p["reason"] in {"dirty_source", "toolchain_changed", "generation_not_ancestor", "recovery_required"}
            ):
                return persist({"status": "cold", "reason": p["reason"], "plan": p})

            main_distance = first_parent_distance(
                checkout,
                str(gen["source_commit"]),
                args.authoritative_main,
            )
            if main_distance is None:
                return persist({
                    "status": "cold",
                    "reason": "warm_generation_distance_unknown",
                })
            if main_distance > args.max_main_distance:
                return persist({
                    "status": "cold",
                    "reason": "warm_generation_stale",
                    "distance_to_main": main_distance,
                    "max_main_distance": args.max_main_distance,
                })

            lease_id = uuid.uuid4().hex
            expires_epoch = time.time() + args.lease_seconds
            reservation = {
                "schema_version": SCHEMA,
                "lease_id": lease_id,
                "kind": "reserved-task",
                "owner": args.task_id,
                "task_id": args.task_id,
                "base_commit": gen["source_commit"],
                "warm_generation_id": gen["generation_id"],
                "authoritative_main": args.authoritative_main,
                "distance_to_main": main_distance,
                "toolchain_fingerprint": gen["toolchain_fingerprint"],
                "build_input_fingerprint": gen["build_input_fingerprint"],
                "reserved_at": now_iso(),
                "expires_epoch": expires_epoch,
                "expires_at": dt.datetime.fromtimestamp(expires_epoch, dt.timezone.utc).isoformat(),
            }
            atomic_json(layout.lease, reservation)
            event(
                layout,
                "task_reserved",
                task_id=args.task_id,
                lease_id=lease_id,
                warm_generation_id=gen["generation_id"],
                base_commit=gen["source_commit"],
            )
            return persist({
                "status": "warm_base",
                "base_commit": gen["source_commit"],
                "warm_generation_id": gen["generation_id"],
                "lease_id": lease_id,
                "authoritative_main": args.authoritative_main,
                "distance_to_main": reservation["distance_to_main"],
                "toolchain_fingerprint": gen["toolchain_fingerprint"],
                "build_input_fingerprint": gen["build_input_fingerprint"],
                "expires_at": reservation["expires_at"],
                "recorded_at": now_iso(),
                "reservation_reused": False,
            })


def task_run(args: argparse.Namespace) -> dict[str, Any]:
    checkout = args.checkout.resolve()
    layout = Layout(args.machine_state.resolve(), args.slot)
    layout.slot.mkdir(parents=True, exist_ok=True)
    layout.logs.mkdir(parents=True, exist_ok=True)
    known = args.known_at if args.known_at is not None else time.time()
    try:
        lease_at_known = read_json(layout.lease)
    except (OSError, ValueError, json.JSONDecodeError):
        lease_at_known = None
    warmer_at_known = bool(lease_at_known and lease_at_known.get("kind") == "warmer")

    with foreground_request(layout, args.task_id, args.target):
        with locked(layout.slot_lock), locked(checkout_lock_path(layout, checkout)):
            reservation = current_slot_lease(layout)
            if reservation:
                if reservation.get("kind") != "reserved-task":
                    event(layout, "task_fallback_required", task_id=args.task_id, reason="lease_present")
                    return {"status": "cold_fallback_required", "reason": "lease_present", "lease": reservation}
                if reservation.get("task_id") != args.task_id:
                    event(layout, "task_fallback_required", task_id=args.task_id, reason="slot_reserved")
                    return {"status": "cold_fallback_required", "reason": "slot_reserved", "lease": reservation}
                if not args.lease_id or reservation.get("lease_id") != args.lease_id:
                    event(layout, "task_fallback_required", task_id=args.task_id, reason="reservation_mismatch")
                    return {"status": "cold_fallback_required", "reason": "reservation_mismatch"}
                if (
                    not args.warm_generation_id
                    or reservation.get("warm_generation_id") != args.warm_generation_id
                ):
                    event(layout, "task_fallback_required", task_id=args.task_id, reason="generation_mismatch")
                    return {"status": "cold_fallback_required", "reason": "generation_mismatch"}
            elif args.lease_id or args.warm_generation_id:
                event(layout, "task_fallback_required", task_id=args.task_id, reason="reservation_missing")
                return {"status": "cold_fallback_required", "reason": "reservation_missing"}

            reserved_generation = reservation.get("warm_generation_id") if reservation else None
            active_lease_id = reservation.get("lease_id") if reservation else None
            try:
                record = read_json(layout.record)
            except (OSError, ValueError, json.JSONDecodeError):
                event(layout, "task_fallback_required", task_id=args.task_id, reason="state_unreadable")
                return {"status": "cold_fallback_required", "reason": "state_unreadable"}
            p = plan(layout, checkout, args.target)
            gen = generation(record)
            if p["reason"] == "dirty_source":
                quarantine(layout, record, "dirty_source_observed")
                event(layout, "task_fallback_required", task_id=args.task_id, reason="dirty_source")
                return {"status": "cold_fallback_required", "reason": "dirty_source", "plan": p}
            if p["reason"] in {"target_missing", "source_unavailable", "recovery_required"}:
                event(layout, "task_fallback_required", task_id=args.task_id, reason=p["reason"])
                return {"status": "cold_fallback_required", "reason": p["reason"], "plan": p}
            if not native_available(p["toolchain"]):
                return {"status": "cold_fallback_required", "reason": "native_apple_toolchain_unavailable", "plan": p}

            use_warm = bool(
                gen
                and gen.get("warm_ready") is True
                and not gen.get("quarantined")
                and gen.get("toolchain_fingerprint") == p["toolchain_fingerprint"]
                and ancestor(checkout, str(gen.get("source_commit")), args.target)
                and (reserved_generation is None or gen.get("generation_id") == reserved_generation)
            )
            warm_generation = gen.get("generation_id") if use_warm else None
            warm_source = str(gen.get("source_commit")) if use_warm else None
            warm_distance = distance(checkout, warm_source, args.target) if warm_source else None
            match = "exact" if warm_distance == 0 else "near" if warm_distance is not None else "cold"
            fallback_reason = None if use_warm else p["reason"]

            cold_generation: str | None = None
            if use_warm:
                derived = Path(str(gen["derived_data_path"]))
                try:
                    switch_from_warm(checkout, warm_source, args.target)
                except RuntimeError as error:
                    use_warm = False
                    match = "cold"
                    fallback_reason = str(error)
            if not use_warm:
                try:
                    switch_exact(checkout, args.target)
                except RuntimeError as error:
                    return {"status": "cold_fallback_required", "reason": str(error), "plan": p}
                cold_generation = uuid.uuid4().hex
                derived = cold_task_root(layout, cold_generation) / "DerivedData"

            tag = args.tag or f"task-{args.task_id[:24]}"
            argv = build_command(checkout, tag, args.command)
            env = build_env(derived, tag)
            with visible_lease(
                layout, "task", args.task_id, args.target,
                lease_id=active_lease_id,
                task_id=args.task_id,
                warm_generation_id=warm_generation,
                reserved_generation_id=reserved_generation,
                match_class=match,
                fallback_reason=fallback_reason,
                cold_task_generation_id=cold_generation,
            ):
                before_bytes = disk_bytes(layout.cache) if args.measure_disk else None
                build_started = time.time()
                run = run_native(
                    layout, checkout, argv, env,
                    layout.logs / f"task-{log_token(closed_identifier(args.task_id, 'task id', 160))}-{int(build_started)}.log",
                    f"task:{args.task_id}", False, False, None,
                    cold_task_generation_id=cold_generation,
                )
                receipt = {
                    "schema_version": SCHEMA,
                    "kind": "task",
                    "slot_id": args.slot,
                    "task_id": args.task_id,
                    "task_known_at": dt.datetime.fromtimestamp(known, dt.timezone.utc).isoformat(),
                    "build_started_at": dt.datetime.fromtimestamp(build_started, dt.timezone.utc).isoformat(),
                    "task_known_to_build_start_seconds": round(max(0.0, build_started - known), 6),
                    "target_commit": args.target,
                    "warm_generation_id": warm_generation,
                    "warm_source_commit": warm_source,
                    "distance_from_warm_source": warm_distance,
                    "match_class": match,
                    "cold_fallback": not use_warm,
                    "fallback_reason": fallback_reason,
                    "reservation_lease_id": active_lease_id,
                    "reserved_generation_id": reserved_generation,
                    "cold_task_generation_id": cold_generation,
                    "warmer_in_flight_at_task_known": warmer_at_known,
                    "toolchain": p["toolchain"],
                    "toolchain_fingerprint": p["toolchain_fingerprint"],
                    "derived_data_path": str(derived),
                }
                if before_bytes is not None:
                    receipt["disk_bytes_before"] = before_bytes
                receipt.update(run)
                if before_bytes is not None:
                    receipt["disk_bytes_after"] = disk_bytes(layout.cache)
                    receipt["disk_growth_bytes"] = receipt["disk_bytes_after"] - before_bytes
                receipt["source_after"] = head(checkout)
                receipt["source_clean_after"] = clean(checkout)
                try:
                    receipt["build_input_fingerprint"] = input_fingerprint(checkout, args.target)
                except (OSError, subprocess.SubprocessError, ValueError):
                    receipt["build_input_fingerprint"] = None

                if cold_generation is not None:
                    retirement_started = time.monotonic()
                    if receipt["outcome"] == "recovery_required":
                        retirement = {"status": "deferred_recovery_required"}
                    else:
                        retirement = retire_cold_task(layout, cold_generation)
                    receipt["cold_cache_retirement"] = retirement["status"]
                    receipt["cold_cache_retirement_seconds"] = round(
                        time.monotonic() - retirement_started,
                        6,
                    )

                if args.receipt:
                    atomic_json(args.receipt, receipt)
                atomic_json(layout.slot / "last-task-receipt.json", receipt)
                event(layout, "task_finished", receipt=receipt)

                if not receipt["source_clean_after"] and gen:
                    quarantine(layout, record, "dirty_source_observed_after_task")
                elif use_warm and gen:
                    if receipt["outcome"] == "success":
                        gen.update({
                            "generation_id": generation_id(
                                args.target,
                                p["toolchain_fingerprint"],
                                receipt["build_input_fingerprint"],
                                str(gen["lineage_id"]),
                            ),
                            "source_commit": args.target,
                            "source_tree": tree(checkout, args.target),
                            "native_validated_commit": args.target,
                            "build_input_fingerprint": receipt["build_input_fingerprint"],
                            "warm_ready": False,
                            "acceptance": "task_build",
                            "last_task_seed_generation_id": warm_generation,
                        })
                        save(layout, record or {})
                    else:
                        quarantine(layout, record, "task_build_failed")
                return {"status": receipt["outcome"], "receipt": receipt}



def release_reservation(args: argparse.Namespace) -> dict[str, Any]:
    layout = Layout(args.machine_state.resolve(), args.slot)
    layout.slot.mkdir(parents=True, exist_ok=True)
    try:
        with locked(layout.slot_lock, blocking=False):
            lease = current_slot_lease(layout, prune_expired=False)
            if not lease:
                return {"status": "clear", "reason": "no_reservation"}
            if lease.get("kind") != "reserved-task":
                return {"status": "blocked", "reason": "active_lease", "lease": lease}
            if lease.get("task_id") != args.task_id or lease.get("lease_id") != args.lease_id:
                return {"status": "blocked", "reason": "reservation_mismatch"}
            layout.lease.unlink(missing_ok=True)
            event(layout, "task_reservation_released", task_id=args.task_id, lease_id=args.lease_id)
            return {"status": "released", "task_id": args.task_id, "lease_id": args.lease_id}
    except BlockingIOError:
        return {"status": "blocked", "reason": "slot_leased"}


def recover(args: argparse.Namespace) -> dict[str, Any]:
    layout = Layout(args.machine_state.resolve(), args.slot)
    layout.slot.mkdir(parents=True, exist_ok=True)
    try:
        with locked(layout.slot_lock, blocking=False):
            unreadable_inflight = False
            try:
                recovery_lease = read_json(layout.lease) or {}
            except (OSError, ValueError, json.JSONDecodeError):
                recovery_lease = {}
            try:
                inflight = read_json(layout.inflight)
            except (OSError, ValueError, json.JSONDecodeError):
                unreadable_inflight = True
                backup_lease = recovery_lease
                backup_run = backup_lease.get("native_run_id")
                backup_group = backup_lease.get("native_process_group")
                if backup_run and backup_run != args.run_id:
                    return {"status": "blocked", "reason": "run_id_mismatch", "expected_run_id": backup_run}
                if not backup_run or not isinstance(backup_group, int) or backup_group <= 0:
                    return {
                        "status": "blocked",
                        "reason": "unreadable_inflight_without_durable_child_identity",
                    }
                inflight = {
                    "schema_version": SCHEMA,
                    "run_id": backup_run,
                    "process_group": backup_group,
                    "launch_guard": backup_lease.get("native_launch_guard", "pipe_v1"),
                    "unreadable": True,
                }
            if not inflight:
                lease = current_slot_lease(layout, prune_expired=False)
                if lease and lease.get("kind") in {"warmer", "task"}:
                    pid = lease.get("pid")
                    if isinstance(pid, int) and pid > 0 and same_process(pid, lease.get("process_identity")):
                        return {"status": "blocked", "reason": "lease_owner_alive", "pid": pid}

                    lease_run = lease.get("native_run_id")
                    lease_group = lease.get("native_process_group")
                    if lease_run is not None or lease_group is not None:
                        if not isinstance(lease_run, str) or not lease_run:
                            return {
                                "status": "blocked",
                                "reason": "stale_lease_without_durable_run_identity",
                            }
                        if lease_run != args.run_id:
                            return {
                                "status": "blocked",
                                "reason": "run_id_mismatch",
                                "expected_run_id": lease_run,
                            }
                        if not isinstance(lease_group, int) or lease_group <= 0:
                            return {
                                "status": "blocked",
                                "reason": "stale_lease_without_durable_child_identity",
                            }
                        if group_alive(lease_group):
                            return {
                                "status": "blocked",
                                "reason": "process_group_alive",
                                "process_group": lease_group,
                            }

                    cold_retirement = None
                    if lease.get("kind") == "task" and lease.get("cold_task_generation_id") is not None:
                        cold_retirement = retire_cold_task(layout, lease.get("cold_task_generation_id"))
                    layout.lease.unlink(missing_ok=True)
                    event(
                        layout,
                        "stale_active_lease_recovered",
                        lease_id=lease.get("lease_id"),
                        lease_kind=lease.get("kind"),
                        cold_cache_retirement=(
                            cold_retirement.get("status") if cold_retirement is not None else None
                        ),
                    )
                    result = {
                        "status": "recovered",
                        "reason": "stale_active_lease",
                        "cold_lineage_required": False,
                    }
                    if cold_retirement is not None:
                        result["cold_cache_retirement"] = cold_retirement["status"]
                    return result
                return {"status": "clear", "reason": "no_inflight"}
            if inflight.get("run_id") != args.run_id:
                return {"status": "blocked", "reason": "run_id_mismatch", "expected_run_id": inflight.get("run_id")}
            pgid = inflight.get("process_group")
            if isinstance(pgid, int) and pgid > 0 and group_alive(pgid):
                return {"status": "blocked", "reason": "process_group_alive", "process_group": pgid}
            try:
                record = read_json(layout.record)
            except (OSError, ValueError, json.JSONDecodeError):
                record = None
            quarantine(layout, record, "interrupted_native_run")

            cold_generation = inflight.get("cold_task_generation_id")
            if cold_generation is None:
                cold_generation = recovery_lease.get("cold_task_generation_id")
            cold_retirement = (
                retire_cold_task(layout, cold_generation)
                if cold_generation is not None
                else None
            )

            layout.recovery.mkdir(parents=True, exist_ok=True)
            recovered = {**inflight, "recovered_at": now_iso(), "recovery": "quarantined_cold_lineage_required"}
            if cold_retirement is not None:
                recovered["cold_cache_retirement"] = cold_retirement["status"]
            atomic_json(layout.recovery / f"{args.run_id}.json", recovered)
            layout.inflight.unlink(missing_ok=True)
            layout.lease.unlink(missing_ok=True)
            ambiguous = not isinstance(pgid, int)
            event(
                layout,
                "native_run_recovered",
                run_id=args.run_id,
                ambiguous_child_launch=ambiguous,
                unreadable_inflight=unreadable_inflight,
                cold_cache_retirement=(
                    cold_retirement.get("status") if cold_retirement is not None else None
                ),
            )
            result = {
                "status": "recovered",
                "run_id": args.run_id,
                "cold_lineage_required": True,
                "ambiguous_child_launch": ambiguous,
                "unreadable_inflight": unreadable_inflight,
            }
            if cold_retirement is not None:
                result["cold_cache_retirement"] = cold_retirement["status"]
            return result
    except BlockingIOError:
        return {"status": "blocked", "reason": "slot_leased"}


def explain(args: argparse.Namespace) -> dict[str, Any]:
    layout = Layout(args.machine_state.resolve(), args.slot)
    result = plan(layout, args.checkout.resolve(), args.target)
    try:
        result["active_lease"] = read_json(layout.lease)
    except (OSError, ValueError, json.JSONDecodeError):
        result["active_lease"] = {"unreadable": True}
    result["foreground_requests"] = live_foreground(layout, prune=False)
    return result


def emit(value: dict[str, Any]) -> int:
    print(json.dumps(value, indent=2, sort_keys=True))
    if value.get("status") == "interrupted":
        return 130
    if value.get("status") in {"failed", "blocked", "cold_fallback_required", "recovery_required"}:
        return 75
    return 0


def common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--machine-state", type=Path, required=True)
    parser.add_argument("--slot", type=slot_id, required=True)
    parser.add_argument("--checkout", type=Path, required=True)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)

    p = sub.add_parser("classify")
    p.add_argument("--checkout", type=Path, required=True)
    p.add_argument("--from-commit", required=True)
    p.add_argument("--to-commit", required=True)

    for name in ("plan", "explain"):
        p = sub.add_parser(name)
        common(p)
        p.add_argument("--target", required=True)

    p = sub.add_parser("warm")
    common(p)
    p.add_argument("--target", required=True)
    p.add_argument("--owner", default="main-warmer")
    p.add_argument("--tag")
    p.add_argument("--ready-fd", type=int)
    p.add_argument(
        "--measure-disk",
        action="store_true",
        help="recursively measure cache bytes before/after native work; intended for benchmarks/diagnostics",
    )
    p.add_argument("command", nargs=argparse.REMAINDER)

    p = sub.add_parser("task-base")
    common(p)
    p.add_argument("--authoritative-main", required=True)
    p.add_argument("--task-id", type=task_id, required=True)
    p.add_argument("--lease-seconds", type=int, default=1800)
    p.add_argument(
        "--max-main-distance",
        type=int,
        default=3,
        help="maximum first-parent commits a warm task base may trail authoritative main",
    )
    p.add_argument("--receipt", type=Path)

    p = sub.add_parser("task-run")
    common(p)
    p.add_argument("--target", required=True)
    p.add_argument("--task-id", type=task_id, required=True)
    p.add_argument("--lease-id")
    p.add_argument("--warm-generation-id")
    p.add_argument("--tag")
    p.add_argument("--known-at", type=float)
    p.add_argument("--receipt", type=Path)
    p.add_argument(
        "--measure-disk",
        action="store_true",
        help="recursively measure cache bytes before/after native work; intended for benchmarks/diagnostics",
    )
    p.add_argument("command", nargs=argparse.REMAINDER)

    p = sub.add_parser("release")
    p.add_argument("--machine-state", type=Path, required=True)
    p.add_argument("--slot", type=slot_id, required=True)
    p.add_argument("--task-id", type=task_id, required=True)
    p.add_argument("--lease-id", required=True)

    p = sub.add_parser("recover")
    p.add_argument("--machine-state", type=Path, required=True)
    p.add_argument("--slot", type=slot_id, required=True)
    p.add_argument("--run-id", required=True)

    p = sub.add_parser("cleanup")
    p.add_argument("--machine-state", type=Path, required=True)
    p.add_argument("--slot", type=slot_id, required=True)
    p.add_argument("--max-generations", type=int, default=1)
    p.add_argument(
        "--measure-bytes",
        action="store_true",
        help="recursively count reclaimed bytes; intended for benchmarks/diagnostics",
    )

    p = sub.add_parser("_cleanup-generation", help=argparse.SUPPRESS)
    p.add_argument("--directory-fd", type=int, required=True)
    return parser


def main() -> int:
    args = make_parser().parse_args()
    if getattr(args, "command", None) and args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if args.action == "_cleanup-generation":
        try:
            info = os.fstat(args.directory_fd)
            if not stat.S_ISDIR(info.st_mode):
                return 1
            _remove_tree_contents_fd(args.directory_fd)
            return 0
        except (OSError, RuntimeError):
            return 1
    if args.action == "classify":
        print(json.dumps(classify(args.checkout.resolve(), args.from_commit, args.to_commit), indent=2, sort_keys=True))
        return 0
    if args.action == "plan":
        return emit(plan(Layout(args.machine_state.resolve(), args.slot), args.checkout.resolve(), args.target))
    if args.action == "explain":
        return emit(explain(args))
    if args.action == "warm":
        return emit(warm(args))
    if args.action == "task-base":
        return emit(task_base(args))
    if args.action == "task-run":
        return emit(task_run(args))
    if args.action == "release":
        return emit(release_reservation(args))
    if args.action == "recover":
        return emit(recover(args))
    if args.action == "cleanup":
        return emit(
            cleanup_retired_cold_tasks(
                Layout(args.machine_state.resolve(), args.slot),
                max_generations=args.max_generations,
                measure_bytes=args.measure_bytes,
            )
        )
    raise AssertionError(args.action)


if __name__ == "__main__":
    raise SystemExit(main())
