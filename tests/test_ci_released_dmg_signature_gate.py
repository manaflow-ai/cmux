#!/usr/bin/env python3
"""Guard: the release and nightly pipelines must verify the SHIPPED DMG the way
an end user does.

Regression context: https://github.com/manaflow-ai/cmux/issues/6670

The release/nightly workflows staple and `spctl`-check the .app BEFORE it is
packaged into the DMG, but historically never re-verified the copy a user
extracts from the shipped DMG. This guard requires both workflows to run
`scripts/verify-released-app-bundle.sh --dmg <final-dmg>` after the DMG is
stapled and before it is uploaded, so a signature regression introduced during
DMG packaging fails the release instead of shipping a bundle that users see as
"invalid signature (code or signature have been modified)" /
"internal error in Code Signing subsystem".

This test is pure static analysis (no codesign), so it runs on the Linux
workflow-guard-tests job. It additionally requires ci.yml to wire the verifier's
`--self-test` into a macOS job, so the verifier's runtime tamper-rejection
behavior is actually proven in CI (not just asserted to exist).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-released-app-bundle.sh"
RELEASE_WF = ROOT / ".github" / "workflows" / "release.yml"
NIGHTLY_WF = ROOT / ".github" / "workflows" / "nightly.yml"
CI_WF = ROOT / ".github" / "workflows" / "ci.yml"

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def first_index(lines: list[str], needle: str) -> int:
    for i, line in enumerate(lines):
        if needle in line:
            return i
    return -1


def section_between(text: str, start: str, end: str) -> str:
    start_idx = text.find(start)
    if start_idx == -1:
        return ""
    end_idx = text.find(end, start_idx)
    if end_idx == -1:
        end_idx = len(text)
    return text[start_idx:end_idx]


def job_block_containing(lines: list[str], needle: str) -> tuple[int, list[str]]:
    needle_idx = first_index(lines, needle)
    if needle_idx == -1:
        return -1, []

    job_start = -1
    for i in range(needle_idx, -1, -1):
        line = lines[i]
        if line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":"):
            job_start = i
            break

    if job_start == -1:
        return -1, []

    job_end = len(lines)
    for i in range(job_start + 1, len(lines)):
        line = lines[i]
        if line.startswith("  ") and not line.startswith("    ") and line.rstrip().endswith(":"):
            job_end = i
            break

    return job_start, lines[job_start:job_end]


def check_script() -> None:
    if not SCRIPT.exists():
        FAILURES.append(f"missing verifier script: {SCRIPT.relative_to(ROOT)}")
        return
    check(
        os.access(SCRIPT, os.X_OK),
        f"{SCRIPT.relative_to(ROOT)} must be executable",
    )
    text = SCRIPT.read_text(encoding="utf-8")
    # The exact end-user commands from the issue must be exercised.
    required = [
        "codesign --verify --deep --strict",
        "spctl --assess --type execute",
        "Info.plist=not bound",
        "Authority=(unavailable)",
        "Notarization Ticket=stapled",
        "--dmg",
        "--self-test",
    ]
    for token in required:
        check(token in text, f"{SCRIPT.relative_to(ROOT)} must reference {token!r}")

    run_checks_body = section_between(text, "run_checks() {", "\n# verify_dmg")
    verify_dmg_body = section_between(text, "verify_dmg() {", "\n# self_test")
    main_body = section_between(text, "main() {", '\nmain "$@"')
    check(
        'if [[ "$REQUIRE_NOTARIZED" == "1" ]]' in run_checks_body,
        f"{SCRIPT.relative_to(ROOT)} run_checks must gate notarization checks on REQUIRE_NOTARIZED=1",
    )
    check(
        "Notarization Ticket=stapled" in run_checks_body,
        f"{SCRIPT.relative_to(ROOT)} run_checks must require a stapled notarization ticket",
    )
    check(
        "spctl --assess --type execute" in run_checks_body,
        f"{SCRIPT.relative_to(ROOT)} run_checks must require Gatekeeper assessment",
    )
    check(
        'run_checks "$dest"' in verify_dmg_body,
        f"{SCRIPT.relative_to(ROOT)} verify_dmg must run the notarization-aware checks on the extracted app",
    )
    check(
        "REQUIRE_NOTARIZED=0" not in verify_dmg_body
        and "CMUX_VERIFY_REQUIRE_NOTARIZED=0" not in verify_dmg_body,
        f"{SCRIPT.relative_to(ROOT)} verify_dmg must not disable notarization checks",
    )
    check(
        "--dmg)" in main_body and 'verify_dmg "$2"' in main_body,
        f"{SCRIPT.relative_to(ROOT)} --dmg mode must dispatch to verify_dmg",
    )


def check_workflow(path: Path, dmg_name: str, upload_anchor: str, staple_anchor: str) -> None:
    if not path.exists():
        FAILURES.append(f"missing workflow: {path.relative_to(ROOT)}")
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    rel = path.relative_to(ROOT)

    verify_idx = -1
    for i, line in enumerate(lines):
        if "verify-released-app-bundle.sh" in line and "--dmg" in line:
            verify_idx = i
            break
    if verify_idx < 0:
        FAILURES.append(
            f"{rel} must run scripts/verify-released-app-bundle.sh --dmg on the shipped DMG"
        )
        return

    # The gate must target the actual shipped DMG.
    check(
        dmg_name in lines[verify_idx],
        f"{rel} must verify the shipped DMG {dmg_name!r} (line: {lines[verify_idx].strip()!r})",
    )

    staple_idx = first_index(lines, staple_anchor)
    upload_idx = first_index(lines, upload_anchor)
    check(staple_idx != -1, f"{rel} is missing expected DMG staple anchor {staple_anchor!r}")
    upload_present = upload_idx != -1
    check(upload_present, f"{rel} is missing expected upload anchor {upload_anchor!r}")

    # Verify only after the DMG is stapled, and before it is uploaded — so a bad
    # DMG can never ship.
    if staple_idx != -1:
        check(
            staple_idx < verify_idx,
            f"{rel} must verify the DMG AFTER it is stapled",
        )
    if upload_present:
        check(
            verify_idx < upload_idx,
            f"{rel} must verify the DMG BEFORE uploading the release asset",
        )


def check_self_test_wired() -> None:
    """ci.yml must run the verifier's --self-test on a macOS runner, so the
    runtime tamper-rejection proof actually executes in CI."""
    if not CI_WF.exists():
        FAILURES.append(f"missing workflow: {CI_WF.relative_to(ROOT)}")
        return
    lines = CI_WF.read_text(encoding="utf-8").splitlines()
    needle = "verify-released-app-bundle.sh --self-test"
    _, job_lines = job_block_containing(lines, needle)
    check(
        bool(job_lines),
        ".github/workflows/ci.yml must run "
        "scripts/verify-released-app-bundle.sh --self-test (a macOS job) so the "
        "verifier's runtime tamper-rejection behavior is proven in CI",
    )
    if not job_lines:
        return

    runs_on = [line.strip() for line in job_lines if line.strip().startswith("runs-on:")]
    check(
        any("macos" in line.lower() for line in runs_on),
        ".github/workflows/ci.yml must run "
        "scripts/verify-released-app-bundle.sh --self-test on a macOS runner",
    )


def main() -> int:
    check_script()
    check_self_test_wired()
    check_workflow(
        RELEASE_WF,
        dmg_name="cmux-macos.dmg",
        staple_anchor='stapler staple "$DMG_RELEASE"',
        upload_anchor="Upload release asset",
    )
    check_workflow(
        NIGHTLY_WF,
        dmg_name="cmux-nightly-macos.dmg",
        staple_anchor='stapler staple "$dmg_release"',
        upload_anchor="Upload branch nightly artifacts",
    )

    if FAILURES:
        print("FAIL: released-DMG signature gate guard found problems:")
        for failure in FAILURES:
            print(f"  - {failure}")
        return 1
    print("OK: release and nightly pipelines verify the shipped DMG end-to-end")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
