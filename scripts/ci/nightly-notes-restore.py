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
import zipfile

HERE = Path(__file__).resolve().parent
NOTES = HERE.parent / "cmux-next" / "release-notes.py"
UPLOADER = HERE / "upload-r2-object.py"
BUILD = re.compile(r"^[0-9]+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
CONTENT_PUBLIC_KEY = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="
R2_BUCKET = "cmux-nightly-next"
RELEASE_BRANCH = "nightly-next"
RELEASE_ENVIRONMENT = "release-next"
RELEASE_WORKFLOW = ".github/workflows/nightly.yml"


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
    if value.get("environment") != RELEASE_ENVIRONMENT:
        fail(f"approval receipt is not from the {RELEASE_ENVIRONMENT} environment")
    if value.get("withdrawal_authority") != RELEASE_ENVIRONMENT:
        fail("approval receipt does not identify the protected withdrawal authority")


def _gh_json(path: str) -> dict:
    result = subprocess.run(["gh", "api", path], check=False, capture_output=True, text=True)
    if result.returncode:
        fail(f"GitHub source record read failed for {path}: {result.stderr.strip() or result.stdout.strip()}")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"GitHub source record for {path} was not JSON: {error}")
    if not isinstance(value, dict):
        fail(f"GitHub source record for {path} was not an object")
    return value


def verify_source_record(provenance: dict, notes_bytes: bytes, signature_bytes: bytes) -> None:
    """Bind the local pair to the original nightly run and its immutable artifact."""
    required = ("artifact_run", "artifact_id", "artifact_sha256", "artifact_name")
    missing = [key for key in required if key not in provenance]
    if missing:
        fail(f"production provenance is missing {', '.join(missing)}")
    artifact_run = str(provenance["artifact_run"])
    artifact_id = str(provenance["artifact_id"])
    if not artifact_run.isdigit() or not artifact_id.isdigit() or not HEX.fullmatch(str(provenance["artifact_sha256"])):
        fail("artifact_run, artifact_id and artifact_sha256 must identify the recorded artifact digest")
    repository = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    run_path = f"repos/{repository}/actions/runs/{provenance['source_run']}/attempts/{provenance['source_attempt']}"
    run = _gh_json(run_path)
    checks = {
        "workflow": run.get("path") == RELEASE_WORKFLOW,
        "branch": run.get("head_branch") == RELEASE_BRANCH,
        "source SHA": run.get("head_sha") == provenance["source_sha"],
        "attempt": str(run.get("run_attempt")) == str(provenance["source_attempt"]),
        "event": run.get("event") in ("push", "workflow_dispatch"),
        "repository": str((run.get("repository") or {}).get("full_name", "")).lower() == repository.lower(),
    }
    failed = [name for name, ok in checks.items() if not ok]
    if failed:
        fail(f"original source run failed trusted checks: {', '.join(failed)}")
    if run.get("status") != "completed":
        fail("original source run is not completed")
    if run.get("conclusion") != "success":
        jobs = _gh_json(f"repos/{repository}/actions/runs/{provenance['source_run']}/jobs?filter=latest&per_page=100")
        published = any(
            job.get("name") in {"nightly-next-one", "publish-nightly"} and job.get("conclusion") == "success"
            for job in jobs.get("jobs", [])
        )
        if not published:
            fail("original source run has no successful nightly publication job")
    artifact = _gh_json(f"repos/{repository}/actions/artifacts/{artifact_id}")
    expected_zip = f"sha256:{provenance['artifact_sha256']}"
    if artifact.get("digest") != expected_zip:
        fail(f"artifact metadata digest {artifact.get('digest')} does not match provenance {expected_zip}")
    if artifact.get("expired") is True or artifact.get("name") != provenance["artifact_name"]:
        fail("source artifact is expired or has the wrong name")
    workflow_run = artifact.get("workflow_run") or {}
    if str(workflow_run.get("id")) != artifact_run or workflow_run.get("head_sha") != provenance["source_sha"]:
        fail("source artifact is not attached to the recorded artifact run and source SHA")
    with tempfile.TemporaryDirectory(prefix="nightly-notes-artifact-") as scratch:
        archive = Path(scratch) / "release-notes.zip"
        result = subprocess.run(
            ["gh", "api", f"repos/{repository}/actions/artifacts/{artifact_id}/zip"],
            check=False, capture_output=True,
        )
        if result.returncode:
            fail(f"source artifact download failed: {result.stderr.decode(errors='replace').strip()}")
        archive.write_bytes(result.stdout)
        if digest(result.stdout) != provenance["artifact_sha256"]:
            fail("downloaded source artifact bytes do not match the trusted artifact digest")
        try:
            with zipfile.ZipFile(archive) as bundle:
                names = set(bundle.namelist())
                build = str(provenance["build"])
                expected = {f"{build}.json", f"{build}.json.sig"}
                if not expected <= names:
                    fail("source artifact does not contain the signed notes pair")
                if bundle.read(f"{build}.json") != notes_bytes or bundle.read(f"{build}.json.sig") != signature_bytes:
                    fail("local notes pair does not match the original signed artifact")
        except (OSError, zipfile.BadZipFile, KeyError) as error:
            fail(f"invalid source artifact: {error}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", required=True, type=Path)
    parser.add_argument("--signature", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--public-key", help="dry-run fixture key; production always uses the pinned key")
    parser.add_argument("--endpoint-url", help=argparse.SUPPRESS)
    parser.add_argument("--bucket", help=argparse.SUPPRESS)
    parser.add_argument("--approval-receipt", type=Path,
                        help="release-owner approval receipt required for a real upload")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    provenance = load_provenance(args.provenance)
    if not args.dry_run and args.public_key:
        fail("--public-key is only allowed for dry-run fixtures")
    if not args.dry_run and (args.endpoint_url or args.bucket):
        fail("production endpoint and bucket are fixed by the release-owner environment")
    public_key = args.public_key or CONTENT_PUBLIC_KEY
    build, notes_bytes, signature_bytes = validate(args.notes, args.signature, provenance, public_key)
    if not args.dry_run:
        if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REF") != "refs/heads/nightly-next":
            fail("upload requires the protected nightly-next GitHub Actions environment")
        if os.environ.get("RELEASE_ENVIRONMENT") != RELEASE_ENVIRONMENT:
            fail("upload requires RELEASE_ENVIRONMENT=release-next")
        if not args.approval_receipt or not args.approval_receipt.is_file():
            fail("a release-owner approval receipt is required for upload")
        load_approval(args.approval_receipt, provenance)
        endpoint_url = os.environ.get("R2_ENDPOINT", "")
        if not endpoint_url:
            fail("R2 endpoint is required for upload")
        if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("AWS_SECRET_ACCESS_KEY"):
            fail("use the established release-owner R2 credentials")
        if not re.fullmatch(r"https://[^/]+\.r2\.cloudflarestorage\.com/?", endpoint_url):
            fail("R2_ENDPOINT must be the protected Cloudflare R2 endpoint")
        verify_source_record(provenance, notes_bytes, signature_bytes)
    else:
        endpoint_url = ""
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
    # Keep the exact bytes that passed verification for the complete upload.
    # Reopening caller paths after verification would permit a swap in between.
    with tempfile.TemporaryDirectory(prefix="nightly-notes-upload-") as scratch:
        staged = ((Path(scratch) / f"{build}.json", f"{PREFIX}{build}.json", "application/json", notes_bytes),
                  (Path(scratch) / f"{build}.json.sig", f"{PREFIX}{build}.json.sig", "text/plain", signature_bytes))
        for path, _, _, content in staged:
            path.write_bytes(content)
    # Check both immutable keys before writing either one.  The uploader repeats
    # this check on every write to close the race between preflight and PUT.
        for path, key, content_type, content in staged:
            subprocess.run([sys.executable, str(UPLOADER), "--file", str(path),
                        "--endpoint-url", endpoint_url, "--bucket", R2_BUCKET,
                        "--key", key, "--content-type", content_type,
                        "--cache-control", "no-cache, no-store, must-revalidate",
                        "--preflight-only", "--expected-sha256", digest(content)], check=True)
        for path, key, content_type, _ in staged:
            subprocess.run([sys.executable, str(UPLOADER), "--file", str(path),
                        "--endpoint-url", endpoint_url, "--bucket", R2_BUCKET,
                        "--key", key, "--content-type", content_type,
                        "--cache-control", "no-cache, no-store, must-revalidate", "--write-once"],
                        check=True)
    return 0


if __name__ == "__main__":
    main()
