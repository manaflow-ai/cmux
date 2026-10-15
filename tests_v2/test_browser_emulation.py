#!/usr/bin/env python3
"""browser.geolocation.set and browser.offline.set work on a WebKit panel."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _eval(client: cmux, surface_id: str, script: str):
    payload = client._call("browser.eval", {"surface_id": surface_id, "script": script}) or {}
    return payload.get("value")


def _expect_invalid(client: cmux, method: str, params: dict) -> None:
    try:
        client._call(method, params)
    except cmuxError as exc:
        _must("invalid_params" in str(exc), f"Expected invalid_params from {method}: {exc}")
        return
    raise cmuxError(f"Expected {method} to reject {params!r}")


def _reported_position(client: cmux, surface_id: str):
    _eval(
        client,
        surface_id,
        "window.__cmuxPosition = null;"
        "navigator.geolocation.getCurrentPosition((p) => {"
        "  window.__cmuxPosition = [p.coords.latitude, p.coords.longitude, p.coords.accuracy];"
        "}); true",
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = _eval(client, surface_id, "window.__cmuxPosition")
        if value:
            return [float(item) for item in value]
    raise cmuxError("getCurrentPosition never answered with the override")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        opened = client._call("browser.open_split", {"url": "about:blank"}) or {}
        sid = str(opened.get("surface_id") or "")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")

        _expect_invalid(client, "browser.geolocation.set", {"surface_id": sid, "latitude": 91, "longitude": 0})
        _expect_invalid(client, "browser.geolocation.set", {"surface_id": sid, "latitude": 10})
        _expect_invalid(client, "browser.offline.set", {"surface_id": sid})

        result = client._call(
            "browser.geolocation.set",
            {"surface_id": sid, "latitude": 37.7749, "longitude": -122.4194, "accuracy": 5},
        ) or {}
        _must(result.get("geolocation", {}).get("latitude") == 37.7749, f"Unexpected geolocation reply: {result}")
        _must(_reported_position(client, sid) == [37.7749, -122.4194, 5.0], "Override position not reported")

        result = client._call("browser.offline.set", {"surface_id": sid, "enabled": True}) or {}
        _must(result.get("offline") is True, f"Unexpected offline reply: {result}")
        _must(_eval(client, sid, "navigator.onLine") is False, "navigator.onLine stayed true while offline")
        # Offline keeps the earlier geolocation override.
        _must(result.get("geolocation", {}).get("longitude") == -122.4194, f"Offline dropped geolocation: {result}")

        client._call("browser.offline.set", {"surface_id": sid, "enabled": False})
        _must(_eval(client, sid, "navigator.onLine") is True, "navigator.onLine stayed false after going online")

        result = client._call("browser.geolocation.set", {"surface_id": sid, "clear": True}) or {}
        _must(result.get("geolocation") is None, f"clear left a geolocation override: {result}")

    print("PASS: browser geolocation and offline emulation on WebKit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
