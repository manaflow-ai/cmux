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

Usage:
  web-ota-pointer.py payload --manifest M --abi-file F --channel C --commit SHA --committed-at T --out P
  web-ota-pointer.py sign --payload P --key PEM --keys KEYS --out POINTER
  web-ota-pointer.py verify --pointer POINTER --keys KEYS [--channel C]   print the payload
  web-ota-pointer.py newer --pointer NEW --keys KEYS [--current CURRENT]  exit 0 when NEW moves forward

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


def sign(args):
    keys = load_keys(args.keys)
    payload = open(args.payload, "rb").read()
    json.loads(payload)
    der = subprocess.run(["openssl", "pkey", "-in", args.key, "-pubout", "-outform", "DER"], capture_output=True)
    if der.returncode != 0 or not der.stdout.startswith(ED25519_SPKI_PREFIX) or len(der.stdout) != 44:
        fail("the signing key is not an ed25519 private key")
    raw = der.stdout[len(ED25519_SPKI_PREFIX):]
    key_id = hashlib.sha256(raw).hexdigest()[:16]
    if keys.get(key_id) != raw:
        fail(f"the signing key {key_id} is not in {args.keys}; the app would refuse its pointers")
    with tempfile.TemporaryDirectory() as tmp:
        data = os.path.join(tmp, "payload")
        open(data, "wb").write(payload)
        ok, sig = openssl("pkeyutl", "-sign", "-inkey", args.key, "-rawin", "-in", data)
    if not ok or len(sig) != 64:
        fail("openssl could not sign the payload")
    envelope = {"schema": SCHEMA, "payload": base64.b64encode(payload).decode(),
                "signatures": [{"key_id": key_id, "sig": base64.b64encode(sig).decode()}]}
    with open(args.out, "w") as out:
        json.dump(envelope, out, indent=1, sort_keys=True)
        out.write("\n")


class Refused(Exception):
    pass


def verified_payload(path, keys, channel=None):
    """The payload of the pointer at `path` when a signature by one of `keys` covers it; else Refused."""
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
    return value


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("payload")
    for name in ("--manifest", "--abi-file", "--channel", "--commit", "--committed-at", "--out"):
        p.add_argument(name, required=True)
    s = sub.add_parser("sign")
    for name in ("--payload", "--key", "--keys", "--out"):
        s.add_argument(name, required=True)
    v = sub.add_parser("verify")
    v.add_argument("--pointer", required=True)
    v.add_argument("--keys", required=True)
    v.add_argument("--channel")
    n = sub.add_parser("newer")
    n.add_argument("--pointer", required=True)
    n.add_argument("--keys", required=True)
    n.add_argument("--current")
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
        print(json.dumps(verified_payload(args.pointer, load_keys(args.keys), args.channel), indent=1, sort_keys=True))
    elif args.command == "newer":
        keys = load_keys(args.keys)
        new = verified_payload(args.pointer, keys)
        if not args.current or not os.path.exists(args.current):
            return 0
        try:
            current = verified_payload(args.current, keys, new["channel"])
        except Refused as error:
            # A pointer no trusted key covers (a rotated key, a broken upload) is replaced.
            print(f"replacing the published pointer: {error}", file=sys.stderr)
            return 0
        # Same key: nothing to move. An older commit never replaces a newer one (two runs that
        # finish out of order).
        if new["key"] == current["key"] or new["committed_at"] <= current["committed_at"]:
            print(f"the published pointer ({current['commit'][:12]}) is current; keeping it", file=sys.stderr)
            return SKIP
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
