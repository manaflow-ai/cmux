#!/usr/bin/env python3
"""nightly-next ships once, as cmux NIGHTLY (com.cmuxterm.app.nightly), on one feed.

Leo, 2026-11-05: "THERE SHOULDN'T BE 2". The track built cmux NEXT
(com.cmuxterm.app.nightly.cmux-next, its own feed in /nightly-next/next/) and then
signed every build a second time as cmux NIGHTLY for the old feed, the app the team
runs (hq#7156). Now each build is signed once, as cmux NIGHTLY with its Developer ID
profile and keychain group, and published to the feed that app polls
(/nightly-next/). The retired cmux NEXT-identity feed gets no builds, only a signed
handover card in its notes.
"""
from __future__ import annotations

from pathlib import Path
import json
import plistlib
import re
import sys
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = nightly_text()
HOST = "https://files-next.cmux.com/"


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


def test_nightly_next_ships_as_cmux_nightly():
    block = identity_block()
    assert field(block, "bundleId") == "com.cmuxterm.app.nightly"
    assert field(block, "appName") == "cmux NIGHTLY"
    assert field(block, "urlScheme") == "cmux-nightly"
    assert field(block, "dmgPrefix") == "cmux-nightly-next-macos"
    assert field(block, "releaseTag") == "nightly-next"


def test_it_signs_with_the_nightly_profile_and_keychain_group():
    entitlements = field(identity_block(), "entitlements")
    assert entitlements == "cmux.nightly.entitlements"
    with open(ROOT / entitlements, "rb") as handle:
        keys = plistlib.load(handle)
    assert keys["com.apple.application-identifier"] == "7WLXT3NR37.com.cmuxterm.app.nightly"
    assert keys["keychain-access-groups"] == ["7WLXT3NR37.com.cmuxterm.app.nightly"]
    assert keys["com.apple.developer.web-browser.public-key-credential"] is True
    assert ("core.setOutput('profile_channel', nightlyProbe ? 'NIGHTLY' : notaryProbe ? 'RELEASE' : "
            "track === 'nightly-next' ? 'NIGHTLY' :") in WORKFLOW
    assert ("core.setOutput('sign_channel', nightlyProbe ? 'nightly' : notaryProbe ? 'stable' : "
            "track === 'nightly-next' ? 'nightly' : channel);") in WORKFLOW
    # The profile step embeds APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 and refuses one for another App ID.
    step = WORKFLOW[WORKFLOW.index("- name: Embed channel provisioning profile"):]
    step = step[:step.index("\n      - ", 10)]
    assert "if: needs.decide.outputs.profile_channel != ''" in step
    assert "needs.decide.outputs.profile_channel == 'NIGHTLY' && secrets.APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64" in step
    embed = (ROOT / "scripts/ci/nightly-steps/embed-provisioning-profile.sh").read_text()
    assert 'if [ "$APP_ID" != "7WLXT3NR37.${CHANNEL_BUNDLE_ID}" ]; then' in embed
    # The packaging scripts sign and check the nightly channel with these entitlements.
    notarize = (ROOT / "scripts/ci/notarize-nightly-dmg.sh").read_text()
    assert 'CHANNEL="${CMUX_CHANNEL:-nightly}"' in notarize


def test_it_signs_in_through_the_nightly_scheme():
    # cmux NEXT set its own LSEnvironment sign-in scheme; cmux NIGHTLY takes the default one for its id.
    assert "Add :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME" not in WORKFLOW


def test_one_feed_and_the_retired_feed_only_keeps_its_metadata():
    base = env_value("NIGHTLY_NEXT_FEED_BASE")
    # UpdateFeedResolver classifies the track by "/nightly-next/" in the feed URL.
    assert base == HOST + "nightly-next" and "/nightly-next/" in base + "/"
    assert env_value("NIGHTLY_NEXT_R2_PREFIX") == "nightly-next/"
    assert "NIGHTLY_NEXT_LEGACY_FEED_BASE" not in WORKFLOW
    # The verdicts and pulled.json stay where the app reads them (UpdaterService.channelFolder).
    assert env_value("NIGHTLY_NEXT_VERDICTS_BASE") == env_value("NIGHTLY_NEXT_RETIRED_FEED_BASE") == HOST + "nightly-next/next"
    assert env_value("NIGHTLY_NEXT_RETIRED_R2_PREFIX") == "nightly-next/next/"
    for ring in re.findall(r"--verdicts-base \S+", WORKFLOW):
        assert "NIGHTLY_NEXT_VERDICTS_BASE" in ring, ring
    # Every build-number check reads the one feed and classic NIGHTLY, never the retired feed.
    checks = re.findall(r'feeds\+=\(([^)]*)\)', WORKFLOW)
    next_checks = [c for c in checks if "NIGHTLY_NEXT_FEED_BASE" in c]
    assert next_checks
    for check in next_checks:
        assert check.strip() == ('--feed "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" '
                                 '--feed "https://files.cmux.com/nightly/${appcast}"'), check


def test_packaging_scripts_know_the_next_channel():
    metadata = (ROOT / "scripts/verify-app-bundle-channel-metadata.sh").read_text()
    assert re.search(r'nightly\)\n\s*EXPECTED_NAME="cmux NIGHTLY"\n\s*EXPECTED_BUNDLE_ID="com.cmuxterm.app.nightly"\n', metadata)


def test_a_pending_notarization_keeps_its_recovery_artifact():
    # notarize-nightly-dmg.sh records CMUX_CHANNEL (sign_channel) in the state
    # file; the recovery artifact must compare against that, not the release
    # channel, or a submission past the wait is stranded.
    step = WORKFLOW[WORKFLOW.index("- name: Prepare pending notarization recovery artifact"):]
    step = step[:step.index("\n      - name:", 10)]
    assert "SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}" in step
    assert '"$SIGN_CHANNEL" <<' in step
    assert 'state["channel"] != sign_channel' in step


def test_release_notes_history_reads_the_feed_then_the_retired_one():
    assert 'for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_RETIRED_FEED_BASE}"; do' in WORKFLOW


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
    value = match.group(1)
    # A YAML anchor (`&name value`) or alias (`*name`, #30278 shares env values to keep nightly.yml
    # under GitHub's size limit) reads as the anchored value, as YAML does.
    alias = re.fullmatch(r"\*([A-Za-z0-9_-]+)", value)
    if alias:
        anchors = re.findall(rf"[ :]&{re.escape(alias[1])} ([^\n]+)\n", WORKFLOW)
        assert len(anchors) == 1, f"alias *{alias[1]} has {len(anchors)} anchors"
        value = anchors[0]
    return re.sub(r"^&[A-Za-z0-9_-]+ ", "", value)


def test_each_app_reads_the_feed_its_publisher_writes():
    # Leo, 2026-10-25: "but where are the nightlies?" An app whose SUFeedURL names a
    # feed no job writes never updates.
    host = HOST
    next_base = env_value("NIGHTLY_NEXT_FEED_BASE")
    # SUFeedURL is feedBase/appcast-<variant>.xml; the upload writes
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


LEGACY_JOBS = ("legacy-identity-target", "sign-nightly-identity-legacy", "verify-nightly-identity-legacy",
               "publish-nightly-identity-legacy", "nightly-identity-legacy-published")


def test_each_build_is_signed_once():
    jobs = re.findall(r"\n  ([a-z0-9-]+):\n", WORKFLOW)
    for name in LEGACY_JOBS:
        assert name not in jobs, f"the second signing's job {name} is back"
        assert name not in WORKFLOW, name
    main = job_block("build-sign-notarize-nightly")
    assert "cmux NIGHTLY identity: " not in main and "LEGACY_" not in main and "legacy_" not in main
    # The copy's 160 extra minutes are gone with it.
    assert "    timeout-minutes: ${{ needs.decide.outputs.notary_test == 'true' && 235 || 160 }}\n" in main
    assert "vars.NIGHTLY_NEXT_LEGACY_IDENTITY" not in WORKFLOW


def test_the_rolling_name_and_release_push_follow_the_one_feed():
    names = (ROOT / "scripts/ci/nightly-steps/github-names-publish-rolling-name.sh").read_text()
    assert '--immutable "$dmg" --alias "$rolling"' in names
    # ReleasePushListener subscribes the cmux NIGHTLY feed as nightly-next-legacy.
    assert "RELEASE_POKE_URL: https://presence.cmux.dev/releases/v1/poke?feed=nightly-next-legacy\n" in WORKFLOW
    assert "poke?feed=nightly-next\n" not in WORKFLOW
    listener = (ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/ReleasePushListener.swift").read_text()
    assert f'"{HOST}nightly-next/appcast-arm64.xml": "nightly-next-legacy"' in listener


def test_the_retired_feed_gets_a_signed_handover_card_and_no_build():
    # Sparkle never installs another bundle id, and the app has no informational update (a higher item
    # with no enclosure would take the install path), so a stray cmux NEXT install reads where its
    # builds went from the one feed-side message it shows: <feed folder>/notes/announcements.json.
    card = json.loads((ROOT / "release-notes/next/retired-feed-announcements.json").read_text())
    assert card["version"] == 1 and len(card["items"]) == 1
    item = card["items"][0]
    assert set(item) <= {"id", "title", "detail", "action", "minBuild", "maxBuild", "startsAt", "expiresAt"}
    assert "cmux NIGHTLY" in item["title"] and "cmux.com/next" in item["detail"]
    assert "http" not in json.dumps(card), "an announcement carries no URL"
    sign = (ROOT / "scripts/ci/nightly-steps/release-notes-sign.sh").read_text()
    assert "cp release-notes/next/retired-feed-announcements.json notes/retired-feed-announcements.json" in sign
    assert "signed+=(notes/retired-feed-announcements.json)" in sign
    assert sign.index("signed+=(notes/retired-feed-announcements.json)") < sign.index('release-notes.py sign --key "$key"')
    upload = (ROOT / "scripts/ci/nightly-steps/release-notes-upload-to-r2.sh").read_text()
    assert "retired-feed-*) continue ;;" in upload
    assert 'key="${NIGHTLY_NEXT_RETIRED_R2_PREFIX:?}notes/announcements.json$suffix"' in upload
    # Nothing writes an appcast under the retired prefix.
    assert not re.search(r"NIGHTLY_NEXT_RETIRED_R2_PREFIX[^\n]*appcast", WORKFLOW + upload)


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
