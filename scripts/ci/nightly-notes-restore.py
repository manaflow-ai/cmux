#!/usr/bin/env python3
"""Restore one historical nightly-next notes pair without rebuilding a release.

The caller supplies the signed notes pair from the original release artifact and
a provenance record from the publishing run.  This tool only writes the pair
under ``nightly-next/notes/`` through the existing release uploader.  Every
write is create-only, so a different object is a hard failure.

Unsigned source records are deliberately rejected.  The release owner must
first produce the original signature through the normal signing workflow.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
NOTES = HERE.parent / "cmux-next" / "release-notes.py"
UPLOADER = HERE / "upload-r2-object.py"
BUILD = re.compile(r"^[0-9]+$")
SHA = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"nightly-notes-restore: {message}")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_provenance(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid provenance {path}: {error}")
    if not isinstance(value, dict):
        fail("provenance must be a JSON object")
    required = ("source_run", "source_attempt", "source_sha", "build", "withdrawn")
    missing = [key for key in required if key not in value]
    if missing:
        fail(f"provenance is missing {', '.join(missing)}")
    if not (str(value["source_run"]).isdigit() and str(value["source_attempt"]).isdigit()):
        fail("source_run and source_attempt must be numeric")
    if not SHA.fullmatch(str(value["source_sha"])):
        fail("source_sha must be a 40-character lowercase commit SHA")
    if not BUILD.fullmatch(str(value["build"])):
        fail("build must be numeric")
    expected_build = f"{value['source_run']}{int(value['source_attempt']):02d}"
    if str(value["build"]) != expected_build:
        fail(f"build {value['build']} does not encode source_run/attempt {value['source_run']}/{value['source_attempt']}")
    if value["withdrawn"] is not False:
        fail("refusing a withdrawn or unknown build")
    return value


def verify(notes: Path, signature: Path, public_key: str) -> None:
    if not notes.is_file() or not signature.is_file():
        fail("both notes JSON and notes JSON.sig are required; unsigned records need release-owner signing")
    # Keep the canonical verifier in release-notes.py so this tool cannot drift
    # from the nightly release gate's Ed25519 contract.
    with tempfile.TemporaryDirectory(prefix="nightly-notes-verify-") as scratch:
        copy = Path(scratch) / notes.name
        sig = Path(str(copy) + ".sig")
        copy.write_bytes(notes.read_bytes())
        sig.write_bytes(signature.read_bytes())
        result = subprocess.run(
            [sys.executable, str(NOTES), "verify", "--public-key", public_key, str(copy)],
            text=True, capture_output=True,
        )
        if result.returncode:
            fail(f"signature verification failed: {result.stderr.strip() or result.stdout.strip()}")


def validate(notes: Path, signature: Path, provenance: dict, public_key: str) -> tuple[str, str]:
    verify(notes, signature, public_key)
    try:
        value = json.loads(notes.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid notes JSON: {error}")
    build = str(provenance["build"])
    if not isinstance(value, dict) or str(value.get("build")) != build:
        fail(f"notes build {value.get('build') if isinstance(value, dict) else None} does not match provenance {build}")
    if value.get("head") != provenance["source_sha"]:
        fail("notes head does not match the original source_sha")
    return build, digest(notes)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--endpoint-url", default=os.environ.get("R2_ENDPOINT", ""))
    parser.add_argument("--bucket", default=os.environ.get("NIGHTLY_NEXT_R2_BUCKET", "cmux-nightly-next"))
    parser.add_argument("--prefix", default="nightly-next/notes/")
    parser.add_argument("--approval-receipt", type=Path,
                        help="release-owner approval receipt required for a real upload")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    provenance = load_provenance(args.provenance)
    build, notes_digest = validate(args.notes, args.signature, provenance, args.public_key)
    if not args.dry_run:
        if not args.approval_receipt or not args.approval_receipt.is_file():
            fail("a release-owner approval receipt is required for upload")
        receipt = args.approval_receipt.read_text(encoding="utf-8")
        for marker in (str(provenance["source_run"]), str(provenance["source_attempt"]),
                       provenance["source_sha"], build):
            if marker not in receipt:
                fail(f"approval receipt does not name {marker}")
        if not args.endpoint_url:
            fail("R2 endpoint is required for upload")
        if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("AWS_SECRET_ACCESS_KEY"):
            fail("use the established release-owner R2 credentials")
    files = ((args.notes, f"{args.prefix}{build}.json", "application/json"),
             (args.signature, f"{args.prefix}{build}.json.sig", "text/plain"))
    print(json.dumps({"build": build, "source_run": str(provenance["source_run"]),
                      "source_attempt": str(provenance["source_attempt"]),
                      "source_sha": provenance["source_sha"], "notes_sha256": notes_digest,
                      "signature_sha256": digest(args.signature),
                      "withdrawn": False, "objects": [key for _, key, _ in files],
                      "create_only": True, "dry_run": args.dry_run}, sort_keys=True))
    if args.dry_run:
        return 0
    for path, key, content_type in files:
        subprocess.run([sys.executable, str(UPLOADER), "--file", str(path),
                        "--endpoint-url", args.endpoint_url, "--bucket", args.bucket,
                        "--key", key, "--content-type", content_type,
                        "--cache-control", "no-cache, no-store, must-revalidate", "--write-once"],
                       check=True)
    return 0


if __name__ == "__main__":
    main()
