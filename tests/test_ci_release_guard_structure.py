#!/usr/bin/env python3
"""Structural contract for parallel release guard ownership."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD_WORKFLOW = ROOT / ".github" / "workflows" / "ci-guards.yml"


def workflow_job_block(job_name: str) -> str:
    lines = GUARD_WORKFLOW.read_text(encoding="utf-8").splitlines()
    marker = f"  {job_name}:"
    for index, line in enumerate(lines):
        if line != marker:
            continue
        body = [line]
        for following in lines[index + 1 :]:
            if (
                following.startswith("  ")
                and not following.startswith("    ")
                and following.strip()
            ):
                break
            body.append(following)
        return "\n".join(body)
    raise AssertionError(f"{job_name} job not found")


def test_release_groups_are_parallel_and_owned() -> None:
    block = workflow_job_block("workflow-guard-tests")

    assert "group: ${{ fromJSON(inputs.linux_guard_test_groups) }}" in block

    expected = {
        "Validate TestFlight notes generator": "release-ios",
        "Validate CMUX INTERNAL main-push path filter": "release-ios",
        "Validate external TestFlight group assignment helper": "release-ios",
        "Validate Pro TestFlight distribution workflow": "release-ios",
        "Validate iOS App Store lane identity": "release-ios",
        "Validate tagged iOS device entitlement fallback": "release-ios",
        "Validate release does not gate on iOS screenshot capture": "release-ios",
        "Validate release tunnel extension identifiers": "release-ios",
        "Validate create-dmg version pinning": "release-notary",
        "Validate app bundle license compliance": "release-notary",
        "Validate nightly API tag finalization": "release-notary",
        "Validate nightly Xcode selection": "release-notary",
        "Validate CI Xcode selection fast path": "release-notary",
        "Validate resumable GitHub release publication": "release-notary",
        "Validate universal nightly workflow": "release-notary",
        "Validate nightly push throttle": "release-notary",
        "Validate nightly notarization behavior": "release-notary",
        "Validate Sparkle delta finalization": "release-notary",
        "Validate previous nightly build fetch": "release-notary",
        "Validate Computer Use helper notarization behavior": "release-notary",
        "Validate release asset guard": "release-notary",
        "Validate release-build timeout guard": "release-notary",
        "Validate Sparkle monotonic guard modes": "release-notary",
        "Validate Sparkle appcast generation without previous archives": "release-notary",
        "Validate markdown viewer asset compression": "release-notary",
        "Validate release bundle stripping": "release-notary",
        "Validate Swift warning budget guard": "release-notary",
        "Validate Ghostty helper cache failure handling": "release-tooling",
        "Validate Release check architectures": "release-tooling",
        "Validate nightly prune Python compatibility": "release-tooling",
        "Validate GhosttyKit checksum verification": "release-tooling",
        "Validate stalled GhosttyKit downloads resume": "release-tooling",
        "Validate GhosttyKit release check behavior": "release-tooling",
        "Validate Zig install without sudo": "release-tooling",
        "Validate Zig download resume and mirror isolation": "release-tooling",
        "Initialize Ghostty for Zig version guard": "release-tooling",
        "Validate Ghostty Zig version synchronization": "release-tooling",
        "Validate cmux-tui client installation": "release-tooling",
        "Validate Python R2 appcast upload guard": "release-tooling",
        "Validate current GhosttyKit checksum pin": "release-tooling",
    }
    for step, group in expected.items():
        marker = (
            f"- name: {step}\n"
            f"        if: ${{{{ matrix.group == '{group}' }}}}"
        )
        assert marker in block, (step, group)

    assert "matrix.group == 'release'" not in block


if __name__ == "__main__":
    test_release_groups_are_parallel_and_owned()
    print("PASS: release guard structure")
