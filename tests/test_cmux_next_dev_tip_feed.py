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
check("concurrency:" not in tip and "cancel-in-progress" not in tip, "a newer tip build never cancels or evicts another")
check(tip.index("notarytool submit") < tip.index("./scripts/sparkle_generate_appcast.sh"), "the DMG is notarized before the feed names it")
uploads = tip[tip.index("Upload the tip feed to R2"):]
check(uploads.index("upload \"tip-new/") < uploads.index("r2_cas.py put"),
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
# Freshness (2026-10-26: nothing published for six hours): the signer never waits on the 12 vCPU
# macOS label, and no shared group evicts a newer handoff while a signer waits.
check(all("12vcpu" not in line for job in (sign, tip) for line in job.splitlines() if line.strip().startswith("runs-on:")),
      "sign and tip never queue on blacksmith-12vcpu-macos-26")
check("concurrency:" not in sign.split("steps:")[0], "no concurrency group evicts a newer DEV handoff while a signer waits")
# No group anywhere in the publisher (a group replaces a pending run): the newest write wins instead.
check("concurrency:" not in workflow, "no concurrency group in the DEV publisher evicts a pending run")
upload = tip[tip.index("Upload the tip feed to R2"):]
# Codex (2026-10-26): a retry after the write cannot stop a rollback; the write itself is conditional.
check(upload.index("r2_cas.py get") < upload.index("tip_feed.py newest") < upload.index("r2_cas.py put")
      and '--if-match "$etag"' in upload and "(( rc == 3 )) || exit" in upload
      and 'upload "tip-out/$TIP_APPCAST"' not in upload,
      "the tip feed is written only by a compare-and-swap on the feed this run read")
lease = publish.index("r2_cas.py lock")
check(lease < publish.index("not_newer && exit 0") < publish.index("\n          write\n") and "r2_cas.py unlock" in publish,
      "publish checks and writes the release inside the R2 lease")
check("timeout-minutes: 30" in publish and "--ttl 2100" in publish,
      "the publish lease outlives the job, so it is never taken from a run still writing")
check("|| exit 1" in publish and "exit 1 ;;" in publish, "an unreadable release or compare fails publish instead of writing")
check(tip_feed.newest(feed(30, 50, 40)) == 50 and tip_feed.newest(feed()) == 0, "newest reads the feed's newest build")


# The lease against an in-memory R2, and the conditions the writes send.
import io
import os
import urllib.error

spec = importlib.util.spec_from_file_location("r2_cas", ROOT / "scripts/ci/r2_cas.py")
r2_cas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2_cas)
os.environ.update(AWS_ACCESS_KEY_ID="test", AWS_SECRET_ACCESS_KEY="test", R2_ENDPOINT="https://r2.invalid", R2_BUCKET="b")
sent = []
def fake_open(request, *, timeout):
    sent.append({name.lower(): value for name, value in request.header_items()})
    raise urllib.error.HTTPError(request.full_url, 412, "Precondition Failed", {}, io.BytesIO())
real_open, r2_cas.r2._open_signed_request = r2_cas.r2._open_signed_request, fake_open
check(not r2_cas.put("k", b"x", etag='"7"', cache_control="no-store", content_type="text/plain")
      and sent[-1].get("if-match") == '"7"', "a feed write sends If-Match and reports a lost race")
check(not r2_cas.put("k", b"x", etag=None, cache_control="no-store", content_type="text/plain")
      and sent[-1].get("if-none-match") == "*", "a first write sends If-None-Match: *")
r2_cas.r2._open_signed_request = real_open

store, version = {}, [0]
def fake_get(key):
    return store.get(key, (None, b""))
def fake_put(key, body, *, etag, cache_control, content_type):
    if store.get(key, (None,))[0] != etag:
        return False
    version[0] += 1
    store[key] = (f'"{version[0]}"', body)
    return True
def fake_delete(key, etag):
    return store.get(key, (None,))[0] == etag and store.pop(key) is not None
r2_cas.get, r2_cas.put, r2_cas.delete = fake_get, fake_put, fake_delete
now = [1000.0]
clock, sleep = (lambda: now[0]), (lambda seconds: now.__setitem__(0, now[0] + seconds))
check(r2_cas.lock("l", "a", 60, 0, clock, sleep), "the first publisher takes the free lease")
check(not r2_cas.lock("l", "b", 30, 30, clock, sleep), "a second publisher waits while the lease is live")
check(not r2_cas.unlock("l", "b") and "l" in store, "only the holder releases the lease")
now[0] += 60
check(r2_cas.lock("l", "b", 60, 0, clock, sleep), "an expired lease is taken over")
check(not r2_cas.unlock("l", "a") and r2_cas.unlock("l", "b") and "l" not in store, "the holder releases its own lease")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: cmux NEXT DEV tip feed")
