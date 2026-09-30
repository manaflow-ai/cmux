#!/usr/bin/env python3
"""The screenshots lane must stop at the first language that captures nothing.

`capture_screenshots` does not raise when the scheme's test build fails. It
records the failure and returns. The lane deliberately passes no `testplan:`
(with `-testPlan` the UI test passes but fastlane collects zero screenshots), so
the plain `cmux-ios` scheme invocation requires every test target in the
scheme's default plan to compile before any screenshot is taken.

When one does not, nothing raises. The lane captures nothing for all nine
languages on both devices, and the failure finally surfaces from the `frame`
lane as "no localized raws in ios/fastlane/screenshots; run capture first",
which names the wrong thing entirely. Release run 35225939389 (v0.64.25) spent
47 minutes that way because
Packages/iOS/CmuxMobileTerminal/Tests/CmuxMobileTerminalTests/GhosttySurfaceWorkQueueTests.swift
was missing `@testable import CmuxMobileTerminal`, so `GhosttySurfaceWorkQueue`
was out of scope and xcodebuild exited 65.

Where a Ruby is available this also syntax-checks the Fastfile.
"""

import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FASTFILE = os.path.join(ROOT, "ios", "fastlane", "Fastfile")

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def main():
    source = open(FASTFILE, encoding="utf-8").read()

    lane = source.split("lane :screenshots do", 1)
    _check(len(lane) == 2, "the Fastfile still defines the screenshots lane")
    body = lane[1].split("\n  lane :", 1)[0] if len(lane) == 2 else ""

    _check(
        "captured_before" in body,
        "the lane records how many screenshots existed before each capture",
    )
    _check(
        "UI.user_error!" in body,
        "the lane raises rather than continuing when a capture produces nothing",
    )
    _check(
        body.index("captured_before") < body.index("capture_screenshots("),
        "the count is taken before the capture, not after",
    )
    # The guard is worthless if it only reports and lets the loop continue.
    _check(
        "UI.user_error!" in body.split("dark_mode: true", 1)[-1],
        "the guard runs after the capture, inside the per-language loop",
    )
    # Passing a testplan would make every capture silently empty, which this
    # guard would then correctly reject on the very first language.
    # Match an actual argument line, not the word in a comment or a message.
    passes_testplan = any(
        line.strip().startswith("testplan:") for line in body.splitlines()
    )
    _check(
        not passes_testplan,
        "the lane still passes no testplan: argument, which is why every test target must compile",
    )

    ruby = shutil.which("ruby")
    if ruby:
        result = subprocess.run([ruby, "-c", FASTFILE], capture_output=True, text=True)
        _check(result.returncode == 0, f"the Fastfile parses ({result.stderr.strip()[:200]})")
    else:
        print("skip: no ruby on PATH, cannot syntax-check the Fastfile here")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios screenshot capture guard tests passed")


if __name__ == "__main__":
    main()
