#!/usr/bin/env python3
"""Assign a TestFlight build to an internal beta group via App Store Connect API.

`upload-testflight.sh --external` makes the build eligible for internal testing too.
This helper resolves the app from its bundle id, waits for the uploaded build to
appear, selects the internal beta group, and attaches the build to that group.
Internal groups do not require beta app review submission.

Group selection:
- `--group-id` / `CMUX_TESTFLIGHT_INTERNAL_GROUP_ID` wins.
- Else `--group-name` / `CMUX_TESTFLIGHT_INTERNAL_GROUP_NAME` exact-matches.
- Else it auto-selects the app's single internal beta group.

If multiple internal groups exist and no selector is provided, it fails loudly so
CI does not claim the wrong group was updated.

Auth comes from the existing ASC environment used by the upload flow:
  ASC_API_KEY_ID, ASC_API_ISSUER_ID, and either ASC_API_KEY_PATH or
  ASC_API_KEY_P8_BASE64.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from typing import Dict, List, Optional, Tuple
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


def _paged_get(token: str, path: str) -> List[Dict]:
    items = []
    next_path = path
    pages = 0
    while next_path:
        if pages >= 50:
            raise RuntimeError("too many ASC pages while enumerating beta groups/builds")
        status, body = _request(token, "GET", next_path)
        if status != 200:
            raise RuntimeError(f"ASC GET {next_path} HTTP {status} (code={_asc_error_code(body)})")
        items.extend(body.get("data", []))
        next_url = (body.get("links") or {}).get("next")
        if not next_url:
            next_path = None
        elif next_url.startswith(API_BASE):
            next_path = next_url[len(API_BASE):]
        else:
            raise RuntimeError("unexpected App Store Connect pagination URL")
        pages += 1
    return items


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


def _find_build(token: str, app_id: str, build_number: str) -> Optional[Tuple[str, str]]:
    encoded_build = urllib.parse.quote(build_number, safe="")
    status, body = _request(
        token,
        "GET",
        f"/v1/builds?filter[app]={app_id}&filter[version]={encoded_build}"
        f"&fields[builds]=version,processingState&limit=1",
    )
    if status != 200:
        raise RuntimeError(f"build lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        return None
    attrs = data[0].get("attributes") or {}
    return data[0]["id"], str(attrs.get("processingState") or "")


def _list_beta_groups(token: str, app_id: str) -> List[Dict]:
    raw = _paged_get(
        token,
        f"/v1/betaGroups?filter[app]={app_id}"
        "&fields[betaGroups]=name,isInternalGroup,hasAccessToAllBuilds&limit=200",
    )
    groups = []
    for item in raw:
        attrs = item.get("attributes") or {}
        groups.append(
            {
                "id": item["id"],
                "name": attrs.get("name", ""),
                "is_internal": bool(attrs.get("isInternalGroup", False)),
                "has_access_to_all_builds": bool(attrs.get("hasAccessToAllBuilds", False)),
            }
        )
    return groups


def _describe_group(group: Dict) -> str:
    kind = "internal" if group.get("is_internal") else "external"
    return f"{group.get('name') or '<unnamed>'} ({group['id']}, {kind})"


def _select_group(groups: List[Dict], group_id: str, group_name: str) -> Dict:
    if group_id:
        matches = [group for group in groups if group["id"] == group_id]
        if not matches:
            raise RuntimeError(f"no beta group found for id {group_id}")
        group = matches[0]
        if not group["is_internal"]:
            raise RuntimeError(f"group {group_id} is external, expected an internal beta group")
        return group

    if group_name:
        matches = [group for group in groups if group["name"] == group_name]
        if not matches:
            raise RuntimeError(f"no beta group found named {group_name!r}")
        if len(matches) > 1:
            raise RuntimeError(
                f"multiple beta groups matched {group_name!r}: "
                + ", ".join(_describe_group(group) for group in matches)
            )
        group = matches[0]
        if not group["is_internal"]:
            raise RuntimeError(f"group {group_name!r} is external, expected an internal beta group")
        return group

    internal_groups = [group for group in groups if group["is_internal"]]
    if not internal_groups:
        raise RuntimeError("no internal beta groups found for this app")
    if len(internal_groups) > 1:
        raise RuntimeError(
            "multiple internal beta groups found; set CMUX_TESTFLIGHT_INTERNAL_GROUP_ID "
            "or CMUX_TESTFLIGHT_INTERNAL_GROUP_NAME. Candidates: "
            + ", ".join(_describe_group(group) for group in internal_groups)
        )
    return internal_groups[0]


def _group_has_build(token: str, group_id: str, build_id: str) -> bool:
    relationships = _paged_get(
        token,
        f"/v1/betaGroups/{group_id}/relationships/builds?limit=200",
    )
    return any(item.get("id") == build_id for item in relationships)


def _assign_build(token: str, group_id: str, build_id: str) -> None:
    payload = {"data": [{"type": "builds", "id": build_id}]}
    status, body = _request(token, "POST", f"/v1/betaGroups/{group_id}/relationships/builds", payload)
    if status not in (200, 201, 204):
        raise RuntimeError(f"assign build HTTP {status} (code={_asc_error_code(body)})")


def _write_state(state_out: str, state: str) -> None:
    if not state_out:
        return
    with open(state_out, "w", encoding="utf-8") as fh:
        fh.write(state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True, help="CFBundleVersion of the uploaded build")
    parser.add_argument("--group-id", default=os.environ.get("CMUX_TESTFLIGHT_INTERNAL_GROUP_ID", ""))
    parser.add_argument("--group-name", default=os.environ.get("CMUX_TESTFLIGHT_INTERNAL_GROUP_NAME", ""))
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--poll-seconds", type=int, default=20)
    parser.add_argument("--state-out", default=os.environ.get("CMUX_TESTFLIGHT_ASSIGN_STATE_OUT_FILE", ""))
    args = parser.parse_args()

    if args.group_id and args.group_name:
        raise RuntimeError("set only one of --group-id or --group-name")

    token = _token()
    app_id = _resolve_app_id(token, args.bundle_id)
    groups = _list_beta_groups(token, app_id)
    target_group = _select_group(groups, args.group_id.strip(), args.group_name.strip())

    deadline = time.time() + max(0, args.timeout_seconds)
    build = None
    while True:
        token = _token()
        build = _find_build(token, app_id, args.build_number)
        if build:
            break
        if time.time() >= deadline:
            raise RuntimeError(
                f"build {args.build_number} not visible on App Store Connect within {args.timeout_seconds}s"
            )
        time.sleep(max(1, args.poll_seconds))

    build_id, processing_state = build
    while processing_state != "VALID":
        if processing_state in ("FAILED", "INVALID"):
            raise RuntimeError(
                f"build {args.build_number} entered processingState={processing_state}"
            )
        if time.time() >= deadline:
            raise RuntimeError(
                f"build {args.build_number} did not reach processingState=VALID within {args.timeout_seconds}s"
            )
        time.sleep(max(1, args.poll_seconds))
        token = _token()
        build = _find_build(token, app_id, args.build_number)
        if not build:
            raise RuntimeError(f"build {args.build_number} disappeared from App Store Connect")
        build_id, processing_state = build

    if target_group["has_access_to_all_builds"]:
        print(
            f"asc_assign_internal_testflight_group: group {_describe_group(target_group)} "
            f"already has access to all builds"
        )
        _write_state(args.state_out, "group_has_all_builds_access")
        return 0

    if _group_has_build(token, target_group["id"], build_id):
        print(
            f"asc_assign_internal_testflight_group: build {args.build_number} already assigned to "
            f"{_describe_group(target_group)}"
        )
        _write_state(args.state_out, "already_assigned")
        return 0

    token = _token()
    _assign_build(token, target_group["id"], build_id)
    print(
        f"asc_assign_internal_testflight_group: assigned build {args.build_number} to "
        f"{_describe_group(target_group)}"
    )
    _write_state(args.state_out, "assigned")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"asc_assign_internal_testflight_group: {exc}", file=sys.stderr)
        raise SystemExit(1)
