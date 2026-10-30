#!/usr/bin/env python3
"""A macOS App ID and its Developer ID provisioning profile, through the App Store Connect API.

nightly-next ships as its own app (com.cmuxterm.app.next) so it installs beside
classic NIGHTLY. Its entitlements (application-identifier, keychain-access-groups)
need an App ID and a Developer ID ("MAC_APP_DIRECT") profile. This registers and
fetches both with the ASC key notarization already uses, so a renewed profile
needs no secret update.

  check     report the App ID, the profile and the Developer ID certificates;
            never writes (a key without provisioning access is reported, exit 0)
  ensure    register the App ID and create the profile when missing; an
            invalid or expired profile is replaced
  download  print the active profile's content (base64), exit 1 when there is none

Capabilities that need Apple's approval, such as the WebAuthn browser
entitlement, are requested in the developer portal, not here.

usage: asc_developer_id_app.py MODE --bundle-id ID --name NAME --profile-name NAME
Auth: ASC_API_KEY_ID, ASC_API_ISSUER_ID and ASC_API_KEY_P8_BASE64 (or ASC_API_KEY_PATH).
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com"
CERT_TYPES = ("DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION")


def _asc_auth():
    # The JWT signing lives with the iOS profile fetch; reuse it.
    path = Path(__file__).resolve().parents[2] / "ios/scripts/asc_download_profile.py"
    spec = importlib.util.spec_from_file_location("asc_download_profile", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def http_client(token: str):
    def call(method: str, path: str, body: dict | None = None):
        request = urllib.request.Request(
            API_BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read() or b"{}")
            except ValueError:
                return error.code, {}
    return call


def _error(status: int, body: dict) -> str:
    code = ((body.get("errors") or [{}])[0]).get("code", "unknown")
    return f"HTTP {status} ({code})"


def _parse_date(value: str) -> dt.datetime:
    return dt.datetime.strptime(value.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z")


def lookup(asc, bundle_id: str, profile_name: str):
    """(bundle, certificates, profiles) or an error string."""
    status, body = asc("GET", "/v1/bundleIds?" + urllib.parse.urlencode(
        {"filter[identifier]": bundle_id, "filter[platform]": "MAC_OS", "limit": 200}))
    if status != 200:
        return f"{_error(status, body)}: this key cannot read Certificates, Identifiers & Profiles"
    # filter[identifier] also matches longer identifiers with the same prefix.
    bundle = next((b for b in body.get("data", []) if b["attributes"]["identifier"] == bundle_id), None)
    status, body = asc("GET", "/v1/certificates?" + urllib.parse.urlencode(
        {"filter[certificateType]": ",".join(CERT_TYPES), "limit": 200}))
    if status != 200:
        return f"{_error(status, body)}: this key cannot read certificates"
    now = dt.datetime.now(dt.timezone.utc)
    certificates = [c for c in body.get("data", []) if _parse_date(c["attributes"]["expirationDate"]) > now]
    status, body = asc("GET", "/v1/profiles?" + urllib.parse.urlencode(
        {"filter[name]": profile_name, "filter[profileType]": "MAC_APP_DIRECT", "limit": 200}))
    if status != 200:
        return f"{_error(status, body)}: this key cannot read profiles"
    profiles = [p for p in body.get("data", []) if p["attributes"]["name"] == profile_name]
    return bundle, certificates, profiles


def run(asc, mode: str, bundle_id: str, name: str, profile_name: str) -> int:
    found = lookup(asc, bundle_id, profile_name)
    if isinstance(found, str):
        print(f"App Store Connect: {found}")
        return 0 if mode == "check" else 1
    bundle, certificates, profiles = found
    active = [p for p in profiles if p["attributes"]["profileState"] == "ACTIVE"]

    if mode == "download":
        if not active:
            print(f"error: no ACTIVE profile named '{profile_name}'", file=sys.stderr)
            return 1
        sys.stdout.write(active[0]["attributes"]["profileContent"])
        return 0

    if mode == "check":
        print(f"App ID {bundle_id}: {'registered' if bundle else 'missing'}")
        states = ", ".join(p["attributes"]["profileState"] for p in profiles)
        print(f"profile '{profile_name}': {states or 'missing'}")
        print(f"Developer ID Application certificates: {len(certificates)} active")
        return 0

    if not certificates:
        print("error: no active Developer ID Application certificate", file=sys.stderr)
        return 1
    if not bundle:
        status, body = asc("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": bundle_id, "name": name, "platform": "MAC_OS"}}})
        if status != 201:
            print(f"error: registering App ID {bundle_id}: {_error(status, body)}", file=sys.stderr)
            return 1
        bundle = body["data"]
        print(f"registered App ID {bundle_id}")
    if active:
        print(f"profile '{profile_name}' is active")
        return 0
    for profile in profiles:  # INVALID or EXPIRED: the name must be free again
        status, body = asc("DELETE", f"/v1/profiles/{profile['id']}")
        if status != 204:
            print(f"error: deleting {profile['attributes']['profileState']} profile: {_error(status, body)}", file=sys.stderr)
            return 1
    status, body = asc("POST", "/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": "MAC_APP_DIRECT"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": c["id"]} for c in certificates]},
        }}})
    if status != 201:
        print(f"error: creating profile '{profile_name}': {_error(status, body)}", file=sys.stderr)
        return 1
    print(f"created profile '{profile_name}'")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["check", "ensure", "download"])
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--name", required=True, help="App ID display name")
    parser.add_argument("--profile-name", required=True)
    args = parser.parse_args(argv)
    try:
        token = _asc_auth()._token()
    except RuntimeError as error:
        print(f"App Store Connect: {error}")
        return 0 if args.mode == "check" else 1
    return run(http_client(token), args.mode, args.bundle_id, args.name, args.profile_name)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
