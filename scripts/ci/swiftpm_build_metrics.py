#!/usr/bin/env python3
"""Measure a SwiftPM build step; these receipts never authorize product reuse."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time

from build_metrics import command_output


SCHEMA = "cmux-next-swiftpm-build/v1"
EXCLUDED = {".git", ".build", "node_modules", ".DS_Store"}
BUILD_ENV = (
    "DEVELOPER_DIR", "SDKROOT", "SWIFT_EXEC", "SWIFTFLAGS", "CC", "CXX",
    "CFLAGS", "CXXFLAGS", "LDFLAGS", "MACOSX_DEPLOYMENT_TARGET", "ARCHS",
)
PROGRESS = re.compile(r"^\[\d+/\d+\] (Compiling|Emitting module|Linking)\b")
STOP_GRACE_SECONDS = 10.0
STOP_HELD_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_identity(root: Path) -> dict:
    """Conservatively identify tracked working bytes plus generated package inputs.

    Use Git object IDs for clean tracked files and actual bytes for dirty files.
    Cover the whole repository (workflow/recipe and pins included), and include
    ignored generated package resources. Exclude build/dependency stores.
    """
    entries = subprocess.check_output(["git", "-C", str(root), "ls-files", "--stage", "-z"])
    dirty = set(subprocess.check_output([
        "git", "-C", str(root), "diff", "HEAD", "--name-only", "-z",
    ]).split(b"\0"))
    paths: dict[str, tuple[str, str | None]] = {}
    gitlinks: dict[str, str] = {}
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, name = entry.split(b"\t", 1)
        mode, object_id, stage = metadata.decode().split()
        if stage != "0":
            raise ValueError("unmerged source index")
        relative = os.fsdecode(name)
        if mode == "160000":
            gitlinks[relative] = object_id
        else:
            paths[relative] = (mode, object_id if name not in dirty else None)
    for base, directories, files in os.walk(root / "Packages"):
        directories[:] = sorted(name for name in directories if name not in EXCLUDED)
        for name in files:
            path = Path(base) / name
            if name not in EXCLUDED:
                paths.setdefault(path.relative_to(root).as_posix(), ("working-file", None))
    inputs = []
    for relative, (mode, object_id) in sorted(paths.items()):
        path = root / relative
        if object_id:
            inputs.append([relative, mode, "git-object", object_id])
            continue
        if path.is_symlink():
            content = os.fsencode(os.readlink(path))
        elif path.exists():
            content = path.read_bytes()
        else:
            content = b"cmux-missing-working-file"
        inputs.append([relative, mode, "working-bytes", hashlib.sha256(content).hexdigest()])
    # A dirty submodule's commit alone does not identify its working bytes.
    dirty_gitlinks = []
    for relative, object_id in sorted(gitlinks.items()):
        path = root / relative
        if (path / ".git").exists():
            status = subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=normal"])
            actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
            if status:
                dirty_gitlinks.append(relative)
            object_id = actual
        inputs.append([relative, "gitlink", object_id])
    return {
        "revision": command_output("git", "-C", str(root), "rev-parse", "HEAD"),
        "tree": command_output("git", "-C", str(root), "rev-parse", "HEAD^{tree}"),
        "working_inputs_sha256": digest(inputs),
        "input_count": len(inputs),
        "dirty_submodules": dirty_gitlinks,
        "scope": "all tracked working files and package files except build/dependency stores",
    }


def scratch_state(package: Path) -> dict:
    build = package / ".build"
    target = build.resolve()
    parts = target.parts
    key = None
    if "spm-scratch" in parts:
        index = parts.index("spm-scratch")
        if index + 1 < len(parts):
            key = parts[index + 1]
    markers = {name: (build / name).is_file() for name in ("build.db", "debug.yaml", "workspace-state.json")}
    warm = any(markers.values())
    reason = "warm_state_present_hit_unknown" if warm else "build_directory_absent" if not build.exists() else "no_prior_build_markers"
    return {
        "build_directory": str(target),
        "linked": build.is_symlink(),
        "owned_scratch_key": key,
        "warm_state_present": warm,
        "state_reason": reason,
        "markers": markers,
        "cache_hit": None,
        "cache_hit_reason": "SwiftPM does not report a verified cache hit for this step",
    }


def dependency_state(package: Path) -> dict:
    return {
        name: hashlib.sha256((package / name).read_bytes()).hexdigest() if (package / name).is_file() else None
        for name in ("Package.resolved", ".build/workspace-state.json")
    }


def write_receipt(record: dict, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{record['role']}.json"
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_summary(record: dict) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    before = record["scratch_before"]
    events = record["compile_work"]
    with Path(summary).open("a", encoding="utf-8") as output:
        output.write(f"### Next test build: {record['role']}\n\n")
        output.write(f"Build-step elapsed: **{record['build_step_seconds']:.3f} s**; exit: **{record['exit_code']}**.\n\n")
        output.write(f"Warm state before build: **{before.get('warm_state_present', 'unknown')}** ({before.get('state_reason', 'unavailable')}); verified cache hit: **unknown**.\n\n")
        output.write(f"SwiftPM progress events: {events['compiling']} compiling, {events['emitting_module']} emitting module; {events['assessment']}.\n\n")
        output.write(f"Build identity: `{record['build_identity_sha256'] or 'unknown'}`. Receipt and streamed build log are in the job's `cmux-next-build-metrics` artifact.\n\n")
        output.write("Equivalent identities identify candidates for shared builds. Elapsed time is build-step wall time, not redundant compiler CPU or a cache-miss measurement.\n\n")


def observe(function, fallback):
    """Telemetry failures must not prevent or change the build."""
    try:
        return function()
    except Exception as error:
        print(f"::warning::SwiftPM build metrics: {type(error).__name__}: {error}", file=sys.stderr)
        return fallback


def stop_build(process: subprocess.Popen, own_process_group: bool, grace_seconds: float = STOP_GRACE_SECONDS) -> None:
    """Stops a build that is still running: SIGTERM, up to GRACE_SECONDS for it to exit, then SIGKILL, and reaps it.
    With its own process group the signals go to the whole group, so no compiler job outlives it."""
    def send(signum: int) -> None:
        try:
            if own_process_group:
                os.killpg(process.pid, signum)
            else:
                process.send_signal(signum)
        except ProcessLookupError:
            pass

    # A second signal must not cut the stop short and leave the build running; it is delivered after the stop.
    held = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_HELD_SIGNALS)
    try:
        if process.poll() is None:
            send(signal.SIGTERM)
            try:
                process.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                pass
        send(signal.SIGKILL)  # what is left of the group; a no-op once every member is gone
        process.wait()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, held)


def run_build(role: str, directory: Path, command: list[str], own_process_group: bool = False) -> int:
    """Runs COMMAND, streams and logs its output and writes the receipt; returns its exit code. When the caller's
    exception (a signal turned into one, KeyboardInterrupt) leaves the read loop, the build is stopped and reaped
    before the exception goes on (stop_build), so the caller's cleanup never races a live build.
    OWN_PROCESS_GROUP starts the build in a new process group, which stop_build then signals as a whole."""
    setup_start = time.monotonic()
    package = Path.cwd()
    root_text = command_output("git", "rev-parse", "--show-toplevel")
    root = Path(root_text) if root_text else package
    source = observe(lambda: source_identity(root), {"error": "source identity unavailable"})
    toolchain = {
        "swift": command_output("swift", "--version"),
        "xcode": command_output("xcodebuild", "-version"),
        "sdk_version": command_output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": command_output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "os": platform.system(), "arch": platform.machine(),
    }
    build_environment = {name: os.environ[name] for name in BUILD_ENV if name in os.environ}
    record = {
        "schema": SCHEMA, "role": role, "command": command,
        "source": source, "toolchain": toolchain,
        "build_environment_sha256": digest(build_environment),
        "build_environment_names": sorted(build_environment),
        "package": os.path.relpath(package, root),
        "runner": os.environ.get("RUNNER_NAME"),
        "run_id": os.environ.get("GITHUB_RUN_ID"), "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "scratch_before": observe(lambda: scratch_state(package), {}),
        "dependencies_before": observe(lambda: dependency_state(package), {}),
        "web_bundle_restore": {
            "outcome": os.environ.get("CMUX_METRICS_WEB_CACHE_OUTCOME") or None,
            "cache_hit": os.environ.get("CMUX_METRICS_WEB_CACHE_HIT") or None,
        },
        "status": "running",
    }
    observe(lambda: write_receipt(record, directory), None)
    log = observe(lambda: (directory / f"{role}.log").open("wb"), None)
    events = {"parser": "swiftpm-progress/v1", "compiling": 0, "emitting_module": 0, "linking": 0, "build_complete_observed": False}
    record["measurement_setup_seconds"] = round(time.monotonic() - setup_start, 6)
    start = time.monotonic()
    process = None
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=own_process_group)
        assert process.stdout is not None
        with process.stdout:
            for line in process.stdout:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                if log:
                    try:
                        log.write(line)
                    except OSError:
                        observe(log.close, None)
                        log = None
                text = line.decode("utf-8", errors="replace").strip()
                match = PROGRESS.match(text)
                if match:
                    events[{"Compiling": "compiling", "Emitting module": "emitting_module", "Linking": "linking"}[match[1]]] += 1
                if text.startswith("Build complete!"):
                    events["build_complete_observed"] = True
        return_code = process.wait()
    except OSError as error:
        print(f"{command[0]}: {error}", file=sys.stderr)
        return_code = 127 if isinstance(error, FileNotFoundError) else 126
        if process is not None:
            stop_build(process, own_process_group)
    except BaseException:
        if process is not None:
            stop_build(process, own_process_group)
        raise
    finally:
        elapsed = time.monotonic() - start
        if log:
            observe(log.close, None)
    exit_code = 128 - return_code if return_code < 0 else return_code
    events["assessment"] = "compile_progress_observed" if events["compiling"] or events["emitting_module"] else "no_compile_progress_observed" if events["build_complete_observed"] else "unknown"
    record.update({
        "status": "completed", "exit_code": exit_code, "process_return_code": return_code,
        "build_step_seconds": round(elapsed, 6), "compile_work": events,
        "scratch_after": observe(lambda: scratch_state(package), {}),
        "dependencies_after": observe(lambda: dependency_state(package), {}),
    })
    record["build_inputs_sha256"] = digest({
        "working_inputs": source.get("working_inputs_sha256"), "command": command,
        "package": record["package"], "resolved_dependencies": record["dependencies_after"].get("Package.resolved"),
    }) if source.get("working_inputs_sha256") and not source.get("dirty_submodules") else None
    record["compatibility_missing"] = [name for name, value in toolchain.items() if not value]
    record["compatibility_sha256"] = digest({
        "toolchain": toolchain, "environment": record["build_environment_sha256"],
        "package_path": str(package), "workspace_state": record["dependencies_after"].get(".build/workspace-state.json"),
    }) if not record["compatibility_missing"] else None
    record["build_identity_sha256"] = digest({
        "inputs": record["build_inputs_sha256"], "compatibility": record["compatibility_sha256"],
    }) if record["build_inputs_sha256"] and record["compatibility_sha256"] else None
    observe(lambda: write_receipt(record, directory), None)
    observe(lambda: write_summary(record), None)
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True, choices=("swift-test", "daemon-test", "generated-files"))
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a build command is required after --")
    return run_build(args.role, args.output_dir, command)


if __name__ == "__main__":
    sys.exit(main())
