#!/usr/bin/env python3
"""Make the payload of the Cloud machine channel or of a Linux release file, both signed by CI.

Cloud machines update their cmux-tui and cmux-tui-hook from this channel by themselves
(`cmux host update`, cmux-tui/crates/cmux-host/src/updater). CI points it at every
feat-cmux-next push whose commit-addressed cmux-tui build is published and read back
(point-machine-channel in .github/workflows/cmux-tui-artifacts.yml).

The payload names, per Linux target, each binary's immutable URL, sha256 and size. The
sha256 comes from the commit's published manifest (--manifest), or, before the manifest is
published, from this run's own build of the binary (--binaries-dir: point-machine-channel-early
uploads the Linux binaries ahead of publish). Either way it is checked again here against a
download of every binary from its URL, which also gives its size:

  {"schema": 1, "purpose": "cmux-cloud-machine-update", "channel": "cloud-machine",
   "key": "<sha256 over the binaries>", "commit": "<sha>", "committed_at": T,
   "published_at": T, "expires_at": T,
   "targets": {"x86_64-unknown-linux-musl": {"cmux-tui": {"url", "sha256", "size"},
                                              "cmux-tui-hook": {...}}, ...}}

scripts/cmux-next/web-ota-pointer.py signs, verifies and orders it: the same envelope and
ed25519 key as the web update pointers. The machine checks `purpose` and `channel`, and the
app's web updater refuses any channel but its own, so neither file stands in for the other.

With --purpose linux-release it makes the payload of the Linux release files instead
(cmuxterm-hq docs/design/linux-signed-packages.md): cmux-tui/<commit>/release.json, written once,
and the channel pointer cmux-tui/channels/linux-<channel>.json, both the same signed payload
(scripts/ci/cmux-machine-channel-point.sh). It names every Linux binary the build publishes (musl,
and the glibc-named copies of the same binaries) and a version that sorts by commit time:

  {"schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
   "version": "<cmux-tui Cargo version>+<committed_at UTC YYYYMMDDHHMMSS>.<commit[:12]>",
   "commit": "<sha>", "committed_at": T, "published_at": T, "expires_at": T,
   "targets": {"x86_64-unknown-linux-gnu": {"cmux-tui": {"url", "sha256", "size"},
                                             "cmux-tui-hook": {...}}, ...}}

An installer holds the channel pointer to expires_at; the per-commit file carries the same field,
but an installer that asks for a version by name does not enforce it.

Usage:
  cmux-machine-channel.py payload (--manifest M | --binaries-dir B) --commit SHA --committed-at T
      --download-dir D --out P [--purpose linux-release --channel C [--cargo-version V]]
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nightly_version  # noqa: E402

SCHEMA = 1
PURPOSE = "cmux-cloud-machine-update"
CHANNEL = "cloud-machine"
FILES = "https://files.cmux.com/cmux-tui"
TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
NAMES = ("cmux-tui", "cmux-tui-hook")
# A machine refuses a channel file older than this: CI re-signs on every push that builds.
LIFETIME = 30 * 24 * 3600
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

LINUX_RELEASE_PURPOSE = "cmux-linux-release"
# The channels a Linux release pointer may name (cmux-tui/channels/linux-<channel>.json).
LINUX_RELEASE_CHANNELS = ("stable", "nightly", "feat-cmux-next")
# Every Linux target a cmux-tui build publishes: the musl builds and their glibc-named copies
# (compatibility_target in .github/workflows/cmux-tui-build-package.yml).
LINUX_RELEASE_TARGETS = ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
                         "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")


def fail(message):
    print(f"cmux-machine-channel: {message}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_sha256(args):
    """The sha256 of each published name, from the manifest or from the binaries in --binaries-dir."""
    if args.manifest:
        manifest = json.load(open(args.manifest))
        if manifest.get("commit") != args.commit:
            fail(f"{args.manifest} is the manifest of {manifest.get('commit')!r}, not {args.commit}")
        return manifest.get("binaries") or {}
    binaries = {}
    for target in args.targets:
        for name in NAMES:
            path = os.path.join(args.binaries_dir, f"{name}-{target}")
            if os.path.isfile(path):
                binaries[f"{name}-{target}"] = sha256_file(path)
    return binaries


def release_version(cargo_version, commit, committed_at):
    """`<cargo version>+<committed_at UTC YYYYMMDDHHMMSS>.<commit[:12]>`: dpkg and rpm compare the part
    after `+` digit run by digit run, so builds sort by commit time and two never tie."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", cargo_version):
        fail(f"cargo version {cargo_version!r} is not MAJOR.MINOR.PATCH")
    return f"{cargo_version}+{time.strftime('%Y%m%d%H%M%S', time.gmtime(committed_at))}.{commit[:12]}"


def attested(path, commit, signer_workflow):
    """True when GitHub holds a build-provenance attestation for the file's bytes, signed by
    signer_workflow (owner/repo/.github/workflows/name.yml) building commit. The manifest's sha256
    comes from the same bucket as the binaries, so it proves nothing about who built them: only the
    attestation, which publish makes for every binary it uploads, does (as install-cmux-tui-client.sh
    checks the manifest). A rate-limited answer is retried; any other refusal is final."""
    repo = signer_workflow.split("/.github/", 1)[0]
    argv = ["gh", "attestation", "verify", path, "--repo", repo, "--signer-workflow", signer_workflow,
            "--source-digest", commit]
    for attempt in range(4):
        result = subprocess.run(argv, capture_output=True, text=True)
        if result.returncode == 0:
            return True
        if "rate limit" not in (result.stdout + result.stderr).lower() or attempt == 3:
            sys.stderr.write(result.stdout + result.stderr)
            return False
        time.sleep(30 * 2 ** attempt)
    return False


def payload(args):
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        fail(f"bad commit {args.commit!r}")
    release = args.purpose == "linux-release"
    if release and args.channel not in LINUX_RELEASE_CHANNELS:
        fail(f"--purpose linux-release needs --channel, one of {', '.join(LINUX_RELEASE_CHANNELS)}")
    if not release and (args.channel or args.cargo_version or args.attest_signer_workflow):
        fail("--channel, --cargo-version and --attest-signer-workflow are for --purpose linux-release")
    if release and not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml",
                                    args.attest_signer_workflow or ""):
        fail("--purpose linux-release needs --attest-signer-workflow owner/repo/.github/workflows/name.yml: "
             "CI signs only bytes its own build attested")
    args.targets = LINUX_RELEASE_TARGETS if release else TARGETS
    binaries = expected_sha256(args)
    os.makedirs(args.download_dir, exist_ok=True)
    targets = {}
    lines = []
    for target in args.targets:
        for name in NAMES:
            published = f"{name}-{target}"
            sha = binaries.get(published)
            if not re.fullmatch(r"[0-9a-f]{64}", str(sha or "")):
                fail(f"no sha256 for {published} ({args.manifest or args.binaries_dir})")
            url = f"{FILES}/{args.commit}/{published}"
            path = os.path.join(args.download_dir, published)
            subprocess.run(["curl", "-fsS", "--retry", "3", "--max-time", "600", "-o", path, f"{url}?channel=1"],
                           check=True)
            if sha256_file(path) != sha:
                fail(f"{url} does not have the expected sha256 {sha}")
            if release and not attested(path, args.commit, args.attest_signer_workflow):
                fail(f"{url} (sha256 {sha}) has no build-provenance attestation by {args.attest_signer_workflow} "
                     f"for {args.commit}; not signing bytes this CI did not build")
            targets.setdefault(target, {})[name] = {"url": url, "sha256": sha, "size": os.path.getsize(path)}
            os.remove(path)  # one binary on disk at a time
            lines.append(f"{published}:{sha}")
    now = int(time.time())
    committed_at = int(args.committed_at)
    if release:
        try:
            cargo_version = args.cargo_version or nightly_version.next_base(ROOT)
        except nightly_version.Refused as error:
            fail(str(error))
        value = {
            "schema": SCHEMA, "purpose": LINUX_RELEASE_PURPOSE, "channel": args.channel,
            "version": release_version(cargo_version, args.commit, committed_at),
            "commit": args.commit, "committed_at": committed_at,
            "published_at": now, "expires_at": now + LIFETIME, "targets": targets,
        }
    else:
        value = {
            "schema": SCHEMA, "purpose": PURPOSE, "channel": CHANNEL,
            "key": hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest(),
            "commit": args.commit, "committed_at": committed_at,
            "published_at": now, "expires_at": now + LIFETIME, "targets": targets,
        }
    with open(args.out, "wb") as out:
        out.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest")
    source.add_argument("--binaries-dir")
    for name in ("--commit", "--committed-at", "--download-dir", "--out"):
        p.add_argument(name, required=True)
    p.add_argument("--purpose", choices=("cloud-machine", "linux-release"), default="cloud-machine")
    p.add_argument("--channel", help="--purpose linux-release: the channel this build publishes to")
    p.add_argument("--cargo-version", help="--purpose linux-release: default cmux-tui/Cargo.toml's version")
    p.add_argument("--attest-signer-workflow",
                   help="--purpose linux-release: the workflow whose attestation every binary must carry")
    args = parser.parse_args(argv[1:])
    payload(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
