#!/usr/bin/env python3
"""
Regression test: `cmux --version` must not scan huge sibling app lists just to
resolve optional version metadata.
"""

from __future__ import annotations

import glob
import os
import plistlib
import shutil
import subprocess
import tempfile
import time


JUNK_APP_COUNT = 40000
RSS_LIMIT_KB = 64 * 1024
TIMEOUT_SECONDS = 10.0
EXPECTED_STDOUT = "cmux 9.9.9 (999)"


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def copy_runtime_frameworks(cli_path: str, fixture_contents: str) -> None:
    frameworks_dir = os.path.join(fixture_contents, "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)

    search_roots: list[str] = []
    current = os.path.dirname(cli_path)
    for _ in range(4):
        search_roots.append(os.path.join(current, "Frameworks"))
        search_roots.append(os.path.join(current, "PackageFrameworks"))
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent

    for search_root in search_roots:
        sentry_framework = os.path.join(search_root, "Sentry.framework")
        if os.path.isdir(sentry_framework):
            shutil.copytree(sentry_framework, os.path.join(frameworks_dir, "Sentry.framework"))
            return


def build_fixture(root: str, cli_path: str) -> str:
    app_path = os.path.join(root, "cmux.app")
    contents_path = os.path.join(app_path, "Contents")
    resources_path = os.path.join(contents_path, "Resources")
    bin_path = os.path.join(resources_path, "bin")
    os.makedirs(bin_path, exist_ok=True)

    fixture_cli = os.path.join(bin_path, "cmux")
    shutil.copy2(cli_path, fixture_cli)
    copy_runtime_frameworks(cli_path, contents_path)

    info = {
        "CFBundleExecutable": "cmux",
        "CFBundleIdentifier": "test.cmux.version-memory-guard",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "9.9.9",
        "CFBundleVersion": "999",
    }
    with open(os.path.join(contents_path, "Info.plist"), "wb") as handle:
        plistlib.dump(info, handle)

    # Regular files are enough here because the fallback scan keys off the
    # ".app" suffix before it ever tries to inspect bundle contents.
    for index in range(JUNK_APP_COUNT):
        open(os.path.join(resources_path, f"junk-{index:05d}.app"), "wb").close()

    return fixture_cli


def run_with_limits(cli_path: str, *args: str) -> dict[str, object]:
    env = dict(os.environ)
    env.pop("CMUX_COMMIT", None)

    proc = subprocess.Popen(
        [cli_path, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

    started = time.time()
    peak_rss_kb = 0
    failure_reason: str | None = None

    while True:
        exit_code = proc.poll()
        if exit_code is not None:
            stdout, stderr = proc.communicate()
            return {
                "exit_code": exit_code,
                "stdout": stdout.strip(),
                "stderr": stderr.strip(),
                "elapsed": time.time() - started,
                "peak_rss_kb": peak_rss_kb,
                "failure_reason": None,
            }

        try:
            rss_kb = int(
                subprocess.check_output(
                    ["ps", "-o", "rss=", "-p", str(proc.pid)],
                    text=True,
                ).strip()
                or "0"
            )
        except subprocess.CalledProcessError:
            rss_kb = 0

        peak_rss_kb = max(peak_rss_kb, rss_kb)
        elapsed = time.time() - started

        if rss_kb > RSS_LIMIT_KB:
            failure_reason = f"rss limit exceeded ({rss_kb} KB > {RSS_LIMIT_KB} KB)"
        elif elapsed > TIMEOUT_SECONDS:
            failure_reason = f"timeout exceeded ({elapsed:.2f}s > {TIMEOUT_SECONDS:.2f}s)"

        if failure_reason:
            proc.kill()
            stdout, stderr = proc.communicate()
            return {
                "exit_code": proc.returncode,
                "stdout": stdout.strip(),
                "stderr": stderr.strip(),
                "elapsed": elapsed,
                "peak_rss_kb": peak_rss_kb,
                "failure_reason": failure_reason,
            }

        time.sleep(0.05)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-version-memory-guard-") as root:
        fixture_cli = build_fixture(root, cli_path)
        result = run_with_limits(fixture_cli, "--version")

    if result["failure_reason"]:
        print("FAIL: `cmux --version` exceeded runtime guard")
        print(f"reason={result['failure_reason']}")
        print(f"elapsed={result['elapsed']:.2f}s")
        print(f"peak_rss_kb={result['peak_rss_kb']}")
        print(f"stdout={result['stdout']}")
        print(f"stderr={result['stderr']}")
        return 1

    if result["exit_code"] != 0:
        print("FAIL: `cmux --version` exited non-zero")
        print(f"exit={result['exit_code']}")
        print(f"stdout={result['stdout']}")
        print(f"stderr={result['stderr']}")
        return 1

    if result["stdout"] != EXPECTED_STDOUT:
        print("FAIL: unexpected version output")
        print(f"stdout={result['stdout']!r}")
        print(f"expected={EXPECTED_STDOUT!r}")
        return 1

    print(
        "PASS: `cmux --version` exits within memory/time limits "
        f"(peak_rss_kb={result['peak_rss_kb']}, elapsed={result['elapsed']:.2f}s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
