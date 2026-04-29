#!/usr/bin/env python3
"""Browser key-event delivery regression coverage.

This test uses debug.shortcut.simulate instead of debug.type. The former sends a
synthetic NSEvent through NSApp, which exercises NSWindow.performKeyEquivalent
and WebKit keyDown routing. The latter calls insertText directly and would miss
the swallowed-space failure mode.
"""

import os
import sys
import time
from typing import Any, Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _wait_until(
    predicate: Callable[[], bool],
    *,
    timeout_s: float,
    label: str,
) -> None:
    deadline = time.time() + timeout_s
    last_exc: Optional[Exception] = None
    while time.time() < deadline:
        try:
            if predicate():
                return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.05)
    if last_exc is not None:
        raise cmuxError(f"Timed out waiting for {label}: {last_exc}")
    raise cmuxError(f"Timed out waiting for {label}")


def _value(payload: dict[str, Any]) -> Any:
    return (payload or {}).get("value")


def _focused_pane_id(client: cmux) -> Optional[str]:
    for _idx, pane_id, _surface_count, focused in client.list_panes():
        if focused:
            return pane_id
    return None


def _browser_eval(client: cmux, surface_id: str, script: str) -> Any:
    return _value(client._call("browser.eval", {"surface_id": surface_id, "script": script}) or {})


def _state(client: cmux, surface_id: str) -> dict[str, Any]:
    state = _browser_eval(
        client,
        surface_id,
        """
        (() => {
          const search = document.querySelector('#search');
          const active = document.activeElement;
          return {
            value: search ? search.value : null,
            selectionStart: search ? search.selectionStart : null,
            selectionEnd: search ? search.selectionEnd : null,
            active: active ? (active.id || active.tagName || '') : '',
            events: (window.__cmuxKeyEvents || []).slice(-16),
          };
        })()
        """,
    )
    _must(isinstance(state, dict), f"Expected browser state dict, got: {state!r}")
    return state


def _install_test_page(client: cmux, surface_id: str) -> None:
    result = _browser_eval(
        client,
        surface_id,
        """
        (() => {
          document.title = 'cmux-space-key-event-delivery';
          document.body.innerHTML = `
            <main>
              <input id="search" autocomplete="off" autocapitalize="off" spellcheck="false">
            </main>
          `;
          const search = document.querySelector('#search');
          window.__cmuxKeyEvents = [];
          const activeName = () => {
            const active = document.activeElement;
            return active ? (active.id || active.tagName || '') : '';
          };
          const record = (type, event) => {
            window.__cmuxKeyEvents.push({
              type,
              key: event.key || event.data || '',
              code: event.code || event.inputType || '',
              value: search.value,
              selectionStart: search.selectionStart,
              selectionEnd: search.selectionEnd,
              active: activeName(),
            });
            if (window.__cmuxKeyEvents.length > 80) {
              window.__cmuxKeyEvents.shift();
            }
          };
          document.addEventListener('keydown', (event) => record('keydown', event), true);
          document.addEventListener('beforeinput', (event) => record('beforeinput', event), true);
          document.addEventListener('input', (event) => record('input', event), true);
          document.addEventListener('keyup', (event) => record('keyup', event), true);
          search.focus();
          search.setSelectionRange(search.value.length, search.value.length);
          return { ready: true, active: activeName() };
        })()
        """,
    )
    _must(isinstance(result, dict) and result.get("ready") is True, f"Failed to install browser fixture: {result!r}")


def _focus_browser_input(client: cmux, surface_id: str) -> None:
    client.focus_webview(surface_id)
    client.wait_for_webview_focus(surface_id, timeout_s=5.0)
    client._call("browser.focus", {"surface_id": surface_id, "selector": "#search"})
    _wait_until(
        lambda: _state(client, surface_id).get("active") == "search",
        timeout_s=3.0,
        label="browser input DOM focus",
    )


def _combo_for_char(ch: str) -> str:
    if ch == " ":
        return "space"
    if len(ch) == 1 and ch.lower() in "abcdefghijklmnopqrstuvwxyz0123456789":
        return ch.lower()
    raise cmuxError(f"Unsupported synthetic key character: {ch!r}")


def _type_via_appkit_key_events(client: cmux, surface_id: str, text: str) -> None:
    expected = str(_state(client, surface_id).get("value") or "")
    for ch in text:
        expected += ch
        before = _state(client, surface_id)
        client.simulate_shortcut(_combo_for_char(ch))

        def delivered() -> bool:
            current = _state(client, surface_id)
            return (
                current.get("value") == expected
                and current.get("selectionStart") == len(expected)
                and current.get("selectionEnd") == len(expected)
            )

        try:
            _wait_until(delivered, timeout_s=1.5, label=f"input value/caret after {ch!r}")
        except cmuxError as exc:
            after = _state(client, surface_id)
            raise cmuxError(
                "Browser key event did not update native input value/caret.\n"
                f"key={ch!r} combo={_combo_for_char(ch)!r} expected_value={expected!r}\n"
                f"before={before}\n"
                f"after={after}"
            ) from exc


def _open_two_pane_browser_workspace(client: cmux) -> tuple[str, str, str]:
    workspace_id = client.new_workspace()
    client.select_workspace(workspace_id)

    _wait_until(
        lambda: any(bool(row.get("in_window")) and row.get("type") == "terminal" for row in client.surface_health()),
        timeout_s=5.0,
        label="fresh terminal workspace in window",
    )

    browser_surface_id = client.open_browser("about:blank")
    _wait_until(
        lambda: str(
            _browser_eval(client, browser_surface_id, "document.readyState")
        ).lower()
        == "complete",
        timeout_s=5.0,
        label="about:blank browser document ready",
    )
    _install_test_page(client, browser_surface_id)
    _focus_browser_input(client, browser_surface_id)

    panes = client.list_panes()
    _must(len(panes) == 2, f"Expected 2 panes in fresh workspace, got: {panes}")
    browser_pane_id = _focused_pane_id(client)
    terminal_pane_id = next((pane_id for _idx, pane_id, _count, _focused in panes if pane_id != browser_pane_id), None)
    _must(browser_pane_id is not None, f"Could not identify focused browser pane: {panes}")
    _must(terminal_pane_id is not None, f"Could not identify terminal pane: {panes}")
    return browser_surface_id, str(browser_pane_id), str(terminal_pane_id)


def test_space_delivery_to_focused_input(client: cmux) -> tuple[bool, str]:
    browser_surface_id, _browser_pane_id, _terminal_pane_id = _open_two_pane_browser_workspace(client)
    _type_via_appkit_key_events(client, browser_surface_id, "red blue")
    state = _state(client, browser_surface_id)
    return True, f"value={state.get('value')!r} selectionStart={state.get('selectionStart')}"


def test_space_delivery_after_pane_focus_spam(client: cmux) -> tuple[bool, str]:
    browser_surface_id, browser_pane_id, terminal_pane_id = _open_two_pane_browser_workspace(client)
    _type_via_appkit_key_events(client, browser_surface_id, "left right")

    for _ in range(30):
        client.focus_pane(terminal_pane_id)
        client.focus_pane(browser_pane_id)
        client.focus_webview(browser_surface_id)

    client.wait_for_webview_focus(browser_surface_id, timeout_s=5.0)
    _wait_until(
        lambda: _state(client, browser_surface_id).get("active") == "search",
        timeout_s=3.0,
        label="browser input focus after pane focus spam",
    )

    _type_via_appkit_key_events(client, browser_surface_id, " space")
    state = _state(client, browser_surface_id)
    _must(state.get("value") == "left right space", f"Unexpected final state: {state}")
    return True, f"value={state.get('value')!r} selectionStart={state.get('selectionStart')}"


def main() -> int:
    print("cmux browser space key event delivery tests")
    print(f"socket={SOCKET_PATH}")

    tests = [
        ("space delivery to focused browser input", test_space_delivery_to_focused_input),
        ("space delivery after 30 pane focus alternations", test_space_delivery_after_pane_focus_spam),
    ]

    failed = 0
    with cmux(SOCKET_PATH) as client:
        for name, fn in tests:
            try:
                ok, message = fn(client)
            except Exception as exc:  # noqa: BLE001
                ok, message = False, str(exc)
            status = "PASS" if ok else "FAIL"
            print(f"{status}: {name} - {message}")
            if not ok:
                failed += 1

    if failed:
        print(f"\n{failed} test(s) failed.")
        return 1
    print("\nAll tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
