#!/usr/bin/env python3
"""Poll one saved Apple notarization submission without a macOS runner."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


API_BASE = "https://appstoreconnect.apple.com"
SUBMISSION_ID = re.compile(r"[A-Za-z0-9._-]+\Z")


def _b64u(value: bytes) -> bytes:
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def _der_ecdsa_to_raw(der: bytes) -> bytes:
    if not der or der[0] != 0x30:
        raise RuntimeError("malformed ECDSA signature from openssl")
    index = 2
    if der[1] & 0x80:
        index = 2 + (der[1] & 0x7F)
    if der[index] != 0x02:
        raise RuntimeError("malformed ECDSA signature (r)")
    r_length = der[index + 1]
    index += 2
    r = int.from_bytes(der[index:index + r_length], "big")
    index += r_length
    if der[index] != 0x02:
        raise RuntimeError("malformed ECDSA signature (s)")
    s_length = der[index + 1]
    index += 2
    s = int.from_bytes(der[index:index + s_length], "big")
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _sign_es256(signing_input: bytes, key_path: str) -> bytes:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise RuntimeError("openssl signing failed")
    return _der_ecdsa_to_raw(result.stdout)


def _token() -> str:
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer_id = os.environ.get("ASC_API_ISSUER_ID")
    encoded_key = os.environ.get("ASC_API_KEY_P8_BASE64")
    if not key_id or not issuer_id or not encoded_key:
        raise RuntimeError(
            "set ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_P8_BASE64"
        )
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64u(json.dumps(header, separators=(",", ":")).encode()) + b"." + _b64u(
        json.dumps(payload, separators=(",", ":")).encode()
    )
    fd, key_path = tempfile.mkstemp(suffix=".p8")
    try:
        os.write(fd, base64.b64decode(encoded_key))
        os.close(fd)
        os.chmod(key_path, 0o600)
        signature = _sign_es256(signing_input, key_path)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        Path(key_path).unlink(missing_ok=True)
    return (signing_input + b"." + _b64u(signature)).decode()


def _api(token: str, submission_id: str) -> tuple[int, dict]:
    base = API_BASE
    request = urllib.request.Request(
        f"{base}/notary/v2/submissions/{submission_id}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read() or b"{}")
        except json.JSONDecodeError:
            body = {}
        return error.code, body


def _state_value(path: Path, wanted: str) -> str:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or key in values:
            raise ValueError(f"invalid or duplicate notarization state line: {line!r}")
        values[key] = value
    return values.get(wanted, "")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    submission_id = _state_value(args.state_file, "submission_id")
    if not SUBMISSION_ID.fullmatch(submission_id):
        raise ValueError("invalid Apple submission id in state")
    status_code, body = _api(_token(), submission_id)
    data = body.get("data") if isinstance(body, dict) else None
    if not isinstance(data, dict) or str(data.get("id", "")) != submission_id:
        status = ""
    else:
        attributes = data.get("attributes")
        status = str(attributes.get("status", "")) if isinstance(attributes, dict) else ""
    output = args.output or Path(f"{args.state_file}.api.log")
    output.write_text(
        json.dumps({"submission_id": submission_id, "http_status": status_code, "status": status, "body": body}, indent=2)
        + "\n",
        encoding="utf-8",
    )
    if status_code != 200 or not status:
        print(f"notarization status query failed for {submission_id} (HTTP {status_code})", file=sys.stderr)
        return 1
    print(f"status={status}")
    if status == "Accepted":
        return 0
    if status in {"In Progress", "InProgress", "Submitted", "Waiting for Upload"}:
        return 2
    print(f"Apple reported terminal notarization status: {status}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
