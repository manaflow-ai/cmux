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


HEX = re.compile(r"^[0-9a-f]{64}$")
PREFIX = "nightly-next/notes/"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_provenance(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid provenance {path}: {error}")
    if not isinstance(value, dict):
        fail("provenance must be a JSON object")
    required = ("source_run", "source_attempt", "source_sha", "build", "withdrawn",
                "notes_sha256", "signature_sha256")
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
    for key in ("notes_sha256", "signature_sha256"):
        if not HEX.fullmatch(str(value[key])):
            fail(f"{key} must be a 64-character lowercase SHA-256 digest")
    return value


def verify(notes: bytes, signature: bytes, name: str, public_key: str) -> None:
    if not notes or not signature:
        fail("both notes JSON and notes JSON.sig are required; unsigned records need release-owner signing")
    # Keep the canonical verifier in release-notes.py so this tool cannot drift
    # from the nightly release gate's Ed25519 contract.
    with tempfile.TemporaryDirectory(prefix="nightly-notes-verify-") as scratch:
        copy = Path(scratch) / name
        sig = Path(str(copy) + ".sig")
        copy.write_bytes(notes)
        sig.write_bytes(signature)
        result = subprocess.run(
            [sys.executable, str(NOTES), "verify", "--public-key", public_key, str(copy)],
            text=True, capture_output=True,
        )
        if result.returncode:
            fail(f"signature verification failed: {result.stderr.strip() or result.stdout.strip()}")


def validate(notes: Path, signature: Path, provenance: dict, public_key: str) -> tuple[str, bytes, bytes]:
    try:
        notes_bytes = notes.read_bytes()
        signature_bytes = signature.read_bytes()
    except OSError as error:
        fail(f"both notes JSON and notes JSON.sig are required; unsigned records need release-owner signing ({error})")
    verify(notes_bytes, signature_bytes, notes.name, public_key)
    try:
        value = json.loads(notes_bytes.decode("utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid notes JSON: {error}")
    build = str(provenance["build"])
    if not isinstance(value, dict) or str(value.get("build")) != build:
        fail(f"notes build {value.get('build') if isinstance(value, dict) else None} does not match provenance {build}")
    if value.get("head") != provenance["source_sha"]:
        fail("notes head does not match the original source_sha")
    notes_sha256 = digest(notes_bytes)
    signature_sha256 = digest(signature_bytes)
    if provenance["notes_sha256"] != notes_sha256:
        fail(f"notes SHA-256 {notes_sha256} does not match provenance {provenance['notes_sha256']}")
    if provenance["signature_sha256"] != signature_sha256:
        fail(f"signature SHA-256 {signature_sha256} does not match provenance {provenance['signature_sha256']}")
    return build, notes_bytes, signature_bytes


def load_approval(path: Path, provenance: dict) -> None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid release-owner approval receipt {path}: {error}")
    if not isinstance(value, dict) or value.get("kind") != "nightly-notes-restore" or value.get("approved") is not True:
        fail("release-owner approval receipt must be an approved nightly-notes-restore record")
    for key in ("source_run", "source_attempt", "source_sha", "build", "notes_sha256", "signature_sha256"):
        if str(value.get(key)) != str(provenance[key]):
            fail(f"approval receipt does not exactly match provenance {key}")
    if value.get("withdrawn") is not False:
        fail("approval receipt does not confirm the build is not withdrawn")
    if not isinstance(value.get("approved_by"), str) or not value["approved_by"].strip():
        fail("approval receipt is missing approved_by")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--public-key", default=os.environ.get("CONTENT_PUBLIC_KEY", ""),
                        help="only for dry-run fixtures; production uses CONTENT_PUBLIC_KEY")
    parser.add_argument("--endpoint-url", default=os.environ.get("R2_ENDPOINT", ""))
    parser.add_argument("--bucket", default=os.environ.get("NIGHTLY_NEXT_R2_BUCKET", "cmux-nightly-next"))
    parser.add_argument("--approval-receipt", type=Path,
                        help="release-owner approval receipt required for a real upload")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    provenance = load_provenance(args.provenance)
    if not args.public_key:
        fail("CONTENT_PUBLIC_KEY is required")
    build, notes_bytes, signature_bytes = validate(args.notes, args.signature, provenance, args.public_key)
    if not args.dry_run:
        if not args.approval_receipt or not args.approval_receipt.is_file():
            fail("a release-owner approval receipt is required for upload")
        load_approval(args.approval_receipt, provenance)
        if not args.endpoint_url:
            fail("R2 endpoint is required for upload")
        if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("AWS_SECRET_ACCESS_KEY"):
            fail("use the established release-owner R2 credentials")
    files = ((args.notes, f"{PREFIX}{build}.json", "application/json", digest(notes_bytes)),
             (args.signature, f"{PREFIX}{build}.json.sig", "text/plain", digest(signature_bytes)))
    print(json.dumps({"build": build, "source_run": str(provenance["source_run"]),
                      "source_attempt": str(provenance["source_attempt"]),
                      "source_sha": provenance["source_sha"], "notes_sha256": digest(notes_bytes),
                      "signature_sha256": digest(signature_bytes),
                      "withdrawn": False, "objects": [key for _, key, _, _ in files],
                      "create_only": True, "dry_run": args.dry_run}, sort_keys=True))
    if args.dry_run:
        return 0
    # Check both immutable keys before writing either one.  The uploader repeats
    # this check on every write to close the race between preflight and PUT.
    for path, key, content_type, expected_digest in files:
        subprocess.run([sys.executable, str(UPLOADER), "--file", str(path),
                        "--endpoint-url", args.endpoint_url, "--bucket", args.bucket,
                        "--key", key, "--content-type", content_type,
                        "--cache-control", "no-cache, no-store, must-revalidate",
                        "--preflight-only", "--expected-sha256", expected_digest], check=True)
    for path, key, content_type, _ in files:
        subprocess.run([sys.executable, str(UPLOADER), "--file", str(path),
                        "--endpoint-url", args.endpoint_url, "--bucket", args.bucket,
                        "--key", key, "--content-type", content_type,
                        "--cache-control", "no-cache, no-store, must-revalidate", "--write-once"],
                       check=True)
    return 0


if __name__ == "__main__":
    main()
