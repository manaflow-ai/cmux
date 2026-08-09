#!/usr/bin/env python3
"""Print a provisioning profile's content (base64) fetched from App Store Connect by name.

Lets CI install a profile without storing it as a repository secret: the profile
is fetched at build time with the same ASC API credentials the upload already
uses, so regenerating the profile in the developer portal needs no secret update.

Usage:
  ./ios/scripts/asc_download_profile.py --name "cmux Demo Distribution Push"

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
        detail = proc.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"openssl signing failed: {detail or 'no stderr output'}")
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
            try:
                os.write(fd, base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"]))
            finally:
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


def _request(token: str, method: str, path: str):
    req = urllib.request.Request(API_BASE + path, method=method)
    req.add_header("Authorization", "Bearer " + token)
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="Exact provisioning profile name")
    args = parser.parse_args()

    token = _token()
    encoded = urllib.parse.quote(args.name, safe="")
    status, body = _request(
        token,
        "GET",
        f"/v1/profiles?filter[name]={encoded}"
        "&fields[profiles]=name,profileState,profileContent&limit=2",
    )
    if status != 200:
        print(f"error: profiles lookup HTTP {status} (code={_asc_error_code(body)})", file=sys.stderr)
        return 1
    profiles = [
        p for p in body.get("data", [])
        if p.get("attributes", {}).get("name") == args.name
    ]
    if not profiles:
        print(f"error: no provisioning profile named '{args.name}'", file=sys.stderr)
        return 1
    active = [p for p in profiles if p["attributes"].get("profileState") == "ACTIVE"]
    if not active:
        print(f"error: profile '{args.name}' exists but none are ACTIVE", file=sys.stderr)
        return 1
    content = active[0]["attributes"].get("profileContent")
    if not content:
        print(f"error: profile '{args.name}' has no profileContent", file=sys.stderr)
        return 1
    sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
