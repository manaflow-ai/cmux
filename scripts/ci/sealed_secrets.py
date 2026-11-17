#!/usr/bin/env python3
"""Hand a secret made inside one CI job to another repository's GitHub environment, as ciphertext only.

A job that mints a credential (a password it just set, a token it just issued) often cannot write the
secret where it is needed: its GITHUB_TOKEN reaches only its own repository, and no App should hold
`secrets: write` just for that. So the job seals each value to the target environment's public key
(libsodium crypto_box_seal, the encryption GitHub's secrets API takes) and writes a bundle that holds
only ciphertext. Only GitHub can open it. Someone with ordinary write access to the target repository
then stores the values with `put`; the plaintext never leaves the job that made it.

    bundle = seal_bundle(repo, environment, key_id, key_b64, {"NAME": "value", ...})
    write_bundle(path, bundle)

    # later, as an account that can write the target repository's environment secrets:
    python3 scripts/ci/sealed_secrets.py put BUNDLE.json

`put` reads the environment's live public key first and refuses when its key_id or bytes differ from
the bundle's (GitHub rotated the key, or the bundle was sealed to another key): nothing is written.
docs/ci-sealed-secrets.md describes the pattern and its users.

Stock python3, standard library only; libsodium comes from the system (libsodium23 on Ubuntu).
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import ctypes.util
import json
import re
import subprocess
import sys
from pathlib import Path

SEALBYTES = 48  # crypto_box_SEALBYTES: an X25519 public key (32) and a Poly1305 tag (16)
PUBLICKEYBYTES = 32
SECRET_NAME = re.compile(r"[A-Z_][A-Z0-9_]{0,99}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ENVIRONMENT = re.compile(r"[A-Za-z0-9_.-]{1,255}")
KEY_ID = re.compile(r"[0-9]{1,40}")
BUNDLE_VERSION = 1


class SealError(Exception):
    pass


def sodium():
    """The system libsodium, initialised. SealError when it is not installed."""
    names = [ctypes.util.find_library("sodium"), "libsodium.so.23", "libsodium.so", "libsodium.dylib"]
    for name in filter(None, names):
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        lib.sodium_init.restype = ctypes.c_int
        lib.crypto_box_seal.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulonglong, ctypes.c_char_p)
        lib.crypto_box_seal.restype = ctypes.c_int
        if lib.sodium_init() < 0:
            raise SealError("libsodium did not initialise")
        return lib
    raise SealError("libsodium is not installed (apt-get install libsodium23)")


def public_key(key_b64):
    try:
        key = base64.b64decode(key_b64, validate=True)
    except (ValueError, TypeError) as error:
        raise SealError("the public key is not base64") from error
    if len(key) != PUBLICKEYBYTES:
        raise SealError("the public key is not a 32-byte X25519 key")
    return key


def seal(value, key_b64, lib=None):
    """crypto_box_seal(value) to the base64 X25519 public key, as base64 (what GitHub's API takes)."""
    key = public_key(key_b64)
    message = value.encode("utf-8") if isinstance(value, str) else bytes(value)
    if not message:
        raise SealError("refusing to seal an empty value")
    lib = lib or sodium()
    out = ctypes.create_string_buffer(len(message) + SEALBYTES)
    if lib.crypto_box_seal(out, message, ctypes.c_ulonglong(len(message)), key) != 0:
        raise SealError("crypto_box_seal failed")
    return base64.b64encode(out.raw).decode("ascii")


def seal_bundle(repo, environment, key_id, key_b64, values, lib=None):
    """The bundle `put` reads: where the values go, the key they were sealed to, and the ciphertexts."""
    if not REPO.fullmatch(repo or ""):
        raise SealError("repo must be OWNER/NAME")
    if not ENVIRONMENT.fullmatch(environment or ""):
        raise SealError("environment name is not valid")
    if not KEY_ID.fullmatch(str(key_id)):
        raise SealError("key_id must be GitHub's numeric key id")
    public_key(key_b64)
    if not values:
        raise SealError("nothing to seal")
    lib = lib or sodium()
    sealed = {}
    for name, value in values.items():
        if not SECRET_NAME.fullmatch(name):
            raise SealError(f"{name!r} is not a GitHub secret name")
        sealed[name] = seal(value, key_b64, lib)
    return {"version": BUNDLE_VERSION, "repo": repo, "environment": environment, "key_id": str(key_id),
            "key": key_b64, "secrets": sealed}


def write_bundle(path, bundle):
    Path(path).write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n")


def read_bundle(path):
    try:
        bundle = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise SealError(f"cannot read the bundle: {error}") from error
    if not isinstance(bundle, dict) or bundle.get("version") != BUNDLE_VERSION:
        raise SealError("not a sealed-secrets bundle (version 1)")
    for field, pattern in (("repo", REPO), ("environment", ENVIRONMENT), ("key_id", KEY_ID)):
        if not isinstance(bundle.get(field), str) or not pattern.fullmatch(bundle[field]):
            raise SealError(f"the bundle's {field} is not valid")
    public_key(bundle.get("key"))
    secrets = bundle.get("secrets")
    if not isinstance(secrets, dict) or not secrets:
        raise SealError("the bundle holds no secrets")
    for name, value in secrets.items():
        if not SECRET_NAME.fullmatch(name) or not isinstance(value, str):
            raise SealError(f"the bundle's secret {name!r} is not valid")
        try:
            raw = base64.b64decode(value, validate=True)
        except ValueError as error:
            raise SealError(f"the bundle's {name} is not base64") from error
        if len(raw) <= SEALBYTES:
            raise SealError(f"the bundle's {name} is not a sealed box")
    return bundle


def gh(args, run=subprocess.run):
    """One `gh api` call; its JSON answer (or None for an empty body). SealError on failure."""
    done = run(["gh", "api", *args], capture_output=True, text=True)
    if done.returncode != 0:
        # gh's stderr names the HTTP status; it never holds the ciphertext we sent.
        raise SealError(f"gh api {args[-1] if args else ''} failed: {done.stderr.strip()[:300]}")
    return json.loads(done.stdout) if done.stdout.strip() else None


def put(bundle, run=subprocess.run, log=print):
    """Store every sealed value in the bundle's environment, after checking the live public key. Each secret is
    its own PUT, so a failure part way leaves the earlier ones stored; rerunning `put` with the same bundle (or
    the producer, for a fresh one) finishes the set."""
    base = f"repos/{bundle['repo']}/environments/{bundle['environment']}/secrets"
    live = gh([f"{base}/public-key"], run) or {}
    if str(live.get("key_id")) != bundle["key_id"] or live.get("key") != bundle["key"]:
        raise SealError(f"{bundle['repo']} environment {bundle['environment']}'s public key is not the one the "
                        f"bundle was sealed to (live key_id {live.get('key_id')}, bundle {bundle['key_id']}): "
                        "nothing was written; reseal to the live key")
    for name in sorted(bundle["secrets"]):
        gh(["-X", "PUT", f"{base}/{name}", "-f", f"encrypted_value={bundle['secrets'][name]}",
            "-f", f"key_id={bundle['key_id']}"], run)
        log(f"stored {name} in {bundle['repo']} environment {bundle['environment']}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    put_command = commands.add_parser("put", help="store a bundle's sealed values in its target environment")
    put_command.add_argument("bundle")
    args = parser.parse_args(argv)
    try:
        if args.command == "put":
            put(read_bundle(args.bundle))
    except SealError as error:
        print(f"sealed_secrets: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
