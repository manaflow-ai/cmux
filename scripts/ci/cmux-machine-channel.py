#!/usr/bin/env python3
"""Make the payload of the Cloud machine channel (cmux-tui/channels/cloud-machine.json).

Cloud machines update their cmux-tui and cmux-tui-hook from this channel by themselves
(`cmux host update`, cmux-tui/crates/cmux-host/src/updater). CI points it at every
feat-cmux-next push whose commit-addressed cmux-tui build is published and read back
(point-machine-channel in .github/workflows/cmux-tui-artifacts.yml).

The payload names, per Linux target, each binary's immutable URL, sha256 and size. The
sha256 comes from the commit's published manifest and is checked again here against a
download of every binary, which also gives its size:

  {"schema": 1, "purpose": "cmux-cloud-machine-update", "channel": "cloud-machine",
   "key": "<sha256 over the binaries>", "commit": "<sha>", "committed_at": T,
   "published_at": T, "expires_at": T,
   "targets": {"x86_64-unknown-linux-musl": {"cmux-tui": {"url", "sha256", "size"},
                                              "cmux-tui-hook": {...}}, ...}}

scripts/cmux-next/web-ota-pointer.py signs, verifies and orders it: the same envelope and
ed25519 key as the web update pointers. The machine checks `purpose` and `channel`, and the
app's web updater refuses any channel but its own, so neither file stands in for the other.

Usage:
  cmux-machine-channel.py payload --manifest M --commit SHA --committed-at T --download-dir D --out P
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

SCHEMA = 1
PURPOSE = "cmux-cloud-machine-update"
CHANNEL = "cloud-machine"
FILES = "https://files.cmux.com/cmux-tui"
TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
NAMES = ("cmux-tui", "cmux-tui-hook")
# A machine refuses a channel file older than this: CI re-signs on every push that builds.
LIFETIME = 30 * 24 * 3600


def fail(message):
    print(f"cmux-machine-channel: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload(args):
    manifest = json.load(open(args.manifest))
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        fail(f"bad commit {args.commit!r}")
    if manifest.get("commit") != args.commit:
        fail(f"{args.manifest} is the manifest of {manifest.get('commit')!r}, not {args.commit}")
    binaries = manifest.get("binaries") or {}
    os.makedirs(args.download_dir, exist_ok=True)
    targets = {}
    lines = []
    for target in TARGETS:
        for name in NAMES:
            published = f"{name}-{target}"
            sha = binaries.get(published)
            if not re.fullmatch(r"[0-9a-f]{64}", str(sha or "")):
                fail(f"the manifest has no sha256 for {published}")
            url = f"{FILES}/{args.commit}/{published}"
            path = os.path.join(args.download_dir, published)
            subprocess.run(["curl", "-fsS", "--retry", "3", "--max-time", "600", "-o", path, f"{url}?channel=1"],
                           check=True)
            if sha256_file(path) != sha:
                fail(f"{url} does not have the manifest's sha256 {sha}")
            targets.setdefault(target, {})[name] = {"url": url, "sha256": sha, "size": os.path.getsize(path)}
            lines.append(f"{published}:{sha}")
    now = int(time.time())
    value = {
        "schema": SCHEMA, "purpose": PURPOSE, "channel": CHANNEL,
        "key": hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest(),
        "commit": args.commit, "committed_at": int(args.committed_at),
        "published_at": now, "expires_at": now + LIFETIME, "targets": targets,
    }
    with open(args.out, "wb") as out:
        out.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    for name in ("--manifest", "--commit", "--committed-at", "--download-dir", "--out"):
        p.add_argument(name, required=True)
    args = parser.parse_args(argv[1:])
    payload(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
