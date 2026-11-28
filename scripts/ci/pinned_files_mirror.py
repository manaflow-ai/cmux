#!/usr/bin/env python3
"""Copy every pinned file in images/cmux-vm/inputs.lock.json to the edge bucket by sha256.

RFD 0056 part 3: a VM image bake fetches each pinned release file from
https://ci-cache-next.cmux.com/v1/any/pinned/<sha256> first and its origin URL after
(web/scripts/cmux-vm-image/lock.ts pinnedFetchCommand). GitHub release downloads ran at
about 100 KB/s into the builder on 2026-11-23 and hit the guest's 5-minute exec cap
(rolls 45109809346, 45113664312, 45126299464).

A pinned file is any JSON object in the lock with a `url` and a 64-hex `sha256`. For
each one the edge lacks, this downloads the origin, checks size and sha256, and uploads
it with curl's SigV4 (the same writer git-mirror-bundle.yml uses). The key is the
content hash, so a copy never changes, and r2_cache_prune.py prunes only
v1/*/objects/, so nothing removes it. Prints one JSON summary line.

  pinned_files_mirror.py [--lock PATH] [--dry-run]

Upload needs AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, CI_CACHE_R2_ENDPOINT,
CI_CACHE_R2_BUCKET; CI_CACHE_R2_PUBLIC_URL and CI_CACHE_R2_NAMESPACE default to the
NEXT bucket's.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "images" / "cmux-vm" / "inputs.lock.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PUBLIC_URL = "https://ci-cache-next.cmux.com"
NAMESPACE = "any"
USER_AGENT = "cmux-pinned-files-mirror"


def pinned_files(node: object) -> list[dict]:
    """Every {url, sha256[, size]} in the lock, once per sha256, in lock order."""
    found: dict[str, dict] = {}

    def walk(value: object) -> None:
        if isinstance(value, dict):
            url, sha = value.get("url"), value.get("sha256")
            if isinstance(url, str) and url.startswith("https://") and isinstance(sha, str) and SHA256.match(sha):
                size = value.get("size")
                found.setdefault(sha, {"sha256": sha, "url": url, "size": size if isinstance(size, int) else None})
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(node)
    return list(found.values())


def edge_url(public_url: str, namespace: str, sha: str) -> str:
    return f"{public_url.rstrip('/')}/v1/{namespace}/pinned/{sha}"


def object_path(bucket: str, namespace: str, sha: str) -> str:
    return f"{bucket}/v1/{namespace}/pinned/{sha}"


def edge_has(url: str, size: int | None) -> bool:
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            length = response.headers.get("content-length")
            return response.status == 200 and (size is None or length is None or int(length) == size)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def download(entry: dict, dest: Path) -> None:
    subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--connect-timeout", "15", "--max-time", "1800",
         "-A", USER_AGENT, "-o", str(dest), entry["url"]],
        check=True,
    )
    if entry["size"] is not None and dest.stat().st_size != entry["size"]:
        raise ValueError(f"{entry['url']}: size {dest.stat().st_size}, lock says {entry['size']}")
    digest = hashlib.sha256()
    with dest.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != entry["sha256"]:
        raise ValueError(f"{entry['url']}: sha256 {digest.hexdigest()}, lock says {entry['sha256']}")


def upload(path: Path, sha: str) -> None:
    endpoint = os.environ["CI_CACHE_R2_ENDPOINT"].rstrip("/")
    bucket = os.environ["CI_CACHE_R2_BUCKET"]
    namespace = os.environ.get("CI_CACHE_R2_NAMESPACE", NAMESPACE)
    # The key pair goes to curl on stdin, never on its command line.
    config = 'user = "{}:{}"\n'.format(os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"])
    result = subprocess.run(
        ["curl", "--config", "-", "--silent", "--show-error", "--retry", "3", "--retry-delay", "2",
         "--connect-timeout", "15", "--max-time", "1800", "--aws-sigv4", "aws:amz:auto:s3",
         "-H", "x-amz-content-sha256: UNSIGNED-PAYLOAD",
         "-H", "content-type: application/octet-stream",
         "-H", "cache-control: public, max-age=31536000, immutable",
         "-o", "/dev/null", "-w", "%{http_code}", "-T", str(path),
         f"{endpoint}/{object_path(bucket, namespace, sha)}"],
        input=config, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0 or result.stdout.strip() != "200":
        raise RuntimeError(f"upload {sha}: curl {result.returncode} http {result.stdout.strip()} {result.stderr.strip()}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lock", type=Path, default=LOCK)
    parser.add_argument("--dry-run", action="store_true", help="report what is missing, upload nothing")
    args = parser.parse_args(argv)
    public_url = os.environ.get("CI_CACHE_R2_PUBLIC_URL", PUBLIC_URL)
    namespace = os.environ.get("CI_CACHE_R2_NAMESPACE", NAMESPACE)
    entries = pinned_files(json.loads(args.lock.read_text()))
    present, uploaded, missing, failed = [], [], [], []
    for entry in entries:
        sha = entry["sha256"]
        if edge_has(edge_url(public_url, namespace, sha), entry["size"]):
            present.append(sha)
            continue
        if args.dry_run:
            missing.append(sha)
            continue
        with tempfile.TemporaryDirectory(prefix="pinned-") as tmp:
            path = Path(tmp) / sha
            try:
                download(entry, path)
                upload(path, sha)
                uploaded.append(sha)
            except (subprocess.CalledProcessError, ValueError, RuntimeError) as error:
                print(f"pinned-files-mirror: {entry['url']}: {error}", file=sys.stderr)
                failed.append(sha)
    print(json.dumps({"files": len(entries), "present": len(present), "uploaded": len(uploaded),
                      "missing": len(missing), "failed": failed}))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
