#!/usr/bin/env python3
"""One cold fill and one warm read; no deployment, retries, or CI setting writes."""
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


def verify(origin, phase, receipt, work):
    blob, headers = work / "artifact.zip", work / "headers"
    token = (Path(os.environ["RUNNER_TEMP"]) / TOKEN_FILE).read_text().strip()
    if not re.fullmatch(r"[a-f0-9]{64}", token):
        raise ValueError("missing valid per-run canary access token")
    config = work / "curl-secret-config"
    config.touch(mode=0o600)
    config.write_text(f'header = "X-Cmux-Canary-Token: {token}"\n')
    start = time.monotonic()
    result = subprocess.run([
        "curl", "--config", str(config), "--silent", "--show-error", "--fail", "--proto", "=https",
        "--connect-timeout", "5", "--max-time", "175", "--max-filesize", str(SIZE),
        "--dump-header", str(headers), "--output", str(blob),
        "--write-out", "%{http_code} %{time_starttransfer} %{time_total} %{size_download}",
        origin + PATH,
    ], capture_output=True, text=True, timeout=180)
    row = {"phase": phase, "curl_exit": result.returncode,
           "wall_seconds": round(time.monotonic() - start, 3), "curl_metrics": result.stdout.strip()}
    receipt["requests"].append(row)
    if result.returncode:
        raise RuntimeError("broker request failed; stop, retain default GitHub fallback")
    parsed = dict(line.split(":", 1) for line in headers.read_text().splitlines() if ":" in line)
    parsed = {key.strip().lower(): value.strip() for key, value in parsed.items()}
    row["cache"] = parsed.get("x-cmux-artifact-cache")
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
    if row["cache"] != expected:
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
        receipt["metadata"] = metadata()
        with tempfile.TemporaryDirectory(prefix="r2-canary-") as temporary:
            for phase in ("cold", "warm"):
                verify(options.origin, phase, receipt, Path(temporary))
        receipt["passed"] = True
    except Exception as error:
        receipt["error_type"] = type(error).__name__
        # No raw subprocess stderr, signed URLs or credentials enter the receipt.
    finally:
        options.receipt.parent.mkdir(parents=True, exist_ok=True)
        options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    raise SystemExit(0 if receipt["passed"] else 1)


if __name__ == "__main__":
    main()
