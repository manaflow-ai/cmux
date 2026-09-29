"""Tell a test run the Mac failed apart from one the code failed.

A run whose log shows one of these runner-level errors and no started test
never asked the tests anything, so running the same commit again is a fair
retry rather than a reprint of a known answer. Both the focused dispatcher's
repeat guard (dispatch-focused-test.py) and the main regression bisect read
this, so "machine failure" means one thing everywhere.

Add a signature only for an error that happens before the first test starts
and that the code under test cannot cause. "never finished bootstrapping" is
not one: an app-hosted test prints it when cmux itself crashes at launch.
"""
from __future__ import annotations

import re

# (text in the failed log, what to tell the person retrying)
SIGNATURES = (
    ("failed to initialize for UI testing", "the UI test runner could not initialize (Automation Mode)"),
    ("No logged-in GUI user is available", "the Mac had no logged-in GUI user"),
    ("Timed out waiting for virtual display readiness", "the virtual display never became ready"),
    ("screen frame capture failed to start", "screen capture could not start"),
    # Homebrew's refusal when the runner user does not own its prefix.
    ("The following directories are not writable by your user", "the Mac's Homebrew prefix is not writable by the runner user"),
    # scripts/select-ci-xcode.sh, before any build, on a Mac without the pinned Xcode.
    ("[cmux-ci machine: xcode-pin-missing]", "the Mac does not have the Xcode the job pins"),
    ("Pinned Xcode developer dir does not exist", "the Mac does not have the Xcode the job pins"),
    ("Pinned Xcode developer dir has no usable macOS SDK", "the Mac does not have the Xcode the job pins"),
    ("the version scripts/ci/xcode-pins.txt pins for its pool", "the Mac does not have the Xcode the job pins"),
)

# XCTest and Swift Testing lines for a test that began. One of these means the
# code ran, and its failure is the code's answer.
STARTED = re.compile(
    r"Test Case '[^']+' started|\bTest (?:\S+\(.*\)|\"[^\"]*\") started", re.IGNORECASE
)

# GitHub prints each step's script before running it, in this color. Those
# lines quote the error messages the script can print, not ones it printed.
SCRIPT_LISTING = "[36;1m"


def reason(log: str) -> str | None:
    """Why the Mac failed this run, or None when a test started or no signature matched."""
    lines = [line for line in log.splitlines() if SCRIPT_LISTING not in line]
    if any(STARTED.search(line) for line in lines):
        return None
    folded = [line.casefold() for line in lines]
    for signature, explanation in SIGNATURES:
        if any(signature.casefold() in line for line in folded):
            return explanation
    return None
