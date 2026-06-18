#!/usr/bin/env python3
"""Set a TestFlight build's "What to Test" notes via the App Store Connect API.

Testers see this text in TestFlight on install and on auto-update. Without it a
build is an opaque `MARKETING_VERSION (timestamp)` with no explanation of what
changed; this script fills that in from ios/CHANGELOG.md (see set-testflight-notes.sh).

It resolves the app from its bundle id, finds the build by CFBundleVersion
(the 14-digit upload timestamp), then creates or updates the build's en-US
`betaBuildLocalizations.whatsNew`. A just-uploaded build is not addressable until
App Store Connect finishes ingesting it, so the build lookup polls/retries.

Dependency-free on purpose (same constraint as asc_max_build.py): the only third
party is `openssl` (preinstalled on macOS), invoked via subprocess for the ES256
JWT signature. The TestFlight credential must not pull unverified pip packages.

Auth comes from the environment (the same vars the upload script already sets):
  ASC_API_KEY_ID, ASC_API_ISSUER_ID, and either ASC_API_KEY_PATH (a .p8 file) or
  ASC_API_KEY_P8_BASE64 (the base64-encoded .p8 contents).

Usage:
  asc_set_testflight_notes.py --bundle-id dev.cmux.app.beta \
      --build-number 20260613120501 --notes-file /tmp/notes.txt \
      [--locale en-US] [--timeout-seconds 900] [--poll-seconds 20]

Exit codes:
  0  notes set (created or updated).
  3  build not found within the timeout (App Store Connect still processing).
  1  any other error (auth, network, API shape).

The caller decides how fatal a non-zero exit is. The upload script treats a
failure here as a WARNING, not an upload failure: the binary is already on
TestFlight and the notes can be re-applied later with set-testflight-notes.sh.
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

# App Store Connect caps What to Test at 4000 characters. Truncate defensively so
# a long changelog block never makes the PATCH/POST fail with a validation error.
MAX_WHATS_NEW = 4000


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _der_ecdsa_to_raw(der):
    """Convert a DER-encoded ECDSA signature (openssl) to JOSE raw r||s (64 bytes)."""
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


def _sign_es256(signing_input, key_path):
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
    try:
        return str(((body.get("errors") or [{}])[0]).get("code", "unknown"))
    except Exception:
        return "unknown"


def _request(token, method, path, payload=None):
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
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read() or b"{}")
        except Exception:
            body = {}
        return e.code, body


def _resolve_app_id(token, bundle_id):
    status, body = _request(
        token,
        "GET",
        f"/v1/apps?filter[bundleId]={bundle_id}&fields[apps]=bundleId&limit=1",
    )
    if status != 200:
        raise RuntimeError(f"apps lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        raise RuntimeError(f"no app found for bundle id {bundle_id}")
    return data[0]["id"]


def _find_build(token, app_id, build_number):
    """Return the build id whose version == build_number, or None if not present yet.

    Uses the version filter so a single request resolves the build without paging
    the whole list. App Store Connect's version is the CFBundleVersion string.
    """
    status, body = _request(
        token,
        "GET",
        f"/v1/builds?filter[app]={app_id}"
        f"&filter[version]={build_number}"
        f"&fields[builds]=version,processingState&limit=1",
    )
    if status != 200:
        raise RuntimeError(f"builds lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        return None
    return data[0]["id"]


def _existing_localization(token, build_id, locale):
    """Return (localization_id or None) for the given locale on the build."""
    status, body = _request(
        token,
        "GET",
        f"/v1/builds/{build_id}/betaBuildLocalizations"
        f"?fields[betaBuildLocalizations]=locale&limit=50",
    )
    if status != 200:
        raise RuntimeError(
            f"betaBuildLocalizations lookup HTTP {status} (code={_asc_error_code(body)})"
        )
    for item in body.get("data", []):
        if (item.get("attributes") or {}).get("locale") == locale:
            return item["id"]
    return None


def _set_notes(token, build_id, locale, whats_new):
    loc_id = _existing_localization(token, build_id, locale)
    if loc_id:
        payload = {
            "data": {
                "type": "betaBuildLocalizations",
                "id": loc_id,
                "attributes": {"whatsNew": whats_new},
            }
        }
        status, body = _request(
            token, "PATCH", f"/v1/betaBuildLocalizations/{loc_id}", payload
        )
        action = "updated"
    else:
        payload = {
            "data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": locale, "whatsNew": whats_new},
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}}
                },
            }
        }
        status, body = _request(token, "POST", "/v1/betaBuildLocalizations", payload)
        action = "created"
    if status not in (200, 201):
        raise RuntimeError(
            f"set notes HTTP {status} (code={_asc_error_code(body)}) while {action[:-1]}ing localization"
        )
    return action


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True, help="CFBundleVersion of the uploaded build")
    parser.add_argument("--notes-file", required=True, help="file containing the What to Test text")
    parser.add_argument("--locale", default="en-US")
    parser.add_argument("--timeout-seconds", type=int, default=900,
                        help="how long to wait for App Store Connect to ingest the build")
    parser.add_argument("--poll-seconds", type=int, default=20)
    args = parser.parse_args()

    with open(args.notes_file, "r", encoding="utf-8") as f:
        whats_new = f.read().strip()
    if not whats_new:
        raise RuntimeError(f"notes file is empty: {args.notes_file}")
    if len(whats_new) > MAX_WHATS_NEW:
        whats_new = whats_new[:MAX_WHATS_NEW - 1].rstrip() + "…"

    token = _token()
    app_id = _resolve_app_id(token, args.bundle_id)

    deadline = time.time() + max(0, args.timeout_seconds)
    build_id = None
    while True:
        # Re-mint the token each loop in case the wait outlives the 600s expiry.
        token = _token()
        build_id = _find_build(token, app_id, args.build_number)
        if build_id:
            break
        if time.time() >= deadline:
            print(
                f"asc_set_testflight_notes: build {args.build_number} not visible on "
                f"App Store Connect within {args.timeout_seconds}s; notes not set",
                file=sys.stderr,
            )
            sys.exit(3)
        print(
            f"asc_set_testflight_notes: build {args.build_number} not processed yet; "
            f"retrying in {args.poll_seconds}s",
            file=sys.stderr,
        )
        time.sleep(max(1, args.poll_seconds))

    action = _set_notes(token, build_id, args.locale, whats_new)
    print(f"asc_set_testflight_notes: {action} {args.locale} What to Test for build {args.build_number}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        print(f"asc_set_testflight_notes: {exc}", file=sys.stderr)
        sys.exit(1)
