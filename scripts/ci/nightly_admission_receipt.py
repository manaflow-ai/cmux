#!/usr/bin/env python3
"""Read the controller's terminal admission proof through GitHub's App identity.

At most two authenticated reads: look once, then retry a missing publication
after the controller's admission window. Waiting locally never authorizes paid
overflow. No job is dispatched or cancelled by this reader.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import time
import urllib.parse
import urllib.request
from typing import Any, Mapping

APP_ID = 5313868  # Existing manaflow-checks App; no new credential or App scope.
CHECK_NAME = "cmux/nightly-admission"
WAIT_SECONDS = 180
PUBLICATION_WAIT_SECONDS = 210  # Lease window plus cached-event and publication delivery.
MAX_RESPONSE_BYTES = 1 << 20
API = "https://api.github.com"


class MissingReceipt(ValueError):
    """The controller has not published this exact lease."""


def lease_id(request: Mapping[str, Any]) -> str:
    # Field order is the controller's nightlyAdmissionRequest Go struct order.
    canonical = {key: request[key] for key in
                 ("repository", "run_id", "run_attempt", "source_sha", "jobs")}
    encoded = json.dumps(canonical, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()[:24]


def timestamp_ns(value: Any) -> int:
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(?:Z|\+00:00)",
                         value) if isinstance(value, str) else None
    if not match:
        raise ValueError("receipt timestamps must be UTC RFC3339")
    whole = dt.datetime.fromisoformat(match[1]).replace(tzinfo=dt.timezone.utc)
    return int(whole.timestamp()) * 1_000_000_000 + int((match[2] or "").ljust(9, "0"))


def validate(receipt: Mapping[str, Any], request: Mapping[str, Any]) -> str:
    """Validate both the private endpoint's receipt and the public projection."""
    for key in ("repository", "run_id", "run_attempt", "source_sha", "jobs"):
        if type(receipt.get(key)) is not type(request[key]) or receipt[key] != request[key]:
            raise ValueError(f"admission receipt mismatches {key}")
    lease = receipt.get("lease_id")
    if not isinstance(lease, str) or not re.fullmatch(r"[0-9a-f]{24}", lease):
        raise ValueError("invalid lease identity")
    created, expires = timestamp_ns(receipt.get("created_at")), timestamp_ns(receipt.get("expires_at"))
    if expires - created != WAIT_SECONDS * 1_000_000_000:
        raise ValueError("admission lease must give the fleet 180 seconds")
    now = time.time_ns()
    if created > now:
        raise ValueError("admission receipt starts in the future")
    status = receipt.get("status")
    if status == "pending":
        return status
    decided = timestamp_ns(receipt.get("decided_at"))
    if decided > now:
        raise ValueError("admission receipt was decided in the future")
    if status == "fleet":
        expected = {job: f"cmux-nightly-{lease}-{job}" for job in request["jobs"]}
        if receipt.get("runners") != expected or not created <= decided < expires:
            raise ValueError("fleet receipt does not reserve matching runners before expiry")
    elif status == "overflow":
        elapsed = receipt.get("no_start_seconds")
        if (type(elapsed) is not int or elapsed < WAIT_SECONDS or decided < expires
                or elapsed != (decided - created) // 1_000_000_000 or receipt.get("runners") != {}):
            raise ValueError("overflow requires a recorded 180-second fleet no-start")
    else:
        raise ValueError("unknown admission status")
    return status


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate receipt JSON key")
        result[key] = value
    return result


def validate_check(check: Mapping[str, Any], request: Mapping[str, Any]) -> dict[str, Any]:
    expected_lease = lease_id(request)
    app = check.get("app")
    if (not isinstance(app, dict) or type(app.get("id")) is not int or app["id"] != APP_ID
            or check.get("name") != CHECK_NAME or check.get("head_sha") != request["source_sha"]
            or check.get("external_id") != expected_lease or check.get("status") != "completed"
            or type(check.get("id")) is not int or check["id"] <= 0):
        raise ValueError("admission check authority or identity mismatch")
    output = check.get("output")
    summary = output.get("summary") if isinstance(output, dict) else None
    if not isinstance(summary, str) or len(summary.encode()) > 16384:
        raise ValueError("admission check summary is missing or oversized")
    projection = json.loads(summary, object_pairs_hook=unique_object)
    required = {"schema", "repository", "run_id", "run_attempt", "source_sha", "lease_id", "jobs",
                "state", "created_at", "decided_at", "expires_at"}
    if (not isinstance(projection, dict) or not required <= projection.keys()
            or projection.keys() - required - {"no_start_seconds", "runner_keys"}
            or type(projection["schema"]) is not int or projection["schema"] != 1
            or projection["lease_id"] != expected_lease):
        raise ValueError("unknown admission projection schema or lease")
    state = projection.pop("state")
    if state not in ("fleet", "overflow") or check.get("conclusion") != (
            "success" if state == "fleet" else "failure"):
        raise ValueError("admission check is not a matching terminal decision")
    projection.pop("schema")
    runners = projection.pop("runner_keys", {})
    receipt = {**projection, "status": state, "runners": runners}
    if state == "fleet" and (type(receipt.get("no_start_seconds", 0)) is not int
                             or receipt.get("no_start_seconds", 0) != 0):
        raise ValueError("fleet receipt cannot claim overflow")
    validate(receipt, request)
    return {**receipt, "check_run_id": check["id"], "publisher_app_id": app["id"]}


def select(payload: Any, request: Mapping[str, Any]) -> dict[str, Any]:
    if (not isinstance(payload, dict) or type(payload.get("total_count")) is not int
            or not isinstance(payload.get("check_runs"), list)
            or payload["total_count"] != len(payload["check_runs"]) or payload["total_count"] > 100):
        raise ValueError("admission checks are malformed or truncated")
    if any(not isinstance(check, dict) for check in payload["check_runs"]):
        raise ValueError("malformed admission check")
    matches = [check for check in payload["check_runs"] if check.get("external_id") == lease_id(request)]
    if not matches:
        raise MissingReceipt("no published admission receipt for this run and attempt")
    if len(matches) != 1:
        raise ValueError("ambiguous admission receipt")
    return validate_check(matches[0], request)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("admission API redirects are forbidden")


def get(request: Mapping[str, Any], token: str) -> Any:
    if not token or request.get("repository") != "manaflow-ai/cmux" or not re.fullmatch(
            r"[0-9a-f]{40}", request.get("source_sha", "")):
        raise ValueError("authenticated same-repository admission read required")
    query = urllib.parse.urlencode({"check_name": CHECK_NAME, "filter": "all", "per_page": 100})
    url = f"{API}/repos/manaflow-ai/cmux/commits/{request['source_sha']}/check-runs?{query}"
    call = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                              "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.build_opener(NoRedirect()).open(call, timeout=15) as response:
        data = response.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        raise ValueError("admission API response is oversized")
    return json.loads(data, object_pairs_hook=unique_object)


def read(request: Mapping[str, Any], token: str) -> dict[str, Any]:
    started = time.monotonic()
    try:
        return select(get(request, token), request)
    except MissingReceipt:
        # One delayed retry, not a GitHub polling loop. Only a validated terminal
        # controller receipt after this wait may authorize paid overflow.
        time.sleep(max(0, PUBLICATION_WAIT_SECONDS - (time.monotonic() - started)))
        return select(get(request, token), request)
