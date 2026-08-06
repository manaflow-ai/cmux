#!/usr/bin/env python3
"""Regression: browser.eval returns bridge-safe JSON or explicit cycle errors."""

import contextlib
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
SECRET_SENTINEL = "CMUX_BROWSER_FAILURE_MUST_NOT_ESCAPE_9D73B2"
SELECTOR_WAIT_SECRET_SENTINEL = "CMUX_SELECTOR_WAIT_FAILURE_MUST_NOT_ESCAPE_A184C6"


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _value(payload: dict):
    return (payload or {}).get("value")


def _expect_circular_reference_error(
    client: cmux, surface_id: str, script: str
) -> None:
    try:
        client._call(
            "browser.eval",
            {
                "surface_id": surface_id,
                "script": script,
            },
        )
    except cmuxError as exc:
        message = str(exc)
        _must(
            "circular_reference" in message,
            f"Expected explicit circular_reference error, got: {message}",
        )
        _must(
            "encode_error" not in message,
            f"Circular values must be rejected before response encoding: {message}",
        )
        return
    raise cmuxError("Expected browser.eval to reject a circular result")


def _expect_sanitized_script_error(client: cmux, surface_id: str) -> None:
    try:
        client._call(
            "browser.eval",
            {
                "surface_id": surface_id,
                "script": f"throw new Error('{SECRET_SENTINEL}')",
            },
        )
    except cmuxError as exc:
        message = str(exc)
        _must(
            message.startswith("js_error: Browser operation failed"),
            f"Expected a stable browser failure, got: {message}",
        )
        _must(
            SECRET_SENTINEL not in message,
            f"Page JavaScript failure details escaped the browser boundary: {message}",
        )
        return
    raise cmuxError("Expected browser.eval to reject a thrown page error")


def _expect_sanitized_selector_wait_error(client: cmux, surface_id: str) -> None:
    client._call(
        "browser.eval",
        {
            "surface_id": surface_id,
            "script": f"""
            (() => {{
              window.__cmuxOriginalSetTimeout = window.setTimeout;
              window.setTimeout = () => {{
                throw new Error('{SELECTOR_WAIT_SECRET_SENTINEL}');
              }};
              return true;
            }})()
            """,
        },
    )
    try:
        client._call(
            "browser.click",
            {
                "surface_id": surface_id,
                "selector": "#cmux-selector-wait-failure",
                "retry_attempts": 2,
            },
        )
    except cmuxError as exc:
        message = str(exc)
        _must(
            message.startswith("js_error: Browser operation failed"),
            f"Expected selector wait evaluation failure, got: {message}",
        )
        _must(
            SELECTOR_WAIT_SECRET_SENTINEL not in message,
            f"Selector wait failure details escaped the browser boundary: {message}",
        )
    else:
        raise cmuxError("Expected browser.click selector wait evaluation to fail")
    finally:
        client._call(
            "browser.eval",
            {
                "surface_id": surface_id,
                "script": """
                (() => {
                  window.setTimeout = window.__cmuxOriginalSetTimeout;
                  delete window.__cmuxOriginalSetTimeout;
                  return true;
                })()
                """,
            },
        )


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

            client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": """
                    (() => {
                      window.__cmuxRealmMarker = 'top';
                      window.__cmuxFrameOnly = 'top-global';
                      const frame = document.createElement('iframe');
                      frame.id = 'cmux-selected-frame';
                      document.body.appendChild(frame);
                      frame.contentDocument.title = 'frame-title';
                      frame.contentWindow.__cmuxRealmMarker = 'frame';
                      frame.contentWindow.__cmuxFrameOnly = 'frame-global';
                      frame.contentWindow.location.hash = 'frame';
                      return true;
                    })()
                    """,
                },
            )
            client._call(
                "browser.frame.select",
                {"surface_id": surface_id, "selector": "#cmux-selected-frame"},
            )
            frame_realm_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "({marker: window.__cmuxRealmMarker, frameOnly: __cmuxFrameOnly, href: location.href, title: document.title})",
                },
            ) or {}
            frame_realm_value = _value(frame_realm_result) or {}
            _must(
                frame_realm_value.get("marker") == "frame",
                f"Expected window to resolve in selected frame: {frame_realm_result}",
            )
            _must(
                frame_realm_value.get("frameOnly") == "frame-global",
                f"Expected frame global to resolve in selected frame: {frame_realm_result}",
            )
            _must(
                str(frame_realm_value.get("href") or "").endswith("#frame"),
                f"Expected location to resolve in selected frame: {frame_realm_result}",
            )
            _must(
                frame_realm_value.get("title") == "frame-title",
                f"Expected document to resolve in selected frame: {frame_realm_result}",
            )
            client._call("browser.frame.main", {"surface_id": surface_id})

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

            custom_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": """
                    (() => {
                      class Payload {
                        constructor() { this.answer = 42; }
                        toJSON() { return 'prototype-hook'; }
                      }
                      return new Payload();
                    })()
                    """,
                },
            ) or {}
            _must(
                _value(custom_result) == {"answer": 42},
                f"Expected a custom instance to become plain JSON data: {custom_result}",
            )

            proto_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": """
                    (() => {
                      const value = Object.create(null);
                      Object.defineProperty(value, '__proto__', {
                        value: 'ordinary-value', enumerable: true
                      });
                      return value;
                    })()
                    """,
                },
            ) or {}
            _must(
                _value(proto_result) == {"__proto__": "ordinary-value"},
                f"Expected own __proto__ data to survive serialization: {proto_result}",
            )

            _expect_circular_reference_error(
                client,
                surface_id,
                "(() => { const value = {}; value.self = value; return value; })()",
            )
            _expect_circular_reference_error(
                client,
                surface_id,
                """
                (() => {
                  const value = new Map();
                  Object.defineProperty(value, 'self', {value, enumerable: true});
                  return value;
                })()
                """,
            )
            _expect_sanitized_script_error(client, surface_id)
            _expect_sanitized_selector_wait_error(client, surface_id)
        finally:
            if surface_id:
                with contextlib.suppress(cmuxError, OSError):
                    client._call("surface.close", {"surface_id": surface_id})

    print(
        "PASS: browser.eval returns bridge-safe objects, explicit cycle errors, "
        "and sanitized script and selector-wait failures"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
