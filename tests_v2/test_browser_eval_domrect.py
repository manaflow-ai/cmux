#!/usr/bin/env python3
"""Regression: browser.eval returns bridge-safe DOM geometry and normal errors."""

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


def _assert_rect(value, label: str) -> None:
    _must(isinstance(value, dict), f"Expected {label} to be a dictionary: {value!r}")
    expected = {
        "x": 1,
        "y": 2,
        "width": 3,
        "height": 4,
        "top": 2,
        "right": 4,
        "bottom": 6,
        "left": 1,
    }
    for key, expected_value in expected.items():
        _must(
            float(value.get(key)) == expected_value,
            f"Expected {label}.{key}={expected_value}, got {value!r}",
        )


def _expect_eval_error(client: cmux, surface_id: str, script: str) -> None:
    try:
        client._call(
            "browser.eval",
            {
                "surface_id": surface_id,
                "script": script,
            },
        )
    except cmuxError as exc:
        _must("js_error" in str(exc), f"Expected a normal JavaScript error: {exc}")
        return
    raise cmuxError("Expected browser.eval to return a normal evaluation error")


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
                    "script": "new DOMRect(1, 2, 3, 4)",
                },
            ) or {}
            _assert_rect(_value(direct_result), "direct DOMRect")

            nested_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "({bounds: new DOMRect(1, 2, 3, 4), items: [new DOMRect(1, 2, 3, 4)]})",
                },
            ) or {}
            nested_value = _value(nested_result) or {}
            _assert_rect(nested_value.get("bounds"), "nested DOMRect")
            nested_items = nested_value.get("items") or []
            _must(len(nested_items) == 1, f"Expected one nested DOMRect: {nested_result}")
            _assert_rect(nested_items[0], "array DOMRect")

            readonly_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "({available: typeof DOMRectReadOnly !== 'undefined', rect: typeof DOMRectReadOnly === 'undefined' ? null : new DOMRectReadOnly(1, 2, 3, 4)})",
                },
            ) or {}
            readonly_value = _value(readonly_result) or {}
            if readonly_value.get("available"):
                _assert_rect(readonly_value.get("rect"), "DOMRectReadOnly")
            else:
                _must(readonly_value.get("rect") is None, f"Unavailable DOMRectReadOnly should be null: {readonly_result}")

            promised_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "Promise.resolve(new DOMRect(1, 2, 3, 4))",
                },
            ) or {}
            _assert_rect(_value(promised_result), "promised DOMRect")

            cross_realm_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "(() => { const frame = document.createElement('iframe'); document.body.appendChild(frame); const rect = new frame.contentWindow.DOMRect(1, 2, 3, 4); const isCrossRealm = !(rect instanceof DOMRectReadOnly); frame.remove(); return {isCrossRealm, rect}; })()",
                },
            ) or {}
            cross_realm_value = _value(cross_realm_result) or {}
            _must(
                cross_realm_value.get("isCrossRealm") is True,
                f"Expected iframe DOMRect to come from another JavaScript realm: {cross_realm_result}",
            )
            _assert_rect(cross_realm_value.get("rect"), "cross-realm DOMRect")

            ordinary_result = client._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": "({zero: 0, text: 'ordinary', flag: false, empty: null})",
                },
            ) or {}
            _must(
                _value(ordinary_result) == {"zero": 0, "text": "ordinary", "flag": False, "empty": None},
                f"Ordinary eval value changed: {ordinary_result}",
            )

            # Containers created in the other realm also need recursive traversal.
            cross_container = client._call(
                "browser.eval",
                {"surface_id": surface_id, "script": "(() => { const frame = document.createElement('iframe'); document.body.appendChild(frame); const value = frame.contentWindow.eval('({rect: new DOMRect(1, 2, 3, 4)})'); frame.remove(); return value; })()"},
            ) or {}
            _assert_rect(_value(cross_container)["rect"], "cross-realm container DOMRect")

            layout = client._call(
                "browser.eval",
                {"surface_id": surface_id, "script": "(() => { const element = document.createElement('div'); element.style.cssText = 'position:fixed;left:1px;top:2px;width:3px;height:4px'; document.body.appendChild(element); const rect = element.getBoundingClientRect(); element.remove(); return rect; })()"},
            ) or {}
            _assert_rect(_value(layout), "layout DOMRect")

            aliases = client._call(
                "browser.eval",
                {"surface_id": surface_id, "script": "(() => { const shared = {rect: new DOMRect(1, 2, 3, 4)}; return [shared, shared]; })()"},
            ) or {}
            _must(len(_value(aliases)) == 2, f"Missing repeated reference: {aliases}")
            for alias in _value(aliases):
                _assert_rect(alias["rect"], "aliased DOMRect")

            undefined = client._call(
                "browser.eval", {"surface_id": surface_id, "script": "undefined"},
            ) or {}
            _must(_value(undefined) == {"__cmux_t": "undefined", "__cmux_v": None}, f"Undefined changed: {undefined}")
            null = client._call(
                "browser.eval", {"surface_id": surface_id, "script": "null"},
            ) or {}
            _must(_value(null) is None, f"Null changed: {null}")

            for script in (
                "throw new Error('browser-eval-regression-error')",
                "Promise.reject(new Error('browser-eval-regression-error'))",
                "(() => { const value = {}; value.self = value; return value; })()",
                "({get rect() { throw new Error('getter failed'); }})",
            ):
                _expect_eval_error(client, surface_id, script)
            survived_error = client._call(
                "browser.eval",
                {"surface_id": surface_id, "script": "6 * 7"},
            ) or {}
            _must(_value(survived_error) == 42, f"Evaluation did not recover after an error: {survived_error}")
        finally:
            if surface_id:
                try:
                    client._call("surface.close", {"surface_id": surface_id})
                except (cmuxError, OSError):
                    pass

    print("PASS: browser.eval bridges DOMRect values and preserves normal values/errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
