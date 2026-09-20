#!/usr/bin/env python3
"""Pin and fetch opt-in app-host layers through exact GitHub artifact IDs.

The canonical inner manifest belongs to app_host_layered_products.py. This
wrapper adds provider identities after upload; no artifact-name lookup, URL
from an index, or same-digest origin substitution is permitted.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import tempfile
import time
import zipfile

from app_host_layered_products import LAYERS as NAMES, MANIFEST, SCHEMA as LAYER_SCHEMA

INDEX = "app-host-layer-index.json"
MAX_INDEX = 8 * 1024 * 1024
MAX_ARCHIVE = 8 * 1024 * 1024 * 1024
SCHEMA = "cmux.app-host-layer-transport"


def mapping(value):
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def records(value):
    if not isinstance(value, list):
        raise ValueError("expected a JSON array")
    return [mapping(row) for row in value]


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("expected a timestamp string")
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp is not timezone-aware")
    return result


def digest(value):
    value = value.removeprefix("sha256:") if isinstance(value, str) else ""
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("invalid SHA-256")
    return value


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def positive(value):
    if isinstance(value, bool) or not str(value).isdecimal() or int(value) <= 0:
        raise ValueError("invalid positive integer")
    return int(value)


def producer(repository, identity, run_head_sha):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid repository")
    for value in (run_head_sha, identity["source_sha"]):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError("invalid source identity")
    return {"repository": repository, "run_id": positive(identity["workflow_run_id"]),
            "run_attempt": positive(identity["workflow_run_attempt"]),
            "run_head_sha": run_head_sha, "source_sha": identity["source_sha"]}


class GitHub:
    """Use gh's authenticated redirect handling, never an index-provided URL."""
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("invalid repository")
        self.repository = repository

    def get(self, path):
        result = subprocess.check_output(["gh", "api", f"repos/{self.repository}/{path}"], timeout=30)
        if len(result) > MAX_INDEX:
            raise ValueError("provider metadata exceeds limit")
        return json.loads(result)

    def download(self, artifact_id, target, limit):
        # gh strips API authorization when following its cross-host blob redirect.
        # Bound bytes and elapsed time while streaming; do not buffer large ZIPs.
        with tempfile.TemporaryFile() as errors, target.open("wb") as output:
            process = subprocess.Popen(["gh", "api", f"repos/{self.repository}/actions/artifacts/{positive(artifact_id)}/zip"],
                                       stdout=subprocess.PIPE, stderr=errors)
            try:
                deadline = time.monotonic() + 1200
                count = 0
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError("artifact download deadline exceeded")
                        if not selector.select(min(remaining, 10)):
                            continue
                        block = os.read(process.stdout.fileno(), 1024 * 1024)
                        if not block:
                            break
                        count += len(block)
                        if count > limit:
                            raise ValueError("provider ZIP exceeds pinned size")
                        output.write(block)
                if process.wait(timeout=max(1, deadline - time.monotonic())):
                    raise ValueError("GitHub artifact download failed")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()


def verify_run(api, expected):
    run = mapping(api.get(f"actions/runs/{expected['run_id']}"))
    if (run.get("id") != expected["run_id"]
            or run.get("run_attempt") != expected["run_attempt"]
            or run.get("head_sha") != expected["run_head_sha"]
            or run.get("path") != ".github/workflows/ci.yml"
            or run.get("event") not in {"pull_request", "merge_group", "workflow_dispatch"}
            or str(mapping(run.get("head_repository", {})).get("full_name", "")).casefold() != expected["repository"].casefold()):
        raise ValueError("producer run identity mismatch")
    attempt = mapping(api.get(f"actions/runs/{expected['run_id']}/attempts/{expected['run_attempt']}"))
    if attempt.get("id") != expected["run_id"] or attempt.get("run_attempt") != expected["run_attempt"]:
        raise ValueError("producer attempt mismatch")
    return timestamp(attempt.get("run_started_at", ""))


def metadata(api, artifact_id, expected_digest, expected, *, since, size=None, limit=MAX_ARCHIVE):
    artifact_id = positive(artifact_id)
    item = mapping(api.get(f"actions/artifacts/{artifact_id}"))
    expires = timestamp(item.get("expires_at", ""))
    created = timestamp(item.get("created_at", ""))
    actual_size = positive(item.get("size_in_bytes"))
    if (item.get("id") != artifact_id or item.get("expired") is not False
            or expires <= dt.datetime.now(dt.timezone.utc)
            or created < since
            or mapping(item.get("workflow_run", {})).get("id") != expected["run_id"]
            or digest(item.get("digest")) != digest(expected_digest)
            or actual_size > limit or (size is not None and actual_size != positive(size))):
        raise ValueError("artifact origin, expiry, size or digest mismatch")
    return item


def fetch_zip(api, reference, expected, target, limit, since, layer):
    started = time.monotonic()
    record = {"layer": layer, "artifact_id": reference.get("artifact_id"),
              "producer_run_id": expected["run_id"], "producer_run_attempt": expected["run_attempt"],
              "expected_zip_bytes": reference.get("artifact_size"),
              "expected_archive_bytes": reference.get("size"), "result": "failure"}
    try:
        item = metadata(api, reference["artifact_id"], reference["artifact_digest"], expected,
                        since=since, size=reference.get("artifact_size"), limit=limit)
        record["expected_zip_bytes"] = item["size_in_bytes"]
        api.download(item["id"], target, item["size_in_bytes"])
        if target.stat().st_size != item["size_in_bytes"] or sha(target) != digest(reference["artifact_digest"]):
            raise ValueError("provider ZIP integrity mismatch")
        record["result"] = "success"
    finally:
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        record["downloaded_bytes"] = target.stat().st_size if target.exists() else 0
        print("CMUX_APP_HOST_LAYER_TRANSFER " + json.dumps(record, sort_keys=True))


def extract_files(archive, expectations, output):
    """Read only exact flat regular members; never call extractall."""
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if len(entries) != len(expectations) or {e.filename for e in entries} != set(expectations):
            raise ValueError("unexpected or duplicate provider ZIP members")
        for entry in entries:
            mode = entry.external_attr >> 16
            if (entry.is_dir() or entry.flag_bits & 1 or (stat.S_IFMT(mode) not in (0, stat.S_IFREG))
                    or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValueError("provider ZIP member is not a regular file")
            expected = expectations[entry.filename]
            size = positive(expected["size"])
            if entry.file_size != size:
                raise ValueError("inner file size mismatch")
            destination = output / entry.filename
            with source.open(entry) as incoming, destination.open("xb") as target:
                copied = 0
                while block := incoming.read(min(1024 * 1024, size - copied + 1)):
                    copied += len(block)
                    if copied > size:
                        raise ValueError("inner file expansion exceeds pinned size")
                    target.write(block)
            if copied != size or sha(destination) != digest(expected["sha256"]):
                raise ValueError("inner file integrity mismatch")


def layer_map(manifest):
    mapping(manifest)
    if (manifest.get("schema") != LAYER_SCHEMA or manifest.get("version") != 1
            or manifest.get("profile") != "app-host-full"):
        raise ValueError("unsupported canonical manifest")
    layers = records(manifest.get("layers", []))
    if len(layers) != len(NAMES) or {row.get("name") for row in layers} != set(NAMES):
        raise ValueError("all four layers are required")
    for row in layers:
        if row.get("archive") != row["name"] + ".aar":
            raise ValueError("unexpected layer archive path")
        if positive(row["size"]) > MAX_ARCHIVE:
            raise ValueError("layer size exceeds limit")
        digest(row["sha256"])
    return {row["name"]: row for row in layers}


def publish_index(api, directory, receipts, identity, expected):
    receipts = records(receipts)
    since = verify_run(api, expected)
    manifest_path = directory / MANIFEST
    if manifest_path.stat().st_size > MAX_INDEX:
        raise ValueError("manifest exceeds limit")
    manifest = json.loads(manifest_path.read_text())
    layers = layer_map(manifest)
    if manifest.get("identity") != identity:
        raise ValueError("canonical identity mismatch")
    if len(receipts) != len(NAMES) or {r.get("name") for r in receipts} != set(NAMES):
        raise ValueError("exactly four upload receipts required")
    result = []
    for receipt in receipts:
        row = layers[receipt["name"]]
        archive = directory / row["archive"]
        if archive.is_symlink() or archive.stat().st_size != row["size"] or sha(archive) != digest(row["sha256"]):
            raise ValueError("local uploaded archive differs from manifest")
        item = metadata(api, receipt["artifact_id"], receipt["artifact_digest"], expected, since=since)
        result.append({key: row[key] for key in ("name", "archive", "sha256", "size")} |
                      {"artifact_id": item["id"], "artifact_digest": item["digest"], "artifact_size": item["size_in_bytes"]})
    if len({r["artifact_id"] for r in result}) != len(NAMES):
        raise ValueError("layer artifact IDs must be distinct")
    index = {"schema": SCHEMA, "version": 1, "producer": expected, "identity": identity,
             "manifest": {"file": MANIFEST, "sha256": sha(manifest_path), "size": manifest_path.stat().st_size},
             "layers": result}
    (directory / INDEX).write_text(json.dumps(index, sort_keys=True, indent=2) + "\n")


def restore_remote(api, reference, identity, expected, destination, restore):
    since = verify_run(api, expected)
    if destination.is_symlink() or destination.exists():
        raise ValueError("layered consumer DerivedData must be absent")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="app-host-layer-fetch-", dir=destination.parent) as temporary:
        root = Path(temporary)
        index_zip = root / "index.zip"
        fetch_zip(api, reference, expected, index_zip, MAX_INDEX, since, "index")
        # The outer ZIP digest is pinned by the producer job output. Read the
        # small index only after that check, then verify both extracted files.
        with zipfile.ZipFile(index_zip) as source:
            entry = source.getinfo(INDEX)
            if (entry.is_dir() or entry.flag_bits & 1
                    or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFREG)
                    or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValueError("unsupported index ZIP member")
            if entry.file_size <= 0 or entry.file_size > MAX_INDEX:
                raise ValueError("index exceeds limit")
            data = source.read(entry)
        index = mapping(json.loads(data))
        manifest_reference = mapping(index.get("manifest", {}))
        if (index.get("schema") != SCHEMA or index.get("version") != 1
                or index.get("producer") != expected or index.get("identity") != identity
                or manifest_reference.get("file") != MANIFEST):
            raise ValueError("layer index identity mismatch")
        if positive(manifest_reference.get("size")) > MAX_INDEX:
            raise ValueError("canonical manifest exceeds limit")
        extract_files(index_zip, {INDEX: {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()},
                                 MANIFEST: index["manifest"]}, root)
        manifest = json.loads((root / MANIFEST).read_text())
        layers = layer_map(manifest)
        if manifest.get("identity") != identity:
            raise ValueError("canonical identity mismatch")
        rows = records(index.get("layers", []))
        if len(rows) != len(NAMES) or {r.get("name") for r in rows} != set(NAMES):
            raise ValueError("transport requires all four layers")
        if len({r.get("artifact_id") for r in rows}) != len(NAMES):
            raise ValueError("duplicate layer artifact IDs")
        for row in rows:
            canonical = layers[row["name"]]
            if any(row.get(k) != canonical[k] for k in ("archive", "size", "sha256")):
                raise ValueError("transport and canonical manifest disagree")
            archive = root / (row["name"] + ".zip")
            fetch_zip(api, row, expected, archive, MAX_ARCHIVE, since, row["name"])
            extract_files(archive, {row["archive"]: row}, root)
        # The local assembler owns pre-extraction archive checks, exact inventory,
        # signatures-preserving paths, and transactional publication of Products.
        started = time.monotonic()
        result = "failure"
        try:
            restore(root / MANIFEST, destination, identity)
            result = "success"
        finally:
            print("CMUX_APP_HOST_LAYER_ASSEMBLY " + json.dumps({
                "producer_run_id": expected["run_id"], "producer_run_attempt": expected["run_attempt"],
                "profile": "app-host-full", "layers": list(NAMES), "result": result,
                "elapsed_seconds": round(time.monotonic() - started, 3)}, sort_keys=True))


def restore_warning_log(derived):
    import reuse_app_host_products as reuse
    products = derived / "Build/Products"
    receipt = products / reuse.RECEIPT
    if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_size > MAX_INDEX:
        raise ValueError("invalid producer warning receipt")
    value = json.loads(receipt.read_text())
    data = reuse.build_log_bytes(products / reuse.BUILD_LOG)
    if hashlib.sha256(data).hexdigest() != value.get("build_log_sha256"):
        raise ValueError("producer warning evidence mismatch")
    destination = derived / reuse.BUILD_LOG
    if destination.is_symlink() or destination.exists():
        raise ValueError("consumer warning log already exists")
    destination.write_bytes(data)


def current_identity():
    import app_host_test_products as products
    value = products.identity()
    return {"source_sha": value["revision"], "workflow_run_id": os.environ["GITHUB_RUN_ID"],
            "workflow_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
            "toolchain": {k: value[k] for k in ("xcode", "architecture", "developer")}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("identity", "publish-index", "restore", "restore-warning-log"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--receipts", type=Path)
    parser.add_argument("--index-id")
    parser.add_argument("--index-digest")
    args = parser.parse_args()
    if args.mode == "restore-warning-log":
        restore_warning_log(args.path)
        return
    identity = current_identity()
    if args.mode == "identity":
        args.path.write_text(json.dumps(identity, sort_keys=True) + "\n")
        return
    expected = producer(os.environ["GITHUB_REPOSITORY"], identity, os.environ["CMUX_RUN_HEAD_SHA"])
    api = GitHub(expected["repository"])
    if args.mode == "publish-index":
        publish_index(api, args.path, json.loads(args.receipts.read_text()), identity, expected)
        return
    hit = False
    try:
        def assemble(manifest, destination, expected_identity):
            identity_path = manifest.parent / "expected-identity.json"
            identity_path.write_text(json.dumps(expected_identity))
            subprocess.run([os.sys.executable, str(Path(__file__).with_name("app_host_layered_products.py")),
                            "restore", str(manifest), str(destination), "--identity", str(identity_path)], check=True)
        restore_remote(api, {"artifact_id": args.index_id, "artifact_digest": args.index_digest},
                       identity, expected, args.path, assemble)
        hit = True
    except (KeyError, ValueError, TypeError, OSError, TimeoutError, subprocess.SubprocessError,
            zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
        print(f"Layered product unavailable ({type(error).__name__}); using legacy aggregate.")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"hit={str(hit).lower()}\n")
    if hit:
        # The workflow passes an absent, task-owned sibling directory. Adopt it
        # only after verified no-replace assembly; a miss leaves legacy state alone.
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write(f"CMUX_DERIVED_DATA_PATH={args.path.resolve()}\n")


if __name__ == "__main__":
    main()
