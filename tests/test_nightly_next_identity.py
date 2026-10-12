#!/usr/bin/env python3
"""nightly-next ships as cmux NEXT, beside classic NIGHTLY (cx-x7hwx).

Both tracks shipped as cmux NIGHTLY (com.cmuxterm.app.nightly), so installing
one replaced the other. nightly-next is now a tagged-nightly identity: its own
app name, bundle id, socket, daemon session, sign-in scheme and feed, signed
without a provisioning profile, still auto-updating.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/nightly.yml").read_text()


def identity_block() -> str:
    match = re.search(r"\n\s*'nightly-next': \{\n(.*?)\n\s*\},", WORKFLOW, re.S)
    assert match, "no nightly-next channelIdentity"
    return match.group(1)


def field(block: str, name: str) -> str:
    match = re.search(rf"{name}: ([^,\n]+),", block)
    assert match, f"no {name}"
    return match.group(1).strip().strip("'")


def env_value(name: str) -> str:
    match = re.search(rf"\n  {name}: (\S+)\n", WORKFLOW)
    assert match, f"no env {name}"
    return match.group(1)


def test_next_has_its_own_identity():
    block = identity_block()
    assert field(block, "bundleId") == "com.cmuxterm.app.nightly.cmux-next"
    assert field(block, "appName") == "cmux NEXT"
    assert field(block, "urlScheme") == "cmux-next"
    assert field(block, "dmgPrefix") == "cmux-nightly-next-macos"


def test_next_signs_without_a_provisioning_profile():
    entitlements = field(identity_block(), "entitlements")
    with open(ROOT / entitlements, "rb") as handle:
        keys = plistlib.load(handle)
    for restricted in ("com.apple.application-identifier", "keychain-access-groups",
                       "com.apple.developer.web-browser.public-key-credential"):
        assert restricted not in keys, f"{entitlements} requests {restricted}, which needs a profile"
    assert "core.setOutput('profile_channel', notaryProbe ? 'RELEASE' : track === 'nightly-next' ? '' :" in WORKFLOW
    assert "if: needs.decide.outputs.profile_channel != ''" in WORKFLOW
    assert "core.setOutput('sign_channel', notaryProbe ? 'stable' : track === 'nightly-next' ? 'next' : channel);" in WORKFLOW


def test_next_signs_in_through_its_own_scheme():
    assert 'Add :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME string ${CHANNEL_URL_SCHEME}' in WORKFLOW


def test_next_feed_is_new_and_still_classified_as_nightly_next():
    base = env_value("NIGHTLY_NEXT_FEED_BASE")
    legacy = env_value("NIGHTLY_NEXT_LEGACY_FEED_BASE")
    # UpdateFeedResolver classifies the track by "/nightly-next/" in the feed URL.
    assert "/nightly-next/" in base + "/" and base != legacy
    assert env_value("NIGHTLY_NEXT_R2_PREFIX") == "nightly-next/next/"
    # Every build-number check keeps NEXT above the old feed and classic NIGHTLY,
    # and tolerates the new feed before its first publication.
    checks = re.findall(r'feeds\+=\(([^)]*)\)', WORKFLOW)
    next_checks = [c for c in checks if "NIGHTLY_NEXT_FEED_BASE" in c]
    assert next_checks
    for check in next_checks:
        assert '--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}"' in check, check
        assert '--feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}"' in check, check
        assert '--feed "https://files.cmux.com/nightly/${appcast}"' in check, check


def test_packaging_scripts_know_the_next_channel():
    metadata = (ROOT / "scripts/verify-app-bundle-channel-metadata.sh").read_text()
    assert re.search(r'next\)\n\s*EXPECTED_NAME="cmux NEXT"\n\s*EXPECTED_BUNDLE_ID="com.cmuxterm.app.nightly.cmux-next"', metadata)
    notarize = (ROOT / "scripts/ci/notarize-nightly-dmg.sh").read_text()
    assert 'next) ENTITLEMENTS_NAME="cmux.next-dev.entitlements"' in notarize


def test_a_pending_notarization_keeps_its_recovery_artifact():
    # notarize-nightly-dmg.sh records CMUX_CHANNEL (sign_channel, `next`) in the
    # state file; the recovery artifact must compare against that, not the
    # release channel, or a submission past the wait is stranded.
    step = WORKFLOW[WORKFLOW.index("- name: Prepare pending notarization recovery artifact"):]
    step = step[:step.index("\n      - name:", 10)]
    assert '"${{ needs.decide.outputs.sign_channel }}"' in step
    assert 'state["channel"] != sign_channel' in step


def test_release_notes_history_carries_over_from_the_old_feed():
    assert 'for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}"; do' in WORKFLOW


def main() -> int:
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except Exception as error:  # noqa: BLE001 - report every failure
            failed += 1
            print(f"FAIL {name}: {error!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
