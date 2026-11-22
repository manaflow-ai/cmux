#!/usr/bin/env python3
"""Package interface fingerprint for compile avoidance (RFC #15391, Work 2).

For a pull request whose Swift changes stay inside allowlisted packages, build
each edited package at the base and at the head with library evolution on,
and compare the .swiftinterface files the compiler emits. Equal interfaces
mean an importer (the app, the CLI, other packages) sees the same declarations,
so the edit is interface-equivalent; anything else is interface-changing.

The receipt is one line, `CMUX_INTERFACE_FINGERPRINT=<json>`, so a fleet step
can hand it back through its streamed log, and `interface_fingerprint=<json>`
in GITHUB_OUTPUT when there is one. macOS status reads it to shadow the skip
(Work 3): it marks would_skip_app_compile and still compiles the app.

This is observation only. It never fails the lane; an error is class unknown.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Packages whose importer-visible surface is only their Swift modules: no
# resources, plugins, generated code, C or Objective-C targets, unsafe flags,
# package dependencies or @_spi. Each maps to the library modules importers
# see. Add a package only once it meets all of that.
# CMUXAgentLaunch, the one package listed, was deleted with the Swift CLI, so
# every package edit currently classifies as compile-required.
ALLOWLIST: dict[str, tuple[str, ...]] = {}

MARKER = "CMUX_INTERFACE_FINGERPRINT="
BUILD_TIMEOUT_SECONDS = 600
DIFF_LINES = 60


def package_dirs(root: Path) -> dict[str, str]:
    dirs = {}
    for name in ALLOWLIST:
        found = sorted(root.glob(f"Packages/*/{name}/Package.swift"))
        if found:
            dirs[name] = found[0].parent.relative_to(root).as_posix()
    return dirs


def classify_paths(changed: list[str], dirs: dict[str, str]) -> dict:
    """Which allowlisted packages the change edits, or why it is out of scope."""
    sources: set[str] = set()
    tests: set[str] = set()
    other: set[str] = set()
    outside: list[str] = []
    for path in changed:
        owner = next((name for name, d in dirs.items() if path.startswith(d + "/")), None)
        if owner is None:
            outside.append(path)
            continue
        rest = path[len(dirs[owner]) + 1:]
        if rest.startswith("Sources/"):
            sources.add(owner)
        elif rest.startswith("Tests/"):
            tests.add(owner)
        else:
            # Package.swift, Package.resolved and anything else beside the
            # sources can change what the package builds or links.
            other.add(owner)
            outside.append(path)
    touched = sorted(sources | tests | other)
    if not changed:
        return {"class": "not_applicable", "reason": "no changed files"}
    if not touched:
        return {"class": "not_applicable", "reason": "no allowlisted package changed"}
    if outside:
        shown = ", ".join(outside[:3]) + (f" and {len(outside) - 3} more" if len(outside) > 3 else "")
        return {
            "class": "ineligible",
            "reason": f"changes outside allowlisted package sources and tests: {shown}",
            "touched": touched,
        }
    if not sources:
        return {"class": "package_tests_only", "reason": "only package tests changed", "touched": touched}
    return {"class": "candidate", "sources": sorted(sources), "touched": touched}


def build_interface(package: Path, modules: tuple[str, ...], scratch: Path) -> str:
    """The public and private interfaces the compiler emits for modules."""
    command = [
        "swift", "build", "--package-path", str(package), "--scratch-path", str(scratch),
        "-Xswiftc", "-enable-library-evolution",
        "-Xswiftc", "-emit-module-interface",
        "-Xswiftc", "-no-verify-emitted-module-interface",
    ]
    for module in modules:
        command += ["--target", module]
    result = subprocess.run(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=BUILD_TIMEOUT_SECONDS,
    )
    if result.returncode != 0:
        tail = "\n".join(result.stdout.splitlines()[-20:])
        raise RuntimeError(f"swift build exited {result.returncode}:\n{tail}")
    parts = []
    for module in modules:
        for suffix in ("swiftinterface", "private.swiftinterface"):
            found = sorted(scratch.glob(f"*/debug/{module}.build/{module}.{suffix}"))
            if not found:
                raise RuntimeError(f"no {module}.{suffix} under {scratch}")
            parts.append(f"// ---- {module}.{suffix}\n" + found[0].read_text())
    return "\n".join(parts)


def extract_base(repo: Path, base_rev: str, pkgdir: str, dest: Path) -> Path | None:
    dest.mkdir(parents=True, exist_ok=True)
    archive = subprocess.Popen(
        ["git", "-C", str(repo), "archive", "--format=tar", base_rev, "--", pkgdir],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    extract = subprocess.run(["tar", "-x", "-C", str(dest)], stdin=archive.stdout, stderr=subprocess.DEVNULL)
    archive.stdout.close()
    if archive.wait() != 0 or extract.returncode != 0:
        return None
    base = dest / pkgdir
    return base if (base / "Package.swift").is_file() else None


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def fingerprint(repo: Path, base_rev: str, changed: list[str], work: Path, build=build_interface) -> dict:
    dirs = package_dirs(repo)
    receipt = classify_paths(changed, dirs)
    if receipt["class"] != "candidate":
        receipt["would_skip_app_compile"] = receipt["class"] == "package_tests_only"
        return receipt

    packages = {}
    changing = []
    for name in receipt.pop("sources"):
        modules = ALLOWLIST[name]
        started = time.monotonic()
        base = extract_base(repo, base_rev, dirs[name], work / "base-src")
        if base is None:
            return {**receipt, "class": "unknown", "would_skip_app_compile": False,
                    "reason": f"{name} is not a package at the base"}
        try:
            base_text = build(base, modules, work / f"{name}-base")
            head_text = build(repo / dirs[name], modules, work / f"{name}-head")
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            return {**receipt, "class": "unknown", "would_skip_app_compile": False,
                    "reason": f"{name}: {error}".splitlines()[0]}
        equal = base_text == head_text
        packages[name] = {
            "interface": "equivalent" if equal else "changed",
            "base_sha256": sha256(base_text),
            "head_sha256": sha256(head_text),
            "seconds": round(time.monotonic() - started, 1),
        }
        if not equal:
            changing.append(name)
            diff = difflib.unified_diff(
                base_text.splitlines(), head_text.splitlines(), "base", "head", lineterm="", n=1,
            )
            lines = list(diff)
            print(f"Interface diff for {name} ({len(lines)} lines):")
            print("\n".join(lines[:DIFF_LINES]))
            if len(lines) > DIFF_LINES:
                print(f"... {len(lines) - DIFF_LINES} more lines")
    receipt["packages"] = packages
    if changing:
        receipt.update({"class": "interface_changing", "would_skip_app_compile": False,
                        "reason": "interface changed: " + ", ".join(changing)})
    else:
        receipt.update({"class": "interface_equivalent", "would_skip_app_compile": True,
                        "reason": "every edited package kept its interface"})
    return receipt


def emit(receipt: dict) -> None:
    line = json.dumps({"version": 1, **receipt}, sort_keys=True, separators=(",", ":"))
    print(MARKER + line, flush=True)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write(f"interface_fingerprint={line}\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(
                "### Package interface fingerprint\n\n"
                f"`{receipt['class']}`, would_skip_app_compile={str(receipt['would_skip_app_compile']).lower()}: "
                f"{receipt.get('reason', '')}\n\n"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--changed-files", type=Path, required=True)
    parser.add_argument("--base", default="HEAD^1")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="interface-fingerprint."))
    try:
        changed = [line for line in args.changed_files.read_text().splitlines() if line]
        receipt = fingerprint(args.repo.resolve(), args.base, changed, work)
    except Exception as error:  # observation only: report, never fail the lane
        receipt = {"class": "unknown", "would_skip_app_compile": False, "reason": str(error).splitlines()[0]}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    emit(receipt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
