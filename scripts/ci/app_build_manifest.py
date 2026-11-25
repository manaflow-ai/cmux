#!/usr/bin/env python3
"""Write-once build manifest per app-input digest (clean-sheet CI RFD hq#26225, step 5).

After a nightly-next build is published, writes
<NIGHTLY_NEXT_R2_PREFIX>builds/app/<digest>/manifest.json to the bucket the publish
already writes, with the publish's own scoped credentials, only if the key is absent.
Nothing reads it yet. It cannot fail or change a publish: every error is logged and the
exit code is 0, and each external call has a short timeout.

Environment: APP_INPUT_DIGEST, HEAD_SHA (the commit the digest was computed for),
BUILD_SHA (the commit published), DMG (path of the published dmg), RUN_ID, optional
NOTARY_SUBMISSION_ID; AWS_*, R2_ENDPOINT, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX
from the publish step. MANIFEST_UPLOADER overrides the uploader command (tests).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPLOADER = HERE / "upload-r2-object.py"
GUARD = HERE / "nightly-next-guard.py"
EXISTS_CODE = 3
TIMEOUT = 20


def log(message: str) -> None:
    print(f"app-build-manifest: {message}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(environ) -> tuple[str, dict]:
    digest = environ.get("APP_INPUT_DIGEST", "").strip()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"no usable app-input digest ({digest!r})")
    head, built = environ.get("HEAD_SHA", "").strip(), environ.get("BUILD_SHA", "").strip()
    if not head or head != built:
        raise ValueError("published commit is not the commit the digest was computed for")
    dmg = Path(environ.get("DMG", ""))
    if not dmg.is_file():
        raise ValueError(f"no published artifact at {dmg}")
    return digest, {
        "schema": 1,
        "app_input_digest": digest,
        "commit": built,
        "bundle_sha256": sha256_file(dmg),
        "bundle_name": dmg.name,
        "notarization_submission_id": environ.get("NOTARY_SUBMISSION_ID", "").strip() or None,
        "built_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id": environ.get("RUN_ID", "").strip() or None,
    }


def put_if_absent(key: str, body: bytes, environ) -> str:
    """'written' or 'exists'; raises on any other failure."""
    with tempfile.TemporaryDirectory(prefix="app-build-manifest-") as scratch:
        path = Path(scratch) / "manifest.json"
        path.write_bytes(body)
        override = environ.get("MANIFEST_UPLOADER")
        if override:
            command = override.split() + [str(path), key]
        else:
            bucket = environ["NIGHTLY_NEXT_R2_BUCKET"]
            subprocess.run([sys.executable, str(GUARD), "r2-key", bucket, key], check=True, timeout=TIMEOUT)
            command = [sys.executable, str(UPLOADER), "--file", str(path), "--endpoint-url", environ["R2_ENDPOINT"],
                       "--bucket", bucket, "--key", key, "--content-type", "application/json",
                       "--cache-control", "public, max-age=31536000, immutable",
                       "--write-once", "--conflict-exit-code", str(EXISTS_CODE)]
        result = subprocess.run(command, timeout=TIMEOUT, check=False)
        if result.returncode == 0:
            return "written"
        if result.returncode == EXISTS_CODE:
            return "exists"
        raise RuntimeError(f"uploader exited {result.returncode}")


def run(environ) -> None:
    digest, manifest = build_manifest(environ)
    key = f"{environ.get('NIGHTLY_NEXT_R2_PREFIX', 'nightly-next/')}builds/app/{digest}/manifest.json"
    body = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    outcome = put_if_absent(key, body, environ)
    log(f"{key}: {outcome}" + (" (kept the first manifest)" if outcome == "exists" else ""))


def main() -> int:
    try:
        run(os.environ)
    except BaseException as error:  # never fail or change a publish
        log(f"skipped: {type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
