#!/usr/bin/env python3
"""Behavioral guard for Xcode compilation cache generation pruning."""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "prune-xcode-compilation-cache.py"


def run_helper(cache_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(HELPER), str(cache_dir)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def make_generation(cas_dir: Path, name: str, payload_kib: int) -> Path:
    generation = cas_dir / name
    generation.mkdir(parents=True)
    (generation / "index").write_bytes(b"i" * 1024)
    (generation / "data.1").write_bytes(b"d" * (payload_kib * 1024))
    return generation


def make_cas_dir(cache_dir: Path, name: str, generations: list[str]) -> Path:
    cas_dir = cache_dir / name
    cas_dir.mkdir(parents=True)
    (cas_dir / "lock").write_bytes(b"")
    (cas_dir / "v1.validation").write_text("1\n")
    for index, generation in enumerate(generations):
        make_generation(cas_dir, generation, payload_kib=64 * (index + 1))
    return cas_dir


def child_names(path: Path) -> set[str]:
    return {child.name for child in path.iterdir()}


def test_keeps_the_two_newest_generations_of_every_cas_dir() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        # A warm nightly leaves the dead upstream (v1.1) behind next to the
        # faulted-in primary (v1.2) and the freshly rotated empty one (v1.3).
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2"])
        (builtin / "v1.3").mkdir()
        generic = make_cas_dir(cache_dir, "generic", ["v1.1"])
        # Generation numbers sort numerically, so v1.10 is newer than v1.9.
        plugin = make_cas_dir(cache_dir, "plugin", ["v1.8", "v1.9", "v1.10"])
        stray = cache_dir / "notes.txt"
        stray.write_text("keep me\n")

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert child_names(builtin) == {"lock", "v1.validation", "v1.2", "v1.3"}, (
            child_names(builtin)
        )
        assert child_names(generic) == {"lock", "v1.validation", "v1.1"}
        assert child_names(plugin) == {"lock", "v1.validation", "v1.9", "v1.10"}
        assert (builtin / "v1.2" / "data.1").stat().st_size == 128 * 1024
        assert stray.read_text() == "keep me\n"
        # Only the removed generations are measured; the live ones are left to
        # the workflow's single `du` over the retained cache.
        assert "builtin: kept v1.2, v1.3; removed v1.1 (" in result.stdout
        assert "plugin: kept v1.9, v1.10; removed v1.8 (" in result.stdout
        assert "generic: kept v1.1; removed nothing" in result.stdout
        assert "removed 2 stale Xcode compilation cache generation(s)" in result.stdout


def test_live_generations_are_untouched() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2"])
        generic = make_cas_dir(cache_dir, "generic", ["v1.1"])

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert child_names(builtin) == {"lock", "v1.validation", "v1.1", "v1.2"}
        assert child_names(generic) == {"lock", "v1.validation", "v1.1"}
        assert "no stale Xcode compilation cache generations found" in result.stdout


def test_cas_dir_held_open_by_another_process_is_left_alone() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2", "v1.3"])
        generic = make_cas_dir(cache_dir, "generic", ["v1.1", "v1.2", "v1.3"])

        with (builtin / "lock").open("rb") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_SH)
            result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert child_names(builtin) == {
            "lock",
            "v1.validation",
            "v1.1",
            "v1.2",
            "v1.3",
        }
        assert child_names(generic) == {"lock", "v1.validation", "v1.2", "v1.3"}
        assert "builtin: still in use" in result.stdout


def test_unlistable_cas_dir_does_not_stop_pruning() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2", "v1.3"])
        sealed = make_cas_dir(cache_dir, "sealed", ["v1.1", "v1.2", "v1.3"])
        # `zzz` sorts after `sealed`, so it is only reached if the unlistable
        # directory was skipped instead of aborting the run.
        trailing = make_cas_dir(cache_dir, "zzz", ["v1.1", "v1.2", "v1.3"])
        can_seal = os.geteuid() != 0
        if can_seal:
            sealed.chmod(0o000)
            # Permission bits are not enforced for every user (root, some
            # containers); only exercise the unlistable path if they took hold.
            try:
                next(sealed.iterdir())
            except OSError:
                pass
            else:
                can_seal = False
                sealed.chmod(0o755)
        try:
            result = run_helper(cache_dir)
        finally:
            sealed.chmod(0o755)

        assert result.returncode == 0, result.stderr
        assert "Traceback" not in result.stderr, result.stderr
        assert child_names(builtin) == {"lock", "v1.validation", "v1.2", "v1.3"}
        assert child_names(trailing) == {"lock", "v1.validation", "v1.2", "v1.3"}
        if can_seal:
            assert child_names(sealed) == {
                "lock",
                "v1.validation",
                "v1.1",
                "v1.2",
                "v1.3",
            }
            assert "sealed: could not inspect" in result.stdout


def test_generations_outside_a_cas_dir_are_left_alone() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        cache_dir.mkdir(parents=True)
        # Xcode never writes generations directly under the cache root. A
        # layout the pruner does not recognise is measured unpruned, never
        # guessed at.
        for name in ("v1.7", "v1.8", "v1.9"):
            make_generation(cache_dir, name, payload_kib=8)
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2", "v1.3"])

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert {"v1.7", "v1.8", "v1.9", "builtin"} <= child_names(cache_dir)
        assert child_names(builtin) == {"lock", "v1.validation", "v1.2", "v1.3"}
        assert "removed 1 stale Xcode compilation cache generation(s)" in result.stdout


def test_cas_dir_without_lock_file_is_left_alone() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "CompilationCache.noindex"
        builtin = make_cas_dir(cache_dir, "builtin", ["v1.1", "v1.2", "v1.3"])
        # Every CAS directory the toolchain has opened carries a `lock` file.
        # Without one there is nothing to lock, so nothing may be deleted.
        unlocked = make_cas_dir(cache_dir, "unlocked", ["v1.1", "v1.2", "v1.3"])
        (unlocked / "lock").unlink()

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert child_names(builtin) == {"lock", "v1.validation", "v1.2", "v1.3"}
        assert child_names(unlocked) == {"v1.validation", "v1.1", "v1.2", "v1.3"}
        assert "unlocked: no CAS lock file; leaving it alone" in result.stdout
        assert "removed 1 stale Xcode compilation cache generation(s)" in result.stdout


def test_missing_cache_is_noop() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        cache_dir = Path(temp_dir) / "missing-compilation-cache"

        result = run_helper(cache_dir)

        assert result.returncode == 0, result.stderr
        assert not cache_dir.exists()
        assert "nothing to prune" in result.stdout


def main() -> int:
    test_keeps_the_two_newest_generations_of_every_cas_dir()
    test_live_generations_are_untouched()
    test_cas_dir_held_open_by_another_process_is_left_alone()
    test_unlistable_cas_dir_does_not_stop_pruning()
    test_generations_outside_a_cas_dir_are_left_alone()
    test_cas_dir_without_lock_file_is_left_alone()
    test_missing_cache_is_noop()
    print("PASS: Xcode compilation cache pruning keeps only the live CAS generations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
