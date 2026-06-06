#!/usr/bin/env python3
"""Print the highest CFBundleVersion already on App Store Connect for an app.

TestFlight only offers a build as an *update* when its CFBundleVersion is the
highest integer build for the app. This helper lets the upload script enforce
that invariant directly against the live source of truth (App Store Connect),
instead of trusting whatever scheme generated the number. It mints an ES256 JWT
from the App Store Connect API key, resolves the app from its bundle id, pages
through the app's builds, and prints `max(int(version))` to stdout (0 if the app
has no builds yet).

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
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

API_BASE = "https://api.appstoreconnect.apple.com"


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _load_private_key():
    key_path = os.environ.get("ASC_API_KEY_PATH")
    if key_path:
        with open(key_path, "rb") as f:
            pem = f.read()
    elif os.environ.get("ASC_API_KEY_P8_BASE64"):
        pem = base64.b64decode(os.environ["ASC_API_KEY_P8_BASE64"])
    else:
        raise RuntimeError("set ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64")
    return serialization.load_pem_private_key(pem, password=None)


def _token():
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer_id = os.environ.get("ASC_API_ISSUER_ID")
    if not key_id or not issuer_id:
        raise RuntimeError("set ASC_API_KEY_ID and ASC_API_ISSUER_ID")
    key = _load_private_key()
    hdr = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    pld = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64u(json.dumps(hdr).encode()) + b"." + _b64u(json.dumps(pld).encode())
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return (signing_input + b"." + _b64u(sig)).decode()


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
        raise RuntimeError(f"apps lookup HTTP {status}: {json.dumps(body)[:300]}")
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
    saw_any = False
    path = f"/v1/builds?filter[app]={app_id}&fields[builds]=version&limit=200"
    pages = 0
    # Page until App Store Connect stops returning a `next` link. NEVER return a
    # partial max: a truncated read could be below the true max, which would let
    # the caller self-heal to a number still <= the real max (the exact
    # non-updatable build this guard prevents). MAX_PAGES (200 * 50 = 10,000
    # builds) is only a runaway backstop; hitting it with more pages pending is
    # an error so the caller fails open instead of trusting an incomplete result.
    MAX_PAGES = 50
    while path:
        if pages >= MAX_PAGES:
            raise RuntimeError(
                f"more than {MAX_PAGES} build pages; refusing to return a partial max"
            )
        status, body = _api(token, path)
        if status != 200:
            raise RuntimeError(f"builds lookup HTTP {status}: {json.dumps(body)[:300]}")
        for b in body.get("data", []):
            saw_any = True
            v = (b.get("attributes") or {}).get("version")
            try:
                n = int(str(v).strip())
            except (TypeError, ValueError):
                continue  # ignore non-integer historical versions
            if n > highest:
                highest = n
        nxt = (body.get("links") or {}).get("next")
        # `next` is an absolute URL; strip the base so _api can re-add it.
        path = nxt[len(API_BASE):] if nxt and nxt.startswith(API_BASE) else None
        pages += 1
    if not saw_any:
        return 0
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
