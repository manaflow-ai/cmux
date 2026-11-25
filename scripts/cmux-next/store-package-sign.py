#!/usr/bin/env python3
"""Sign a cmux App Store package (AppPlatform/store/<name>) with the store key.

Writes <package>/STORE.sig: the signed envelope of scripts/cmux-next/web-ota-pointer.py around the
payload

  {"schema": 1, "purpose": "cmux-store-package", "id": ..., "version": ..., "files": {<path>: <sha256>}}

with every file of the package but STORE.sig. The daemon (cmux-tui-core apps/store_trust.rs) lists a
cmux/ or manaflow-ai/ store package as Verified only when a key of
cmux-tui/crates/cmux-tui-core/src/apps/store-keys.json signed exactly those files; the web update
keys are never accepted there. Packages of any other publisher are left unsigned.

sync-app-runtime.sh runs this for each store package when CMUX_STORE_SIGNING_KEY_FILE names the
ed25519 private key (PEM; CI secret CMUX_STORE_SIGNING_KEY). Builds without it ship unsigned store
packages, which list as Unverified.

Usage: store-package-sign.py --key PEM [--keys KEYS] PACKAGE...
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
KEYS = os.path.join(ROOT, "cmux-tui/crates/cmux-tui-core/src/apps/store-keys.json")
SIGNATURE_FILE = "STORE.sig"
PURPOSE = "cmux-store-package"
FIRST_PARTY = ("cmux", "manaflow-ai")


def files_of(package):
    files = {}
    for dirpath, dirnames, filenames in os.walk(package):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, package).replace(os.sep, "/")
            if rel == SIGNATURE_FILE:
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                sys.exit(f"store-package-sign: {path} is not a regular file")
            with open(path, "rb") as f:
                files[rel] = hashlib.sha256(f.read()).hexdigest()
    return files


def sign(package, key, keys):
    manifest = json.load(open(os.path.join(package, "cmux-app.v2.json")))
    app_id, version = manifest["id"], manifest["version"]
    if app_id.split("/", 1)[0] not in FIRST_PARTY:
        print(f"store-package-sign: {app_id} is not cmux's; left unsigned")
        return
    stale = os.path.join(package, SIGNATURE_FILE)
    if os.path.exists(stale):
        os.remove(stale)
    payload = {"schema": 1, "purpose": PURPOSE, "id": app_id, "version": version, "files": files_of(package)}
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "payload.json")
        with open(path, "wb") as out:
            out.write(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())
        subprocess.run([sys.executable, os.path.join(HERE, "web-ota-pointer.py"), "sign", "--payload", path,
                        "--key", key, "--keys", keys, "--out", stale], check=True)
    print(f"store-package-sign: signed {app_id}@{version}")


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", required=True)
    parser.add_argument("--keys", default=KEYS)
    parser.add_argument("packages", nargs="+")
    args = parser.parse_args(argv[1:])
    for package in args.packages:
        sign(package, args.key, args.keys)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
