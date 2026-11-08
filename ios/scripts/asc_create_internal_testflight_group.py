#!/usr/bin/env python3
"""Create an internal TestFlight beta group via App Store Connect API.

Creates a new internal beta group for dogfooding builds and outputs the group ID.

Usage:
  ./ios/scripts/asc_create_internal_testflight_group.py --bundle-id dev.cmux.app.beta --group-name "cmux internal"

Auth comes from ASC environment:
  ASC_API_KEY_ID, ASC_API_ISSUER_ID, and either ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Dict
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com"


def _b64u(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def _der_ecdsa_to_raw(der: bytes) -> bytes:
    if not der or der[0] != 0x30:
        raise RuntimeError("malformed ECDSA signature from openssl")
    idx = 2
    if der[1] & 0x80:
        idx = 2 + (der[1] & 0x7F)
    if der[idx] != 0x02:
        raise RuntimeError("malformed ECDSA signature (r)")
    rlen = der[idx + 1]
    idx += 2
    r = int.from_bytes(der[idx:idx + rlen], "big")
    idx += rlen
    if der[idx] != 0x02:
        raise RuntimeError("malformed ECDSA signature (s)")
    slen = der[idx + 1]
    idx += 2
    s = int.from_bytes(der[idx:idx + slen], "big")
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def _sign_es256(signing_input: bytes, key_path: str) -> bytes:
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        raise RuntimeError("openssl signing failed")
    return _der_ecdsa_to_raw(proc.stdout)


def _token() -> str:
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer_id = os.environ.get("ASC_API_ISSUER_ID")
    if not key_id or not issuer_id:
        raise RuntimeError("set ASC_API_KEY_ID and ASC_API_ISSUER_ID")
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64u(json.dumps(header).encode()) + b"." + _b64u(json.dumps(payload).encode())

    key_path = os.environ.get("ASC_API_KEY_PATH")
    if key_path:
        signature = _sign_es256(signing_input, key_path)
    elif os.environ.get("ASC_API_KEY_P8_BASE64"):
        fd, tmp = tempfile.mkstemp(suffix=".p8")
        try:
            os.write(fd, base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"]))
            os.close(fd)
            signature = _sign_es256(signing_input, tmp)
        finally:
            os.unlink(tmp)
    else:
        raise RuntimeError("set ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64")
    return (signing_input + b"." + _b64u(signature)).decode()


def _asc_error_code(body: Dict) -> str:
    try:
        return str(((body.get("errors") or [{}])[0]).get("code", "unknown"))
    except Exception:
        return "unknown"


def _request(token: str, method: str, path: str, payload=None):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(API_BASE + path, method=method, data=data)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read() or b"{}"
            return resp.status, json.loads(raw)
    except urllib.error.HTTPError as err:
        try:
            body = json.loads(err.read() or b"{}")
        except Exception:
            body = {}
        return err.code, body


def _resolve_app_id(token: str, bundle_id: str) -> str:
    encoded = urllib.parse.quote(bundle_id, safe="")
    status, body = _request(
        token,
        "GET",
        f"/v1/apps?filter[bundleId]={encoded}&fields[apps]=bundleId&limit=1",
    )
    if status != 200:
        raise RuntimeError(f"apps lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        raise RuntimeError(f"no app found for bundle id {bundle_id}")
    return data[0]["id"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--group-name", required=True, help="Name for the internal beta group")
    args = parser.parse_args()

    token = _token()
    app_id = _resolve_app_id(token, args.bundle_id)

    # Create internal beta group
    payload = {
        "data": {
            "type": "betaGroups",
            "attributes": {
                "name": args.group_name,
                "isInternalGroup": True,
            },
            "relationships": {
                "app": {
                    "data": {
                        "type": "apps",
                        "id": app_id,
                    }
                }
            },
        }
    }

    status, body = _request(token, "POST", "/v1/betaGroups", payload)
    if status not in (200, 201):
        raise RuntimeError(f"create beta group HTTP {status} (code={_asc_error_code(body)})")

    group = body.get("data", {})
    group_id = group.get("id")
    if not group_id:
        raise RuntimeError("no group ID returned from App Store Connect")

    attrs = group.get("attributes", {})
    group_name = attrs.get("name", "")
    print(f"Created internal TestFlight group: {group_name}")
    print(f"Group ID: {group_id}")
    print()
    print("Add these GitHub repository variables to cmux:")
    print(f'  IOS_TESTFLIGHT_INTERNAL_GROUP_ID = {group_id}')
    print(f'  IOS_TESTFLIGHT_INTERNAL_GROUP_NAME = {group_name}')
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"asc_create_internal_testflight_group: {exc}", file=sys.stderr)
        raise SystemExit(1)
