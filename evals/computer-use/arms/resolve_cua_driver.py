# SPDX-License-Identifier: MIT
"""Pin and fetch the cua-driver-rs v0.38.0 baseline (stdlib only).

  python3 -I arms/resolve_cua_driver.py pin     # fill every "sha256": "PENDING" from the release's checksums.txt
  python3 -I arms/resolve_cua_driver.py fetch [--platform linux-x86_64] [--dest DIR]
                                                # download, verify sha256, unpack; prints the binary path

`fetch` refuses an asset whose sha256 is still PENDING or does not match. The
release is MIT (arms/cua-driver-LICENSE.txt); the binary is used unmodified.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import sys
import tarfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ARM = os.path.join(HERE, "cua-driver-0.38.0.json")
DEFAULT_DEST = os.path.join(os.path.dirname(HERE), ".cache", "cua-driver-0.38.0")


def load() -> dict:
    with open(ARM) as f:
        return json.load(f)


def host_key() -> str:
    os_name = {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")
    machine = platform.machine().lower()
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
    return f"{os_name}-{arch}"


def download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "cmux-cu-eval"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def pin() -> int:
    arm = load()
    rel = arm["release"]
    sums: dict[str, str] = {}
    for line in download(rel["base_url"] + rel["checksums"]).decode().splitlines():
        parts = line.split()
        if len(parts) == 2:
            sums[parts[1].lstrip("*")] = parts[0]
    changed = 0
    for key, asset in rel["assets"].items():
        digest = sums.get(asset["name"])
        if not digest:
            print(f"{key}: {asset['name']} is not in checksums.txt", file=sys.stderr)
            return 1
        if asset["sha256"] not in ("PENDING", digest):
            print(f"{key}: pinned {asset['sha256']} but the release says {digest}; refusing", file=sys.stderr)
            return 1
        if asset["sha256"] == "PENDING":
            asset["sha256"] = digest
            changed += 1
        print(f"{key}: {asset['name']} {digest}")
    with open(ARM, "w") as f:
        json.dump(arm, f, indent=2)
        f.write("\n")
    print(f"pinned {changed} asset(s) in {ARM}")
    return 0


def fetch(key: str, dest: str) -> int:
    rel = load()["release"]
    asset = rel["assets"].get(key)
    if not asset:
        print(f"no asset for {key}; known: {', '.join(rel['assets'])}", file=sys.stderr)
        return 1
    if asset["sha256"] == "PENDING":
        print("sha256 is PENDING; run `resolve_cua_driver.py pin` first", file=sys.stderr)
        return 1
    out = os.path.join(dest, key)
    bin_path = os.path.join(out, asset["bin"])
    if os.path.exists(bin_path):
        print(bin_path)
        return 0
    data = download(rel["base_url"] + asset["name"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != asset["sha256"]:
        print(f"sha256 mismatch for {asset['name']}: got {digest}, pinned {asset['sha256']}", file=sys.stderr)
        return 1
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    archive = os.path.join(out, asset["name"])
    with open(archive, "wb") as f:
        f.write(data)
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            for m in z.namelist():
                if m.startswith("/") or ".." in m.split("/"):
                    raise SystemExit(f"unsafe member {m}")
            z.extractall(out)
    else:
        with tarfile.open(archive) as t:
            t.extractall(out, filter="data")
    if not os.path.exists(bin_path):
        for root, _, files in os.walk(out):
            if asset["bin"] in files:
                bin_path = os.path.join(root, asset["bin"])
                break
    os.chmod(bin_path, 0o755)
    shutil.copy(os.path.join(HERE, "cua-driver-LICENSE.txt"), os.path.join(out, "LICENSE-cua-driver.txt"))
    print(bin_path)
    return 0


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pin")
    f = sub.add_parser("fetch")
    f.add_argument("--platform", default=host_key())
    f.add_argument("--dest", default=DEFAULT_DEST)
    a = p.parse_args()
    return pin() if a.cmd == "pin" else fetch(a.platform, a.dest)


if __name__ == "__main__":
    sys.exit(main())
