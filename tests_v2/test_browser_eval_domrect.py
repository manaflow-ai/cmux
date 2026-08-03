#!/usr/bin/env python3
"""Regression: browser.eval serializes direct and nested DOMRect values."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _value(payload: dict):
    return (payload or {}).get("value")


def main() -> int:
    surface_id = ""
    with cmux(SOCKET_PATH) as client:
        try:
            opened = client._call("browser.open_split", {"url": "about:blank"}) or {}
            surface_id = str(opened.get("surface_id") or "")
            _must(bool(surface_id), f"browser.open_split returned no surface_id: {opened}")

            direct_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "document.documentElement.getBoundingClientRect()",
                },
            ) or {}
            direct_rect = _value(direct_result)
            _must(
                isinstance(direct_rect, dict),
                f"Expected DOMRect dictionary: {direct_result}",
            )
            _must(
                float(direct_rect.get("width") or 0.0) > 0.0,
                f"Expected positive DOMRect width: {direct_result}",
            )

            nested_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "({bounds: document.documentElement.getBoundingClientRect(), items: [document.body.getBoundingClientRect()]})",
                },
            ) or {}
            nested_value = _value(nested_result) or {}
            nested_rect = nested_value.get("bounds")
            nested_items = nested_value.get("items") or []
            _must(
                isinstance(nested_rect, dict),
                f"Expected nested DOMRect dictionary: {nested_result}",
            )
            _must(
                len(nested_items) == 1 and isinstance(nested_items[0], dict),
                f"Expected DOMRect dictionary inside array: {nested_result}",
            )

            cross_realm_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": """
                    (() => {
                      const frame = document.createElement('iframe');
                      document.body.appendChild(frame);
                      const rect = frame.contentDocument.documentElement.getBoundingClientRect();
                      const isCrossRealm = !(rect instanceof DOMRectReadOnly);
                      frame.remove();
                      return {isCrossRealm, rect};
                    })()
                    """,
                },
            ) or {}
            cross_realm_value = _value(cross_realm_result) or {}
            _must(
                cross_realm_value.get("isCrossRealm") is True,
                f"Expected iframe DOMRect to come from another JavaScript realm: {cross_realm_result}",
            )
            _must(
                isinstance(cross_realm_value.get("rect"), dict),
                f"Expected cross-realm DOMRect dictionary: {cross_realm_result}",
            )
        finally:
            if surface_id:
                try:
                    client._call("surface.close", {"surface_id": surface_id})
                except cmuxError:
                    pass

    print("PASS: browser.eval serializes direct, nested, and cross-realm DOMRect values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
