#!/usr/bin/env python3
"""App Store Connect operations agents can run without a person: ios-asc-ops.yml runs this with the ASC API key.

The key (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64) lives only in the `release` environment, which
deploys from main, `rc/**` and `v*`. ios-asc-ops.yml runs from main, decodes the key to a 0600 file for one job and
calls this script with one fixed operation. Nothing here prints the key; review-detail reads drop the demo account's
password before printing.

  ios_asc_ops.py OP [--app ID] [--version STRING] [--attributes JSON] [--path PATH]

Operations (reads first; every write prints the object it wrote, read back after the write):
  app-info            the app, its appInfos (state, age rating) and its App Store versions
  versions            the app's App Store versions (id, versionString, appStoreState, platform)
  age-rating          every appInfo's ageRatingDeclaration attributes
  review-detail       the App Store review detail of a version (--version, else the editable one)
  submissions         the app's review submissions and their states
  get                 a read of one App Store Connect path (--path /v1/..., GET only)
  age-rating-patch    PATCH the editable appInfo's ageRatingDeclaration with --attributes JSON, then read it back
  review-detail-sync  set the review detail's attributes (notes, contact, demo account) from --attributes JSON on
                      --version (else the editable one); creates the detail when the version has none

Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH. Stock python3 and openssl; no packages.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APPS = {
    "6791408425": "cmux INTERNAL (dev.cmux.app.internal)",
    "6783338052": "cmux (com.cmux.app)",
}
DEFAULT_APP = "6791408425"
EDITABLE_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                   "INVALID_BINARY", "READY_FOR_REVIEW")
EDITABLE_INFO_STATES = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "READY_FOR_REVIEW",
                        "WAITING_FOR_REVIEW")
REVIEW_DETAIL_KEYS = ("contactFirstName", "contactLastName", "contactPhone", "contactEmail", "demoAccountName",
                      "demoAccountPassword", "demoAccountRequired", "notes")
REDACT = ("demoAccountPassword",)
PATH_RE = re.compile(r"/v[12]/[A-Za-z0-9_/.\-]+(\?[A-Za-z0-9_=&%\[\],.\-]*)?")
READS = ("app-info", "versions", "age-rating", "review-detail", "submissions", "get")
WRITES = ("age-rating-patch", "review-detail-sync")


# ---- the JWT (same shape as scripts/ci/ios_internal_notes.py on feat-cmux-next) ----

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to the JWS r||s form (32 bytes each)."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("integer too long for P-256")
        out += value.rjust(32, b"\x00")
        i += 2 + n
    return out


def asc_token(key_id: str, issuer: str, key_path: str, now: int | None = None) -> str:
    now = int(now if now is not None else time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{claims}.{_b64url(_der_to_raw(der))}"


# ---- HTTP ----

class Client:
    def __init__(self, token: str, opener=urllib.request.urlopen):
        self.token = token
        self.opener = opener

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(API + path, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/json",
            **({"Content-Type": "application/json"} if data is not None else {})})
        try:
            with self.opener(req, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:2000]
            raise SystemExit(f"{method} {path}: HTTP {err.code}: {detail}") from None
        return json.loads(raw) if raw else {}

    def get(self, path: str) -> dict:
        return self.call("GET", path)


def redact(value):
    if isinstance(value, dict):
        return {k: ("<redacted>" if k in REDACT and v else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


# ---- reads ----

def versions(client: Client, app: str) -> list[dict]:
    q = urllib.parse.urlencode({"limit": "50", "fields[appStoreVersions]": "versionString,appStoreState,platform,"
                                                                          "createdDate,releaseType"})
    return [{"id": v["id"], **v.get("attributes", {})}
            for v in client.get(f"/v1/apps/{app}/appStoreVersions?{q}").get("data", [])]


def app_infos(client: Client, app: str) -> list[dict]:
    return [{"id": i["id"], **i.get("attributes", {})} for i in client.get(f"/v1/apps/{app}/appInfos").get("data", [])]


def editable_version(client: Client, app: str, version: str | None) -> dict:
    found = versions(client, app)
    if version:
        match = [v for v in found if v.get("versionString") == version]
    else:
        match = [v for v in found if v.get("appStoreState") in EDITABLE_STATES]
    if not match:
        raise SystemExit(f"no App Store version {'named ' + version if version else 'in an editable state'} on app "
                         f"{app}; versions: {[(v.get('versionString'), v.get('appStoreState')) for v in found]}")
    return match[0]


def editable_info(client: Client, app: str) -> dict:
    infos = app_infos(client, app)
    for info in infos:
        if (info.get("appStoreState") or info.get("state")) in EDITABLE_INFO_STATES:
            return info
    if len(infos) == 1:
        return infos[0]
    raise SystemExit(f"no editable appInfo on app {app}: {[(i['id'], i.get('appStoreState') or i.get('state')) for i in infos]}")


def age_ratings(client: Client, app: str) -> list[dict]:
    out = []
    for info in app_infos(client, app):
        decl = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        out.append({"appInfo": info["id"], "appInfoState": info.get("appStoreState") or info.get("state"),
                    "declaration": decl.get("id"), "attributes": decl.get("attributes", {})})
    return out


def review_detail(client: Client, version_id: str) -> dict | None:
    try:
        data = client.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail").get("data")
    except SystemExit as err:
        if "HTTP 404" in str(err):
            return None
        raise
    return {"id": data["id"], **data.get("attributes", {})} if data else None


def run(op: str, args, client: Client) -> dict:
    app = args.app
    if op == "app-info":
        app_json = client.get(f"/v1/apps/{app}?fields[apps]=name,bundleId,sku,primaryLocale,contentRightsDeclaration")
        return {"app": {"id": app, **app_json.get("data", {}).get("attributes", {})},
                "appInfos": app_infos(client, app), "versions": versions(client, app),
                "ageRating": age_ratings(client, app)}
    if op == "versions":
        return {"versions": versions(client, app)}
    if op == "age-rating":
        return {"ageRating": age_ratings(client, app)}
    if op == "review-detail":
        version = editable_version(client, app, args.version)
        return {"version": version, "reviewDetail": review_detail(client, version["id"])}
    if op == "submissions":
        q = urllib.parse.urlencode({"filter[app]": app, "limit": "20",
                                    "fields[reviewSubmissions]": "state,submittedDate,platform"})
        return {"submissions": [{"id": s["id"], **s.get("attributes", {})}
                                for s in client.get(f"/v1/reviewSubmissions?{q}").get("data", [])]}
    if op == "get":
        if not args.path or not PATH_RE.fullmatch(args.path):
            raise SystemExit(f"--path must be an App Store Connect API path like /v1/apps/{app}/appInfos")
        return client.get(args.path)
    attributes = parse_attributes(args.attributes)
    if op == "age-rating-patch":
        info = editable_info(client, app)
        decl = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        if not decl.get("id"):
            raise SystemExit(f"appInfo {info['id']} has no ageRatingDeclaration")
        client.call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}",
                    {"data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": attributes}})
        after = client.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data") or {}
        return {"appInfo": info["id"], "declaration": decl["id"], "before": decl.get("attributes", {}),
                "after": after.get("attributes", {})}
    if op == "review-detail-sync":
        unknown = sorted(set(attributes) - set(REVIEW_DETAIL_KEYS))
        if unknown:
            raise SystemExit(f"unknown review detail attributes {unknown}; allowed: {list(REVIEW_DETAIL_KEYS)}")
        version = editable_version(client, app, args.version)
        before = review_detail(client, version["id"])
        if before:
            client.call("PATCH", f"/v1/appStoreReviewDetails/{before['id']}",
                        {"data": {"type": "appStoreReviewDetails", "id": before["id"], "attributes": attributes}})
        else:
            client.call("POST", "/v1/appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": attributes,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
        return {"version": version, "before": before, "after": review_detail(client, version["id"])}
    raise SystemExit(f"unknown op {op}")


def parse_attributes(text: str | None) -> dict:
    try:
        value = json.loads(text or "")
    except json.JSONDecodeError as err:
        raise SystemExit(f"--attributes must be a JSON object: {err}") from None
    if not isinstance(value, dict) or not value:
        raise SystemExit("--attributes must be a non-empty JSON object")
    return value


def main(argv: list[str] | None = None, client: Client | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("op", choices=READS + WRITES)
    parser.add_argument("--app", default=DEFAULT_APP)
    parser.add_argument("--version", default="")
    parser.add_argument("--attributes", default="")
    parser.add_argument("--path", default="")
    args = parser.parse_args(argv)
    if args.app not in APPS:
        parser.error(f"--app must be one of {sorted(APPS)} ({', '.join(APPS.values())})")
    if client is None:
        key_id, issuer, key_path = (os.environ.get(k, "") for k in ("ASC_KEY_ID", "ASC_ISSUER_ID",
                                                                     "ASC_PRIVATE_KEY_PATH"))
        if not (key_id and issuer and key_path and Path(key_path).is_file()):
            print("ios_asc_ops: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH are required", file=sys.stderr)
            return 2
        client = Client(asc_token(key_id, issuer, key_path))
    result = redact(run(args.op, args, client))
    text = json.dumps({"op": args.op, "app": args.app, "appName": APPS[args.app], "result": result}, indent=2,
                      sort_keys=True)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### ios-asc-ops `{args.op}` on {APPS[args.app]}\n\n```json\n{text[:60000]}\n```\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
