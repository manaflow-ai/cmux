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
check(all("12vcpu" not in line for job in (sign, tip) for line in job.splitlines() if line.strip().startswith("runs-on:")),
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
check("TIP_RUN_TAG: r${{ github.run_id }}-${{ github.run_attempt }}" in tip
      and 'cmux-NEXT-DEV-$TIP_BUILD.dmg' not in tip
      and "SPARKLE_DELTA_NAME_PREFIX: cmux-NEXT-DEV-tip-${{ github.run_id }}-${{ github.run_attempt }}-" in tip,
      "each attempt's tip archive and deltas have their own names, so a re-run never hits an earlier upload")
check("--write-once" in tip, "tip archives and deltas are write-once, so a feed's signature always matches its bytes")
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
               "R2_ENDPOINT": "https://r2.invalid", "FAIL_UPLOAD": fail_upload}
        result = subprocess.run(["bash", "-e", "-c", tip_script], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        log = (tmp / "log").read_text() if (tmp / "log").exists() else ""
        written = sorted(tmp.glob("written*.xml"))
        last = [e["build"] for e in tip_feed.items(str(written[-1]))] if written else None
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
# CMUX_TIMESTAMP=none makes the Linux signer drop the time stamp and the Developer ID check
# (scripts/ci/rcodesign-sign-bundle-dev.sh); the publisher must never set it.
check("CMUX_TIMESTAMP" not in workflow, "the DEV workflow never sets CMUX_TIMESTAMP")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: cmux NEXT DEV tip feed")
