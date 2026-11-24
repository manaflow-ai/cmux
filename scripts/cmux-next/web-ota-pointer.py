#!/usr/bin/env python3
"""Make, sign and check the signed pointer of a cmux-next web update channel (plans/cmux-next/web-ota.md).

A channel pointer (`cmux-next-web/ota/<channel>.json` on files.cmux.com) names the web bundle
archive the app should serve for that channel. It is an envelope around exact payload bytes, so
nothing is canonicalized twice:

  {"schema": 1, "payload": "<base64 payload JSON>", "signatures": [{"key_id": "...", "sig": "<base64>"}]}

The payload is compact JSON with sorted keys: schema, channel, key (web-bundle-key.py --source),
archive, sha256, size and outputs (from the key's published manifest.json), abi (webviews/src/web-abi.json),
commit and committed_at (the commit that published it, unix seconds) and published_at. The app
verifies a signature against Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
before it reads any payload field, and refuses a payload older than the last one it took.

The same envelope and keys sign other files, told apart by the payload's `purpose` (web pointers
have none): the Cloud machine channel (`cmux-cloud-machine-update`, scripts/ci/cmux-machine-channel.py)
and the Linux release files (`cmux-linux-release`: cmux-tui/<commit>/release.json and
cmux-tui/channels/linux-<channel>.json). `verify --purpose` refuses a payload of any other purpose, and
for a Linux release file checks its shape: the version, every URL under
https://files.cmux.com/cmux-tui/<commit>/ (or, for a file that names a `tree_key`,
https://files.cmux.com/cmux-tui/tree/<tree_key>/: the tree's own release.json, a shared-tree commit's
alias of it, and a channel pointer at a tree), and `expires_at`. Every Linux release payload carries
`expires_at`, but only a channel pointer is held to it: the per-commit release.json is reached by an
explicit version and stays valid (`--allow-expired`).

Usage:
  web-ota-pointer.py payload --manifest M --abi-file F --channel C --commit SHA --committed-at T --out P
  web-ota-pointer.py sign --payload P --key PEM [--extra-key PEM2]... --keys KEYS --out POINTER
      --extra-key: a rotation's next key; signs too when KEYS lists it, else skipped with a warning
  web-ota-pointer.py verify --pointer POINTER --keys KEYS [--channel C] [--purpose P [--allow-expired]]
      print the payload
  web-ota-pointer.py newer --pointer NEW --keys KEYS [--current CURRENT]  exit 0 when NEW moves forward
      [--tree-key K --current-tree-key K2]  exit 3 (keep) when K == K2: the same source tree
  web-ota-pointer.py same-build --pointer NEW --current CURRENT --keys KEYS
      exit 0 when CURRENT is a signed file of the same build (all but published_at and expires_at, and
      for a Linux release file sequence and version, equal), 1 otherwise: a write-once file someone
      published with other contents
      [--same-tree]  also ignore commit and committed_at, and require the same tree_key: the write-once
      tree/<key>/release.json, which any commit of the tree may find already written
  web-ota-pointer.py sequence --pointer CURRENT --keys KEYS --channel C
      print the Linux release file's sequence (the stamp in its version for a phase-1 file), 0 when none
      verifies; newer refuses a Linux release pointer that would not raise it

Signing and verifying run openssl (3.0 or newer: `pkeyutl -rawin` with ed25519).
"""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

SCHEMA = 1
CHANNELS = ("every-merge", "nightly")
# The SubjectPublicKeyInfo DER prefix of an ed25519 key; the raw 32 bytes follow.
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
# The exit status of "nothing to publish" (`newer`: the published pointer is current; `payload`: the
# manifest predates `outputs`), apart from 1 for an error.
SKIP = 3
# The Linux release files (scripts/ci/cmux-machine-channel.py payload --purpose linux-release).
LINUX_RELEASE = "cmux-linux-release"
FILES = "https://files.cmux.com/cmux-tui/"
# The fields a re-sign of one build changes; same-build ignores them.
SIGNING_TIME_FIELDS = ("published_at", "expires_at")
LINUX_RELEASE_SIGNING_FIELDS = ("sequence", "version")
# `same-build --same-tree`: the commit of a tree file is whichever commit of the tree signed it first.
TREE_COMMIT_FIELDS = ("commit", "committed_at")
# `newer --tree-key`: a published file of the same source tree is kept only while it has this long
# to live (the Cloud machine file lives 30 days, cmux-machine-channel.py LIFETIME).
TREE_KEEP_MIN_SECONDS = 7 * 24 * 3600


def fail(message):
    print(f"web-ota-pointer: {message}", file=sys.stderr)
    sys.exit(1)


def compact(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def load_keys(path):
    keys = {}
    for entry in json.load(open(path)).get("keys", []):
        raw = base64.b64decode(entry["ed25519"])
        if len(raw) != 32:
            fail(f"{path}: key {entry.get('id')} is not 32 bytes")
        if hashlib.sha256(raw).hexdigest()[:16] != entry["id"]:
            fail(f"{path}: key {entry['id']} does not match its id")
        keys[entry["id"]] = raw
    if not keys:
        fail(f"{path} holds no keys")
    return keys


def make_payload(args):
    manifest = json.load(open(args.manifest))
    abi = json.load(open(args.abi_file))["abi"]
    if args.channel not in CHANNELS:
        fail(f"unknown channel {args.channel}")
    if manifest.get("outputs") is None:
        print(f"web-ota-pointer: {args.manifest} has no outputs digest (published before pointers)", file=sys.stderr)
        sys.exit(SKIP)
    for field, pattern in (("key", r"[0-9a-f]{64}"), ("sha256", r"[0-9a-f]{64}"), ("outputs", r"[0-9a-f]{64}"),
                           ("archive", r"web-bundles-[0-9a-f]{64}\.tar\.gz")):
        if not re.fullmatch(pattern, str(manifest.get(field) or "")):
            fail(f"{args.manifest}: bad {field} {manifest.get(field)!r}")
    if manifest["archive"] != f"web-bundles-{manifest['sha256']}.tar.gz":
        fail(f"{args.manifest}: the archive name does not carry its sha256")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        fail(f"bad commit {args.commit!r}")
    if not isinstance(abi, int) or abi < 1:
        fail(f"{args.abi_file}: abi must be a positive integer")
    payload = {
        "schema": SCHEMA, "channel": args.channel, "key": manifest["key"], "archive": manifest["archive"],
        "sha256": manifest["sha256"], "size": int(manifest["size"]), "outputs": manifest["outputs"], "abi": abi,
        "commit": args.commit, "committed_at": int(args.committed_at), "published_at": int(time.time()),
    }
    with open(args.out, "wb") as out:
        out.write(compact(payload))


def openssl(*argv):
    result = subprocess.run(["openssl", *argv], capture_output=True)
    return result.returncode == 0, result.stdout


def signature_of(payload, pem, keys, keys_path):
    """(key_id, signature) of `payload` by the ed25519 private key `pem`; Refused unless `keys` lists it."""
    der = subprocess.run(["openssl", "pkey", "-in", pem, "-pubout", "-outform", "DER"], capture_output=True)
    if der.returncode != 0 or not der.stdout.startswith(ED25519_SPKI_PREFIX) or len(der.stdout) != 44:
        raise Refused(f"the signing key {pem} is not an ed25519 private key")
    raw = der.stdout[len(ED25519_SPKI_PREFIX):]
    key_id = hashlib.sha256(raw).hexdigest()[:16]
    if keys.get(key_id) != raw:
        raise Refused(f"the signing key {key_id} is not in {keys_path}; the app would refuse its pointers")
    with tempfile.TemporaryDirectory() as tmp:
        data = os.path.join(tmp, "payload")
        open(data, "wb").write(payload)
        ok, sig = openssl("pkeyutl", "-sign", "-inkey", pem, "-rawin", "-in", data)
    if not ok or len(sig) != 64:
        raise Refused("openssl could not sign the payload")
    return key_id, sig


def sign(args):
    """Sign with --key, and with each --extra-key the key list already names (a key rotation's next
    key: verifiers take any one listed signature, so a dual-signed file verifies on hosts that know
    only the old key and on hosts that know only the new one). An --extra-key the list does not name
    yet (its public half has not shipped) is skipped with a warning, never a failure."""
    keys = load_keys(args.keys)
    payload = open(args.payload, "rb").read()
    json.loads(payload)
    signed = [signature_of(payload, args.key, keys, args.keys)]
    for pem in args.extra_key or []:
        try:
            key_id, sig = signature_of(payload, pem, keys, args.keys)
        except Refused as error:
            print(f"::warning::web-ota-pointer: extra signing key skipped: {error}", file=sys.stderr)
            continue
        if key_id not in [k for k, _ in signed]:
            signed.append((key_id, sig))
    envelope = {"schema": SCHEMA, "payload": base64.b64encode(payload).decode(),
                "signatures": [{"key_id": k, "sig": base64.b64encode(sig).decode()} for k, sig in signed]}
    with open(args.out, "w") as out:
        json.dump(envelope, out, indent=1, sort_keys=True)
        out.write("\n")


class Refused(Exception):
    pass


def verified_payload(path, keys, channel=None, purpose=None, check_expiry=True):
    """The payload of the pointer at `path` when a signature by one of `keys` covers it; else Refused.

    With `purpose`, also the payload's purpose, the shape of its kind and (unless not `check_expiry`)
    its expires_at; without one (the web update pointers) none of these."""
    try:
        envelope = json.load(open(path))
        payload = base64.b64decode(envelope["payload"], validate=True)
        signatures = envelope["signatures"]
    except (ValueError, KeyError, TypeError) as error:
        raise Refused(f"{path} is not a pointer envelope: {error}")
    if envelope.get("schema") != SCHEMA:
        raise Refused(f"{path}: unknown schema {envelope.get('schema')!r}")
    good = False
    with tempfile.TemporaryDirectory() as tmp:
        data = os.path.join(tmp, "payload")
        open(data, "wb").write(payload)
        for signature in signatures if isinstance(signatures, list) else []:
            key_id = signature.get("key_id") if isinstance(signature, dict) else None
            raw = keys.get(key_id) if isinstance(key_id, str) else None
            if raw is None:
                continue
            try:
                sig_bytes = base64.b64decode(signature.get("sig", ""), validate=True)
            except (ValueError, TypeError):
                # A malformed signature covers nothing (binascii.Error is a ValueError).
                continue
            pub = os.path.join(tmp, "pub.der")
            sig = os.path.join(tmp, "sig")
            open(pub, "wb").write(ED25519_SPKI_PREFIX + raw)
            open(sig, "wb").write(sig_bytes)
            ok, _ = openssl("pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", pub, "-rawin",
                            "-in", data, "-sigfile", sig)
            if ok:
                good = True
                break
    if not good:
        raise Refused(f"{path}: no valid signature by a trusted key")
    value = json.loads(payload)
    if value.get("schema") != SCHEMA:
        raise Refused(f"{path}: unknown payload schema {value.get('schema')!r}")
    if channel is not None and value.get("channel") != channel:
        raise Refused(f"{path}: the payload is for channel {value.get('channel')!r}, not {channel!r}")
    if purpose is not None:
        if value.get("purpose") != purpose:
            raise Refused(f"{path}: the payload's purpose is {value.get('purpose')!r}, not {purpose!r}")
        if purpose == LINUX_RELEASE:
            check_linux_release(path, value)
        if check_expiry:
            expires_at = value.get("expires_at")
            if not isinstance(expires_at, int) or isinstance(expires_at, bool):
                raise Refused(f"{path}: the payload has no expires_at")
            if expires_at <= int(time.time()):
                raise Refused(f"{path}: the payload expired at {expires_at}")
    return value


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


# scripts/ci/cmux-machine-channel.py LINUX_RELEASE_TARGETS: the targets every release file carries.
LINUX_RELEASE_TARGETS = ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
                         "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")


# scripts/ci/cmux-machine-channel.py LINUX_RELEASE_NAMES: the binaries a release file may carry, each at its
# own published name. cmux-tui and cmux-tui-hook are in every file (phase 1); the rest since phase 1b.
LINUX_RELEASE_NAMES = ("cmux-tui", "cmux-tui-hook", "cmux-tui-acpmux", "cmux-tui-app-host",
                       "cmux-tui-agent-screen-detection")


def release_sequence(value):
    """A verified Linux release payload's publish order: its `sequence`, or for a phase-1 file the stamp
    in its version (check_linux_release holds the two to that form)."""
    if "sequence" in value:
        return value["sequence"]
    return int(value["version"].split("+", 1)[1].split(".", 1)[0])


def check_linux_release(path, value):
    """The shape of a Linux release payload; Refused on anything an installer must not act on."""
    commit = value.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise Refused(f"{path}: bad commit {commit!r}")
    for field in ("committed_at", "published_at", "expires_at"):
        if not is_int(value.get(field)) or value[field] <= 0:
            raise Refused(f"{path}: bad {field} {value.get(field)!r}")
    if not isinstance(value.get("channel"), str) or not value["channel"]:
        raise Refused(f"{path}: no channel")
    stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime(value["committed_at"]))
    # Phase 1b: `sequence` orders the files (the publish time, YYYYMMDDHHMMSS, raised above the channel's
    # current one) and the version carries it. A phase-1 file has none: its version carries the commit
    # time's stamp, which is never above a later file's sequence (a publish never precedes its commit).
    if "sequence" in value:
        sequence = value["sequence"]
        if not is_int(sequence) or not 10**13 <= sequence < 10**14 or sequence < int(stamp):
            raise Refused(f"{path}: bad sequence {sequence!r} (YYYYMMDDHHMMSS, not before the commit's {stamp})")
        stamp = str(sequence)
    version = value.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\+" + stamp + r"\." + commit[:12],
                                                         version):
        raise Refused(f"{path}: version {version!r} is not <cargo version>+{stamp}.{commit[:12]}")
    targets = value.get("targets")
    if not isinstance(targets, dict) or not targets:
        raise Refused(f"{path}: no targets")
    # Every Linux target an installer may ask for, each with both binaries; other entries (packages,
    # later) may sit beside them.
    for target in LINUX_RELEASE_TARGETS:
        files = targets.get(target)
        missing = [name for name in ("cmux-tui", "cmux-tui-hook") if not isinstance(files, dict) or name not in files]
        if missing:
            raise Refused(f"{path}: target {target} has no {' or '.join(missing)}")
    # A tree file (tree/<key>/release.json), an alias of it (a commit that shares the tree) and a channel
    # pointer at a tree name the tree's key; their URLs are the tree's copies. A per-commit file of a commit
    # that built its own publication has none, and its URLs are under its commit.
    if "tree_key" in value:
        tree_key = value["tree_key"]
        if not isinstance(tree_key, str) or not re.fullmatch(r"[0-9a-f]{40}", tree_key):
            raise Refused(f"{path}: bad tree_key {tree_key!r}")
        prefix = f"{FILES}tree/{tree_key}/"
    else:
        prefix = f"{FILES}{commit}/"
    for target, files in targets.items():
        if not isinstance(files, dict) or not files:
            raise Refused(f"{path}: target {target!r} names no files")
        for name, entry in files.items():
            url = entry.get("url") if isinstance(entry, dict) else None
            # A URL under the commit's own publication (or the tree's it names), one plain file name below
            # it (as check_binary in cmux-tui/crates/cmux-host/src/updater/channel.rs): never another host,
            # commit or tree.
            rest = url[len(prefix):] if isinstance(url, str) and url.startswith(prefix) else ""
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", rest):
                raise Refused(f"{path}: {target} {name}: the url {url!r} is not under {prefix}")
            if name in LINUX_RELEASE_NAMES and rest != f"{name}-{target}":
                raise Refused(f"{path}: {target} {name}: the url is not {prefix}{name}-{target}")
            if not re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256") or "")):
                raise Refused(f"{path}: {target} {name}: bad sha256 {entry.get('sha256')!r}")
            if not is_int(entry.get("size")) or entry["size"] <= 0:
                raise Refused(f"{path}: {target} {name}: bad size {entry.get('size')!r}")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    for name in ("--manifest", "--abi-file", "--channel", "--commit", "--committed-at", "--out"):
        p.add_argument(name, required=True)
    s = sub.add_parser("sign")
    for name in ("--payload", "--key", "--keys", "--out"):
        s.add_argument(name, required=True)
    s.add_argument("--extra-key", action="append", help="also sign with this key when KEYS lists it (rotation)")
    v = sub.add_parser("verify")
    v.add_argument("--pointer", required=True)
    v.add_argument("--keys", required=True)
    v.add_argument("--channel")
    v.add_argument("--purpose", help="refuse a payload of any other purpose; check its kind's shape and expiry")
    v.add_argument("--allow-expired", action="store_true", help="with --purpose: a per-commit file, no expiry")
    n = sub.add_parser("newer")
    n.add_argument("--pointer", required=True)
    n.add_argument("--keys", required=True)
    n.add_argument("--current")
    n.add_argument("--tree-key", help="the source tree key of NEW's commit (cmux_tui_tree_key.py)")
    n.add_argument("--current-tree-key", help="the source tree key of CURRENT's commit; equal to --tree-key: keep")
    q = sub.add_parser("sequence", help="print the sequence of the Linux release file at --pointer, 0 when none "
                                        "verifies (missing, unsigned, another purpose): the next signer's floor - 1")
    q.add_argument("--pointer", required=True)
    q.add_argument("--keys", required=True)
    q.add_argument("--channel", required=True)
    b = sub.add_parser("same-build")
    for name in ("--pointer", "--current", "--keys"):
        b.add_argument(name, required=True)
    b.add_argument("--same-tree", action="store_true",
                   help="CURRENT is tree/<key>/release.json: any commit of NEW's tree_key with the same files")
    args = parser.parse_args(argv[1:])
    try:
        return run(args)
    except Refused as error:
        fail(str(error))


def run(args):
    if args.command == "payload":
        make_payload(args)
    elif args.command == "sign":
        sign(args)
    elif args.command == "verify":
        if args.allow_expired and not args.purpose:
            fail("--allow-expired needs --purpose")
        value = verified_payload(args.pointer, load_keys(args.keys), args.channel, args.purpose,
                                 check_expiry=not args.allow_expired)
        print(json.dumps(value, indent=1, sort_keys=True))
    elif args.command == "newer":
        keys = load_keys(args.keys)
        new = verified_payload(args.pointer, keys)
        purpose = new.get("purpose")
        if purpose is not None:
            # A file of another purpose never stands in for this one, in either place.
            verified_payload(args.pointer, keys, purpose=purpose, check_expiry=False)
        if not args.current or not os.path.exists(args.current):
            return 0
        try:
            current = verified_payload(args.current, keys, new["channel"], purpose, check_expiry=False)
        except Refused as error:
            # A pointer no trusted key covers (a rotated key, a broken upload) is replaced.
            print(f"replacing the published pointer: {error}", file=sys.stderr)
            return 0
        # Same key: nothing to move. An older commit never replaces a newer one (two runs that
        # finish out of order).
        # A Linux release payload has no key: its commit time alone orders it.
        same_key = "key" in new and new["key"] == current.get("key")
        if same_key or new["committed_at"] <= current["committed_at"]:
            print(f"the published pointer ({current['commit'][:12]}) is current; keeping it", file=sys.stderr)
            return SKIP
        # A Linux release pointer never moves to a lower or equal sequence: an installer refuses a lower one
        # than it installed, so the channel would freeze for it. The signer asks for the current one + 1
        # (--min-sequence); a run that lost the race to a newer sequence leaves the channel to the next push.
        if purpose == LINUX_RELEASE and release_sequence(new) <= release_sequence(current):
            print(f"the published pointer ({current['commit'][:12]}) has sequence {release_sequence(current)}, "
                  f"not below this file's {release_sequence(new)}; keeping it", file=sys.stderr)
            return SKIP
        # The same source tree (cmux_tui_tree_key.py, a hash of every build input) is the same code:
        # a newer commit that changed nothing the build reads (a push that adopts an earlier commit's
        # published tree), or the fat build of the commit whose thin build the channel names, keeps the
        # published pointer, so no machine updates to identical code. Only while
        # the published file has more than TREE_KEEP_MIN_SECONDS to live: a machine refuses an
        # expired file, so a channel that sat on one tree that long is re-signed by the next push.
        if args.tree_key and args.tree_key == args.current_tree_key:
            left = current.get("expires_at", float("inf")) - time.time()
            if left > TREE_KEEP_MIN_SECONDS:
                print(f"the published pointer ({current['commit'][:12]}) has the same tree {args.tree_key[:12]}; "
                      "keeping it", file=sys.stderr)
                return SKIP
            print(f"the published pointer has the same tree but expires in {int(left)} s; re-signing it",
                  file=sys.stderr)
    elif args.command == "sequence":
        try:
            value = verified_payload(args.pointer, load_keys(args.keys), args.channel, LINUX_RELEASE,
                                     check_expiry=False)
            print(release_sequence(value))
        except (Refused, OSError) as error:
            print(f"no current sequence: {error}", file=sys.stderr)
            print(0)
    elif args.command == "same-build":
        keys = load_keys(args.keys)
        new = verified_payload(args.pointer, keys)
        purpose = new.get("purpose")
        current = verified_payload(args.current, keys, purpose=purpose, check_expiry=False)
        # A Linux release file's sequence and the version that carries it are the signing run's too.
        skip = SIGNING_TIME_FIELDS + (LINUX_RELEASE_SIGNING_FIELDS if purpose == LINUX_RELEASE else ())
        if args.same_tree:
            # tree/<key>/release.json: written once by the first commit of the tree to sign it. A later
            # commit of the same tree (its alias) keeps it when it names the same files.
            if purpose != LINUX_RELEASE or not new.get("tree_key") or new.get("tree_key") != current.get("tree_key"):
                fail(f"{args.current} is not a release file of tree {new.get('tree_key')!r}")
            skip += TREE_COMMIT_FIELDS
        build = lambda value: {k: v for k, v in value.items() if k not in skip}
        if build(new) != build(current):
            changed = sorted(k for k in set(new) | set(current)
                             if k not in skip and new.get(k) != current.get(k))
            fail(f"{args.current} is a different build than {args.pointer} (fields {', '.join(changed)})")
        print(f"{args.current} already holds this build ({current.get('commit', '')[:12]})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
