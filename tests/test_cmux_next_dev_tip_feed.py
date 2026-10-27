#!/usr/bin/env python3
"""The cmux NEXT DEV tip feed: rollback guard, delta bases, feed check, and
the publisher steps that stamp and publish it."""

from __future__ import annotations

import importlib.util
import subprocess
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
tip_dmg_build = workflow[workflow.index("\n  tip-dmg-build:\n"):workflow.index("\n  tip-dmg:\n")]
tip_dmg = workflow[workflow.index("\n  tip-dmg:\n"):workflow.index("\n  tip:\n")]
tip = workflow[workflow.index("\n  tip:\n"):workflow.index("\n  tip-deltas:\n")]
tip_deltas = workflow[workflow.index("\n  tip-deltas:\n"):]
for job, label in ((tip_dmg, "tip-dmg"), (tip, "tip"), (tip_deltas, "tip-deltas")):
    check("environment: release" in job, f"{label} runs in the existing release environment")
    check("concurrency:" not in job and "cancel-in-progress" not in job, f"a newer tip build never cancels or evicts another ({label})")
    check("needs.sign.outputs.build != ''" in job.split("steps:")[0], f"only a stamped build gets a tip DMG ({label})")
    check(job.split("needs:")[0].count("continue-on-error: true") == 1,
          f"a red {label} job never makes the dispatcher re-publish the same source run")
# The Mac half (Leo, 2026-10-26: "I THOUGHT THESE COULD JUST GO ON LINUX"): only Apple's codesign
# check and hdiutil, with no environment and no secret.
check("environment:" not in tip_dmg_build and "secrets." not in tip_dmg_build and "keychain" not in tip_dmg_build,
      "tip-dmg-build holds no signing secret and no keychain")
check(tip_dmg_build.split("needs:")[0].count("continue-on-error: true") == 1
      and "needs.sign.outputs.build != ''" in tip_dmg_build.split("steps:")[0],
      "tip-dmg-build is advisory and runs only for a stamped build")
check(all(word not in tip_dmg_build for word in ("notarytool", "stapler", "codesign --force", "sparkle_generate_appcast")),
      "tip-dmg-build only checks the app and builds the unsigned DMG")
tip_dmg_code = "\n".join(line for line in tip_dmg.splitlines() if not line.lstrip().startswith("#"))
check(all(word not in tip_dmg_code for word in ("keychain", "xcrun", "hdiutil", "/usr/bin/", "PlistBuddy", "swift ")),
      "tip-dmg uses no macOS tool: rcodesign and Python on Linux")
check(tip_dmg.index("./scripts/ci/rcodesign-notarize-dmg-dev.sh") < tip_dmg.index("python3 scripts/ci/tip_appcast_linux.py"),
      "the DMG is signed, notarized and stapled before the feed names it")
uploads = tip[tip.index("Upload the tip feed to R2"):]
check(uploads.index("upload \"tip-new/") < uploads.index("r2_cas.py put"),
      "archives upload before the feed that names them")
check("TIP_APP_FLOOR_SHA: df21458196edaaf3de5192da56ecd2a315aacae7" in workflow
      and 'compare/$TIP_APP_FLOOR_SHA...$SOURCE_SHA' in workflow,
      "a source from before the tip app (#24954) gets no tip feed")
check('python3 scripts/ci/tip_appcast_linux.py SPARKLE_PRIVATE_KEY "tip-new/cmux-NEXT-DEV-$TIP_BUILD-$TIP_RUN_TAG.dmg"' in tip_dmg
      and '"signed-handoff/$APP_ARCHIVE_NAME" "$APP_NAME" "$DOWNLOAD_URL_PREFIX" "$RELEASE_NOTES_URL" "$TIP_BUILD"' in tip_dmg
      and "SPARKLE_PRIVATE_KEY: ${{ secrets.NIGHTLY_SPARKLE_PRIVATE_KEY }}" in tip_dmg,
      "the appcast is signed with the key named by variable, for this build, from the archive the DMG holds")
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
steps = [tip_dmg_build.find(marker) for marker in (
    "name: Download the signed app\n", "-format ULMO",
    "name: Upload the unsigned tip DMG", "name: Mark the unsigned DMG uploaded")]
check(-1 not in steps and steps == sorted(steps), "tip-dmg-build: build the DMG from the signed app, then hand it off")
steps = [tip_dmg.find(marker) for marker in (
    "name: Download the unsigned tip DMG", 'sha256sum -c "$APP_ARCHIVE_NAME.sha256"', 'cmp -s tip-unsigned/built-from.sha256',
    '"$UNSIGNED_SHA256  tip-unsigned/$TIP_DMG_NAME" | sha256sum -c -', "name: Download the signer",
    '"$SIGNER_SHA256  $signer" | sha256sum -c -', 'echo "RCODESIGN=$signer" >> "$GITHUB_ENV"',
    "./scripts/ci/rcodesign-notarize-dmg-dev.sh", "python3 scripts/ci/tip_appcast_linux.py")]
check(-1 not in steps and steps == sorted(steps),
      "tip-dmg: require the DMG tip-dmg-build made from the signed archive, then sign, notarize, staple and write the appcast")
publish = workflow[workflow.index("\n  publish:\n"):workflow.index("\n  tip:\n")]
# Apple's codesign runs in verify now, so publish and tip ship only what verify passed. A skipped
# or cancelled verify has empty outputs and a result other than success: both block.
for job, label, needs in ((publish, "publish", "needs: [sign, verify]"), (tip, "tip", "needs: [sign, verify, tip-dmg]")):
    head = job.split("steps:")[0]
    check(needs in head and "needs.verify.result == 'success'" in head
          and "needs.verify.outputs.verified == 'true'" in head and "needs.sign.result == 'success'" in head,
          f"{label} needs verify to succeed with verified 'true'")
runner = workflow[workflow.index("\n  runner:\n"):workflow.index("\n  verify:\n")]
check("python3 scripts/ci/e2e_runner_pool.py" in runner and "--queue-rounds" not in runner
      and "glaeda-*) ;;" in runner and "environment: release" in runner,
      "the placement job offers an owned Mac only when one is free now, with protected credentials")
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
check(all("12vcpu" not in line for job in (sign, tip_dmg_build, tip_dmg, tip, tip_deltas) for line in job.splitlines() if line.strip().startswith("runs-on:")),
      "sign and tip never queue on blacksmith-12vcpu-macos-26")
check("concurrency:" not in sign.split("steps:")[0], "no concurrency group evicts a newer DEV handoff while a signer waits")
# No group anywhere in the publisher (a group replaces a pending run): the newest write wins instead.
check("concurrency:" not in workflow, "no concurrency group in the DEV publisher evicts a pending run")
upload = tip[tip.index("Upload the tip feed to R2"):]
# Codex (2026-10-26): a retry after the write cannot stop a rollback; the write itself is conditional.
check(upload.index("r2_cas.py get") < upload.index("tip_feed.py newest") < upload.index("tip_feed.py merge") < upload.index("r2_cas.py put")
      and '--if-match "$etag"' in upload and "(( rc == 3 )) || exit" in upload
      and 'upload "tip-out/$TIP_APPCAST"' not in upload,
      "the tip feed is written only by a compare-and-swap on the feed this run read")
lease = publish.index("r2_cas.py lock")
check(lease < publish.index("not_newer && exit 0") < publish.index("\n          write\n") and "r2_cas.py unlock" in publish,
      "publish checks and writes the release inside the R2 lease")
publish_step = publish[publish.index("- name: Publish the rolling GitHub prerelease"):]
check("timeout-minutes: 45" in publish_step.split("run: |")[0] and "--ttl 3000" in publish_step
      and "(( wait > 900 - waited ))" in publish_step,
      "the publish lease outlives the publish step, so it is never taken from a run still writing")
check("TIP_RUN_TAG: r${{ github.run_id }}-${{ github.run_attempt }}" in tip_dmg
      and "TIP_RUN_TAG: r${{ github.run_id }}-${{ github.run_attempt }}" in tip
      and "DMG_RUN_TAG: ${{ needs.tip-dmg.outputs.run_tag }}" in tip
      and 'cmux-NEXT-DEV-$TIP_BUILD.dmg' not in tip_dmg + tip
      and "SPARKLE_DELTA_NAME_PREFIX: cmux-NEXT-DEV-tip-${{ github.run_id }}-${{ github.run_attempt }}-" in tip_deltas,
      "each tip-dmg and each tip attempt has its own names, so a re-run never shares an upload with an earlier one")
check("--write-once" in tip, "tip archives and deltas are write-once, so a feed's signature always matches its bytes")

# Move 4 (Leo, 2026-10-26: "And I thought we were incremental..."): tip-dmg builds, signs and
# notarizes while verify runs; tip, the only R2 writer, still needs verify.
import json
import yaml
jobs = yaml.safe_load(workflow)["jobs"]
build_job, dmg_job, feed_job = jobs["tip-dmg-build"], jobs["tip-dmg"], jobs["tip"]
check(build_job["needs"] == ["sign", "runner"] and "verify" not in build_job["if"]
      and "needs.runner" not in build_job["if"], "tip-dmg-build starts right after sign, alongside verify")
# Owned Macs first, Blacksmith macOS last, never a hosted Mac in this repository: attempt 1 takes
# the runner job's dmg_label (two owned machines free now) and every re-run takes Blacksmith.
check(build_job["runs-on"] == "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
      "(github.run_attempt == 1 && needs.runner.outputs.dmg_label || 'blacksmith-6vcpu-macos-26') }}",
      "tip-dmg-build takes an owned pick on attempt 1 only, else Blacksmith macOS")
runner_job = jobs["runner"]
pick = next(step for step in runner_job["steps"] if step.get("id") == "pool")
check(runner_job["outputs"]["dmg_label"] == "${{ steps.pool.outputs.dmg_label }}"
      and 'label="$(pick 2 --wait-owned)"' in pick["run"] and 'glaeda-*) dmg_label="$label" ;;' in pick["run"]
      and 'label="$(pick 1 --wait-owned)"' in pick["run"] and '--jobs "$1"' in pick["run"],
      "dmg_label is an owned pool with two machines free, or waited on when Blacksmith has no two free, moving slots")
# The picker counts Blacksmith room only on the label these jobs fall back to (their runs-on).
fallbacks = {job["runs-on"].rsplit("'", 2)[-2] for job in (build_job, jobs["verify"])}
check(fallbacks == {pick["env"]["BLACKSMITH_LABELS"].rsplit("'", 2)[-2]}
      and '--blacksmith-labels "$BLACKSMITH_LABELS"' in pick["run"],
      "the pick counts Blacksmith room only on verify's and tip-dmg-build's own fallback label")
build_steps = [step for step in build_job["steps"] if isinstance(step, dict)]
fresh = [i for i, step in enumerate(build_steps) if 'rm -rf "$dir"' in str(step.get("run", ""))
         and '"$RUNNER_TEMP/' in str(step.get("run", ""))]
removed = [i for i, step in enumerate(build_steps) if "always()" in str(step.get("if", ""))
           and 'rm -rf "$TIP_WORK_DIR"' in str(step.get("run", ""))]
check(fresh and removed and fresh[0] < removed[-1] and removed[-1] == len(build_steps) - 1
      and "github.token" not in json.dumps(build_job),
      "tip-dmg-build works in a fresh $RUNNER_TEMP directory it removes last, and holds no token")
check(build_job["steps"][next(i for i, step in enumerate(build_steps) if step.get("name") == "Upload the unsigned tip DMG")]
      ["with"]["path"] == "${{ env.TIP_WORK_DIR }}/tip-unsigned/*",
      "the unsigned DMG hand-off to tip-dmg has the same files")
check(dmg_job["needs"] == ["sign", "tip-dmg-build", "rcodesign"] and "verify" not in dmg_job["if"]
      and "needs.rcodesign.result == 'success'" in dmg_job["if"]
      and "needs.tip-dmg-build.outputs.fresh == 'true'" in dmg_job["if"],
      "tip-dmg signs only a DMG tip-dmg-build uploaded for a fresh build, alongside verify")
check("macos" in build_job["runs-on"] and "ubuntu" in dmg_job["runs-on"] and "macos" not in dmg_job["runs-on"],
      "only the unsigned DMG is built on a Mac; signing, notarization, stapling and the appcast run on Linux")
check(build_job["outputs"]["fresh"] == "${{ steps.upload.outputs.fresh }}"
      and dmg_job["env"]["UNSIGNED_SHA256"] == "${{ needs.tip-dmg-build.outputs.dmg_sha256 }}"
      and "cmux-next-dev-tip-unsigned-$GITHUB_RUN_ATTEMPT" in tip_dmg_build,
      "each tip-dmg-build attempt hands off its own artifact, which tip-dmg checks by digest")
check(feed_job["needs"] == ["sign", "verify", "tip-dmg"] and "needs.tip-dmg.outputs.ready == 'true'" in feed_job["if"],
      "tip writes the feed only after verify passed and tip-dmg handed off a ready DMG")
dmg_steps = {step.get("name"): step for step in dmg_job["steps"]}
build_dmg = {step.get("name"): step for step in build_job["steps"]}["Build the tip DMG"]
build_run = build_dmg["run"]
check("continue-on-error" not in build_dmg and "|| true" not in build_run and "set -euo pipefail" in build_run,
      "a DMG build error fails tip-dmg-build: no || true")
# Apple's codesign check is verify's alone (it ran in both): the feed takes the DMG only after verify
# passed for the digest tip-dmg built from (tip's needs and the digest check above).
check("codesign" not in build_run and "codesign --verify --deep --strict" in verify,
      "Apple's codesign check of the signed app runs once, in verify")
order = [tip_dmg.find(marker) for marker in (
    "./scripts/ci/rcodesign-notarize-dmg-dev.sh", "python3 scripts/ci/tip_appcast_linux.py",
    "python3 scripts/ci/tip_feed.py check", "name: Upload the tip DMG and appcast for tip", "name: Mark the tip DMG ready for tip")]
check(-1 not in order and order == sorted(order),
      "tip-dmg: sign, notarize and staple the DMG, write and check the appcast, then hand off")
check(all(word not in tip_dmg + tip_dmg_build for word in ("CF_R2_", "r2_cas.py", "upload-r2-object.py")),
      "tip-dmg and tip-dmg-build write nothing public: R2 keys and uploads live only in tip, after verify")
check(dmg_job["outputs"]["ready"] == "${{ steps.ready.outputs.ready }}" and dmg_steps["Mark the tip DMG ready for tip"]["id"] == "ready"
      and "if" in dmg_steps["Mark the tip DMG ready for tip"] and "always()" not in dmg_steps["Mark the tip DMG ready for tip"]["if"],
      "ready is set only by the step after the handoff upload, so a failed tip-dmg never reads as ready")
check("handoff" in dmg_job["outputs"] and "cmux-next-dev-tip-$GITHUB_RUN_ATTEMPT" in tip_dmg
      and feed_job["env"]["DMG_RUN_TAG"] == "${{ needs.tip-dmg.outputs.run_tag }}",
      "each tip-dmg attempt hands off under its own artifact name, which tip reads from its outputs")
check("ubuntu" in feed_job["runs-on"] and "macos" not in feed_job["runs-on"], "tip, left with only R2 writes, runs on Linux")
feed_steps = [step.get("name") for step in feed_job["steps"]]
check(feed_steps.index("Require the archive verify tested") < feed_steps.index("Upload the tip feed to R2")
      and "if" not in feed_job["steps"][feed_steps.index("Upload the tip feed to R2")],
      "tip checks the digest verify tested before any upload")
verify_job = jobs["verify"]
check(any(step.get("with", {}).get("name") == "cmux-next-dev-daily-tested" for step in verify_job["steps"])
      and any(step.get("with", {}).get("name") == "cmux-next-dev-daily-tested" for step in feed_job["steps"]),
      "tip reads the digest verify uploads after it passed")

# The digest gate, run in bash.
require = next(step for step in feed_job["steps"] if step.get("name") == "Require the archive verify tested")["run"]
def run_require(built, tested, tag="r7-1", own="r7-1", extra=()):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "tip-handoff").mkdir(); (tmp / "tip-tested").mkdir()
        (tmp / "tip-handoff" / "built-from.sha256").write_text(built)
        (tmp / "tip-tested" / "tested.sha256").write_text(tested)
        (tmp / "tip-handoff" / "cmux-NEXT-DEV-102-r7-1.dmg").write_text("dmg")
        (tmp / "tip-handoff" / "appcast-arm64.xml").write_text(open(feed(102, 100)).read().replace(
            "DEV-102.dmg", "DEV-102-r7-1.dmg").replace("</item>", '<sparkle:deltas><enclosure url="https://files.cmux.com/nightly-next/tip/cmux-NEXT-DEV-tip-7-1-102-100.delta"/></sparkle:deltas></item>', 1))
        for name in ("cmux-NEXT-DEV-tip-7-1-102-100.delta", *extra):
            (tmp / "tip-handoff" / name).write_text("delta")
        env = {"PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "DMG_RUN_TAG": tag, "TIP_RUN_TAG": own,
               "TIP_BUILD": "102", "TIP_APPCAST": "appcast-arm64.xml"}
        result = subprocess.run(["bash", "-e", "-c", require], cwd=tmp, env=env, capture_output=True, text=True, timeout=30)
        placed = sorted(str(path.relative_to(tmp)) for path in (*tmp.glob("tip-new/*"), *tmp.glob("tip-out/*")))
        feed_out = tmp / "tip-out" / "appcast-arm64.xml"
        urls = [entry["url"] for entry in tip_feed.items(str(feed_out))] + sum(
            (entry["deltas"] for entry in tip_feed.items(str(feed_out))), []) if feed_out.exists() else []
        return result.returncode, placed, urls
digest = "ab" * 32 + "  cmux-NEXT-DEV.zip\n"
rc, placed, urls = run_require(digest, digest)
check(rc == 0 and placed == ["tip-new/cmux-NEXT-DEV-102-r7-1.dmg", "tip-out/appcast-arm64.xml", "tip-out/cmux-NEXT-DEV-tip-7-1-102-100.delta"]
      and f"{prefix}102-r7-1.dmg" in urls,
      f"the tested archive's DMG, appcast and deltas go where the upload step reads them ({rc} {placed} {urls})")
# Codex (2026-10-26): a re-run of tip alone (attempt 2) must not share objects with tip attempt 1,
# whose late write or delete could otherwise land on them.
rc, placed, urls = run_require(digest, digest, own="r7-2")
check(rc == 0 and placed == ["tip-new/cmux-NEXT-DEV-102-r7-2.dmg", "tip-out/appcast-arm64.xml", "tip-out/cmux-NEXT-DEV-tip-7-2-102-100.delta"]
      and f"{prefix}102-r7-2.dmg" in urls and "https://files.cmux.com/nightly-next/tip/cmux-NEXT-DEV-tip-7-2-102-100.delta" in urls
      and not any("r7-1" in url or "tip-7-1-" in url for url in urls),
      f"a tip re-run publishes tip-dmg's files under its own names, and the appcast names them ({rc} {placed} {urls})")
rc, placed, urls = run_require(digest, digest, extra=("cmux-NEXT-DEV-tip-7-1-102-99.delta",))
check(rc != 0, "the moved deltas and the appcast's delta URLs must match in number")
rc, placed, urls = run_require(digest, "cd" * 32 + "  cmux-NEXT-DEV.zip\n")
check(rc != 0 and placed == [], "a DMG around an archive verify did not test never reaches the upload")
rc, placed, urls = run_require(digest, digest, tag="")
check(rc != 0, "a handoff with no run tag never publishes")
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
def conflict_409(request, *, timeout):
    raise urllib.error.HTTPError(request.full_url, 409, "Conflict", {}, io.BytesIO())
r2_cas.r2._open_signed_request = conflict_409
check(not r2_cas.put("k", b"x", etag='"7"', cache_control="no-store", content_type="text/plain"),
      "R2's 409 for a concurrent writer is a lost race, retried like a 412")
r2_cas.r2._open_signed_request = real_open

# The lease against an in-memory R2 whose clock is not the runner's.
store, version, r2_now = {}, [0], [1000.0]
def fake_read(key):
    if key not in store:
        return None, b"", 0.0
    etag, body, written = store[key]
    return etag, body, r2_now[0] - written
def fake_put(key, body, *, etag, cache_control, content_type):
    if store.get(key, (None,))[0] != etag:
        return False
    version[0] += 1
    store[key] = (f'"{version[0]}"', body, r2_now[0])
    return True
r2_cas.read, r2_cas.put = fake_read, fake_put
runner = [0.0]  # a runner clock far from R2's: expiry must not read it
clock, sleep = (lambda: runner[0]), (lambda seconds: runner.__setitem__(0, runner[0] + seconds))
check(r2_cas.lock("l", "a", 60, 0, clock, sleep) and r2_cas.holds("l", "a"), "the first publisher takes the free lease")
runner[0] += 10_000
check(not r2_cas.lock("l", "b", 60, 30, clock, sleep), "a runner clock running ahead never ends a live lease")
check(not r2_cas.unlock("l", "b") and r2_cas.holds("l", "a"), "only the holder releases the lease")
r2_now[0] += 61
check(r2_cas.lock("l", "b", 60, 0, clock, sleep) and not r2_cas.holds("l", "a"), "a lease expired on R2's clock is taken over")
check(not r2_cas.unlock("l", "a") and r2_cas.unlock("l", "b") and not r2_cas.holds("l", "b"), "the holder releases its own lease")
check(r2_cas.lock("l", "c", 60, 0, clock, sleep), "a released lease is free at once")
unlock_src = (ROOT / "scripts/ci/r2_cas.py").read_text().split("def unlock", 1)[1].split("\ndef ", 1)[0]
check("delete(" not in unlock_src and "_store(" in unlock_src, "release is a conditional PUT, not an undocumented conditional DELETE")

# The publish step's decision, run in bash with gh and the R2 helper stubbed.
import re
import subprocess
import textwrap

lines = publish[publish.index("- name: Publish the rolling GitHub prerelease"):].split("run: |\n", 1)[1].splitlines()
body = []
for line in lines:
    if line.strip() and len(line) - len(line.lstrip()) < 10:
        break
    body.append(line)
publish_script = textwrap.dedent("\n".join(body))

STUB_GH = r"""#!/bin/bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
  "api repos/o/r/releases/tags/cmux-next-dev")
    [[ -n "$NOTES_SHA" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [[ "$NOTES_SHA" == none ]] && { echo "Hand-edited notes."; exit 0; }
    [[ "$NOTES_SHA" == empty ]] && { echo ""; exit 0; }
    echo "Rolling build from feat-cmux-next commit $NOTES_SHA."; exit 0 ;;
  api\ repos/o/r/compare/*)
    pair="${2#repos/o/r/compare/}"; key="${pair//[^a-zA-Z0-9]/_}"; var="CMP_${key}"  # bash 5 drops env names with "-"
    [[ -n "${!var:-}" ]] || { echo "gh: compare failed (HTTP 502)" >&2; exit 1; }
    echo "${!var}"; exit 0 ;;
  api\ repos/o/r/commits/*)
    sha="${2#repos/o/r/commits/}"
    [[ " $GONE " == *" $sha "* ]] && { echo "gh: No commit found for SHA: $sha (HTTP 422)" >&2; exit 1; }
    echo "$sha"; exit 0 ;;
  "release view") exit 0 ;;
  "release upload"|"release edit"|"release create") echo WRITE >> "$STUB_LOG"; exit 0 ;;
esac
exit 1
"""
STUB_PY = r"""#!/bin/bash
if [[ "$1" == scripts/ci/r2_cas.py ]]; then
  echo "r2 ${*:2}" >> "$STUB_LOG"
  case "$2" in
    lock|unlock) exit 0 ;;
    holds) [[ "$HOLDS" == yes ]] && exit 0 || exit 3 ;;
    get) out="${@: -1}"; if [[ -n "$RECORD_SHA" ]]; then printf '{"commit":"%s"}' "$RECORD_SHA" > "$out"; echo '"9"'; else : > "$out"; echo absent; fi; exit 0 ;;
    put) exit 0 ;;
  esac
fi
exec /usr/bin/env python3 "$@"
"""
A, B, C = "a" * 40, "b" * 40, "c" * 40
def run_publish(source, *, notes="", record="", holds="yes", cmp=None, gone=""):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "bin").mkdir()
        for name, text in (("gh", STUB_GH), ("python3", STUB_PY)):
            (tmp / "bin" / name).write_text(text)
            (tmp / "bin" / name).chmod(0o755)
        (tmp / "zip").write_text("app")
        (tmp / "zip.sha256").write_text("x  zip\n")
        env = {
            "PATH": f"{tmp / 'bin'}:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "STUB_LOG": str(tmp / "log"),
            "RUNNER_TEMP": str(tmp), "APP_ARCHIVE_NAME": "zip", "RELEASE_TAG": "cmux-next-dev", "GH_REPO": "o/r",
            "SOURCE_SHA": source, "GITHUB_SHA": "f" * 40, "LEASE_KEY": "lease", "RECORD_KEY": "record",
            "LEASE_OWNER": "run-1", "NOTES_SHA": notes, "RECORD_SHA": record, "HOLDS": holds, "GONE": gone,
        }
        for pair, status in (cmp or {}).items():
            env["CMP_" + re.sub(r"[^a-zA-Z0-9]", "_", pair)] = status
        result = subprocess.run(["bash", "-e", "-c", publish_script], env=env, capture_output=True, text=True, timeout=60)
        log = (tmp / "log").read_text() if (tmp / "log").exists() else ""
        return result.returncode, log
def wrote(log):
    return "WRITE" in log
def recorded(log):
    return any(line.startswith("r2 put --key record") for line in log.splitlines())

rc, log = run_publish(B, notes=A, cmp={f"{B}...{A}": "behind"})
check(rc == 0 and recorded(log) and wrote(log) and log.index("r2 put --key record") < log.index("WRITE"),
      "a newer commit records itself, then writes the release")
rc, log = run_publish(B, notes=A, record=C, cmp={f"{B}...{C}": "ahead"})
check(rc == 0 and not wrote(log) and not recorded(log), "the record outranks stale notes: a half-finished newer write still blocks older commits")
rc, log = run_publish(C, record=C, cmp={f"{C}...{C}": "identical"})
check(rc == 0 and wrote(log), "a run for the recorded commit repairs its own half-finished write")
rc, log = run_publish(B, record=A)
check(rc != 0 and not wrote(log), "a compare error fails publish instead of writing")
rc, log = run_publish(B, record=A, cmp={f"{B}...{A}": "diverged", f"{A}...feat-cmux-next": "diverged", f"{B}...feat-cmux-next": "ahead"})
check(rc == 0 and wrote(log), "after a rewrite, the commit still on feat-cmux-next replaces one that left it")
rc, log = run_publish(A, record=B, cmp={f"{A}...{B}": "diverged", f"{B}...feat-cmux-next": "ahead"})
check(rc == 0 and not wrote(log), "a commit that left feat-cmux-next never replaces one still on it")
rc, log = run_publish(B, notes="none")
check(rc != 0 and not wrote(log), "a release whose notes name no commit is never overwritten")
rc, log = run_publish(B, notes="empty")
check(rc != 0 and not wrote(log), "a release with empty notes is never overwritten")
rc, log = run_publish(B)
check(rc == 0 and wrote(log), "with no release and no record, the first run publishes")
rc, log = run_publish(B, record=C, gone=C, cmp={f"{B}...feat-cmux-next": "ahead"})
check(rc == 0 and wrote(log) and recorded(log), "a recorded commit the repository lost is replaced by a commit on the branch")
rc, log = run_publish(B, record=C, gone=C, cmp={f"{B}...feat-cmux-next": "diverged"})
check(rc != 0 and not wrote(log), "a lost record is never replaced by a commit off the branch")
rc, log = run_publish(B, record=A, holds="no", cmp={f"{B}...{A}": "behind"})
check(rc != 0 and not wrote(log), "a run that lost the lease never writes")


# merge: the generated appcast came from an earlier read; a build published since is kept.
def appcast(*builds):
    return open(feed(*builds)).read()
generated = feed(102, 100, 99)
live = feed(101, 100, 99)
merged = tip_feed.merge(generated, live, 102, 3)
merged_path = feed()
open(merged_path, "w").write(merged)
check([e["build"] for e in tip_feed.items(merged_path)] == [102, 101, 100] and not tip_feed.check(merged_path, 102),
      "merging onto the latest feed keeps a build published since the appcast was generated")
check([e["build"] for e in tip_feed.items(feed(102))] == [102], "fixture sanity")
open(merged_path, "w").write(tip_feed.merge(generated, None, 102, 3))
check([e["build"] for e in tip_feed.items(merged_path)] == [102], "with no live feed, the merge is the new item alone")
try:
    tip_feed.merge(generated, feed(103), 102, 3)
    check(False, "merging under a newer live build must refuse")
except ValueError:
    pass

# The tip upload step, run in bash: R2 and the uploader stubbed, tip_feed.py real.
tip_lines = upload.split("run: |\n", 1)[1].splitlines()
tip_body = []
for line in tip_lines:
    if line.strip() and len(line) - len(line.lstrip()) < 10:
        break
    tip_body.append(line)
tip_script = textwrap.dedent("\n".join(tip_body))
TIP_STUB_PY = r"""#!/bin/bash
if [[ "$1" == scripts/ci/r2_cas.py ]]; then
  echo "r2 ${*:2}" >> "$STUB_LOG"
  case "$2" in
    get)
      n=$(( $(cat "$STUB_DIR/gets" 2>/dev/null || echo 0) + 1 )); echo $n > "$STUB_DIR/gets"
      src="$STUB_DIR/live$n.xml"; [[ -f "$src" ]] || src="$STUB_DIR/live.xml"
      out="${@: -1}"
      if [[ -f "$src" ]]; then cp "$src" "$out"; echo "\"etag$n\""; else : > "$out"; echo absent; fi; exit 0 ;;
    put)
      n=$(( $(cat "$STUB_DIR/puts" 2>/dev/null || echo 0) + 1 )); echo $n > "$STUB_DIR/puts"
      file=""; prev=""; for a in "$@"; do [[ "$prev" == --file ]] && file="$a"; prev="$a"; done
      cp "$file" "$STUB_DIR/written$n.xml"
      [[ -f "$STUB_DIR/conflict$n" ]] && exit 3
      # The write lands, but its answer is lost.
      [[ -f "$STUB_DIR/lost$n" ]] && { rm -f "$STUB_DIR"/live[0-9]*.xml; cp "$file" "$STUB_DIR/live.xml"; exit 1; }
      # The write fails with no answer, and may land later.
      [[ -f "$STUB_DIR/pending$n" ]] && exit 1
      exit 0 ;;
    delete) exit 0 ;;
  esac
fi
if [[ "$1" == scripts/ci/upload-r2-object.py ]]; then
  echo "upload ${*:2}" >> "$STUB_LOG"
  [[ -n "$FAIL_UPLOAD" && "$*" == *"$FAIL_UPLOAD"* ]] && exit 1; exit 0
fi
exec "$REAL_PY" "$@"
"""
def run_tip(lives, conflicts=(), fail_upload="", lost=(), pending=()):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "bin").mkdir()
        (tmp / "bin" / "python3").write_text(TIP_STUB_PY)
        (tmp / "bin" / "python3").chmod(0o755)
        (tmp / "scripts" / "ci").mkdir(parents=True)
        (tmp / "scripts" / "ci" / "tip_feed.py").write_text((ROOT / "scripts/ci/tip_feed.py").read_text())
        (tmp / "tip-new").mkdir(); (tmp / "tip-out").mkdir()
        (tmp / "tip-new" / "cmux-NEXT-DEV-102-r7-1.dmg").write_text("dmg")
        (tmp / "tip-out" / "cmux-NEXT-DEV-tip-7-1-102-100.delta").write_text("delta")
        (tmp / "tip-out" / "appcast-arm64.xml").write_text(appcast(102, 100, 99).replace("DEV-102.dmg", "DEV-102-r7-1.dmg"))
        for n, builds in enumerate(lives, 1):
            if builds is not None:
                (tmp / f"live{n}.xml").write_text(appcast(*builds))
        for name, ns in (("conflict", conflicts), ("lost", lost), ("pending", pending)):
            for n in ns:
                (tmp / f"{name}{n}").write_text("")
        env = {"PATH": f"{tmp / 'bin'}:/usr/bin:/bin", "STUB_LOG": str(tmp / "log"), "STUB_DIR": str(tmp),
               "REAL_PY": sys.executable, "TIP_R2_PREFIX": "nightly-next/tip", "TIP_APPCAST": "appcast-arm64.xml",
               "TIP_BUILD": "102", "TIP_RUN_TAG": "r7-1", "TIP_KEEP": "3", "SOURCE_SHA": "a" * 40,
               "TIP_BASE_URL": "https://files.cmux.com/nightly-next/tip", "GITHUB_STEP_SUMMARY": str(tmp / "summary"),
               "R2_ENDPOINT": "https://r2.invalid", "FAIL_UPLOAD": fail_upload, "GITHUB_OUTPUT": str(tmp / "output")}
        result = subprocess.run(["bash", "-e", "-c", tip_script], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        log = (tmp / "log").read_text() if (tmp / "log").exists() else ""
        written = sorted(tmp.glob("written*.xml"))
        last = [e["build"] for e in tip_feed.items(str(written[-1]))] if written else None
        output = (tmp / "output").read_text() if (tmp / "output").exists() else ""
        if result.returncode == 0 and written and log.count("r2 put") and "r2 delete" not in log:
            check("written=true" in output and "run_tag=r7-1" in output, f"tip says it wrote the feed ({output!r})")
        return result.returncode, log, last, result.stderr
rc, log, last, err = run_tip([(100, 99), (101, 100, 99)], conflicts=(1,))
check(rc == 0 and last == [102, 101, 100] and "r2 delete" not in log,
      f"a lost race re-reads and keeps the build published in between ({rc} {last} {err[-300:]})")
rc, log, last, err = run_tip([(100, 99), (103, 100)], conflicts=(1,))
check(rc == 0 and last == [102, 100, 99] and log.count("r2 delete") == 2,
      f"a newer build ends the run, which removes its unused archive and delta ({rc} {log!r})")
rc, log, last, err = run_tip([None])
check(rc == 0 and last == [102] and "r2 delete" not in log, f"the first feed is created with the new item ({rc} {err[-300:]})")
rc, log, last, err = run_tip([(100, 99)], fail_upload=".delta")
check(rc != 0 and last is None and log.count("r2 delete") == 2,
      f"a failed upload fails the step, writes no feed and removes what it uploaded ({rc} {log!r})")
rc, log, last, err = run_tip([(100, 99)], lost=(1,))
check(rc != 0 and last == [102, 100, 99] and "r2 delete" not in log,
      f"a feed write whose answer was lost but which landed keeps the files the feed now names ({rc} {log!r})")
rc, log, last, err = run_tip([(100, 99)], pending=(1,))
check(rc != 0 and "r2 delete" not in log,
      f"a feed write that failed without an answer may still land, so the uploads stay ({rc} {log!r})")
check("retention-days: 1" in tip_dmg.split("name: Upload the tip DMG and appcast for tip", 1)[1].split("- name:", 1)[0],
      "the per-run DMG handoff is kept one day, not three")

# Move 2 (Leo, 2026-10-26: "And I thought we were incremental..."): the full DMG first, deltas after.
check("SPARKLE_PREVIOUS_ARCHIVES_DIR" not in tip_dmg and "tip-previous/" not in tip_dmg
      and 'grep -q "<sparkle:deltas>" "tip-out/$TIP_APPCAST"' in tip_dmg,
      "tip-dmg's appcast offers the full DMG alone, so the first feed write names no delta")
delta_job = jobs["tip-deltas"]
check(delta_job["needs"] == ["sign", "tip-dmg", "tip"] and "needs.tip.outputs.written == 'true'" in delta_job["if"]
      and jobs["tip"]["outputs"]["written"] == "${{ steps.feed.outputs.written }}"
      and tip.rstrip().endswith('echo "written=true" >> "$GITHUB_OUTPUT"'),
      "tip-deltas starts only after tip wrote the full-DMG feed")
check(delta_job.get("continue-on-error") is True and "concurrency" not in delta_job,
      "tip-deltas is advisory and takes no concurrency group")
check(delta_job["env"]["TIP_RUN_TAG"] == "${{ needs.tip.outputs.run_tag }}"
      and jobs["tip"]["outputs"]["run_tag"] == "${{ steps.feed.outputs.run_tag }}",
      "tip-deltas looks for the DMG name tip put in the feed")
delta_upload = tip_deltas[tip_deltas.index("- name: Add the deltas to the tip feed"):]
check(delta_upload.index("r2_cas.py get") < delta_upload.index("tip_feed.py add-deltas") < delta_upload.index("upload-r2-object.py")
      < delta_upload.index("r2_cas.py put") and '--if-match "$etag"' in delta_upload and "--if-absent" not in delta_upload
      and "--write-once" in delta_upload and "(( rc == 3 )) || exit" in delta_upload,
      "the delta write is a compare-and-swap on the feed it read, after the write-once deltas, and never creates a feed")
check(tip_deltas.index("tip_feed.py bases") < tip_deltas.index("./scripts/sparkle_generate_appcast.sh"),
      "deltas are made only while this build's item takes them")

# bases and add-deltas against feeds shaped like the live one.
def live_feed(*builds, url_tag="r9-1", deltas_for=()):
    body = []
    for build in builds:
        extra = (f'\n            <sparkle:deltas>\n                <enclosure url="{prefix}tip-1-1-{build}-1.delta" sparkle:deltaFrom="1" length="1" '
                 f'type="application/octet-stream" sparkle:edSignature="ZA=="/>\n            </sparkle:deltas>') if build in deltas_for else ""
        body.append(
            f"        <item>\n            <title>{build}</title>\n            <sparkle:version>{build}</sparkle:version>\n"
            f'            <enclosure url="{prefix}{build}-{url_tag}.dmg" length="{build}" type="application/octet-stream" '
            f'sparkle:edSignature="c2ln{build}"/>{extra}\n        </item>\n')
    text = ('<?xml version="1.0" standalone="yes"?>\n<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
            f"    <channel>\n        <title>cmux NEXT DEV</title>\n{''.join(body)}    </channel>\n</rss>\n")
    path = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
    path.write(text)
    path.close()
    return path.name
ours_url = f"{prefix}102-r9-1.dmg"
check(tip_feed.bases(live_feed(102, 101, 100), 102, ours_url, 3) == ["ours", f"{prefix}101-r9-1.dmg", f"{prefix}100-r9-1.dmg"],
      "deltas start from the feed's older builds")
check(tip_feed.bases(live_feed(103, 102, 101), 102, ours_url, 3)[0].startswith("skip"), "a newer build takes no deltas for this one")
check(tip_feed.bases(live_feed(101, 100), 102, ours_url, 3)[0].startswith("skip"), "a build no longer in the feed takes no deltas")
check(tip_feed.bases(live_feed(102, 101, url_tag="r9-2"), 102, ours_url, 3)[0].startswith("skip"),
      "another attempt's DMG for the same build takes none of this attempt's deltas")
check(tip_feed.bases(live_feed(102, 101, deltas_for=(102,)), 102, ours_url, 3)[0].startswith("skip"), "deltas are added once")

def generated_with_deltas(names, signature="c2ln102"):
    deltas = "".join(f'<enclosure url="https://files.cmux.com/nightly-next/tip/{name}" sparkle:deltaFrom="101" length="5" '
                     f'type="application/octet-stream" sparkle:edSignature="ZGVsdGE="/>' for name in names)
    text = ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>'
            f'<item><title>102</title><sparkle:version>102</sparkle:version><enclosure url="{ours_url}" length="102" '
            f'type="application/octet-stream" sparkle:edSignature="{signature}"/><sparkle:deltas>{deltas}</sparkle:deltas></item>'
            f'<item><title>101</title><sparkle:version>101</sparkle:version><enclosure url="{prefix}101-r9-1.dmg" length="101" '
            'type="application/octet-stream" sparkle:edSignature="c2ln101"/></item></channel></rss>')
    path = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
    path.write(text)
    path.close()
    return path.name
files = tempfile.mkdtemp()
delta_name = "cmux-NEXT-DEV-tip-7-1-102-101.delta"
Path(files, delta_name).write_text("delta")
live = live_feed(102, 101, 100)
added = tip_feed.add_deltas(generated_with_deltas([delta_name]), live, 102, ours_url, files)
added_path = feed()
open(added_path, "w").write(added)
entries = tip_feed.items(added_path)
live_text = open(live).read()
check([e["build"] for e in entries] == [102, 101, 100] and entries[0]["deltas"] == [f"https://files.cmux.com/nightly-next/tip/{delta_name}"]
      and not tip_feed.check(added_path, 102),
      "add-deltas gives this build's item its deltas and keeps the feed valid")
check(tip_feed.DELTAS.sub("", added) == live_text and added.count("<sparkle:deltas>") == 1,
      "add-deltas changes nothing but this build's deltas: every other byte, every other item, stays")
for bad, why in ((lambda: tip_feed.add_deltas(generated_with_deltas([delta_name]), live_feed(103, 102, 101), 102, ours_url, files),
                  "a newer build published since"),
                 (lambda: tip_feed.add_deltas(generated_with_deltas([delta_name]), live_feed(101, 100), 102, ours_url, files),
                  "this build left the feed")):
    try:
        bad()
        check(False, f"add-deltas must add nothing when {why}")
    except tip_feed.NothingToAdd:
        pass
for bad, why in ((lambda: tip_feed.add_deltas(generated_with_deltas([delta_name], signature="b3RoZXI="), live, 102, ours_url, files),
                  "the generated item signs other bytes"),
                 (lambda: tip_feed.add_deltas(generated_with_deltas(["not-uploaded.delta"]), live, 102, ours_url, files),
                  "a delta was not uploaded by this run")):
    try:
        bad()
        check(False, f"add-deltas must refuse when {why}")
    except ValueError:
        pass

# The delta write, run in bash: R2 and the uploader stubbed, tip_feed.py real.
delta_lines = delta_upload.split("run: |\n", 1)[1].splitlines()
delta_body = []
for line in delta_lines:
    if line.strip() and len(line) - len(line.lstrip()) < 10:
        break
    delta_body.append(line)
delta_script = textwrap.dedent("\n".join(delta_body))
def run_deltas(lives, conflicts=(), pending=(), fail_upload=""):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "bin").mkdir()
        (tmp / "bin" / "python3").write_text(TIP_STUB_PY)
        (tmp / "bin" / "python3").chmod(0o755)
        (tmp / "scripts" / "ci").mkdir(parents=True)
        (tmp / "scripts" / "ci" / "tip_feed.py").write_text((ROOT / "scripts/ci/tip_feed.py").read_text())
        (tmp / "tip-out").mkdir()
        (tmp / "tip-out" / delta_name).write_text("delta")
        (tmp / "tip-out" / "appcast-arm64.xml").write_text(open(generated_with_deltas([delta_name])).read())
        for n, builds in enumerate(lives, 1):
            if builds is not None:
                (tmp / f"live{n}.xml").write_text(open(live_feed(*builds)).read())
        for name, ns in (("conflict", conflicts), ("pending", pending)):
            for n in ns:
                (tmp / f"{name}{n}").write_text("")
        env = {"PATH": f"{tmp / 'bin'}:/usr/bin:/bin", "STUB_LOG": str(tmp / "log"), "STUB_DIR": str(tmp),
               "REAL_PY": sys.executable, "TIP_R2_PREFIX": "nightly-next/tip", "TIP_APPCAST": "appcast-arm64.xml",
               "TIP_BUILD": "102", "DMG_URL": ours_url, "GITHUB_STEP_SUMMARY": str(tmp / "summary"),
               "R2_ENDPOINT": "https://r2.invalid", "FAIL_UPLOAD": fail_upload}
        result = subprocess.run(["bash", "-e", "-c", delta_script], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        log = (tmp / "log").read_text() if (tmp / "log").exists() else ""
        written = sorted(tmp.glob("written*.xml"))
        last = tip_feed.items(str(written[-1])) if written else None
        return result.returncode, log, last, result.stderr
rc, log, last, err = run_deltas([(102, 101, 100)])
check(rc == 0 and last and [e["build"] for e in last] == [102, 101, 100] and last[0]["deltas"] and "r2 delete" not in log
      and log.index("upload ") < log.index("r2 put"),
      f"the deltas upload, then the feed gains them ({rc} {err[-300:]})")
rc, log, last, err = run_deltas([(102, 101, 100), (103, 102, 101)], conflicts=(1,))
check(rc == 0 and log.count("r2 put") == 1 and log.count("r2 delete") == 1,
      f"a newer build published during the delta write ends it, writes nothing and removes its deltas ({rc} {log!r})")
rc, log, last, err = run_deltas([(102, 101, 100), (102, 101, 100)], conflicts=(1,))
check(rc == 0 and log.count("r2 put") == 2 and log.count("upload ") == 1 and "r2 delete" not in log and last[0]["deltas"],
      f"a lost race re-reads and writes again, uploading the deltas once ({rc} {log!r})")
rc, log, last, err = run_deltas([(103, 102, 101)])
check(rc == 0 and "upload " not in log and "r2 put" not in log, f"no deltas go up for a build that is no longer the newest ({rc} {log!r})")
rc, log, last, err = run_deltas([None])
check(rc == 0 and "upload " not in log and "r2 put" not in log, f"a missing feed is never created by the delta write ({rc} {log!r})")
rc, log, last, err = run_deltas([(102, 101, 100)], pending=(1,))
check(rc != 0 and "r2 delete" not in log, f"after a delta write with no clear answer the deltas stay ({rc} {log!r})")
rc, log, last, err = run_deltas([(102, 101, 100)], fail_upload=".delta")
check(rc != 0 and "r2 put" not in log, f"a failed delta upload writes no feed, which stays valid without deltas ({rc} {log!r})")

# CMUX_TIMESTAMP=none makes the Linux signer drop the time stamp and the Developer ID check
# (scripts/ci/rcodesign-sign-bundle-dev.sh); the publisher must never set it.
check("CMUX_TIMESTAMP" not in workflow, "the DEV workflow never sets CMUX_TIMESTAMP")

# tip-deltas runs Apple's tools on the DMG rcodesign signed, notarized and stapled on Linux,
# before any delta work.
delta_steps = [step.get("name") for step in jobs["tip-deltas"]["steps"]]
apple = next(step for step in jobs["tip-deltas"]["steps"] if step.get("name") == "Check the published DMG with Apple's tools")
check(delta_steps.index("Download the tip DMG") < delta_steps.index("Check the published DMG with Apple's tools")
      < delta_steps.index("Fetch the delta bases") and "if" not in apple and "continue-on-error" not in apple
      and all(word in apple["run"] for word in ("codesign --verify", "xcrun stapler validate",
                                                 "spctl --assess --type open --context context:primary-signature")),
      "tip-deltas checks the published DMG's signature, stapled ticket and Gatekeeper verdict with Apple's tools")

# The Linux appcast (scripts/ci/tip_appcast_linux.py) against openssl and a fake signed archive.
import base64
import hashlib
import plistlib
import zipfile
spec = importlib.util.spec_from_file_location("tip_appcast_linux", ROOT / "scripts/ci/tip_appcast_linux.py")
tip_appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tip_appcast)
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dmg = tmp / "cmux-NEXT-DEV-102-r7-1.dmg"
    dmg.write_bytes(os.urandom(300_000))
    seed = os.urandom(32)
    der = tmp / "key.der"
    der.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
    reference = subprocess.run(["openssl", "pkeyutl", "-sign", "-keyform", "DER", "-inkey", str(der), "-rawin", "-in", str(dmg)],
                               capture_output=True, check=True).stdout
    signature, public = tip_appcast.sign_file(seed, str(dmg))
    check(signature == reference, "the Ed25519 signature is openssl's for the same seed (so generate_appcast's too)")
    scalar, nonce = tip_appcast.expanded_key(seed)
    check(tip_appcast.sign_file(scalar.to_bytes(32, "little") + nonce + public, str(dmg)) == (signature, public),
          "the old 96-byte Sparkle key signs the same as its seed")
    def write_archive(build, key):
        # A base64 key can hold '/', which is no file name (run 40442893396 failed on one).
        archive = tmp / f"app-{build}-{hashlib.sha256(key.encode()).hexdigest()[:8]}.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("cmux NEXT DEV.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleVersion": build, "CFBundleShortVersionString": f"1.0.0-tip.{build}", "CFBundleName": "cmux NEXT DEV",
                "LSMinimumSystemVersion": "14.0", "SUPublicEDKey": key}, fmt=plistlib.FMT_BINARY))
        return archive
    def run_appcast(archive, build="102"):
        out = tmp / "appcast-arm64.xml"
        out.unlink(missing_ok=True)
        env = {**os.environ, "TIP_KEY": base64.b64encode(seed).decode()}
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/tip_appcast_linux.py"), "TIP_KEY", str(dmg), str(archive),
                                 "cmux NEXT DEV", "https://files.cmux.com/nightly-next/tip/", "https://example.com/notes", build, str(out)],
                                env=env, capture_output=True, text=True, timeout=60)
        return result.returncode, out
    good = base64.b64encode(public).decode()
    rc, out = run_appcast(write_archive("102", good))
    entries = tip_feed.items(str(out)) if rc == 0 else []
    check(rc == 0 and tip_feed.check(str(out), 102) == [] and entries[0]["url"] == f"{prefix}102-r7-1.dmg"
          and f'length="{dmg.stat().st_size}"' in out.read_text()
          and f'sparkle:edSignature="{base64.b64encode(signature).decode()}"' in out.read_text()
          and "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" in out.read_text()
          and "<sparkle:deltas>" not in out.read_text(),
          "the Linux appcast offers the signed full DMG alone, for this build")
    rc, _ = run_appcast(write_archive("101", good))
    check(rc != 0, "an archive of another build gets no appcast")
    rc, _ = run_appcast(write_archive("102", base64.b64encode(os.urandom(32)).decode()))
    check(rc != 0, "an app that trusts another key gets no appcast")

# Our signer is built without secrets alongside sign; sign and tip-dmg run only the binary whose
# sha256 that job reported. The binary is cached under the hash of the build script and the patch.
signer_job = jobs["rcodesign"]
cache_step = next(step for step in signer_job["steps"] if "actions/cache@" in str(step.get("uses", "")))
check("environment" not in signer_job and "secrets." not in json.dumps(signer_job)
      and signer_job["permissions"] == {"contents": "read"} and "concurrency" not in signer_job
      and "ubuntu" in signer_job["runs-on"] and "macos" not in signer_job["runs-on"],
      "the signer is built on Linux with no environment, secret or concurrency group")
check("hashFiles('scripts/ci/build-rcodesign.sh', 'scripts/ci/rcodesign-0.29.0-dmg.patch')" in cache_step["with"]["key"]
      and cache_step["with"]["path"] == "${{ runner.temp }}/rcodesign",
      "the cached signer is keyed by the build script and the patch")
check(signer_job["steps"][0]["with"]["ref"] == "${{ github.sha }}"
      and not any("setup-cmux-tui-rust" in str(step.get("uses", "")) or "sh.rustup.rs" in step.get("run", "")
                  for step in signer_job["steps"]),
      "the signer builds from the dispatched commit with the image's rustup, never a fetched installer")
check(any(step.get("run", "").startswith("./scripts/ci/build-rcodesign.sh") for step in signer_job["steps"])
      and signer_job["outputs"]["sha256"] == "${{ steps.digest.outputs.sha256 }}"
      and dmg_job["env"]["SIGNER_SHA256"] == "${{ needs.rcodesign.outputs.sha256 }}",
      "tip-dmg checks the signer against the digest its build reported")
# rcodesign reads every RCODESIGN_* variable as configuration; one in tip-dmg broke run 40454509260.
for consumer in (dmg_job, jobs["sign"]):
    check(not [key for env in [consumer.get("env", {})] + [step.get("env", {}) for step in consumer["steps"]]
               for key in env if key.startswith("RCODESIGN_")],
          "no RCODESIGN_* variable reaches a signing job")
check('compgen -e | grep "^RCODESIGN_"' in (ROOT / "scripts/ci/rcodesign-notarize-dmg-dev.sh").read_text(),
      "the DMG signer drops RCODESIGN_* variables")
upload = next(step for step in signer_job["steps"] if "upload-artifact" in str(step.get("uses", "")))
for consumer in (dmg_job, jobs["sign"]):
    download = next(step for step in consumer["steps"] if step.get("name") == "Download the signer")
    install = next(step for step in consumer["steps"] if step.get("name") == "Install the signer")
    check(download["with"]["name"] == "${{ needs.rcodesign.outputs.artifact }}"
          and signer_job["outputs"]["artifact"] == upload["with"]["name"]
          and '"$SIGNER_SHA256  $signer" | sha256sum -c -' in install["run"],
          "a signing job runs only the signer its attempt's build reported, by digest")
check("rcodesign" in jobs["sign"]["needs"] and not any("install-rcodesign" in step.get("run", "") for step in jobs["sign"]["steps"]),
      "the bundle is signed with our signer, not the stock release")
build_script = (ROOT / "scripts/ci/build-rcodesign.sh").read_text()
check("CRATE_SHA256=f24e9ebdb70a2aee3ca1cea217009fb50776955f0d7678c31d22e48c1524667f" in build_script
      and "--locked" in build_script and "rcodesign-$CRATE_VERSION-dmg.patch" in build_script,
      "the signer builds the pinned crate with its own lock file and our patch")
patch_text = (ROOT / "scripts/ci/rcodesign-0.29.0-dmg.patch").read_text()
check("+++ b/src/dmg.rs" in patch_text and "team_name" in patch_text and "derive_designated_requirements" in patch_text
      and "0x20200" in patch_text and "builder.use_codesign_cms_encoding()?;" in patch_text,
      "the signer patch carries the DMG signature")
check(all(f"+++ b/src/{name}.rs" in patch_text for name in ("macho_signing", "signing_settings", "code_requirement", "bundle_signing"))
      and "CODESIGN_CMS_RESERVATION: usize = 18000" in patch_text and "Ok(16384)" in patch_text
      and "entitlements_xml_raw" in patch_text and "apple_text::format" in patch_text,
      "the signer patch carries signing parity: page size, reservation, entitlements and requirement text")

dmg_signer = (ROOT / "scripts/ci/rcodesign-notarize-dmg-dev.sh").read_text()
dmg_signer_code = "\n".join(line for line in dmg_signer.splitlines() if not line.lstrip().startswith("#"))
check('[[ "$team" == 7WLXT3NR37 ]]' in dmg_signer_code and "--for-notarization" not in dmg_signer_code and "--timestamp-url http://timestamp.apple.com/ts01" in dmg_signer_code,
      "the DMG is signed with Apple's time stamp")
check(all(want in dmg_signer_code for want in ("version: '0x20200'", "flags: CodeSignatureFlags(0x0)", "team_name: $team",
                                                "(certificate leaf[subject.OU] = \\\"$team\\\")")),
      "the DMG signature is checked before notarization")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: cmux NEXT DEV tip feed")
