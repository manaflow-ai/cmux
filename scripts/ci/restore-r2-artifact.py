#!/usr/bin/env python3
"""Try the authenticated R2 artifact broker; every miss leaves GitHub download enabled.

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
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

REPOSITORY = "manaflow-ai/cmux"
OIDC_AUDIENCE = "cmux-ci-artifacts"
OIDC_REQUEST_HOST_SUFFIX = ".actions.githubusercontent.com"
MAX_BYTES = 2 * 1024**3
ARCHIVES = {"app-host-products.tar.gz", "app-host-products.aar"}


def github_metadata(artifact_id: int) -> dict:
    raw = subprocess.check_output(
        ["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact_id}"],
        text=True, timeout=20,
    )
    return json.loads(raw)


def _secret_curl_config(path: Path, header: str) -> None:
    if "\n" in header or "\r" in header:
        raise ValueError("invalid secret header")
    escaped = header.replace("\\", "\\\\").replace('"', '\\"')
    path.touch(mode=0o600)
    path.chmod(0o600)
    path.write_text(f'header = "{escaped}"\n')


def actions_identity(work: Path) -> str:
    request_url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL", "")
    request_token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "")
    parsed = urlsplit(request_url)
    hostname = parsed.hostname or ""
    if (parsed.scheme != "https" or not hostname.endswith(OIDC_REQUEST_HOST_SUFFIX)
            or hostname == OIDC_REQUEST_HOST_SUFFIX[1:] or parsed.port not in (None, 443)
            or parsed.username or parsed.password or parsed.fragment or not request_token):
        raise ValueError("Actions OIDC identity unavailable")
    query = [(key, value) for key, value in parse_qsl(parsed.query, keep_blank_values=True)
             if key != "audience"]
    query.append(("audience", OIDC_AUDIENCE))
    url = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urlencode(query), ""))
    config = work / "oidc-curl.conf"
    _secret_curl_config(config, f"Authorization: Bearer {request_token}")
    raw = subprocess.check_output([
        "curl", "--fail", "--silent", "--show-error", "--proto", "=https",
        "--connect-timeout", "5", "--max-time", "10", "--config", str(config), url,
    ], text=True, timeout=15)
    if len(raw) > 32 * 1024:
        raise ValueError("Actions OIDC response too large")
    token = json.loads(raw).get("value", "")
    if not isinstance(token, str) or len(token) > 16 * 1024 or not re.fullmatch(
            r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", token):
        raise ValueError("invalid Actions OIDC identity")
    return token


def download(url: str, target: Path, size: int, identity: str, work: Path) -> dict:
    config = work / "broker-curl.conf"
    headers = work / "broker-headers"
    _secret_curl_config(config, f"Authorization: Bearer {identity}")
    result = subprocess.run([
        "curl", "--fail", "--silent", "--show-error", "--proto", "=https",
        "--connect-timeout", "5", "--max-time", "175", "--max-filesize", str(size),
        "--config", str(config), "--dump-header", str(headers),
        "--write-out", "%{http_code} %{time_starttransfer} %{time_total} %{size_download}",
        "--output", str(target), url,
    ], check=True, timeout=180, capture_output=True, text=True)
    fields = result.stdout.strip().split()
    if len(fields) != 4 or fields[0] != "200":
        raise RuntimeError("invalid broker transfer receipt")
    cache = ""
    for line in headers.read_text(errors="replace").splitlines():
        name, separator, value = line.partition(":")
        if separator and name.strip().casefold() == "x-cmux-artifact-cache":
            cache = value.strip().casefold()
    if cache not in {"fill", "hit"}:
        raise RuntimeError("broker omitted cache result")
    first_byte = float(fields[1])
    total = float(fields[2])
    downloaded = int(float(fields[3]))
    if first_byte < 0 or total < first_byte or downloaded < 0:
        raise RuntimeError("invalid broker timing receipt")
    return {
        "cache": cache,
        "broker_wait_seconds": round(first_byte, 3),
        "transfer_seconds": round(total - first_byte, 3),
        "broker_total_seconds": round(total, 3),
        "downloaded_bytes": downloaded,
    }


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
            metadata=github_metadata, fetch=download, identity=actions_identity,
            receipt: dict | None = None, expected_provider_digest: str = "") -> bool:
    record = receipt if receipt is not None else {}
    started = time.monotonic()
    record.update({
        "artifact_id": artifact_id,
        "run_id": run_id,
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "job": os.environ.get("GITHUB_JOB"),
        "shard": os.environ.get("CMUX_APP_HOST_SHARD"),
        "runner_name": os.environ.get("RUNNER_NAME"),
        "runner_os": os.environ.get("RUNNER_OS"),
        "transport": "github",
        "r2_result": "disabled" if not broker else "miss",
    })
    if not broker:
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        return False
    try:
        parsed = urlsplit(broker)
        if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
                or parsed.query or parsed.fragment or parsed.path not in ("", "/")
                or repository != REPOSITORY or not artifact_id.isdecimal() or not run_id.isdecimal()):
            raise ValueError("invalid broker configuration")

        metadata_started = time.monotonic()
        info = metadata(int(artifact_id))
        record["metadata_seconds"] = round(time.monotonic() - metadata_started, 3)
        digest = info.get("digest", "")
        size = info.get("size_in_bytes")
        producer = info.get("workflow_run", {})
        expected = expected_provider_digest.removeprefix("sha256:").lower()
        if (info.get("id") != int(artifact_id) or info.get("expired") is not False
                or not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest)
                or (expected and (not re.fullmatch(r"[a-f0-9]{64}", expected)
                                  or digest != "sha256:" + expected))
                or not isinstance(size, int) or not 0 < size <= MAX_BYTES
                or not isinstance(producer, dict) or producer.get("id") != int(run_id)):
            raise ValueError("artifact does not match this producer run")

        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="cmux-r2-artifact-", dir=destination.parent) as work:
            staging = Path(work)
            zip_path = staging / "artifact.zip"
            oidc = identity(staging)
            url = f"{broker.rstrip('/')}/v1/{REPOSITORY}/artifacts/{artifact_id}/{digest[7:]}.zip"
            transfer = fetch(url, zip_path, size, oidc, staging)
            if not isinstance(transfer, dict):
                transfer = {}
            record.update(transfer)
            outer_started = time.monotonic()
            unpack(zip_path, staging / "products", digest[7:], size)
            record["outer_restore_seconds"] = round(time.monotonic() - outer_started, 3)
            if destination.exists():
                destination.rmdir()  # Never merge a hit into stale/partial products.
            (staging / "products").rename(destination)

        record["transport"] = "r2"
        record["r2_result"] = str(record.get("cache", "hit"))
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        print("CMUX_TEST_PRODUCT_TRANSFER " + json.dumps(record, sort_keys=True))
        print(f"R2 artifact transport restored GitHub artifact {artifact_id}; product validation still runs.")
        return True
    except (ValueError, TypeError, AttributeError, OSError, subprocess.SubprocessError,
            zipfile.BadZipFile, RuntimeError) as error:
        record["fallback_reason"] = type(error).__name__
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        print("CMUX_R2_ARTIFACT_ATTEMPT " + json.dumps(record, sort_keys=True))
        print(f"R2 artifact transport miss ({type(error).__name__}); using GitHub.")
        return False


def main() -> None:
    output = Path(os.environ["GITHUB_OUTPUT"])
    receipt: dict = {}
    hit = restore(
        os.environ.get("CI_ARTIFACT_R2_URL", ""), os.environ.get("ARTIFACT_ID", ""),
        os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GITHUB_REPOSITORY", ""),
        Path(os.environ["RUNNER_TEMP"]) / "app-host-products", receipt=receipt,
        expected_provider_digest=os.environ.get("ARTIFACT_PROVIDER_DIGEST", ""),
    )
    values = {
        "hit": str(hit).lower(),
        "route": "r2" if hit else "github",
        "r2_result": str(receipt.get("r2_result", "miss")),
        "cache": str(receipt.get("cache", "")),
        "downloaded_bytes": str(receipt.get("downloaded_bytes", "")),
        "broker_wait_seconds": str(receipt.get("broker_wait_seconds", "")),
        "transfer_seconds": str(receipt.get("transfer_seconds", "")),
        "outer_restore_seconds": str(receipt.get("outer_restore_seconds", "")),
    }
    with output.open("a") as handle:
        for key, value in values.items():
            if "\n" in value or "\r" in value:
                raise ValueError("invalid GitHub output")
            handle.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
