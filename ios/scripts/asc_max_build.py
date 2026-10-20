#!/usr/bin/env python3
"""Print the highest CFBundleVersion already on App Store Connect for an app.

TestFlight only offers a build as an *update* when its CFBundleVersion is the
highest integer build for the app. This helper lets the upload script enforce
that invariant directly against the live source of truth (App Store Connect),
instead of trusting whatever scheme generated the number. It mints an ES256 JWT
from the App Store Connect API key, resolves the app from its bundle id, pages
through the app's builds, and prints `max(int(version))` to stdout (0 if the app
has no builds yet).

Dependency-free on purpose: the only third party is `openssl` (preinstalled on
macOS), invoked via subprocess for the ECDSA signature. The TestFlight upload job
holds the signing/upload credential, so it must not `pip install` unverified code
that could persist in site-packages and run once the key is on disk.

Auth comes from the environment (the same vars the upload workflow already sets):
  ASC_API_KEY_ID, ASC_API_ISSUER_ID, and either ASC_API_KEY_PATH (a .p8 file) or
  ASC_API_KEY_P8_BASE64 (the base64-encoded .p8 contents).

Usage:
  asc_max_build.py --bundle-id dev.cmux.app.beta

On success: prints a single integer to stdout and exits 0.
On any error (missing creds, network, JWT, API shape, no matching app): prints a
diagnostic to stderr and exits non-zero. Callers MUST treat a non-zero exit as
"could not determine" and fall back to their own build number (fail-open), so a
transient App Store Connect hiccup never blocks a publish.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com"


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _der_ecdsa_to_raw(der):
    """Convert a DER-encoded ECDSA signature (openssl output) to JOSE raw r||s.

    A P-256 signature is `SEQUENCE { INTEGER r, INTEGER s }` with short-form
    lengths, so two fixed-width 32-byte integers concatenated give the 64-byte
    raw form ES256 (RFC 7518) requires.
    """
    if not der or der[0] != 0x30:
        raise RuntimeError("malformed ECDSA signature from openssl")
    idx = 2
    if der[1] & 0x80:  # long-form SEQUENCE length (not expected for P-256)
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


def _sign_es256(signing_input, key_path):
    """ES256-sign `signing_input` with the .p8 at `key_path` using openssl."""
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        raise RuntimeError("openssl signing failed")
    return _der_ecdsa_to_raw(proc.stdout)


def _token():
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer_id = os.environ.get("ASC_API_ISSUER_ID")
    if not key_id or not issuer_id:
        raise RuntimeError("set ASC_API_KEY_ID and ASC_API_ISSUER_ID")
    hdr = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    pld = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64u(json.dumps(hdr).encode()) + b"." + _b64u(json.dumps(pld).encode())

    key_path = os.environ.get("ASC_API_KEY_PATH")
    if key_path:
        sig = _sign_es256(signing_input, key_path)
    elif os.environ.get("ASC_API_KEY_P8_BASE64"):
        # Materialize the key to a 0600 temp file only for the openssl call.
        fd, tmp = tempfile.mkstemp(suffix=".p8")
        try:
            os.write(fd, base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"]))
            os.close(fd)
            sig = _sign_es256(signing_input, tmp)
        finally:
            os.unlink(tmp)
    else:
        raise RuntimeError("set ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64")
    return (signing_input + b"." + _b64u(sig)).decode()


def _asc_error_code(body):
    """Extract the App Store Connect error code, never the raw payload.

    Error responses can echo request/response detail; surfacing only the status
    and this scalar code keeps upstream content out of CI logs.
    """
    try:
        return str(((body.get("errors") or [{}])[0]).get("code", "unknown"))
    except Exception:
        return "unknown"


def _api(token, path):
    req = urllib.request.Request(API_BASE + path, method="GET")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def _resolve_app_id(token, bundle_id):
    status, body = _api(
        token, f"/v1/apps?filter[bundleId]={bundle_id}&fields[apps]=bundleId&limit=1"
    )
    if status != 200:
        raise RuntimeError(f"apps lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        raise RuntimeError(f"no app found for bundle id {bundle_id}")
    return data[0]["id"]


def _max_build(token, app_id):
    """Page through the app's builds and return the max integer version (0 if none).

    ASC `sort=-version` is a STRING sort, so it cannot be trusted across builds
    with different digit counts (the exact bug this guard exists to prevent).
    Fetch pages and compute the max as an integer instead.
    """
    highest = 0
    path = f"/v1/builds?filter[app]={app_id}&fields[builds]=version&limit=200"
    pages = 0
    # Page until App Store Connect stops returning a `next` link. NEVER return a
    # partial max: a truncated read could be below the true max, which would let
    # the caller self-heal to a number still <= the real max (the exact
    # non-updatable build this guard prevents). So every way pagination could end
    # early (page cap, or a `next` URL we can't follow) RAISES instead of
    # returning what was seen so far; the caller then fails open. MAX_PAGES
    # (200 * 50 = 10,000 builds) is only a runaway backstop. `highest` is 0 when
    # the app has no integer builds, which is the correct "no floor" sentinel.
    MAX_PAGES = 50
    while path:
        if pages >= MAX_PAGES:
            raise RuntimeError(
                f"more than {MAX_PAGES} build pages; refusing to return a partial max"
            )
        status, body = _api(token, path)
        if status != 200:
            raise RuntimeError(f"builds lookup HTTP {status} (code={_asc_error_code(body)})")
        for b in body.get("data", []):
            v = (b.get("attributes") or {}).get("version")
            try:
                n = int(str(v).strip())
            except (TypeError, ValueError):
                continue  # ignore non-integer historical versions
            highest = max(highest, n)
        nxt = (body.get("links") or {}).get("next")
        if not nxt:
            path = None
        elif nxt.startswith(API_BASE):
            path = nxt[len(API_BASE):]  # `next` is absolute; _api re-adds the base
        else:
            raise RuntimeError("unexpected App Store Connect pagination URL; refusing to return a partial max")
        pages += 1
    return highest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True, help="app bundle identifier")
    args = parser.parse_args()
    token = _token()
    app_id = _resolve_app_id(token, args.bundle_id)
    print(_max_build(token, app_id))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # fail-open: caller falls back on any error
        print(f"asc_max_build: {exc}", file=sys.stderr)
        sys.exit(1)
