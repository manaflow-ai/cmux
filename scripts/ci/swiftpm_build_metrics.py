#!/usr/bin/env python3
"""Measure a SwiftPM build step; these receipts never authorize product reuse.

A build that fails at link on objects a kept build directory carried from an
interrupted job has those modules' objects cleared and runs again, once (see
clear_stale_link). A build that crashed or was signalled is never retried.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
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
UNDEFINED_START = "Undefined symbols for architecture"
UNDEFINED_END = "ld: symbol(s) not found"
UNDEFINED_SYMBOL = re.compile(r'^"(.+)", referenced from:$')
REFERENCING_OBJECT = re.compile(r" in (?:[^\s()]+\()?([^\s()]+\.o)\)?$")
SYMBOL_MODULE = re.compile(r"(?<![\w.])([A-Za-z_]\w*)\.")
EXTENSION_MODULE = re.compile(r"\(extension in ([A-Za-z_]\w*)\):")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# A compiler or linker that crashed: its failure is never a stale object's, and a retry could hide it.
CRASH = re.compile(r"Stack dump:|PLEASE submit a bug report|failed due to signal|Fatal error:|"
                   r"terminated by signal|Segmentation fault|Illegal instruction|Abort trap|Bus error|Assertion failed:")
# What clear_stale_link removes from a module's directory: its objects and the driver's incremental state
# (dependency graph, per-file dependencies, diagnostics). The planning files SwiftPM wrote for the module
# (output-file-map.json, sources, module maps, DerivedSources) stay, so a cached build plan still runs;
# with no objects llbuild runs the module's compile again, and with no priors the driver compiles it whole.
CLEARED_SUFFIXES = (".o", ".swiftdeps", ".priors", ".d", ".dia", ".swiftconstvalues", ".swiftdeps~")


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


def stale_link_modules(build: Path, lines: list[str]) -> list[Path]:
    """The module build directories (<triple>/<config>/<Module>.build) an undefined-symbol
    link failure names: those whose module a missing symbol belongs to (the first qualified
    name in its demangled form: `static CmuxNextAgentPane.AcpmuxStatusClient.call(...)`
    belongs to CmuxNextAgentPane), and those holding an object that references one. When no
    missing symbol belongs to a module of this build (a C symbol, a library the link lacks),
    none: that is not a stale object. An explicit <Module>.build object path scopes that
    reference to its module; a bare object name can identify any module holding that object.

    A kept build directory (owned_spm_scratch.py) can hold objects from a job that was
    cancelled mid-compile. The Swift driver records a module's dependency graph only when
    its compile finishes, so the next job that changes a file back recompiles that file
    but not the files that call it: their objects still reference the cancelled branch's
    signatures, and the link fails on symbols no source in the checkout declares
    (cmux#27302, 2026-10-29: `AcpmuxStatusClient.call(..., requiredCapability:)`, left by a
    cancelled cmux#27017 job on the same runner). Removing those modules' objects and
    incremental state makes SwiftPM compile them whole again.
    """
    module_directories = sorted(path for path in build.glob("*/*/*.build") if path.is_dir())
    modules, objects = set(), set()
    for line in lines:
        text = line.strip()
        symbol = UNDEFINED_SYMBOL.match(text)
        if symbol:
            owner = EXTENSION_MODULE.search(symbol[1]) or SYMBOL_MODULE.search(symbol[1])
            if owner:
                modules.add(owner[1])
            continue
        referencing = REFERENCING_OBJECT.search(text)
        if referencing:
            path = Path(referencing[1])
            owner = next((part for part in reversed(path.parts[:-1])
                          if part != ".build" and part.endswith(".build")), None)
            objects.add((owner, path.name))
    if not any(directory.name[: -len(".build")] in modules for directory in module_directories):
        return []
    return [
        directory for directory in module_directories
        if directory.name[: -len(".build")] in modules or any(
            (owner is None or owner == directory.name) and (directory / name).is_file()
            for owner, name in objects
        )
    ]


def clear_stale_link(package: Path, lines: list[str]) -> list[str]:
    """Remove the objects and incremental state (CLEARED_SUFFIXES) of the module directories
    stale_link_modules names under PACKAGE's .build (a kept scratch directory is reached
    through its link); returns those directories, relative to .build."""
    build = package / ".build"
    if not build.is_dir():
        return []
    cleared = []
    for directory in stale_link_modules(build, lines):
        removed = False
        for path in sorted(directory.rglob("*")):
            if path.name.endswith(CLEARED_SUFFIXES) and path.is_file() and not path.is_symlink():
                try:
                    path.unlink()
                    removed = True
                except OSError as error:
                    print(f"::warning::could not clear {path}: {error}", file=sys.stderr)
        if removed:
            cleared.append(directory.relative_to(build).as_posix())
    return cleared


def run_command(command: list[str], log, events: dict) -> tuple[int, list[str], bool, object]:
    """Run COMMAND, streaming its output to stdout and LOG and counting progress into EVENTS.
    Returns its return code, the lines of any undefined-symbol link error, whether the output
    shows a crash (CRASH), and the log (None once a write to it failed)."""
    undefined: list[str] = []
    in_undefined = False
    crashed = False
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
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
            text = ANSI.sub("", line.decode("utf-8", errors="replace")).strip()
            if CRASH.search(text):
                crashed = True
            match = PROGRESS.match(text)
            if match:
                events[{"Compiling": "compiling", "Emitting module": "emitting_module", "Linking": "linking"}[match[1]]] += 1
            if text.startswith("Build complete!"):
                events["build_complete_observed"] = True
            if text.startswith(UNDEFINED_START):
                in_undefined = True
            elif in_undefined:
                if text.startswith(UNDEFINED_END):
                    in_undefined = False
                elif len(undefined) < 2000:
                    undefined.append(text)
    return process.wait(), undefined, crashed, log


def retryable(return_code: int, undefined: list[str], crashed: bool) -> bool:
    """Only an ordinary link failure (exit 1, no crash, an undefined-symbol block) is retried. A
    signal (a negative return code, or 128+N from a shell), a crash or any other failure stands."""
    return return_code == 1 and bool(undefined) and not crashed


def run_build(role: str, directory: Path, command: list[str]) -> int:
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
    retry = {"detected": False, "cleared": [], "first_exit_code": None, "crashed": False}
    attempts = 0
    try:
        while True:
            attempts += 1
            return_code, undefined, crashed, log = run_command(command, log, events)
            retry["crashed"] = retry["crashed"] or crashed
            if attempts > 1 or not retryable(return_code, undefined, crashed):
                break
            retry["detected"] = True
            retry["first_exit_code"] = return_code
            retry["cleared"] = observe(lambda: clear_stale_link(package, undefined), [])
            if not retry["cleared"]:
                print("::warning title=SwiftPM link::no missing symbol belongs to a module of this build; not retried",
                      file=sys.stderr)
                break
            print(f"::warning title=Stale SwiftPM objects::the link failed on undefined symbols; cleared "
                  f"{', '.join(retry['cleared'])} and building again once", file=sys.stderr)
            sys.stdout.flush()
    except OSError as error:
        print(f"{command[0]}: {error}", file=sys.stderr)
        return_code = 127 if isinstance(error, FileNotFoundError) else 126
    finally:
        elapsed = time.monotonic() - start
        if log:
            observe(log.close, None)
    exit_code = 128 - return_code if return_code < 0 else return_code
    events["assessment"] = "compile_progress_observed" if events["compiling"] or events["emitting_module"] else "no_compile_progress_observed" if events["build_complete_observed"] else "unknown"
    record.update({
        "status": "completed", "exit_code": exit_code, "process_return_code": return_code,
        "build_step_seconds": round(elapsed, 6), "compile_work": events,
        "attempts": attempts, "stale_link_retry": retry,
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
