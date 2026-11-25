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
download of every binary from its URL, which also gives its size. With --machine-path the URLs are
the commit's machine copy, cmux-tui/<commit>/machine/<name>-<target>: the Cloud machine channel's
thin-LTO build, which the early job uploads there (scripts/ci/cmux-machine-linux-bytes.sh) so it
never stands in for the shipped fat cmux-tui/<commit>/<name>-<target>. The updater accepts exactly
these two URLs for the payload's commit (cmux-tui/crates/cmux-host/src/updater/channel.rs):

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
(scripts/ci/cmux-machine-channel-point.sh). It names every Linux file an installer fetches for every
target the build publishes (musl, and the glibc-named copies of the same binaries; LINUX_RELEASE_NAMES),
`sequence`, the publish order (the publish time as UTC YYYYMMDDHHMMSS, raised to --min-sequence, one more
than the channel's current sequence, when the clock would not exceed it), and a version that sorts by it:

  {"schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
   "version": "<cmux-tui Cargo version>+<sequence>.<commit[:12]>", "sequence": 20261122110500,
   "commit": "<sha>", "committed_at": T, "published_at": T, "expires_at": T,
   "targets": {"x86_64-unknown-linux-gnu": {"cmux-tui": {"url", "sha256", "size"},
                                             "cmux-tui-hook": {...}, "cmux-tui-acpmux": {...},
                                             "cmux-tui-app-host": {...}}, ...}}

With --purpose mac-live it makes the Mac live update file instead (cmuxterm-hq
docs/design/nightly-live-updates.md): cmux-tui/<commit>/mac-live.json, written once, which `cmux app try`
reads, and cmux-tui/channels/mac-live.json, forward only. It names the commit's aarch64-apple-darwin daemon
binaries the app's bin/ holds (cmux-tui and its companions, from the commit's manifest, each downloaded and
checked like the Cloud machine channel's) and `live_from`, every app commit that can take them live
(`hot-apply.py live-from`, --live-from), and `daemon_from`, the wider list of app commits that can run
them beside their own Swift (the daemon ABI floor only), which the nightly-live channel follows:

  {"schema": 1, "purpose": "cmux-mac-live-update", "channel": "nightly-live", "commit": "<sha>",
   "committed_at": T, "published_at": T, "expires_at": T, "live_from": ["<sha>", "<parent>", ...],
   "daemon_from": ["<sha>", "<parent>", ..., "<grandparent>", ...],
   "targets": {"aarch64-apple-darwin": {"cmux-tui": {"url", "sha256", "size"},
                                        "cmux-tui-app-host": {...}, ...}}}

With --screen-sharing-helper F (mac-live only; F is the helper record of the commit's helper source key,
scripts/ci/screen_sharing_helper_release.py) it also names the NIGHTLY's signed Screen Sharing helper, the zip
cmux-tui/<commit>/cmux-screen-sharing-helper-aarch64-apple-darwin.zip, downloaded and checked like the binaries,
under a NEW top-level key, never inside `targets` (a new name there makes every older `cmux app try` refuse
the file; a new top-level key is ignored by it):

   "screen_sharing_helper": {"url", "sha256", "size", "bundle_id", "team", "designated_requirement"}

With --tree-key K the Linux release payload names the tree's copies instead,
https://files.cmux.com/cmux-tui/tree/<K>/<name>-<target> (scripts/ci/publish-cmux-tui-tree.py publishes them,
RELEASE_NAMES), and carries "tree_key": K. It is the payload of cmux-tui/tree/<K>/release.json, which the run that
publishes the tree signs, and of that commit's release.json and the channel pointer, which then names the tree.
The bytes are still checked against this run's own build (--binaries-dir): a tree another run published (other
bytes) is not this run's to sign.

`alias` makes the payload of cmux-tui/<commit>/release.json for a commit that shares a published tree and built
nothing of its own (mark-tree-commits signs it): from the tree's verified release.json (--tree-release), whose
tree_key must be the one the caller computed for the commit (--tree-key), the same channel, tree_key and targets,
this commit and its commit time, and a fresh sequence, version, published_at and expires_at.

With --purpose mac-app it makes the payload of cmux-tui/<commit>/mac-app.json, the full Mac app build `cmux app try`
installs in place with no GitHub token (reload-build.yml publish-mac-app), written once and never a channel pointer.
It names the app zip reload-build made (--zip, its sha256 and size) at its URL (--url, which must be
https://files.cmux.com/cmux-tui/<commit>/mac-app-release.zip) and the run (--run-id). Nothing is downloaded and
no time field is signed, so two signings of one build are the same bytes:

  {"schema": 1, "purpose": "cmux-mac-app-build", "commit": "<sha>", "configuration": "release", "arch": "arm64",
   "app": {"url", "sha256", "size"}, "run_id": "<github run id>"}

An installer holds the channel pointer to expires_at; the per-commit file carries the same field,
but an installer that asks for a version by name does not enforce it.

Usage:
  cmux-machine-channel.py payload (--manifest M | --binaries-dir B [--machine-path]) --commit SHA
      --committed-at T --download-dir D --out P [--purpose linux-release --channel C [--cargo-version V] [--min-sequence N]]
      [--tree-key K] [--purpose mac-live --live-from F [--screen-sharing-helper R]]
  cmux-machine-channel.py payload --purpose mac-app --commit SHA --zip APP.ZIP --url URL --run-id ID --out P
  cmux-machine-channel.py alias --tree-release R --keys KEYS --tree-key K --channel C --commit SHA
      --committed-at T --out P [--min-sequence N]
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
import screen_sharing_helper_release as helper_release  # noqa: E402

SCHEMA = 1
PURPOSE = "cmux-cloud-machine-update"
CHANNEL = "cloud-machine"
FILES = "https://files.cmux.com/cmux-tui"
TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
NAMES = ("cmux-tui", "cmux-tui-hook")
# A machine refuses a channel file older than this: CI re-signs on every push that builds.
LIFETIME = 30 * 24 * 3600
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
POINTER = os.path.join(ROOT, "scripts", "cmux-next", "web-ota-pointer.py")

LINUX_RELEASE_PURPOSE = "cmux-linux-release"
# The channels a Linux release pointer may name (cmux-tui/channels/linux-<channel>.json).
LINUX_RELEASE_CHANNELS = ("stable", "nightly", "feat-cmux-next")
# Every Linux target a cmux-tui build publishes: the musl builds and their glibc-named copies
# (compatibility_target in .github/workflows/cmux-tui-build-package.yml).
LINUX_RELEASE_TARGETS = ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
                         "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
# Every file an installer fetches (cmuxterm-hq docs/design/linux-signed-packages.md section 2): the CLI and
# daemon, the hook, acpmux (machine join installs it as acpmux), the app host, and on the musl targets the
# agent screen detector (cmux-tui-build-package.yml "Stage binary" requires it there; its glibc-named copy
# goes in when the build has it).
LINUX_RELEASE_NAMES = ("cmux-tui", "cmux-tui-hook", "cmux-tui-acpmux", "cmux-tui-app-host",
                       "cmux-tui-agent-screen-detection")
LINUX_RELEASE_MUSL_ONLY = ("cmux-tui-agent-screen-detection",)


MAC_LIVE_PURPOSE = "cmux-mac-live-update"
MAC_LIVE_CHANNEL = "nightly-live"
MAC_LIVE_TARGET = "aarch64-apple-darwin"
# The names `cmux app try` places in the app's bin/ (cmux-tui/crates/cmux-tui/src/cli/app/try_cmd/live.rs FILES);
# it refuses a file naming any other. cmux-tui is required, the rest go in when the build has them.
MAC_LIVE_NAMES = ("cmux-tui", "cmux-tui-app-host", "cmux-tui-cloud-server", "cmux-tui-browser-host",
                  "cmux-tui-host", "cmux-tui-holder", "cmux-tui-agent-screen-detection")
MAC_LIVE_FROM_MAX = 400
# The full Mac app build `cmux app try` installs in place (try_cmd, reload-build.yml publish-mac-app).
MAC_APP_PURPOSE = "cmux-mac-app-build"
MAC_APP_ZIP = "mac-app-release.zip"
# The top-level key of the signed Screen Sharing helper (try_cmd/helper.rs KEY).
MAC_LIVE_HELPER_KEY = "screen_sharing_helper"


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
        for name in args.names:
            path = os.path.join(args.binaries_dir, f"{name}-{target}")
            if os.path.isfile(path):
                binaries[f"{name}-{target}"] = sha256_file(path)
    return binaries


def stamp(seconds):
    """UTC YYYYMMDDHHMMSS as an integer."""
    return int(time.strftime("%Y%m%d%H%M%S", time.gmtime(seconds)))


def release_sequence(now, committed_at, min_sequence):
    """The publish order of a Linux release file: the publish time as YYYYMMDDHHMMSS, raised to
    min_sequence (one more than the channel's current sequence) when the clock would not exceed it.
    Never below the commit time's stamp, which is what a phase-1 file (no `sequence`) is ordered by."""
    return max(stamp(now), stamp(committed_at), min_sequence)


def release_version(cargo_version, commit, sequence):
    """`<cargo version>+<sequence>.<commit[:12]>`: dpkg and rpm compare the part after `+` digit run by
    digit run, so builds sort in publish order and two never tie. Phase 1 put the commit time's stamp
    there, the same 14-digit form, and a publish never precedes its commit: versions keep rising."""
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", cargo_version):
        fail(f"cargo version {cargo_version!r} is not MAJOR.MINOR.PATCH")
    return f"{cargo_version}+{sequence}.{commit[:12]}"


def commit_list(args, key, commits):
    """One of --live-from's lists: the commit first, at most MAC_LIVE_FROM_MAX full shas, each once."""
    if not isinstance(commits, list) or not commits or commits[0] != args.commit:
        fail(f"{args.live_from} {key} does not start at {args.commit}")
    if len(commits) > MAC_LIVE_FROM_MAX or len(set(commits)) != len(commits):
        fail(f"{args.live_from} {key} names {len(commits)} commits (at most {MAC_LIVE_FROM_MAX}, each once)")
    if not all(isinstance(c, str) and re.fullmatch(r"[0-9a-f]{40}", c) for c in commits):
        fail(f"{args.live_from} {key} names something that is not a full commit sha")
    return commits


def live_from(args):
    """--live-from's lists (hot-apply.py live-from's JSON): live_from (whole app) and daemon_from (daemon
    compatibility only, which the nightly-live channel reads). live_from is a prefix of daemon_from; a file
    from an older hot-apply.py without daemon_from signs live_from alone."""
    value = json.load(open(args.live_from))
    if not isinstance(value, dict):
        fail(f"{args.live_from} is not a JSON object")
    commits = commit_list(args, "live_from", value.get("live_from"))
    if "daemon_from" not in value:
        return commits, None
    daemon = commit_list(args, "daemon_from", value.get("daemon_from"))
    if daemon[:len(commits)] != commits:
        fail(f"{args.live_from} live_from is not a prefix of daemon_from")
    return commits, daemon


def mac_live(args):
    """The Mac live update payload of a commit manifest (--manifest only: the darwin build is not this job's)."""
    if not args.manifest or not args.live_from or args.machine_path or args.channel or args.cargo_version:
        fail("--purpose mac-live takes --manifest and --live-from only")
    if args.tree_key and not re.fullmatch(r"[0-9a-f]{40}", args.tree_key):
        fail(f"bad tree key {args.tree_key!r}")
    binaries = expected_sha256(args)
    commits, daemon = live_from(args)
    os.makedirs(args.download_dir, exist_ok=True)
    files = {}
    for name in MAC_LIVE_NAMES:
        published = f"{name}-{MAC_LIVE_TARGET}"
        sha = binaries.get(published)
        if sha is None and name != "cmux-tui":
            continue  # a companion this build does not have: `app try` removes the app's, as hot-apply does
        if not re.fullmatch(r"[0-9a-f]{64}", str(sha or "")):
            fail(f"no sha256 for {published} ({args.manifest})")
        url = f"{FILES}/{args.commit}/{published}"
        path = os.path.join(args.download_dir, published)
        subprocess.run(["curl", "-fsS", "--retry", "3", "--max-time", "600", "-o", path, f"{url}?channel=1"],
                       check=True)
        if sha256_file(path) != sha:
            fail(f"{url} does not have the expected sha256 {sha}")
        files[name] = {"url": url, "sha256": sha, "size": os.path.getsize(path)}
        os.remove(path)
    now = int(time.time())
    value = {"schema": SCHEMA, "purpose": MAC_LIVE_PURPOSE, "channel": MAC_LIVE_CHANNEL, "commit": args.commit,
             "committed_at": int(args.committed_at), "published_at": now, "expires_at": now + LIFETIME,
             "live_from": commits, "targets": {MAC_LIVE_TARGET: files}} | ({"daemon_from": daemon} if daemon else {})
    # The commit's cmux-tui tree: a Team-signed app (a NIGHTLY) takes its daemon from the tree's Team-signed
    # set (cmux-tui/tree/<key>/team-signed/, cmux-tui-team-signed.yml), each file bound to the unsigned
    # sha256 named here; the ad-hoc bytes above would leave its Cloud unverified (cmuxterm-hq#11364).
    if args.tree_key:
        value["tree_key"] = args.tree_key
    if args.screen_sharing_helper:
        value[MAC_LIVE_HELPER_KEY] = screen_sharing_helper(args)
    return value


def screen_sharing_helper(args):
    """The signed helper of --screen-sharing-helper's record, as the commit's own copy serves it."""
    try:
        record = helper_release.verify_value(json.load(open(args.screen_sharing_helper)))
    except (helper_release.Refused, ValueError) as error:
        fail(f"{args.screen_sharing_helper}: {error}")
    url = f"{FILES}/{args.commit}/{helper_release.ZIP}"
    path = os.path.join(args.download_dir, helper_release.ZIP)
    subprocess.run(["curl", "-fsS", "--retry", "3", "--max-time", "600", "-o", path, f"{url}?channel=1"],
                   check=True)
    size = os.path.getsize(path)
    if sha256_file(path) != record["sha256"] or size != record["size"]:
        fail(f"{url} is not the helper zip {args.screen_sharing_helper} names")
    os.remove(path)
    return {"url": url, "sha256": record["sha256"], "size": size, "bundle_id": record["bundle_id"],
            "team": record["team"], "designated_requirement": record["designated_requirement"]}


def mac_app(args):
    """The Mac app build payload of --zip: reload-build's app.zip, published at the commit's own URL."""
    if not (args.zip and args.url and args.run_id):
        fail("--purpose mac-app needs --zip, --url and --run-id")
    if (args.manifest or args.binaries_dir or args.live_from or args.screen_sharing_helper or args.machine_path
            or args.channel or args.cargo_version or args.min_sequence or args.tree_key):
        fail("--purpose mac-app takes --commit, --zip, --url, --run-id and --out only")
    if not re.fullmatch(r"[0-9]{1,20}", args.run_id):
        fail(f"bad run id {args.run_id!r}")
    url = f"{FILES}/{args.commit}/{MAC_APP_ZIP}"
    if args.url != url:
        fail(f"--url must be {url}")
    if not os.path.isfile(args.zip):
        fail(f"{args.zip} is not a file")
    return {"schema": SCHEMA, "purpose": MAC_APP_PURPOSE, "commit": args.commit, "configuration": "release",
            "arch": "arm64", "app": {"url": url, "sha256": sha256_file(args.zip), "size": os.path.getsize(args.zip)},
            "run_id": args.run_id}


def payload(args):
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        fail(f"bad commit {args.commit!r}")
    if args.purpose == "mac-app":
        with open(args.out, "wb") as out:
            out.write(json.dumps(mac_app(args), sort_keys=True, separators=(",", ":")).encode())
        return
    if args.zip or args.url or args.run_id:
        fail("--zip, --url and --run-id are for --purpose mac-app")
    if not (args.manifest or args.binaries_dir) or not args.committed_at or not args.download_dir:
        fail("payload needs --manifest or --binaries-dir, --committed-at and --download-dir")
    if args.purpose == "mac-live":
        value = mac_live(args)
        with open(args.out, "wb") as out:
            out.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
        return
    if args.live_from or args.screen_sharing_helper:
        fail("--live-from and --screen-sharing-helper are for --purpose mac-live")
    release = args.purpose == "linux-release"
    if release and args.channel not in LINUX_RELEASE_CHANNELS:
        fail(f"--purpose linux-release needs --channel, one of {', '.join(LINUX_RELEASE_CHANNELS)}")
    if not release and (args.channel or args.cargo_version or args.min_sequence):
        fail("--channel, --cargo-version and --min-sequence are for --purpose linux-release")
    if args.tree_key and not release:
        fail("--tree-key is for --purpose linux-release")
    if args.tree_key and not re.fullmatch(r"[0-9a-f]{40}", args.tree_key):
        fail(f"bad tree key {args.tree_key!r}")
    if release and not args.binaries_dir:
        # Everything in the bucket, the manifest included, is what a bucket writer controls, and publish
        # adopts (and attests) whatever Linux bytes the prefix already serves. Only this run's own build
        # artifacts are outside the bucket: sign only bytes equal to them.
        fail("--purpose linux-release needs --binaries-dir, this run's own build of the binaries; "
             "a checksum from the bucket proves nothing about who built the bytes")
    if args.machine_path and (release or not args.binaries_dir):
        # The machine copy is the Cloud machine channel's own build: never a Linux release, and only
        # this run's build of it names its checksums.
        fail("--machine-path is for the cloud-machine payload of --binaries-dir")
    if args.target and release:
        fail("--target is for the cloud-machine payload: a Linux release names every target")
    if args.target and set(args.target) - set(TARGETS):
        fail(f"--target names {sorted(set(args.target) - set(TARGETS))}, not one of {list(TARGETS)}")
    # --target: a payload of some targets only. point-machine-channel-early points the channel from
    # the x86_64 build alone, and a second point of the same commit adds aarch64
    # (web-ota-pointer.py newer's completes rule).
    args.targets = LINUX_RELEASE_TARGETS if release else tuple(t for t in TARGETS if not args.target or t in args.target)
    args.names = LINUX_RELEASE_NAMES if release else NAMES
    binaries = expected_sha256(args)
    os.makedirs(args.download_dir, exist_ok=True)
    targets = {}
    lines = []
    for target in args.targets:
        for name in args.names:
            published = f"{name}-{target}"
            sha = binaries.get(published)
            if sha is None and name in LINUX_RELEASE_MUSL_ONLY and not target.endswith("-musl"):
                continue
            if not re.fullmatch(r"[0-9a-f]{64}", str(sha or "")):
                fail(f"no sha256 for {published} ({args.manifest or args.binaries_dir})")
            if args.tree_key:
                url = f"{FILES}/tree/{args.tree_key}/{published}"
            else:
                url = f"{FILES}/{args.commit}/{'machine/' if args.machine_path else ''}{published}"
            path = os.path.join(args.download_dir, published)
            subprocess.run(["curl", "-fsS", "--retry", "3", "--max-time", "600", "-o", path, f"{url}?channel=1"],
                           check=True)
            if sha256_file(path) != sha:
                fail(f"{url} does not have the expected sha256 {sha}")
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
        sequence = release_sequence(now, committed_at, args.min_sequence or 0)
        value = {
            "schema": SCHEMA, "purpose": LINUX_RELEASE_PURPOSE, "channel": args.channel,
            "version": release_version(cargo_version, args.commit, sequence), "sequence": sequence,
            "commit": args.commit, "committed_at": committed_at,
            "published_at": now, "expires_at": now + LIFETIME, "targets": targets,
        } | ({"tree_key": args.tree_key} if args.tree_key else {})
    else:
        value = {
            "schema": SCHEMA, "purpose": PURPOSE, "channel": CHANNEL,
            "key": hashlib.sha256("\n".join(sorted(lines)).encode()).hexdigest(),
            "commit": args.commit, "committed_at": committed_at,
            "published_at": now, "expires_at": now + LIFETIME, "targets": targets,
        }
    with open(args.out, "wb") as out:
        out.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def alias(args):
    """The payload of cmux-tui/<commit>/release.json for a commit that shares a published tree: the tree's
    verified release.json, retold for this commit. Nothing is downloaded: the tree file's signature covers
    its targets, and the caller computed --tree-key for this commit from the source (cmux_tui_tree_key.py),
    never from an unsigned marker in the bucket."""
    for name, value in (("commit", args.commit), ("tree key", args.tree_key)):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            fail(f"bad {name} {value!r}")
    if args.channel not in LINUX_RELEASE_CHANNELS:
        fail(f"--channel must be one of {', '.join(LINUX_RELEASE_CHANNELS)}")
    verified = subprocess.run(
        [sys.executable, POINTER, "verify", "--pointer", args.tree_release, "--keys", args.keys,
         "--purpose", LINUX_RELEASE_PURPOSE, "--channel", args.channel, "--allow-expired"],
        capture_output=True, text=True)
    if verified.returncode != 0:
        fail(f"{args.tree_release} does not verify: {verified.stderr.strip()}")
    tree = json.loads(verified.stdout)
    if tree.get("tree_key") != args.tree_key:
        fail(f"{args.tree_release} is the release file of tree {tree.get('tree_key')!r}, not {args.tree_key}")
    now = int(time.time())
    committed_at = int(args.committed_at)
    sequence = release_sequence(now, committed_at, args.min_sequence or 0)
    value = {
        "schema": SCHEMA, "purpose": LINUX_RELEASE_PURPOSE, "channel": args.channel,
        "version": release_version(tree["version"].split("+", 1)[0], args.commit, sequence), "sequence": sequence,
        "commit": args.commit, "committed_at": committed_at, "tree_key": args.tree_key,
        "published_at": now, "expires_at": now + LIFETIME, "targets": tree["targets"],
    }
    with open(args.out, "wb") as out:
        out.write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    source = p.add_mutually_exclusive_group()
    source.add_argument("--manifest")
    source.add_argument("--binaries-dir")
    for name in ("--commit", "--out"):
        p.add_argument(name, required=True)
    for name in ("--committed-at", "--download-dir"):
        p.add_argument(name, help="every purpose but mac-app")
    p.add_argument("--purpose", choices=("cloud-machine", "linux-release", "mac-live", "mac-app"), default="cloud-machine")
    p.add_argument("--zip", help="--purpose mac-app: reload-build's app.zip")
    p.add_argument("--url", help="--purpose mac-app: where the zip is published")
    p.add_argument("--run-id", help="--purpose mac-app: the GitHub run that built it")
    p.add_argument("--live-from", help="--purpose mac-live: `hot-apply.py live-from SHA`'s JSON")
    p.add_argument("--screen-sharing-helper",
                   help="--purpose mac-live: the commit's signed helper record (screen_sharing_helper_release.py)")
    p.add_argument("--channel", help="--purpose linux-release: the channel this build publishes to")
    p.add_argument("--cargo-version", help="--purpose linux-release: default cmux-tui/Cargo.toml's version")
    p.add_argument("--min-sequence", type=int, default=0,
                   help="--purpose linux-release: the lowest sequence to sign (the channel's current one + 1)")
    p.add_argument("--target", action="append", choices=TARGETS,
                   help="--purpose cloud-machine: sign only this target (repeat for more); default every target")
    p.add_argument("--machine-path", action="store_true",
                   help="name the commit's machine copy, cmux-tui/<commit>/machine/<name>-<target>")
    p.add_argument("--tree-key", help="--purpose linux-release: name the tree's copies, cmux-tui/tree/<key>/")
    a = sub.add_parser("alias", help="the release.json payload of a commit that shares a published tree")
    for name in ("--tree-release", "--keys", "--tree-key", "--channel", "--commit", "--committed-at", "--out"):
        a.add_argument(name, required=True)
    a.add_argument("--min-sequence", type=int, default=0,
                   help="the lowest sequence to sign (the channel's current one + 1)")
    args = parser.parse_args(argv[1:])
    if args.command == "alias":
        alias(args)
    else:
        payload(args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
