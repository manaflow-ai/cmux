from __future__ import annotations

from typing import Any

BROWSER_BACKEND = "webkitgtk"

BACKEND_LIMITED_BROWSER_METHODS: dict[str, dict[str, str]] = {
    "browser.trace.start": {
        "capability": "trace_archive",
        "mode": "javascript_observation",
        "reason": "WebKitGTK tracing is limited to in-page events and PerformanceEntry snapshots.",
    },
    "browser.trace.stop": {
        "capability": "trace_archive",
        "mode": "javascript_observation",
        "reason": "WebKitGTK tracing does not produce a Playwright/CDP trace archive on Linux.",
    },
    "browser.network.route": {
        "capability": "network_route_interception",
        "mode": "metadata_only",
        "reason": "WebKitGTK route interception is recorded as route metadata without request mutation.",
    },
    "browser.network.unroute": {
        "capability": "network_route_interception",
        "mode": "metadata_only",
        "reason": "WebKitGTK route interception is recorded as route metadata without request mutation.",
    },
    "browser.network.requests": {
        "capability": "network_route_interception",
        "mode": "performance_entries",
        "reason": "WebKitGTK request listing is derived from resource performance entries.",
    },
    "browser.screencast.start": {
        "capability": "screencast_streaming",
        "mode": "single_frame_snapshot",
        "reason": "WebKitGTK screencast uses screenshot snapshots instead of a streaming frame source.",
    },
    "browser.screencast.stop": {
        "capability": "screencast_streaming",
        "mode": "single_frame_snapshot",
        "reason": "WebKitGTK screencast uses screenshot snapshots instead of a streaming frame source.",
    },
    "browser.input_mouse": {
        "capability": "raw_input_backend",
        "mode": "javascript_event",
        "reason": "WebKitGTK raw mouse input is emulated through JavaScript events.",
    },
    "browser.input_keyboard": {
        "capability": "raw_input_backend",
        "mode": "text_injection",
        "reason": "WebKitGTK keyboard input is routed through focused element text injection.",
    },
    "browser.input_touch": {
        "capability": "raw_input_backend",
        "mode": "javascript_event",
        "reason": "WebKitGTK touch input is emulated through JavaScript events.",
    },
}


def browser_backend_limits() -> list[str]:
    return sorted({item["capability"] for item in BACKEND_LIMITED_BROWSER_METHODS.values()})


def browser_backend_limit(method: str) -> dict[str, Any]:
    detail = BACKEND_LIMITED_BROWSER_METHODS.get(method)
    if detail is None:
        raise ValueError(f"browser method is not backend-limited: {method}")
    return {
        "code": "backend_limit",
        "method": method,
        "backend": BROWSER_BACKEND,
        **detail,
    }
