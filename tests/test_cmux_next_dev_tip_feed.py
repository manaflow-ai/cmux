#!/usr/bin/env python3
"""The cmux NEXT DEV tip feed: rollback guard, delta bases, feed check, and
the publisher steps that stamp and publish it."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tip_feed", ROOT / "scripts/ci/tip_feed.py")
tip_feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tip_feed)

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


def feed(*entries, channel=None, signed=True, host="https://files.cmux.com/nightly-next/tip/"):
    body = []
    for build in entries:
        tag = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
        signature = ' sparkle:edSignature="c2ln"' if signed else ""
        body.append(
            f"<item><title>{build}</title><sparkle:version>{build}</sparkle:version>{tag}"
            f'<enclosure url="{host}cmux-NEXT-DEV-{build}.dmg" length="1"{signature} type="application/octet-stream"/>'
            f"</item>"
        )
    xml = (
        '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        f"<channel>{''.join(body)}</channel></rss>"
    )
    handle = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
    handle.write(xml)
    handle.close()
    return handle.name


prefix = "https://files.cmux.com/nightly-next/tip/cmux-NEXT-DEV-"
check(tip_feed.previous(feed(30, 10, 20), 40, 3) == ["fresh", f"{prefix}30.dmg", f"{prefix}20.dmg"],
      "a newer build takes the two newest items as delta bases")
check(tip_feed.previous(feed(30), 30, 3) == ["stale 30"], "the same build never republishes")
check(tip_feed.previous(feed(30), 20, 3) == ["stale 30"], "an older build never rolls the feed back")
check(tip_feed.previous(feed(30, host="https://example.com/"), 40, 3) == ["fresh"],
      "a base outside the tip prefix is never fetched")
check(tip_feed.check(feed(40, 30), 40) == [], "a signed, untagged tip feed passes")
check(tip_feed.check(feed(30, 40), 30) != [], "a feed whose newest item is another build fails")
check(tip_feed.check(feed(40, signed=False), 40) != [], "an unsigned item fails")
check(tip_feed.check(feed(40, channel="cmux-next-dev"), 40) != [], "a ring tag fails: tip items stay untagged")

workflow = (ROOT / ".github/workflows/cmux-next-dev-daily.yml").read_text()
check("TIP_FEED_URL: https://files.cmux.com/nightly-next/tip/appcast-arm64.xml" in workflow,
      "the sign job stamps the tip feed")
stamp = workflow.index("Stamp the tip feed, its key and a build number")
check(stamp < workflow.index("Sign and verify cmux NEXT DEV"), "the stamp happens before signing")
check("secrets.NIGHTLY_SPARKLE_PRIVATE_KEY" in workflow and "secrets.SPARKLE_NEXT_PRIVATE_KEY" not in workflow,
      "the tip feed uses the release environment's NIGHTLY Sparkle key")
tip = workflow[workflow.index("\n  tip:\n"):]
check("environment: release" in tip, "the tip job runs in the existing release environment")
check("cancel-in-progress: false" in tip, "a newer tip build never cancels a running one")
check(tip.index("notarytool submit") < tip.index("./scripts/sparkle_generate_appcast.sh"), "the DMG is notarized before the feed names it")
uploads = tip[tip.index("Upload the tip feed to R2"):]
check(uploads.index("upload \"tip-new/") < uploads.index("upload \"tip-out/$TIP_APPCAST\""),
      "archives upload before the feed that names them")
check("TIP_APP_FLOOR_SHA: df21458196edaaf3de5192da56ecd2a315aacae7" in workflow
      and 'compare/$TIP_APP_FLOOR_SHA...$SOURCE_SHA' in workflow,
      "a source from before the tip app (#24954) gets no tip feed")
check("if: steps.stamp.outputs.build != ''" in workflow, "only a stamped build uploads a tip DMG")
check('[[ "$app_key" == "$signing_key" ]]' in tip, "the feed key must be the key the app in the DMG trusts")
check("generate_appcast did not add edSignature" in tip, "the sign_update fallback never publishes")
check(tip.index('[[ "$app_key" == "$signing_key" ]]') < tip.index("./scripts/sparkle_generate_appcast.sh"),
      "the key is checked before the feed is generated")
check(tip.split("needs:")[0].count("continue-on-error: true") == 1,
      "a red tip job never makes the dispatcher re-publish the same source run")
sign = workflow[workflow.index("\n  sign:\n"):workflow.index("\n  verify:\n")]
early = sign[sign.index("Submit the tip DMG for notarization"):]
check("--no-wait" in early and "continue-on-error: true" in early.split("run: |")[0],
      "the sign job submits the tip DMG without waiting, and a failed submit never fails signing")
check(sign.index("Upload the signed tip DMG") < sign.index("Submit the tip DMG for notarization"),
      "the early submit runs after the DMG is uploaded, so it never delays the tip artifact")
check("notary_id: ${{ steps.notary.outputs.id }}" in sign, "the sign job hands its submission id to the tip job")
check("EARLY_NOTARY_ID: ${{ needs.sign.outputs.notary_id }}" in tip and 'notarytool wait "$id"' in tip,
      "the tip job waits for the early submission")
check(tip.index('notarytool wait "$id"') < tip.index("notarytool submit") < tip.index("xcrun stapler staple"),
      "the tip job submits itself only when the early submission could not be read, before stapling")
publish = workflow[workflow.index("\n  publish:\n"):workflow.index("\n  tip:\n")]
check("tip" not in publish.split("needs:")[1].split("\n")[0], "the rolling prerelease never waits for the tip feed")
# Freshness (2026-10-26: nothing published for six hours): the signer and the tip feed never wait
# on a Blacksmith macOS queue, and no shared group evicts a newer handoff while a signer waits.
check("runs-on: macos-26\n" in sign and "runs-on: macos-26\n" in tip, "sign and tip run on hosted macos-26")
check(all("blacksmith" not in line for job in (sign, tip) for line in job.splitlines() if line.strip().startswith("runs-on:")),
      "sign and tip take no Blacksmith macOS label")
check("concurrency:" not in sign.split("steps:")[0], "no concurrency group evicts a newer DEV handoff while a signer waits")
check("concurrency:" in tip.split("steps:")[0] and "concurrency:" in publish,
      "the feed and the prerelease keep one writer each")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: cmux NEXT DEV tip feed")
