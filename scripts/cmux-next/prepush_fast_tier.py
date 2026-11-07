#!/usr/bin/env python3
"""A bounded early signal, before the existing mandatory push checks and fleet work.

Runs installed analyzers on git blobs, and selected pure TS suites in a disposable Linux
sandbox. No checkout code runs on the host. No installs, project builds, network, credentials,
or shared writable caches. Missing tools/sandbox and the deadline are DEFERRED, never green.
The manifest is installed with the reviewed checks; changing it in a push cannot select code.
CMUX_FAST_TIER_DISABLED=1 is the kill switch; existing push and fleet checks still run.
"""
from __future__ import annotations

import argparse
import ast
import fcntl
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Leave half a second for Python startup, result output and the best-effort timing receipt.
WORK_SECONDS = 4.0


def sibling(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def git(root: Path, *args: str) -> bytes:
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True).stdout


def sandbox(snapshot: Path, bun: Path, compiler: Path | None = None) -> list[str] | None:
    bubblewrap = shutil.which("bwrap", path="/usr/bin:/bin") if sys.platform == "linux" else None
    if not bubblewrap:
        return None
    args = [bubblewrap, "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
            "--setenv", "HOME", "/tmp", "--setenv", "PATH", "/usr/bin:/bin",
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
    for name in ("/usr", "/bin", "/lib", "/lib64"):
        if Path(name).exists():
            args += ["--ro-bind", name, name]
    args += ["--ro-bind", str(snapshot), "/src", "--ro-bind", str(bun), "/tools/bun",
             "--chdir", "/src"]
    if compiler:
        args += ["--ro-bind", str(compiler), "/tools/typescript"]
    return args


def execute(argv: list[str]) -> dict:
    result = subprocess.run(argv, capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    # Sandbox setup is infrastructure, not a source failure.
    status = "deferred" if "bwrap:" in output else "failed" if result.returncode else "passed"
    return {"status": status, "detail": output}


def check_range(root: Path, own, scratch: Path | None = None) -> list[dict]:
    checks: list[dict] = []
    changed = set(os.fsdecode(p) for p in git(root, "diff", "--name-only", "-z", "--diff-filter=AMR",
                                             own.base, own.head).split(b"\0") if p)
    # Use data-only parsers; never import changed Python or source shell files.
    for path in sorted(changed):
        # .json also names JSONC configuration (tsconfig, VS Code); only package manifests
        # have a strict JSON contract here. Their valid comments must not become false reds.
        if not (path.endswith(".py") or Path(path).name == "package.json"):
            continue
        data = git(root, "show", f"{own.head}:{path}")
        try:
            ast.parse(data, filename=path) if path.endswith(".py") else json.loads(data)
        except (SyntaxError, ValueError, UnicodeError) as error:
            try:
                before = git(root, "show", f"{own.base}:{path}")
                ast.parse(before, filename=path) if path.endswith(".py") else json.loads(before)
            except (SyntaxError, ValueError, UnicodeError):
                checks.append({"name": path, "status": "deferred", "detail": "parse error also on base"})
                continue
            except subprocess.CalledProcessError:
                pass
            checks.append({"name": path, "status": "failed", "detail": str(error)})
        else:
            checks.append({"name": path, "status": "passed", "detail": "source syntax"})

    manifest = json.loads((HERE / "prepush-fast-suites.json").read_text())
    if any(check["status"] == "failed" for check in checks):
        return checks
    selected = [entry for entry in manifest["suites"] if changed.intersection(entry.values())]
    if not selected:
        return checks
    bun_path = shutil.which("bun")
    if not bun_path:
        return checks + [{"name": "selected suites", "status": "deferred", "detail": "bun unavailable"}]
    # Only committed, explicitly listed blobs enter the sandbox: no .env, .git, config,
    # hooks, working-tree fix, untracked secret, dependency installer or project preload.
    with tempfile.TemporaryDirectory(prefix="snapshot-", dir=scratch) as temp:
        snapshot = Path(temp)
        for entry in selected:
            for path in entry.values():
                target = snapshot / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(git(root, "show", f"{own.head}:{path}"))
        if any(re.search(r"\b(?:import|require)\b|\bexport\b[^;]*\bfrom\b",
                         (snapshot / entry["source"]).read_text()) for entry in selected):
            return checks + [{"name": "selected suites", "status": "deferred",
                              "detail": "source gained dependencies; expand and measure the reviewed suite manifest"}]
        bun = Path(bun_path).resolve()
        compiler = root / "webviews/node_modules/typescript"
        compiler = compiler.resolve() if (compiler / "lib/tsc.js").is_file() else None
        prefix = sandbox(snapshot, bun, compiler)
        if prefix is None:
            return checks + [{"name": "selected suites", "status": "deferred", "detail": "sandbox unavailable"}]
        if compiler:
            sources = sorted({entry["source"] for entry in selected})
            checks.append({"name": "selected-file typecheck", **execute(prefix + [
                "/tools/bun", "/tools/typescript/lib/tsc.js", "--noEmit", "--strict",
                "--target", "es2022", "--module", "esnext", "--moduleResolution", "bundler",
                "--skipLibCheck", *sources])})
            if checks[-1]["status"] == "failed":
                return checks
        else:
            checks.append({"name": "selected-file typecheck", "status": "deferred",
                           "detail": "TypeScript is not warm; no installation in the push path"})
        tests = sorted({entry["test"] for entry in selected})
        checks.append({"name": "selected unit suites", **execute(prefix + [
            "/tools/bun", "test", "--timeout", "1000", *[f"./{p}" for p in tests]])})
        if checks[-1]["status"] == "passed" and not re.search(r"\b[1-9][0-9]* pass\b", checks[-1]["detail"]):
            checks[-1] = {"name": "selected unit suites", "status": "deferred", "detail": "no executed-test evidence"}
    return checks


def worker(args, refs: str) -> dict:
    push_range = sibling("push_range")
    if args.base:
        ranges, errors = [push_range.given_range(args.repo, args.base, args.head)], []
    else:
        ranges, errors = push_range.pushed_ranges(args.repo, refs.splitlines(), args.remote)
    checks = [{"name": "push range", "status": "deferred", "detail": error} for error in errors]
    heads = []
    for own in ranges:
        heads.append(own.head)
        # A merge's subtracted ranges need the full gate's attribution, not an approximate early failure.
        if own.before:
            checks.append({"name": own.head, "status": "deferred", "detail": "merge attribution goes to full checks"})
        else:
            checks.extend(check_range(args.repo, own, args.scratch))
    return {"head": heads[0] if len(heads) == 1 else None, "heads": heads, "checks": checks}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--scratch", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    refs = "" if args.base else sys.stdin.read()
    if args.worker:
        try:
            print(json.dumps(worker(args, refs)))
        except Exception as error:
            print(json.dumps({"head": None, "checks": [{"name": "tier", "status": "deferred", "detail": str(error)}]}))
        return 0
    started = time.monotonic()
    # Hook installs retire old versioned snapshots only under an exclusive .in-use lock.
    # Retain this one while the worker imports the manifest and sibling helpers.
    snapshot_lock = None
    try:
        snapshot_lock = (HERE / ".in-use").open("r")
        fcntl.flock(snapshot_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except OSError:
        if HERE.name.startswith("cmux-next-checks."):
            print(json.dumps({"status": "deferred", "checks": [], "detail": "installed snapshot is retiring"}))
            return 0
    timing = sibling("inner_loop_timing")
    pushed_heads = [line.split()[1] for line in refs.splitlines()
                    if len(line.split()) == 4 and re.fullmatch(r"[0-9a-f]{40}", line.split()[1])
                    and line.split()[1] != "0" * 40]
    receipt = {"started_at": timing.now(), "checks": [],
               "head": pushed_heads[0] if len(pushed_heads) == 1 else None}
    if os.environ.get("CMUX_FAST_TIER_DISABLED") == "1":
        receipt["checks"] = [{"name": "tier", "status": "deferred", "detail": "CMUX_FAST_TIER_DISABLED=1"}]
    else:
        command = [sys.executable, "-I", str(Path(__file__).resolve()), "--worker", "--repo", str(args.repo),
                   "--remote", args.remote]
        if args.base:
            command += ["--base", args.base, "--head", args.head]
        # The supervisor owns cleanup even when it must kill the worker's process group.
        with tempfile.TemporaryDirectory(prefix="cmux-fast-tier-") as scratch:
            command += ["--scratch", scratch]
            proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, start_new_session=True)
            try:
                out, err = proc.communicate(refs, timeout=WORK_SECONDS)
                receipt.update(json.loads(out))
            except (subprocess.TimeoutExpired, ValueError):
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                receipt["checks"] = [{"name": "tier", "status": "deferred", "detail": "4s budget exhausted or no result"}]
    receipt["elapsed_ms"] = round((time.monotonic() - started) * 1000, 2)
    statuses = {check["status"] for check in receipt["checks"]}
    receipt["status"] = "failed" if "failed" in statuses else "deferred" if "deferred" in statuses else "passed"
    timing.record(args.repo, prepush=receipt)
    print(json.dumps(receipt))
    if snapshot_lock is not None:
        snapshot_lock.close()
    return 1 if receipt["status"] == "failed" else 0


if __name__ == "__main__":
    sys.exit(main())
