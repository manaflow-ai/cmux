#!/usr/bin/env python3
"""One exploratory, local-CAS off/on pair using the app-host build recipe.

Each arm builds its own seed, archives and restores it at the same absolute
paths, then compiles the same comment-only edit. This is not a cross-host or
production cache benchmark. No timing is reported as fleet savings.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


MUTATION_PATH = Path("Sources/AppDelegate.swift")
MUTATION = b"\n// App-host compilation-cache measurement: identical incremental input.\n"


def command(argv: list[str], root: Path, env: dict[str, str]) -> float:
    start = time.monotonic()
    process = subprocess.Popen(argv, cwd=root, env=env, start_new_session=True)
    try:
        status = process.wait()
        if status:
            raise subprocess.CalledProcessError(status, argv)
    except BaseException:
        # Helpers launch xcodebuild/cargo children. Stop this owned group before
        # restoring source or deleting its private build state.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise
    return time.monotonic() - start


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_receipt(output: Path, receipt: dict) -> None:
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


def measure(root: Path, state: Path, output: Path, env: dict[str, str], receipt: dict) -> None:
    """Use only owned paths; restore source bytes even when a build fails."""
    source = root / MUTATION_PATH
    original = source.read_bytes()
    original_stat = source.stat()
    changed = original + MUTATION
    receipt["mutation"] = {"path": str(MUTATION_PATH), "kind": "comment-only",
                           "before_sha256": digest(original), "after_sha256": digest(changed)}
    derived, packages, cas = (state / name for name in ("derived", "packages", "cas"))
    # These settings apply only to this process tree, not to the runner's fleet CAS.
    env = dict(env, CMUX_FLEET_CAS_SETTINGS=str(state / "no-remote-cas-settings"),
               CMUX_CI_CANONICAL_ROOT=str(state / "canonical"),
               CMUX_PRODUCT_PROFILE="app-host",
               CMUX_CI_MODULE_CACHE_PATH=str(derived / "ModuleCache.noindex"))
    # An inherited recovery toggle would silently make both arms cache-off.
    env.pop("CMUX_CI_DISABLE_COMPILATION_CACHE", None)
    env.pop("CMUX_CI_DISABLE_EXPLICIT_MODULES", None)
    helper = str(root / "scripts/ci/compile-app-host-test-product.sh")
    receipt["arms"] = []
    try:
        for mode in ("off", "on"):
            source.write_bytes(original)
            os.utime(source, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
            # Both arms use the same paths and start with no build or CAS state.
            for path in (derived, cas):
                if path.exists():
                    shutil.rmtree(path)
            env["CMUX_CI_ENABLE_APP_COMPILATION_CACHE"] = "1" if mode == "on" else "0"
            arm = {"mode": mode, "status": "running"}
            receipt["arms"].append(arm)
            write_receipt(output, receipt)
            arm["resolve_seconds"] = command([helper, "resolve", str(derived), str(packages)], root, env)
            arm["seed_seconds"] = command([helper, "build", str(derived), str(packages), str(cas),
                                            str(output / f"{mode}-seed.log")], root, env)
            archive = state / "seed.tar.gz"
            arm["archive_seconds"] = command(["tar", "-czf", str(archive), "-C", str(state),
                                               "derived", "cas"], root, env)
            arm["archive_bytes"] = archive.stat().st_size
            for path in (derived, cas):
                shutil.rmtree(path)
            arm["restore_seconds"] = command(["tar", "-xzf", str(archive), "-C", str(state)], root, env)
            archive.unlink()
            # Seed logs must never be counted as measured compile/cache work.
            for path in derived.glob("*-build.log"):
                path.unlink()
            source.write_bytes(changed)
            arm["compile_seconds"] = command([helper, "build", str(derived), str(packages), str(cas),
                                               str(output / f"{mode}-incremental.log")], root, env)
            metrics_path = output / f"{mode}-metrics.json"
            command(["python3", str(root / "scripts/ci/build_metrics.py"), str(derived),
                     "--output", str(metrics_path), "--compile-seconds", str(arm["compile_seconds"]),
                     "--compile-outcome", "success"], root, env)
            metrics = json.loads(metrics_path.read_text())
            arm["metrics"] = metrics
            targets = metrics["aggregate"]["targets"]
            arm["app_target"] = targets.get("cmux", {})
            if arm["app_target"].get("swift_compile_events", 0) < 1:
                raise RuntimeError(f"{mode}: no app SwiftCompile event; a no-op is not a cache measurement")
            if metrics["compiler_cache"]["cache_backend"] != "local":
                raise RuntimeError(f"{mode}: expected isolated local CAS")
            products = derived / "Build/Products"
            product = products / "Debug/cmux"
            if not product.is_file() or not os.access(product, os.X_OK) or not list(products.rglob("*.xctestrun")):
                raise RuntimeError(f"{mode}: missing app-host test product")
            command(["python3", str(root / "scripts/swift_warning_budget.py"),
                     "--log", str(derived / "cmux-build.log")], root, env)
            arm["status"] = "completed"
            write_receipt(output, receipt)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        if receipt["arms"]:
            receipt["arms"][-1].update(status="failed", error=str(error))
        raise
    finally:
        source.write_bytes(original)
        os.utime(source, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        write_receipt(output, receipt)


def setup(root: Path, state: Path, env: dict[str, str]) -> None:
    command(["git", "submodule", "update", "--init", "--recursive", "--",
             "ghostty", "vendor/bonsplit"], root, env)
    env["GHOSTTY_SHA"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD:ghostty"], cwd=root, text=True).strip()
    xcode_env = state / "xcode.env"
    xcode_env.touch()
    # Pin only this workload; never switch the worker's global Xcode default.
    command([str(root / "scripts/select-ci-xcode.sh")], root,
            dict(env, GITHUB_ENV=str(xcode_env), CMUX_CI_SKIP_XCODE_SELECT="1"))
    for line in xcode_env.read_text().splitlines():
        if line.startswith("DEVELOPER_DIR="):
            env["DEVELOPER_DIR"] = line.split("=", 1)[1]
    command([str(root / "scripts/install-rust-ci.sh")], root, env)
    command([str(root / "scripts/download-prebuilt-ghosttykit.sh")], root, env)


def main() -> int:
    argparse.ArgumentParser(description=__doc__).parse_args()
    if os.uname().sysname != "Darwin":
        raise SystemExit("app-host-cache: requires a managed macOS measurement worker")
    root = Path(__file__).resolve().parents[2]
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    artifact_root = root / ".build"
    artifact_root.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="app-host-cache-", dir=artifact_root))
    receipt = {"schema": "app-host-cache-measure/v1", "source_sha": sha, "status": "running",
               "design": "off-then-on; same-host restored local seed; identical comment-only edit",
               "limitations": ["exploratory single ordered pair", "no cross-host seed or network transfer",
                               "no production savings or byte-equivalence claim"]}
    env = dict(os.environ, GITHUB_SHA=sha, CMUX_SKIP_ZIG_BUILD="1", CMUX_CI_REQUIRED_MACOS_SDK_MAJOR="26")
    env["PATH"] = str(Path.home() / ".cargo/bin") + os.pathsep + env["PATH"]
    # command() stops its owned process group before TERM unwinds private state.
    def interrupted(signum, frame):
        raise InterruptedError(f"measurement interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    write_receipt(output, receipt)
    try:
        with tempfile.TemporaryDirectory(prefix="app-host-cache-") as scratch:
            state = Path(scratch).resolve()
            source = state / "src"
            # A local clone borrows immutable objects but owns its Git metadata,
            # including submodules; cleanup cannot change the worker checkout.
            command(["git", "clone", "--shared", "--no-checkout", str(root), str(source)], root, env)
            command(["git", "checkout", "--detach", sha], source, env)
            receipt["source_path"] = str(source)
            started = time.monotonic()
            setup(source, state, env)
            receipt["setup_seconds"] = time.monotonic() - started
            measure(source, state, output, env, receipt)
        receipt["status"] = "completed"
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
    write_receipt(output, receipt)
    print("APP_HOST_CACHE_RECEIPT " + json.dumps(receipt, sort_keys=True), flush=True)
    print(f"receipt: {output / 'receipt.json'}", flush=True)
    return 0 if receipt["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
