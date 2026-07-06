#!/usr/bin/env python3
"""Assign a TestFlight build to an external beta group via App Store Connect API.

`upload-testflight.sh --external` makes the build eligible for external testing,
but testers do not receive it until the build is added to an external beta group.
This helper resolves the app from its bundle id, waits for the uploaded build to
appear, selects the external beta group, and attaches the build to that group.
When Apple reports the build as `READY_FOR_BETA_SUBMISSION` (the first external
build of a MARKETING_VERSION), it also creates the beta app review submission so
external testers can actually receive that version once review clears.

Group selection:
- `--group-id` / `CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID` wins.
- Else `--group-name` / `CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME` exact-matches.
- Else it auto-selects the app's single external beta group.

If multiple external groups exist and no selector is provided, it fails loudly so
CI does not claim founders were updated when the target group was ambiguous.

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
ACTIVE_EXTERNAL_BUILD_STATES = {
    "READY_FOR_BETA_TESTING",
    "IN_BETA_REVIEW",
    "WAITING_FOR_BETA_REVIEW",
}
ACTIVE_BETA_REVIEW_STATES = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
}


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


def _build_beta_detail(token: str, build_id: str) -> Dict[str, str]:
    status, body = _request(
        token,
        "GET",
        f"/v1/builds/{build_id}/buildBetaDetail",
    )
    if status != 200:
        raise RuntimeError(f"build beta detail lookup HTTP {status} (code={_asc_error_code(body)})")
    attrs = (body.get("data") or {}).get("attributes") or {}
    return {
        "external_build_state": str(attrs.get("externalBuildState") or ""),
        "internal_build_state": str(attrs.get("internalBuildState") or ""),
    }


def _build_pre_release_version(token: str, build_id: str) -> Dict[str, str]:
    status, body = _request(
        token,
        "GET",
        f"/v1/builds/{build_id}/preReleaseVersion?fields[preReleaseVersions]=version",
    )
    if status != 200:
        raise RuntimeError(f"pre-release version lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data") or {}
    attrs = data.get("attributes") or {}
    return {
        "id": str(data.get("id") or ""),
        "version": str(attrs.get("version") or ""),
    }


def _beta_review_submission(token: str, build_id: str) -> Optional[Dict[str, str]]:
    status, body = _request(
        token,
        "GET",
        f"/v1/betaAppReviewSubmissions?filter[build]={build_id}"
        "&fields[betaAppReviewSubmissions]=betaReviewState&limit=1",
    )
    if status != 200:
        raise RuntimeError(f"beta app review submission lookup HTTP {status} (code={_asc_error_code(body)})")
    data = body.get("data", [])
    if not data:
        return None
    attrs = data[0].get("attributes") or {}
    return {"id": data[0]["id"], "beta_review_state": str(attrs.get("betaReviewState") or "")}


def _pre_release_version_build_ids(token: str, pre_release_version_id: str) -> List[str]:
    builds = _paged_get(
        token,
        f"/v1/preReleaseVersions/{pre_release_version_id}/relationships/builds?limit=200",
    )
    return [str(item.get("id") or "") for item in builds if item.get("id")]


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
        if group["is_internal"]:
            raise RuntimeError(f"group {group_id} is internal, expected an external beta group")
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
        if group["is_internal"]:
            raise RuntimeError(f"group {group_name!r} is internal, expected an external beta group")
        return group

    external_groups = [group for group in groups if not group["is_internal"]]
    if not external_groups:
        raise RuntimeError("no external beta groups found for this app")
    if len(external_groups) > 1:
        raise RuntimeError(
            "multiple external beta groups found; set CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID "
            "or CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME. Candidates: "
            + ", ".join(_describe_group(group) for group in external_groups)
        )
    return external_groups[0]


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


def _submit_beta_review(token: str, build_id: str) -> None:
    payload = {
        "data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {
                "build": {
                    "data": {
                        "type": "builds",
                        "id": build_id,
                    }
                }
            },
        }
    }
    status, body = _request(token, "POST", "/v1/betaAppReviewSubmissions", payload)
    if status not in (200, 201):
        raise RuntimeError(f"submit beta app review HTTP {status} (code={_asc_error_code(body)})")


def _find_active_review_submission_on_sibling_build(
    token: str,
    build_id: str,
) -> Optional[Dict[str, str]]:
    pre_release_version = _build_pre_release_version(token, build_id)
    pre_release_version_id = pre_release_version["id"]
    if not pre_release_version_id:
        return None
    for sibling_build_id in _pre_release_version_build_ids(token, pre_release_version_id):
        if sibling_build_id == build_id:
            continue
        submission = _beta_review_submission(token, sibling_build_id)
        if submission is None:
            continue
        review_state = submission["beta_review_state"]
        if review_state in ACTIVE_BETA_REVIEW_STATES:
            return {
                "build_id": sibling_build_id,
                "submission_id": submission["id"],
                "beta_review_state": review_state,
                "pre_release_version": pre_release_version["version"],
            }
    return None


def _report_pending_sibling_review(build_number: str, sibling_submission: Dict[str, str]) -> None:
    print(
        "asc_assign_external_testflight_group: build "
        f"{build_number} stays pending while sibling build {sibling_submission['build_id']} for "
        f"version {sibling_submission['pre_release_version'] or 'unknown'} remains in beta review "
        f"(submission {sibling_submission['submission_id']}, "
        f"state={sibling_submission['beta_review_state']})"
    )

def _ensure_external_review_submission(
    token: str,
    build_id: str,
    build_number: str,
    deadline: float,
    poll_seconds: int,
) -> None:
    last_submit_error = ""
    while True:
        try:
            detail = _build_beta_detail(token, build_id)
            external_state = detail["external_build_state"]
            submission = _beta_review_submission(token, build_id)
            sibling_submission = _find_active_review_submission_on_sibling_build(token, build_id)
        except RuntimeError as exc:
            if time.time() >= deadline:
                raise RuntimeError(
                    f"build {build_number} review metadata did not become readable within the timeout window: {exc}"
                )
            time.sleep(max(1, poll_seconds))
            token = _token()
            continue

        if external_state in ACTIVE_EXTERNAL_BUILD_STATES:
            print(
                "asc_assign_external_testflight_group: build "
                f"{build_number} external state is {external_state}"
            )
            return

        if submission is not None:
            review_state = submission["beta_review_state"]
            if review_state in ACTIVE_BETA_REVIEW_STATES:
                print(
                    "asc_assign_external_testflight_group: build "
                    f"{build_number} external state is {external_state or 'unknown'} with submission "
                    f"{submission['id']} (state={review_state or 'unknown'})"
                )
                return
            raise RuntimeError(
                "build "
                f"{build_number} external state is {external_state or '<empty>'} with beta app review "
                f"submission {submission['id']} in unexpected betaReviewState={review_state or '<empty>'}"
            )

        if sibling_submission is not None:
            _report_pending_sibling_review(build_number, sibling_submission)
            return

        if external_state == "READY_FOR_BETA_SUBMISSION":
            try:
                _submit_beta_review(token, build_id)
                last_submit_error = ""
            except RuntimeError as exc:
                submission = _beta_review_submission(token, build_id)
                if submission is not None:
                    review_state = submission["beta_review_state"]
                    if review_state in ACTIVE_BETA_REVIEW_STATES:
                        print(
                            "asc_assign_external_testflight_group: build "
                            f"{build_number} external state is READY_FOR_BETA_SUBMISSION with submission "
                            f"{submission['id']} (state={review_state or 'unknown'})"
                        )
                        return
                    raise RuntimeError(
                        "build "
                        f"{build_number} external state is READY_FOR_BETA_SUBMISSION with beta app review "
                        f"submission {submission['id']} in unexpected betaReviewState={review_state or '<empty>'}"
                    )
                sibling_submission = _find_active_review_submission_on_sibling_build(token, build_id)
                if sibling_submission is not None:
                    _report_pending_sibling_review(build_number, sibling_submission)
                    return
                last_submit_error = str(exc) or "submit beta app review did not succeed yet"
                if time.time() >= deadline:
                    raise RuntimeError(
                        f"build {build_number} failed to submit beta app review within the timeout window"
                    )
                time.sleep(max(1, poll_seconds))
                token = _token()
                continue
            print(
                f"asc_assign_external_testflight_group: submitted build {build_number} for beta app review"
            )
            return

        if time.time() >= deadline:
            if last_submit_error:
                raise RuntimeError(
                    f"build {build_number} did not become externally reviewable within the timeout window "
                    f"({last_submit_error})"
                )
            raise RuntimeError(
                "build "
                f"{build_number} is in unexpected externalBuildState={external_state or '<empty>'} "
                "with no beta app review submission"
            )

        time.sleep(max(1, poll_seconds))
        token = _token()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-number", required=True, help="CFBundleVersion of the uploaded build")
    parser.add_argument("--group-id", default=os.environ.get("CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID", ""))
    parser.add_argument("--group-name", default=os.environ.get("CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME", ""))
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--poll-seconds", type=int, default=20)
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
            f"asc_assign_external_testflight_group: group {_describe_group(target_group)} "
            f"already has access to all builds"
        )
        token = _token()
        _ensure_external_review_submission(
            token,
            build_id,
            args.build_number,
            time.time() + max(0, args.timeout_seconds),
            args.poll_seconds,
        )
        return 0

    if _group_has_build(token, target_group["id"], build_id):
        print(
            f"asc_assign_external_testflight_group: build {args.build_number} already assigned to "
            f"{_describe_group(target_group)}"
        )
        token = _token()
        _ensure_external_review_submission(
            token,
            build_id,
            args.build_number,
            time.time() + max(0, args.timeout_seconds),
            args.poll_seconds,
        )
        return 0

    token = _token()
    _assign_build(token, target_group["id"], build_id)
    print(
        f"asc_assign_external_testflight_group: assigned build {args.build_number} to "
        f"{_describe_group(target_group)}"
    )
    token = _token()
    _ensure_external_review_submission(
        token,
        build_id,
        args.build_number,
        time.time() + max(0, args.timeout_seconds),
        args.poll_seconds,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"asc_assign_external_testflight_group: {exc}", file=sys.stderr)
        raise SystemExit(1)
