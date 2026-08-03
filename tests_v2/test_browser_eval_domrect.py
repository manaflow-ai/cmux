#!/usr/bin/env python3
"""Regression: browser.eval returns bridge-safe JSON or explicit cycle errors."""

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


def _expect_circular_reference_error(client: cmux, surface_id: str) -> None:
    try:
        client._call(
            "browser.eval",
            {
                "surface_id": surface_id,
                "script": "(() => { const value = {}; value.self = value; return value; })()",
            },
        )
    except cmuxError as exc:
        message = str(exc)
        _must(
            "circular_reference" in message,
            f"Expected explicit circular_reference error, got: {message}",
        )
        _must(
            "browser.eval result contains a circular reference" in message,
            f"Expected deterministic circular-reference message, got: {message}",
        )
        _must(
            "encode_error" not in message,
            f"Circular values must be rejected before response encoding: {message}",
        )
        return
    raise cmuxError("Expected browser.eval to reject a circular result")


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

            repeated_alias_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": """
                    (() => {
                      const shared = {answer: 42};
                      return {first: shared, second: shared, items: [shared, shared]};
                    })()
                    """,
                },
            ) or {}
            repeated_alias_value = _value(repeated_alias_result) or {}
            expected_alias = {"answer": 42}
            _must(
                repeated_alias_value.get("first") == expected_alias
                and repeated_alias_value.get("second") == expected_alias
                and repeated_alias_value.get("items") == [expected_alias, expected_alias],
                f"Expected repeated aliases to become JSON-safe copies: {repeated_alias_result}",
            )

            _expect_circular_reference_error(client, surface_id)
        finally:
            if surface_id:
                try:
                    client._call("surface.close", {"surface_id": surface_id})
                except (cmuxError, OSError):
                    pass

    print("PASS: browser.eval returns bridge-safe DOMRects, aliases, and cycle errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
