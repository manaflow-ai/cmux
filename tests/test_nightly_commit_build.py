#!/usr/bin/env python3
"""Per-commit cmux NIGHTLY builds (scripts/ci/nightly_commit_build.py and the nightly-commit jobs of
cmux-next-dev-daily.yml): the identity rewrite, build.json and its signatures, and the publisher's
gates (off by default, latest wins by skipping, write-once, never the nightly feed)."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_commit_build.py"
spec = importlib.util.spec_from_file_location("nightly_commit_build", SCRIPT)
ncb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ncb)

failures = []
SHA = "0123456789abcdef0123456789abcdef01234567"
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"


def check(ok, message):
    if not ok:
        failures.append(message)


def run(*args, env=None):
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


def dev_plist(path: Path, **overrides) -> None:
    plist = {
        "CFBundleName": "cmux NEXT DEV", "CFBundleDisplayName": "cmux NEXT DEV",
        "CFBundleIdentifier": "com.cmuxterm.app.debug.next", "CFBundleExecutable": "cmux",
        "CFBundleShortVersionString": "0.64.0", "CFBundleVersion": "108", "CMUXCommit": SHA,
        "CFBundleIconFile": "AppIcon-Debug", "CFBundleIconName": "AppIcon-Debug",
        "CFBundleURLTypes": [{"CFBundleURLName": "com.cmuxterm.app.debug.next", "CFBundleURLSchemes": ["cmux"]},
                             {"CFBundleURLName": "com.cmuxterm.app.debug.next.auth", "CFBundleURLSchemes": ["cmux-dev-next"]}],
        "LSEnvironment": {"CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev-next", "OTHER": "kept"},
        "SUFeedURL": "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml", "SUPublicEDKey": "x" * 43 + "=",
    }
    plist.update(overrides)
    path.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    key = "IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM="

    # identity: every key prepare_variant and nightly-next-legacy-identity.sh set; CMUXCommit stays.
    info = tmp / "Info.plist"
    dev_plist(info)
    done = run("identity", info, "4447000000001", FEED, key, "0.64.0-nightly.4447000000001")
    check(done.returncode == 0, f"identity rewrites a DEV plist: {done.stderr}")
    data = info.read_bytes()
    plist = plistlib.loads(data)
    check(data.startswith(b"bplist00"), "identity keeps the plist's binary format")
    check(plist["CFBundleName"] == plist["CFBundleDisplayName"] == "cmux NIGHTLY", "the app is named cmux NIGHTLY")
    check(plist["CFBundleIdentifier"] == "com.cmuxterm.app.nightly", "the bundle id is the nightly's")
    check(plist["CFBundleURLTypes"][1]["CFBundleURLSchemes"] == ["cmux-nightly"]
          and plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["cmux"], "only the auth URL scheme becomes cmux-nightly")
    check(plist["LSEnvironment"] == {"OTHER": "kept"}, "the CMUX_AUTH_CALLBACK_SCHEME override is dropped, nothing else")
    check(plist["SUFeedURL"] == FEED and plist["SUPublicEDKey"] == key, "the nightly-next feed and key replace the tip's")
    check(plist["CFBundleVersion"] == "4447000000001" and plist["CFBundleShortVersionString"] == "0.64.0-nightly.4447000000001",
          "the build and marketing version are the nightly's")
    check(plist["CMUXCommit"] == SHA, "CMUXCommit stays")
    check(plist["CFBundleIconFile"] == plist["CFBundleIconName"] == "AppIcon-Nightly", "the nightly icon is named")
    dev_plist(info, LSEnvironment={"CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev-next"})
    run("identity", info, "4447000000001", FEED, key, "0.64.0-nightly.4447000000001")
    check("LSEnvironment" not in plistlib.loads(info.read_bytes()), "an emptied LSEnvironment is removed")

    for label, overrides, args in (
        ("a non-DEV app", {"CFBundleIdentifier": "com.cmuxterm.app"}, ()),
        ("an app with no full CMUXCommit", {"CMUXCommit": SHA[:7]}, ()),
        ("an app whose second URL type is not auth", {"CFBundleURLTypes": [{"CFBundleURLName": "a"}, {"CFBundleURLName": "b"}]}, ()),
        ("the tip feed", {}, ("https://files-next.cmux.com/nightly-next/tip/appcast-arm64.xml",)),
        ("a feed off files-next", {}, ("https://files.cmux.com/nightly/appcast-arm64.xml",)),
    ):
        dev_plist(info, **overrides)
        before = info.read_bytes()
        done = run("identity", info, "4447000000001", *(args or (FEED,)), key, "0.64.0-nightly.4447000000001")
        check(done.returncode != 0 and info.read_bytes() == before, f"identity refuses {label} and leaves it alone")
    dev_plist(info)
    check(run("identity", info, "4447000000001", FEED, key, "0.64.0-tip.4447000000001").returncode != 0,
          "identity refuses a marketing version that is not <V>-nightly.<build>")

    # URL types: the nightly's names (project bundle id) and Default rank for http/https.
    dev_plist(info, CFBundleURLTypes=[
        {"CFBundleURLName": "com.cmuxterm.app.debug.next.web", "CFBundleURLSchemes": ["http", "https"], "LSHandlerRank": "Alternate"},
        {"CFBundleURLName": "com.cmuxterm.app.debug.next.auth", "CFBundleURLSchemes": ["cmux-next-dev"], "LSHandlerRank": "Default"}])
    run("identity", info, "4447000000001", FEED, key, "0.64.0-nightly.4447000000001")
    types = plistlib.loads(info.read_bytes())["CFBundleURLTypes"]
    check([t["CFBundleURLName"] for t in types] == ["com.cmuxterm.app.web", "com.cmuxterm.app.auth"]
          and types[0]["LSHandlerRank"] == "Default" and types[1]["CFBundleURLSchemes"] == ["cmux-nightly"],
          f"URL types take the nightly's names and web rank: {types}")

    # marketing-version: nightly_version.py next-base's line from the source commit's cmux-tui/Cargo.toml.
    cargo = tmp / "Cargo.toml"
    cargo.write_text('[workspace]\nmembers = []\n\n[workspace.package]\nversion = "1.0.0"\nedition = "2021"\n')
    done = run("marketing-version", cargo, "4447000000001")
    check(done.returncode == 0 and done.stdout.strip() == "1.0.0-nightly.4447000000001",
          f"the marketing version is <V>-nightly.<build>: {done.stdout!r} {done.stderr!r}")
    cargo.write_text('[workspace.package]\nversion = "1.0"\n')
    check(run("marketing-version", cargo, "1").returncode != 0, "a version that is not MAJOR.MINOR.PATCH is refused")
    cargo.write_text('[package]\nversion = "1.0.0"\n')
    check(run("marketing-version", cargo, "1").returncode != 0, "a Cargo.toml with no [workspace.package] version is refused")

    # icns: the repository's own AppIcon-Nightly set, every macOS size, PNG elements.
    iconset = ROOT / "Assets.xcassets/AppIcon-Nightly.appiconset"
    if iconset.is_dir():
        out_icns = tmp / "AppIcon-Nightly.icns"
        done = run("icns", iconset, out_icns)
        check(done.returncode == 0, f"icns builds AppIcon-Nightly.icns: {done.stderr}")
        blob = out_icns.read_bytes()
        check(blob[:4] == b"icns" and int.from_bytes(blob[4:8], "big") == len(blob), "the icns header names its length")
        kinds, at = [], 8
        while at < len(blob):
            kinds.append(blob[at:at + 4])
            at += int.from_bytes(blob[at + 4:at + 8], "big")
        check(at == len(blob) and sorted(kinds) == sorted(ncb.ICNS_TYPES.values()), f"every iconutil element once: {kinds}")
    partial = tmp / "partial.appiconset"
    partial.mkdir()
    (partial / "16.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (partial / "Contents.json").write_text(json.dumps({"images": [{"idiom": "mac", "size": "16x16", "scale": "1x", "filename": "16.png"}]}))
    check(run("icns", partial, tmp / "p.icns").returncode != 0, "icns refuses a set without every size")

    # entitlements: cmux.nightly.entitlements less the tunnel keys (feat-cmux-next's copy).
    out = tmp / "app.entitlements"
    done = run("entitlements", ROOT / "cmux.nightly.entitlements", out)
    check(done.returncode == 0, f"entitlements derive from cmux.nightly.entitlements: {done.stderr}")
    ent = plistlib.loads(out.read_bytes())
    check(not set(ncb.TUNNEL_KEYS) & set(ent), "the tunnel keys are dropped")
    check(ent["com.apple.application-identifier"] == "7WLXT3NR37.com.cmuxterm.app.nightly"
          and ent["keychain-access-groups"] == ["7WLXT3NR37.com.cmuxterm.app.nightly"]
          and ent.get("com.apple.developer.web-browser.public-key-credential") is True,
          "the App ID, keychain group and passkey entitlement stay")
    check(run("entitlements", ROOT / "cmux.next-dev.entitlements", out).returncode != 0,
          "entitlements refuse a file that is not the nightly App ID's")

    # profile: the NIGHTLY Developer ID profile only.
    prof = tmp / "profile.plist"
    for label, body, ok in (
        ("the NIGHTLY Developer ID profile", {"ProvisionsAllDevices": True,
         "Entitlements": {"com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app.nightly"}}, True),
        ("another App ID", {"ProvisionsAllDevices": True,
         "Entitlements": {"com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app"}}, False),
        ("a development profile", {"ProvisionedDevices": ["x"],
         "Entitlements": {"com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app.nightly"}}, False),
    ):
        prof.write_bytes(plistlib.dumps(body))
        check((run("profile", prof).returncode == 0) == ok, f"profile {'accepts' if ok else 'refuses'} {label}")

    # channel: verify-app-bundle-channel-metadata.sh nightly's plist and icon checks.
    app = tmp / "cmux NIGHTLY.app"
    (app / "Contents/Resources").mkdir(parents=True)
    dev_plist(app / "Contents/Info.plist")
    run("identity", app / "Contents/Info.plist", "4447000000001", FEED, key, "0.64.0-nightly.4447000000001")
    check(run("channel", app).returncode != 0, "channel refuses an app without AppIcon-Nightly.icns")
    (app / "Contents/Resources/AppIcon-Nightly.icns").write_bytes(b"icns")
    check(run("channel", app).returncode == 0, "channel accepts the nightly identity with its icon")

    # newest-handoff: only this workflow's publish runs count, never candidates.
    runs = tmp / "runs.json"
    runs.write_text(json.dumps({"workflow_runs": [
        {"display_title": "cmux NEXT DEV daily · publish 44470000000"},
        {"display_title": "cmux NEXT DEV daily · publish 44480000000"},
        {"display_title": "cmux NEXT DEV candidate · " + SHA + " · source 44490000000"},
        {"display_title": "cmux NEXT DEV daily"}]}))
    done = run("newest-handoff", runs)
    check(done.stdout.strip() == "44480000000", f"the newest handed source run: {done.stdout!r}")
    runs.write_text(json.dumps({"workflow_runs": []}))
    check(run("newest-handoff", runs).stdout.strip() == "0", "no publish runs read as 0")

    # index, sign and check: the folder `cmux app try` reads.
    seed = base64.b64encode(os.urandom(32)).decode()
    signing = {"TEST_SPARKLE_KEY": seed}
    folder = tmp / SHA
    folder.mkdir()
    build = "4447000000001"
    dmg = folder / f"cmux-nightly-commit-macos-arm64-{build}.dmg"
    dmg.write_bytes(os.urandom(4096))
    public = base64.b64encode(ncb.tip_appcast_linux.sign_file(base64.b64decode(seed), str(dmg))[1]).decode()
    done = run("sign", "TEST_SPARKLE_KEY", dmg, f"{dmg}.signature.json", "--public-key", public, env=signing)
    check(done.returncode == 0, f"sign writes the DMG's sidecar: {done.stderr}")
    sidecar = json.loads(Path(f"{dmg}.signature.json").read_text())
    check(set(sidecar) == {"edSignature", "length"} and sidecar["length"] == 4096,
          "the sidecar is ArchiveSignature's {edSignature, length}")
    check(run("sign", "TEST_SPARKLE_KEY", dmg, tmp / "x.json", "--public-key", key, env=signing).returncode != 0,
          "sign refuses a key that does not derive the pinned public key")
    check(run("sign", "UNSET_KEY", dmg, tmp / "x.json").returncode != 0, "sign refuses an empty key variable")
    done = run("index", "--commit", SHA, "--build", build, "--dmg", dmg, "--source-run", "44470000000",
               "--published-at", "1795000000", "--out", folder / "build.json")
    check(done.returncode == 0, f"index writes build.json: {done.stderr}")
    raw = (folder / "build.json").read_bytes()
    record = json.loads(raw)
    check(raw == json.dumps(record, sort_keys=True, separators=(",", ":")).encode(), "build.json is compact sorted JSON")
    check(record == {"schema": 1, "purpose": "cmux-nightly-commit-build", "commit": SHA, "build": build, "arch": "arm64",
                     "dmg": dmg.name, "length": 4096, "sha256": ncb.sha256(dmg), "source_run": 44470000000,
                     "published_at": 1795000000}, f"build.json names the commit, build and DMG: {record}")
    run("sign", "TEST_SPARKLE_KEY", folder / "build.json", folder / "build.json.signature.json", env=signing)
    done = run("check", folder, "--public-key", public, "--commit", SHA)
    check(done.returncode == 0, f"check passes the folder it wrote: {done.stderr}")
    check(run("check", folder, "--public-key", key).returncode != 0, "check refuses signatures by another key")
    check(run("check", folder, "--public-key", public, "--commit", "f" * 40).returncode != 0,
          "check refuses a folder for another commit")
    for label, bad_build, source in (("a build that is not source run + attempt", "44470000000", "44470000000"),
                                     ("a DMG named for another build", "4447000000002", "44470000000")):
        check(run("index", "--commit", SHA, "--build", bad_build, "--dmg", dmg, "--source-run", source,
                  "--out", tmp / "bad.json").returncode != 0, f"index refuses {label}")
    original = dmg.read_bytes()
    dmg.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
    check(run("check", folder, "--public-key", public).returncode != 0, "check refuses a DMG with other bytes")
    dmg.write_bytes(original)
    (folder / "build.json").write_bytes(raw.replace(b'"published_at":1795000000', b'"published_at":1795000001'))
    check(run("check", folder, "--public-key", public).returncode != 0, "check refuses a build.json its signature does not cover")
    (folder / "build.json").write_bytes(raw)
    check(run("check", folder, "--public-key", public).returncode == 0, "the restored folder checks again")

# The workflow: off by default, from the sign job's source, never the nightly feed, build.json last.
workflow = (ROOT / ".github/workflows/cmux-next-dev-daily.yml").read_text()
jobs = workflow[workflow.index("\n  nightly-commit-sign:\n"):]
sign_job = jobs[:jobs.index("\n  nightly-commit-dmg-build:\n")]
dmg_job = jobs[jobs.index("\n  nightly-commit-dmg-build:\n"):jobs.index("\n  nightly-commit-publish:\n")]
publish_job = jobs[jobs.index("\n  nightly-commit-publish:\n"):]
code = "\n".join(line for line in jobs.splitlines() if not line.lstrip().startswith("#"))
check("vars.NIGHTLY_COMMIT_BUILDS == '1'" in sign_job.split("steps:")[0] and "inputs.pr_head_sha == ''" in sign_job.split("steps:")[0],
      "the per-commit NIGHTLY is off unless vars.NIGHTLY_COMMIT_BUILDS is 1, and never for a candidate")
for label, job in (("nightly-commit-sign", sign_job), ("nightly-commit-dmg-build", dmg_job), ("nightly-commit-publish", publish_job)):
    head = job.split("steps:")[0]
    check("concurrency:" not in head, f"{label} has no concurrency group (it would replace pending runs)")
    check("continue-on-error: true" in head, f"{label} is advisory, so the dispatcher never re-hands the source")
check("needs.nightly-commit-sign.outputs.build != ''" in dmg_job.split("steps:")[0]
      and "needs.nightly-commit-sign.outputs.build != ''" in publish_job.split("steps:")[0],
      "the Mac and publish jobs run only for a signed build")
check("environment:" not in dmg_job and "secrets." not in dmg_job, "the Mac job holds no secret")
check("environment: release" in sign_job and "environment: release" in publish_job, "the signing jobs use the release environment")
# The feed URL is the one line that names an appcast: the app reads it, nothing here writes it.
unfed = "\n".join(line for line in code.splitlines() if "NIGHTLY_FEED_URL: https://" not in line)
for word in ("appcast", "tip_feed.py", "r2_cas.py put", "nightly-next/tip", "gh release", "publish-nightly-next-r2.py",
             "notes/", "gh run cancel", "/cancel"):
    check(word not in unfed, f"the per-commit jobs never touch the nightly feed or cancel anything ({word})")
for secret in ("APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64", "SPARKLE_NEXT_PRIVATE_KEY", "NIGHTLY_NEXT_R2_ACCESS_KEY_ID",
               "NIGHTLY_NEXT_R2_SECRET_ACCESS_KEY", "NIGHTLY_NEXT_R2_ACCOUNT_ID"):
    check(f"secrets.{secret}" in sign_job and f"for name in" in sign_job and secret in sign_job.split("for name in")[1].split("done")[0],
          f"the sign job fails closed, by name, without {secret}")
check("IOPItMLjtc4NsROTNZ6a/jsUW+C4fcicl6SNjVVvzRM=" in sign_job and "sparkle-public-key SPARKLE_NEXT_PRIVATE_KEY" in sign_job,
      "the nightly-next key must derive the pinned nightly-next public key")
check("NIGHTLY_FEED_URL: https://files-next.cmux.com/nightly-next/appcast-arm64.xml" in sign_job,
      "a tried build carries the nightly-next feed, so Sparkle moves it on to the next nightly")
check('echo "build=${SOURCE_RUN_ID}$(printf \'%02d\' "$GITHUB_RUN_ATTEMPT")"' in sign_job,
      "the build number is the source run id and this publisher's two-digit attempt")
decide = sign_job[sign_job.index("name: Decide the build"):sign_job.index("name: Download the exact Release app artifact")]
check(decide.index("newest-handoff") < decide.index('echo "build=') and decide.index("build.json") < decide.index('echo "build='),
      "a newer handed source or an existing build.json skips before the build is set")
check("./scripts/ci/nightly-commit-identity.sh" in sign_job and "cmux-next-dev-daily-unsigned-${SOURCE_SHA}" in sign_job,
      "the sign job re-identifies the same unsigned Release app the DEV sign job signs")
steps = [dmg_job.find(marker) for marker in ("codesign --verify --deep --strict", "Print :com.apple.application-identifier",
                                             "Print :keychain-access-groups:0", "verify-app-bundle-channel-metadata.sh \"$app\" nightly",
                                             "-format ULMO")]
check(-1 not in steps and steps == sorted(steps), "the Mac job checks the signed app with Apple's tools, then builds the DMG")
uploads = publish_job[publish_job.index("name: Publish under nightly-next/commits/<sha>"):]
order = [uploads.find(f'upload {name}') for name in ('"$dmg"', '"$dmg.signature.json"', "build.json.signature.json", "build.json application")]
check(-1 not in order and order == sorted(order), "the DMG and signatures upload before build.json")
check(uploads.count("--write-once") == 1 and "R2_BUCKET: cmux-nightly-next" in uploads,
      "every upload is write-once to the bucket behind files-next.cmux.com")
check(publish_job.index("rcodesign-notarize-dmg-dev.sh") < publish_job.index("nightly_commit_build.py sign")
      < publish_job.index("nightly_commit_build.py check") < publish_job.index("upload-r2-object.py"),
      "the DMG is notarized and stapled, then signed and checked, then published")
script = (ROOT / "scripts/ci/nightly-commit-identity.sh").read_text()
check("CMUX_SIGN_MODE=all" in script and "rcodesign-sign-bundle-dev.sh" in script and "embedded.provisionprofile" in script,
      "the identity script embeds the NIGHTLY profile and signs the whole bundle inside out")

if failures:
    print("FAIL")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("PASS: per-commit cmux NIGHTLY builds")
