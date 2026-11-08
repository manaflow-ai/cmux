#!/usr/bin/env python3
"""Bounded readiness, then one cold fill and warm read; never retry artifacts."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ARTIFACT = 10610975375
SIZE = 606055512
DIGEST = "08f56e901618eff4aacdffbd3046d9e9732b638004cba1d69ad44f447199608f"
TOKEN_FILE = "cmux-r2-canary-access-token"
READINESS_PATH = "/__cmux_artifact_canary_ready"
PATH = f"/v1/manaflow-ai/cmux/artifacts/{ARTIFACT}/{DIGEST}.zip"


def metadata():
    value = json.loads(subprocess.check_output([
        "gh", "api", f"repos/manaflow-ai/cmux/actions/artifacts/{ARTIFACT}"
    ], text=True, timeout=20))
    expiry = dt.datetime.fromisoformat(value["expires_at"].replace("Z", "+00:00"))
    if (value.get("id") != ARTIFACT or value.get("size_in_bytes") != SIZE
            or value.get("digest") != f"sha256:{DIGEST}" or value.get("expired") is not False
            or expiry <= dt.datetime.now(dt.timezone.utc)
            or value.get("workflow_run", {}).get("id") != 35527292634):
        raise ValueError("allowlisted artifact expired or identity changed")
    return {key: value[key] for key in ("id", "size_in_bytes", "digest", "expires_at", "expired")}


def safe_headers(path):
    if not path.exists():
        return {}
    with path.open("rb") as source:
        text = source.read(16384).decode("utf-8", errors="replace")
    values = {}
    for line in text.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            values[key.strip().lower()] = value.strip()
    safe = {}
    marker = values.get("x-cmux-canary-stage")
    if marker in {"gate-rejected", "ready-v1", "artifact-v1"}:
        safe["canary_stage"] = marker
    cache = values.get("x-cmux-artifact-cache")
    if cache in {"hit", "fill"}:
        safe["cache"] = cache
    if values.get("server", "").lower() == "cloudflare":
        safe["server"] = "cloudflare"
    ray = values.get("cf-ray", "")
    if re.fullmatch(r"[a-fA-F0-9]{16}-[A-Za-z]{3}", ray):
        safe["cf_ray"] = ray
    return safe


def request(origin, path, phase, receipt, work, limit, max_bytes):
    blob, headers = work / "artifact.zip", work / "headers"
    token = (Path(os.environ["RUNNER_TEMP"]) / TOKEN_FILE).read_text().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", token):
        raise ValueError("missing valid per-run canary access token")
    config = work / "curl-secret-config"
    config.touch(mode=0o600)
    config.write_text(f'header = "X-Cmux-Canary-Token: {token}"\n')
    # A failed connection must not inherit the preceding probe's headers/body.
    headers.unlink(missing_ok=True)
    blob.unlink(missing_ok=True)
    start = time.monotonic()
    row = {"phase": phase, "curl_exit": None, "http_status": None}
    receipt["requests"].append(row)
    try:
        result = subprocess.run([
            "curl", "--config", str(config), "--silent", "--show-error", "--fail", "--proto", "=https",
            "--connect-timeout", "5", "--max-time", str(limit), "--max-filesize", str(max_bytes),
            "--dump-header", str(headers), "--output", str(blob),
            "--write-out", "%{http_code} %{time_starttransfer} %{time_total} %{size_download}",
            origin + path,
        ], capture_output=True, text=True, timeout=limit if phase == "readiness" else limit + 5)
        row["curl_exit"] = result.returncode
        metrics = result.stdout.strip()
        if len(metrics) < 128 and re.fullmatch(r"[0-9]{3} [0-9.]+ [0-9.]+ [0-9.]+", metrics):
            status, first_byte, total, size = metrics.split()
            try:
                row.update(http_status=int(status), first_byte_seconds=float(first_byte),
                           transfer_seconds=float(total), downloaded_bytes=int(float(size)))
            except ValueError:
                pass
    except subprocess.TimeoutExpired:
        row["request_error"] = "process-timeout"
    finally:
        row["wall_seconds"] = round(time.monotonic() - start, 3)
        row.update(safe_headers(headers))
    return row


def wait_for_readiness(origin, receipt, work):
    receipt["stage"] = "readiness"
    start = time.monotonic()
    deadline = start + 60
    receipt["readiness_passed"] = False
    try:
        for attempt in range(6):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            row = request(origin, READINESS_PATH, "readiness", receipt, work, min(5, remaining), 4096)
            if row.get("canary_stage") == "gate-rejected":
                raise RuntimeError("canary authorization gate rejected readiness")
            if (row["curl_exit"] == 0 and row["http_status"] == 204
                    and row.get("canary_stage") == "ready-v1"):
                receipt["readiness_passed"] = True
                return
            # Only readiness is retried; completion-to-next-probe gap is >=10s.
            if attempt == 5 or deadline - time.monotonic() <= 10:
                break
            time.sleep(10)
        raise RuntimeError("canary readiness deadline or probe budget exhausted")
    finally:
        receipt["readiness_seconds"] = round(time.monotonic() - start, 3)


def verify(origin, phase, receipt, work):
    receipt["stage"] = phase
    row = request(origin, PATH, phase, receipt, work, 175, SIZE)
    if row["curl_exit"] != 0 or row["http_status"] != 200:
        raise RuntimeError("broker request failed; stop, retain default GitHub fallback")
    blob = work / "artifact.zip"
    start = time.monotonic()
    digest = hashlib.sha256()
    with blob.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    row.update(hash_seconds=round(time.monotonic() - start, 3), size=blob.stat().st_size,
               sha256=digest.hexdigest())
    if row["size"] != SIZE or row["sha256"] != DIGEST:
        raise ValueError("downloaded bytes do not match independent GitHub identity")
    expected = "fill" if phase == "cold" else "hit"
    if row.get("cache") != expected:
        raise ValueError(f"expected {expected}; cannot label this request {phase}")
    blob.unlink()


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--origin", required=True)
    args.add_argument("--receipt", required=True, type=Path)
    options = args.parse_args()
    if not re.fullmatch(r"https://cmux-ci-artifacts-canary-[1-9][0-9]{0,19}-[1-9][0-9]{0,3}\.[a-z0-9-]+\.workers\.dev", options.origin):
        raise SystemExit("expected the isolated canary workers.dev HTTPS origin")
    receipt = {"artifact_id": ARTIFACT, "origin": options.origin, "requests": [],
               "runner_os": os.environ.get("RUNNER_OS", "local-unknown"),
               "runner_environment": os.environ.get("RUNNER_ENVIRONMENT", "local-unknown"),
               "run_id": os.environ.get("GITHUB_RUN_ID"), "source_sha": os.environ.get("GITHUB_SHA"),
               "started_at": dt.datetime.now(dt.timezone.utc).isoformat(), "passed": False,
               "scope": "ZIP transport/hash only; no outer extraction, inner product validation or test reuse"}
    try:
        receipt["stage"] = "metadata"
        receipt["metadata"] = metadata()
        with tempfile.TemporaryDirectory(prefix="r2-canary-") as temporary:
            wait_for_readiness(options.origin, receipt, Path(temporary))
            for phase in ("cold", "warm"):
                verify(options.origin, phase, receipt, Path(temporary))
        receipt["passed"] = True
    except Exception as error:
        receipt["error_type"] = type(error).__name__
        receipt["error_stage"] = receipt.get("stage", "setup")
        # No raw subprocess stderr, signed URLs or credentials enter the receipt.
    finally:
        options.receipt.parent.mkdir(parents=True, exist_ok=True)
        options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    raise SystemExit(0 if receipt["passed"] else 1)


if __name__ == "__main__":
    main()
