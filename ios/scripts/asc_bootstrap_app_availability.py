#!/usr/bin/env python3
"""Create initial public App Store availability when it does not exist.

Apple exposes initial availability through the public App Store Connect API at
POST /v2/appAvailabilities. The asc availability edit command only updates an
existing record, so the production release lane needs this one-time bootstrap.

The app is made available in every current territory, without pre-order, and
future territories are enabled. Repeated runs are no-ops once the record exists.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

import asc_max_build


OFFICIAL_API_BASE = "https://api.appstoreconnect.apple.com"
MAX_TERRITORY_PAGES = 20


def _api_base() -> str:
    override = os.environ.get("CMUX_ASC_API_BASE_URL")
    if not override:
        return OFFICIAL_API_BASE
    parsed = urllib.parse.urlsplit(override)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {
        "127.0.0.1",
        "::1",
        "localhost",
    }:
        raise RuntimeError("CMUX_ASC_API_BASE_URL is restricted to loopback tests")
    return override.rstrip("/")


def _timeout_seconds() -> int:
    raw = os.environ.get("ASC_TIMEOUT_SECONDS", "30")
    try:
        timeout = int(raw)
    except ValueError as error:
        raise RuntimeError("ASC_TIMEOUT_SECONDS must be an integer") from error
    if not 1 <= timeout <= 600:
        raise RuntimeError("ASC_TIMEOUT_SECONDS must be between 1 and 600")
    return timeout


def _error_code(body: Any) -> str:
    try:
        return str(((body.get("errors") or [{}])[0]).get("code", "unknown"))
    except Exception:
        return "unknown"


def _request(
    token: str,
    base: str,
    method: str,
    path_or_url: str,
    timeout: int,
    payload: dict[str, Any] | None = None,
) -> tuple[int, dict[str, Any]]:
    if path_or_url.startswith("/"):
        url = base + path_or_url
    else:
        url = path_or_url
        parsed_base = urllib.parse.urlsplit(base)
        parsed_url = urllib.parse.urlsplit(url)
        if (parsed_url.scheme, parsed_url.netloc) != (parsed_base.scheme, parsed_base.netloc):
            raise RuntimeError("App Store Connect pagination changed API origin")

    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            body = json.loads(error.read() or b"{}")
        except json.JSONDecodeError:
            body = {}
        return error.code, body


def _existing_availability(
    token: str, base: str, app_id: str, timeout: int
) -> str | None:
    status, body = _request(
        token,
        base,
        "GET",
        f"/v1/apps/{urllib.parse.quote(app_id)}/appAvailabilityV2",
        timeout,
    )
    if status == 404:
        return None
    if status != 200:
        raise RuntimeError(
            f"availability lookup HTTP {status} (code={_error_code(body)})"
        )
    data = body.get("data")
    if data is None:
        return None
    if not isinstance(data, dict) or not data.get("id"):
        raise RuntimeError("availability lookup returned an unexpected resource")
    return str(data["id"])


def _territory_ids(token: str, base: str, timeout: int) -> list[str]:
    path: str | None = "/v1/territories?limit=200"
    territory_ids: set[str] = set()
    pages = 0
    while path:
        if pages >= MAX_TERRITORY_PAGES:
            raise RuntimeError("territory pagination exceeded safety limit")
        status, body = _request(token, base, "GET", path, timeout)
        if status != 200:
            raise RuntimeError(
                f"territory lookup HTTP {status} (code={_error_code(body)})"
            )
        data = body.get("data")
        if not isinstance(data, list):
            raise RuntimeError("territory lookup returned an unexpected resource")
        for item in data:
            if not isinstance(item, dict) or not item.get("id"):
                raise RuntimeError("territory lookup returned an invalid territory")
            territory_ids.add(str(item["id"]))
        next_url = (body.get("links") or {}).get("next")
        if next_url is not None and not isinstance(next_url, str):
            raise RuntimeError("territory lookup returned an invalid next link")
        path = next_url or None
        pages += 1
    if not territory_ids:
        raise RuntimeError("territory lookup returned no territories")
    return sorted(territory_ids)


def _create_payload(app_id: str, territory_ids: list[str]) -> dict[str, Any]:
    linkage: list[dict[str, str]] = []
    included: list[dict[str, Any]] = []
    for territory_id in territory_ids:
        availability_id = f"${{local-{territory_id.lower()}}}"
        linkage.append({"type": "territoryAvailabilities", "id": availability_id})
        included.append(
            {
                "type": "territoryAvailabilities",
                "id": availability_id,
                "attributes": {"available": True, "preOrderEnabled": False},
                "relationships": {
                    "territory": {
                        "data": {"type": "territories", "id": territory_id}
                    }
                },
            }
        )
    return {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "territoryAvailabilities": {"data": linkage},
            },
        },
        "included": included,
    }


def bootstrap(app_id: str) -> tuple[str, int]:
    token = asc_max_build._token()
    base = _api_base()
    timeout = _timeout_seconds()
    existing_id = _existing_availability(token, base, app_id, timeout)
    if existing_id:
        return existing_id, 0

    territory_ids = _territory_ids(token, base, timeout)
    status, body = _request(
        token,
        base,
        "POST",
        "/v2/appAvailabilities",
        timeout,
        _create_payload(app_id, territory_ids),
    )
    if status == 409:
        existing_id = _existing_availability(token, base, app_id, timeout)
        if existing_id:
            return existing_id, 0
    if status != 201:
        raise RuntimeError(
            f"availability create HTTP {status} (code={_error_code(body)})"
        )
    data = body.get("data")
    if not isinstance(data, dict) or not data.get("id"):
        raise RuntimeError("availability create returned an unexpected resource")
    return str(data["id"]), len(territory_ids)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="numeric App Store Connect app ID")
    args = parser.parse_args()
    if not args.app.isdigit():
        raise RuntimeError("--app must be a numeric App Store Connect app ID")
    availability_id, created_territories = bootstrap(args.app)
    if created_territories:
        print(
            f"created App Store availability {availability_id} "
            f"for {created_territories} territories"
        )
    else:
        print(f"App Store availability already exists: {availability_id}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"asc_bootstrap_app_availability: {error}", file=sys.stderr)
        sys.exit(1)
