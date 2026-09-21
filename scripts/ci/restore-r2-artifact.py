#!/usr/bin/env python3
"""Try the immutable R2 artifact broker; every miss leaves GitHub download enabled.

Only the outer GitHub ZIP transport changes. The existing restore step still
validates the producer archive hash, product receipts, and warning log.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

import app_host_consumer_receipt as consumer_receipt

REPOSITORY = "manaflow-ai/cmux"
MAX_BYTES = 2 * 1024**3
ARCHIVES = {"app-host-products.tar.gz", "app-host-products.aar"}


def github_metadata(artifact_id: int) -> dict:
    raw = subprocess.check_output(
        ["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact_id}"],
        text=True, timeout=20,
    )
    return json.loads(raw)


def download(url: str, target: Path, size: int) -> None:
    # No credentials are sent to the broker. Its own Actions-read token stays
    # server-side, and the PR has no R2 write credentials.
    subprocess.run([
        "curl", "--fail", "--silent", "--show-error", "--proto", "=https",
        "--connect-timeout", "5", "--max-time", "175", "--max-filesize", str(size),
        "--output", str(target), url,
    ], check=True, timeout=180)


def unpack(archive: Path, destination: Path, digest: str, size: int) -> None:
    if archive.stat().st_size != size or size > MAX_BYTES:
        raise ValueError("artifact size mismatch")
    h = hashlib.sha256()
    with archive.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    if h.hexdigest() != digest:
        raise ValueError("artifact digest mismatch")
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) != 1 or entries[0].filename not in ARCHIVES:
            raise ValueError("unexpected artifact contents")
        entry = entries[0]
        mode = entry.external_attr >> 16
        if (entry.is_dir() or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                or entry.flag_bits & 1 or not 0 < entry.file_size <= MAX_BYTES):
            raise ValueError("invalid archive entry")
        destination.mkdir()
        with zipped.open(entry) as source, (destination / entry.filename).open("wb") as target:
            copied = 0
            while chunk := source.read(1024 * 1024):
                copied += len(chunk)
                if copied > entry.file_size:
                    raise ValueError("archive expansion exceeded declared size")
                target.write(chunk)
            if copied != entry.file_size:
                raise ValueError("truncated archive")


def restore(broker: str, artifact_id: str, run_id: str, repository: str, destination: Path,
            metadata=github_metadata, fetch=download) -> bool:
    if not broker:
        consumer_receipt.append_fallback("r2:disabled")
        return False
    try:
        parsed = urlsplit(broker)
        if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
                or parsed.query or parsed.fragment or parsed.path not in ("", "/")
                or repository != REPOSITORY or not artifact_id.isdecimal() or not run_id.isdecimal()):
            raise ValueError("invalid broker configuration")
        info = metadata(int(artifact_id))
        digest = info.get("digest", "")
        size = info.get("size_in_bytes")
        producer = info.get("workflow_run", {})
        if (info.get("id") != int(artifact_id) or info.get("expired") is not False
                or not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest)
                or not isinstance(size, int) or not 0 < size <= MAX_BYTES
                or not isinstance(producer, dict) or producer.get("id") != int(run_id)):
            raise ValueError("artifact does not match this producer run")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="cmux-r2-artifact-", dir=destination.parent) as work:
            staging = Path(work)
            zip_path = staging / "artifact.zip"
            url = f"{broker.rstrip('/')}/v1/{REPOSITORY}/artifacts/{artifact_id}/{digest[7:]}.zip"
            transfer_started = time.monotonic()
            try:
                fetch(url, zip_path, size)
            finally:
                elapsed = round(time.monotonic() - transfer_started, 3)
                consumer_receipt.add_transfer(
                    "r2-aggregate", size,
                    zip_path.stat().st_size if zip_path.exists() else 0, elapsed)
            unpack(zip_path, staging / "products", digest[7:], size)
            if destination.exists():
                destination.rmdir()  # Never merge a hit into stale/partial products.
            (staging / "products").rename(destination)
        consumer_receipt.aggregate_hit("r2-aggregate")
        print(f"R2 artifact transport restored GitHub artifact {artifact_id}; product validation still runs.")
        return True
    except (ValueError, TypeError, AttributeError, OSError, subprocess.SubprocessError, zipfile.BadZipFile, RuntimeError) as error:
        consumer_receipt.append_fallback(f"r2:{type(error).__name__}:{error}")
        print(f"R2 artifact transport miss ({type(error).__name__}: {error}); using GitHub.")
        return False


def main() -> None:
    output = Path(os.environ["GITHUB_OUTPUT"])
    with output.open("a") as handle:
        handle.write("hit=false\n")
    hit = restore(
        os.environ.get("CI_ARTIFACT_R2_URL", ""), os.environ.get("ARTIFACT_ID", ""),
        os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GITHUB_REPOSITORY", ""),
        Path(os.environ["RUNNER_TEMP"]) / "app-host-products",
    )
    if hit:
        with output.open("a") as handle:
            handle.write("hit=true\n")


if __name__ == "__main__":
    main()
