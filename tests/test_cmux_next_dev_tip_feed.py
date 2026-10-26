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
check("needs.sign.outputs.build != ''" in tip.split("steps:")[0], "only a stamped build gets a tip DMG")
check('[[ "$app_key" == "$signing_key" ]]' in tip, "the feed key must be the key the app in the DMG trusts")
check("generate_appcast did not add edSignature" in tip, "the sign_update fallback never publishes")
check(tip.index('[[ "$app_key" == "$signing_key" ]]') < tip.index("./scripts/sparkle_generate_appcast.sh"),
      "the key is checked before the feed is generated")
check(tip.split("needs:")[0].count("continue-on-error: true") == 1,
      "a red tip job never makes the dispatcher re-publish the same source run")
sign = workflow[workflow.index("\n  sign:\n"):workflow.index("\n  verify:\n")]
verify = workflow[workflow.index("\n  verify:\n"):workflow.index("\n  publish:\n")]
# The signer runs on Linux (rcodesign): no keychain, no DMG and no notarization there.
check("runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}" in sign
      and "./scripts/ci/rcodesign-sign-bundle-dev.sh" in sign, "the sign job signs on Linux with rcodesign")
sign_code = "\n".join(line for line in sign.splitlines() if not line.lstrip().startswith("#"))
check(all(word not in sign_code for word in ("keychain", "notarytool", "--no-wait", "hdiutil", "/usr/bin/", "PlistBuddy", "swift ")),
      "the sign job uses no keychain, macOS tool or notarization")
check(all(line.strip().startswith("[[ -n") for line in sign_code.splitlines() if "$NIGHTLY_SPARKLE_PRIVATE_KEY" in line)
      and "sparkle-public-key NIGHTLY_SPARKLE_PRIVATE_KEY" in sign,
      "the Sparkle private key reaches the key derivation by environment, never on a command line")
check("notary_id" not in workflow, "the tip job makes its own notarization submission")
# The tip job builds, signs and submits the DMG, with a keychain it deletes before notarizing.
steps = [tip.find(marker) for marker in (
    "name: Download the signed app\n", "codesign --verify --deep --strict", "-format ULMO",
    "signing-keychain.sh create", "codesign --force --timestamp --keychain", "signing-keychain.sh delete",
    "notarytool submit", 'notarytool wait "$id"', "xcrun stapler staple", "./scripts/sparkle_generate_appcast.sh")]
check(-1 not in steps and steps == sorted(steps), "tip: unpack and codesign the signed app, build the DMG, sign it, delete the keychain, then notarize")
check(tip.count("if: always()") >= 2, "the tip job deletes its keychain whatever happens")
publish = workflow[workflow.index("\n  publish:\n"):workflow.index("\n  tip:\n")]
# Apple's codesign runs in verify now, so publish and tip ship only what verify passed. A skipped
# or cancelled verify has empty outputs and a result other than success: both block.
for job, label in ((publish, "publish"), (tip, "tip")):
    head = job.split("steps:")[0]
    check("needs: [sign, verify]" in head and "needs.verify.result == 'success'" in head
          and "needs.verify.outputs.verified == 'true'" in head and "needs.sign.result == 'success'" in head,
          f"{label} needs verify to succeed with verified 'true'")
runner = workflow[workflow.index("\n  runner:\n"):workflow.index("\n  verify:\n")]
check("python3 scripts/ci/e2e_runner_pool.py" in runner and "--queue-rounds" not in runner
      and "glaeda-*) ;;" in runner and "environment:" not in runner,
      "the placement job offers an owned Mac only when one is free now, and no other label")
check(runner.count("github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && github.run_attempt == 1") == 3,
      "only main's own first attempt is offered an owned Mac")
check("name: owned-pool-watch" in runner and "name: macos-pool-persistent-${{ github.run_id }}" in runner,
      "an owned pick uploads the rescue markers")
check("verified: ${{ steps.check.outputs.verified }}" in verify
      and verify.rstrip().count('echo "verified=true" >> "$GITHUB_OUTPUT"') == 1
      and verify.index("codesign --verify --deep --strict") < verify.index("verify_signed_dev_app.py")
      < verify.index("--require-signed") < verify.index('echo "verified=true"'),
      "verify says verified only after codesign, the signature checks and the sidecar passed")
check("tip" not in publish.split("needs:")[1].split("\n")[0], "the rolling prerelease never waits for the tip feed")
# Freshness (2026-10-26: nothing published for six hours): the signer never waits on the 12 vCPU
# macOS label, and no shared group evicts a newer handoff while a signer waits.
check(all("12vcpu" not in line for job in (sign, tip) for line in job.splitlines() if line.strip().startswith("runs-on:")),
      "sign and tip never queue on blacksmith-12vcpu-macos-26")
check("concurrency:" not in sign.split("steps:")[0], "no concurrency group evicts a newer DEV handoff while a signer waits")
check("concurrency:" in tip.split("steps:")[0] and "concurrency:" in publish,
      "the feed and the prerelease keep one writer each")
# CMUX_TIMESTAMP=none makes the Linux signer drop the time stamp and the Developer ID check
# (scripts/ci/rcodesign-sign-bundle-dev.sh); the publisher must never set it.
check("CMUX_TIMESTAMP" not in workflow, "the DEV workflow never sets CMUX_TIMESTAMP")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: cmux NEXT DEV tip feed")
