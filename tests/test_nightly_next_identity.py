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
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = nightly_text()


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
    assert "SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}" in step
    assert '"$SIGN_CHANNEL" <<' in step
    assert 'state["channel"] != sign_channel' in step


def test_release_notes_history_carries_over_from_the_old_feed():
    assert 'for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}"; do' in WORKFLOW


def job_block(name: str) -> str:
    match = re.search(rf"\n  {name}:\n(.*?)(?=\n  [a-z0-9-]+:\n|\Z)", WORKFLOW, re.S)
    assert match, f"no job {name}"
    return match.group(1)


def job_containing(text: str) -> str:
    at = WORKFLOW.index(text)
    name = re.findall(r"\n  ([a-z0-9-]+):\n", WORKFLOW[:at])[-1]
    return job_block(name)


def job_env(block: str, name: str) -> str:
    match = re.search(rf"\n      {name}: ([^\n]+)\n", block)
    assert match, f"no job env {name}"
    return match.group(1)


def test_each_app_reads_the_feed_its_publisher_writes():
    # Leo, 2026-10-25: "but where are the nightlies?" cmux NIGHTLY checks the old
    # feed; an app whose SUFeedURL names a feed no job writes never updates.
    host = "https://files-next.cmux.com/"
    next_base = env_value("NIGHTLY_NEXT_FEED_BASE")
    legacy_base = env_value("NIGHTLY_NEXT_LEGACY_FEED_BASE")
    # cmux NEXT: SUFeedURL is feedBase/appcast-<variant>.xml; the upload writes
    # NIGHTLY_NEXT_R2_PREFIX + each of the track's feeds, served from the same path.
    assert field(identity_block(), "feedBase") == "process.env.NIGHTLY_NEXT_FEED_BASE"
    # The signing job hands prepare_variant decide's feedBase, and prepare_variant
    # writes its third argument into SUFeedURL.
    builder = job_containing("          prepare_variant \\\n")
    assert job_env(builder, "CHANNEL_FEED_BASE") == "${{ needs.decide.outputs.feed_base }}"
    assert "\n      feed_base: ${{ steps.decide.outputs.feed_base }}\n" in job_block("decide")
    assert "core.setOutput('feed_base', channelIdentity.feedBase);" in WORKFLOW
    assert re.search(r'\n {10}prepare_variant \\\n {12}"\$APP_DIR" \\\n {12}"\$CHANNEL_BUNDLE_ID" \\\n {12}"\$\{CHANNEL_FEED_BASE\}/\$\{NIGHTLY_APPCAST\}"\n', builder)
    assert 'local feed_url="$3"' in builder and builder.count(":SUFeedURL string") == 1
    # ...and nothing reassigns the values between the checks above and their use.
    assert len(re.findall(r"\bfeed_url=", builder)) == 1
    decide = job_block("decide")
    assert len(re.findall(r"\b(?:variants|feeds)\b\s*(?:\[[^\]]*\]\s*)?(?:\.(?:push|unshift|splice|fill|reverse|sort)\b|=(?!=))", decide)) == 2
    assert 'Add :SUFeedURL string ${feed_url}"' in builder
    # The arm64 variant bakes appcast-arm64.xml (only universal keeps appcast.xml).
    assert ('          if [ "$NIGHTLY_VARIANT" = "universal" ]; then\n            NIGHTLY_APPCAST="appcast.xml"\n'
            '          else\n            NIGHTLY_APPCAST="appcast-${NIGHTLY_VARIANT}.xml"\n          fi\n') in builder
    assert builder.count("NIGHTLY_APPCAST=") == 3, "the two assignments above, and its export"
    # nightly-next builds only arm64, so it bakes and publishes only appcast-arm64.xml.
    assert "const variants = fastBuild || track === 'nightly-next' ? ['arm64'] :" in WORKFLOW
    assert "const feeds = track === 'nightly-next'\n              ? ['appcast-arm64.xml']\n" in WORKFLOW
    upload = WORKFLOW[WORKFLOW.index("- name: Upload nightly-next appcasts to R2"):]
    upload = upload[:upload.index("\n      - name:", 10)]
    # publish-nightly-next-r2.py write-feed puts nightly-out/<feed> at NIGHTLY_NEXT_R2_PREFIX + <feed>
    # in NIGHTLY_NEXT_R2_BUCKET (compare-and-swap).
    assert 'for appcast in $NIGHTLY_FEEDS; do' in upload
    assert 'publish-nightly-next-r2.py" write-feed --feed "nightly-out/$appcast"' in upload
    writer = (ROOT / "scripts/ci/publish-nightly-next-r2.py").read_text()
    assert 'key = env("NIGHTLY_NEXT_R2_PREFIX") + feed.name' in writer
    assert '"--bucket", env("NIGHTLY_NEXT_R2_BUCKET"), "--key", key' in writer
    # ...and NIGHTLY_FEEDS in that job is decide's feed list, the one checked above.
    publisher = job_containing("- name: Upload nightly-next appcasts to R2")
    assert job_env(publisher, "NIGHTLY_FEEDS") == "${{ needs.decide.outputs.feeds }}"
    assert "\n      feeds: ${{ steps.decide.outputs.feeds }}\n" in job_block("decide")
    assert "core.setOutput('feeds', feeds.join(' '));" in WORKFLOW
    assert next_base + "/" == host + env_value("NIGHTLY_NEXT_R2_PREFIX")
    # files-next.cmux.com serves this bucket; both uploaders write to it.
    assert env_value("NIGHTLY_NEXT_R2_BUCKET") == "cmux-nightly-next"
    assert len(re.findall(r"\bNIGHTLY_NEXT_R2_BUCKET\s*[:=]", WORKFLOW)) == 1
    # cmux NIGHTLY: the legacy sign job bakes LEGACY_BASE/LEGACY_APPCAST, and the
    # legacy publish job uploads that same key.
    sign = job_block("sign-nightly-identity-legacy")
    publish = job_block("publish-nightly-identity-legacy")
    assert job_env(sign, "LEGACY_APPCAST") == job_env(publish, "LEGACY_APPCAST") == "appcast-arm64.xml"
    assert sign.count("LEGACY_FEED_URL=") == 2, "one assignment, one pass to the script"
    assert 'LEGACY_FEED_URL="${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"' in sign
    # The script is handed that variable (no other value), and writes it into SUFeedURL.
    assert re.search(r'LEGACY_FEED_URL="\$LEGACY_FEED_URL" \\\n(?:\s+[A-Z_]+="[^"\n]*" \\\n)*\s+\./scripts/ci/nightly-next-legacy-identity\.sh ', sign)
    script = (ROOT / "scripts/ci/nightly-next-legacy-identity.sh").read_text()
    assert 'pb "Set :SUFeedURL $LEGACY_FEED_URL"' in script and script.count(":SUFeedURL") == 1
    assert f'prefix="${{NIGHTLY_NEXT_LEGACY_FEED_BASE#{host}}}"' in publish
    assert 'upload "legacy-out/$LEGACY_APPCAST" "$prefix/$LEGACY_APPCAST"' in publish
    # upload() puts its file at its second argument, the key checked above.
    assert publish.count("--key ") == 1 and publish.count("--bucket ") == 1
    assert '--bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "$2"' in publish
    assert len(re.findall(r"\bprefix=", publish)) == 1
    for block in (sign, publish):
        assert not re.search(r"\bLEGACY_APPCAST=|\bLEGACY_FEED_URL\s*=\s*[^\"$]", block)
    assert legacy_base.startswith(host) and legacy_base != next_base
    # legacy-identity-target picks the candidate by comparing cmux NEXT's feed with this one.
    target = job_block("legacy-identity-target")
    assert '-o old-all.xml "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"' in target
    assert '-o next-all.xml "${NIGHTLY_NEXT_FEED_BASE}/${LEGACY_APPCAST}"' in target
    assert re.findall(r"\n\s+LEGACY_APPCAST: (\S+)\n", target) == ["appcast-arm64.xml"]


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
