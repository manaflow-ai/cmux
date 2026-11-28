#!/usr/bin/env python3
"""Unpack a verified published NIGHTLY for the isolated journal recovery journey.

No app is launched or modified. The output directory must be new. The receipt binds
the signed download, app source, bundled daemon source and actual executable bytes;
it is provenance, never a recovery verdict.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

CI = Path(__file__).resolve().parents[1] / "ci"
sys.path.insert(0, str(CI))
import nightly_next_artifact_check as artifact
from nightly_next_fix_forward import build_run

FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def pick_build(xml: bytes, build: str) -> dict[str, str]:
    if not re.fullmatch(r"[0-9]{3,}", build):
        raise ValueError("build must be an explicit numbered NIGHTLY")
    matches = []
    for item in ET.fromstring(xml).iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        version = item.findtext(SPARKLE + "version")
        if version is None:
            version = enclosure.get(SPARKLE + "version", "")
        if version.strip() != build:
            continue
        url = enclosure.get("url", "")
        expected = f"cmux-nightly-next-macos-arm64-{build}.dmg"
        parsed = urlsplit(url)
        allowed = (
            parsed.netloc == "files-next.cmux.com" and parsed.path.startswith("/nightly-next/")
        ) or (
            parsed.netloc == "github.com"
            and parsed.path.startswith("/manaflow-ai/cmux/releases/download/nightly-next/")
        )
        if not (parsed.scheme == "https" and allowed and parsed.path.rsplit("/", 1)[-1] == expected):
            raise ValueError("feed enclosure is not this numbered arm64 NIGHTLY")
        length = enclosure.get("length", "")
        signature = enclosure.get(SPARKLE + "edSignature", "")
        if not length.isdigit() or int(length) <= 0 or not signature:
            raise ValueError("feed enclosure has no length or signature")
        matches.append({"url": url, "length": length, "signature": signature})
    if len(matches) != 1:
        raise ValueError("the feed must contain exactly one signed enclosure for this build")
    return matches[0]


def run(*args: str, timeout: int = 120) -> str:
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def full_commit(repo: Path, sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        raise ValueError("source receipt does not name a commit")
    return run("git", "-C", str(repo), "rev-parse", "--verify", f"{sha}^{{commit}}")


def contains(repo: Path, source: str, required: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", required, source],
        check=True, timeout=30,
    )


def app_receipt(app: Path, build: str, source: str, repo: Path, required: str) -> dict:
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "com.cmuxterm.app.nightly":
        raise ValueError("download is not the NIGHTLY app")
    if str(info.get("CFBundleVersion")) != build:
        raise ValueError("app build differs from the feed")
    artifact.check_commit(str(info.get("CMUXCommit", "")), source)
    binary = app / "Contents/Resources/bin/cmux-tui"
    # Symlinks in the signed bundle are expected, but cannot point outside it.
    binary.resolve(strict=True).relative_to(app.resolve())
    if not os.access(binary, os.X_OK):
        raise ValueError("bundled daemon is not executable")
    version = (binary.parent / "cmux-tui.version").read_text()
    fields = dict(line.split("=", 1) for line in version.splitlines() if "=" in line)
    daemon_source = full_commit(repo, fields.get("commit", ""))
    required = full_commit(repo, required)
    contains(repo, source, required)
    contains(repo, daemon_source, required)
    binaries = {}
    # Split NIGHTLY builds may launch the host/holder companions. Bind those too,
    # rather than describing the thin client's bytes as the running engine.
    for name in ("cmux-tui", "acpmux", "cmux-tui-host", "cmux-holder", "cmux-cloud"):
        candidate = binary.parent / name
        if candidate.exists():
            candidate.resolve(strict=True).relative_to(app.resolve())
            binaries[name] = {"path": str(candidate), "sha256": artifact.file_sha256(candidate)}
    return {
        "source_sha": source,
        "daemon_source_sha": daemon_source,
        "contains_sha": required,
        "app_build": build,
        "workflow_run": build_run(build),
        "binary_path": str(binary),
        "binary_sha256": artifact.file_sha256(binary),
        "runtime_binaries": binaries,
        "daemon_version_receipt": version,
    }


def prepare(build: str, out: Path, repo: Path, required: str) -> Path:
    if sys.platform != "darwin":
        raise ValueError("NIGHTLY extraction requires a managed fleet Mac")
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    feed = out / "feed.xml"
    run("curl", "-fsSL", "--proto", "=https", "--max-time", "60", "-A",
        "cmux-journal-nightly-recovery/1", "-H",
        "Cache-Control: no-cache", "-o", str(feed), FEED, timeout=70)
    selected = pick_build(feed.read_bytes(), build)
    dmg = out / "nightly.dmg"
    run("curl", "-fsSL", "--proto", "=https", "--max-time", "600", "-A",
        "cmux-journal-nightly-recovery/1", "-o", str(dmg),
        selected["url"], timeout=610)
    digest = artifact.check_dmg(dmg, selected["length"], selected["signature"])
    source, source_receipt = artifact.expected_commit(
        "manaflow-ai/cmux", build, FEED.rsplit("/", 1)[0] + "/notes",
    )
    mount = out / "mount"
    mount.mkdir()
    app = out / "cmux NIGHTLY.app"
    # Always try to detach this unique mount even if attach timed out after mounting.
    try:
        run("hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", str(mount))
        apps = list(mount.glob("*.app"))
        if len(apps) != 1:
            raise ValueError("NIGHTLY DMG must hold exactly one app")
        run("ditto", str(apps[0]), str(app), timeout=300)
    finally:
        run("hdiutil", "detach", str(mount), "-quiet")
    run("codesign", "--verify", "--deep", "--strict", str(app), timeout=180)
    run("spctl", "-a", "-vv", "--type", "execute", str(app), timeout=180)
    receipt = app_receipt(app, build, source, repo, required)
    receipt.update({
        "published": True, "feed_url": FEED, "artifact_url": selected["url"],
        "artifact_sha256": digest, "source_receipt": source_receipt,
        "app_signature_verified": True,
    })
    target = out / "provenance.json"
    target.write_text(json.dumps(receipt, indent=2) + "\n")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--contains", required=True, help="merged product commit being verified")
    args = parser.parse_args()
    print(prepare(args.build, args.out, args.repo, args.contains))


if __name__ == "__main__":
    main()
