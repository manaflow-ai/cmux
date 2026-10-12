#!/usr/bin/env python3
"""Native picker socket behavior; requires an explicit isolated tagged socket.

Successful picks deliberately require native user gestures and belong in UI tests.
This suite checks native state isolation, bounded worker waits, and cancellation.
"""

import concurrent.futures
import json
import os
import socket
import threading
import time

from cmux import cmux


def wait_request(socket_path, params, sent):
    """Use a separate connection so a blocked response cannot serialize probes."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(7)
        connection.connect(socket_path)
        request = {"id": 1, "method": "browser.picked.wait", "params": params}
        connection.sendall((json.dumps(request) + "\n").encode())
        sent.set()
        data = bytearray()
        while b"\n" not in data:
            chunk = connection.recv(65536)
            assert chunk, "Picker wait socket closed without a response"
            data.extend(chunk)
        return json.loads(bytes(data).split(b"\n", 1)[0])


def error_code(response):
    assert response.get("ok") is False, response
    return (response.get("error") or {}).get("code")


def open_browser(client, workspace):
    result = client._call("browser.tab.new", {
        "workspace_id": workspace, "url": "about:blank", "focus": False,
    })
    params = {"workspace_id": workspace, "surface_id": result["surface_id"]}
    client._call("browser.wait", {**params, "load_state": "complete", "timeout_ms": 5000})
    return params


def assert_fields(result, params):
    assert result["workspace_id"] == params["workspace_id"], result
    assert result["surface_id"] == params["surface_id"], result
    assert result["workspace_ref"].startswith("workspace:"), result
    assert result["surface_ref"].startswith("surface:"), result


def main():
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    assert socket_path.startswith("/tmp/cmux-debug-") and socket_path.endswith(".sock"), \
        "Use an isolated tagged Debug socket explicitly"
    with cmux(socket_path) as client, concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        focused = client.identify().get("focused")
        workspace = client._call("workspace.create", {"focus": False})["workspace_id"]
        try:
            params = open_browser(client, workspace)
            result = client._call("browser.picked", params)
            assert_fields(result, params)
            assert result["picked"] is False and result["element"] is None, result
            client._call("browser.eval", {**params, "script": """(() => {
                window.__cmuxPointedElement = {xpath:'/html/body', text:'forged',
                                               tag:'BODY', timestamp_ms:Date.now()};
                return true;
            })()"""})
            result = client._call("browser.picked", params)
            assert result["picked"] is False and result["element"] is None, result
            cleared = client._call("browser.picked.clear", params)
            assert_fields(cleared, params)
            assert cleared["cleared"] is True, cleared

            sent = threading.Event()
            started = time.monotonic()
            waiting = pool.submit(wait_request, socket_path, {**params, "timeout_ms": 700}, sent)
            assert sent.wait(2), "Wait request was not sent"
            probe_started = time.monotonic()
            assert client.identify().get("focused") == focused
            assert time.monotonic() - probe_started < 0.5, "Picker wait held the UI/control plane"
            assert error_code(waiting.result(timeout=3)) == "timeout"
            assert time.monotonic() - started >= 0.5, "No-selection wait returned immediately"

            for action in ("clear", "navigate", "close"):
                params = open_browser(client, workspace)
                sent_events = [threading.Event(), threading.Event()]
                futures = [pool.submit(wait_request, socket_path,
                                       {**params, "timeout_ms": 5000}, event)
                           for event in sent_events]
                assert all(event.wait(2) for event in sent_events), "Concurrent wait requests were not sent"
                # Socket sends precede worker registration. Keep the UI answering
                # real requests during that scheduling window, rather than sleep.
                registration_deadline = time.monotonic() + 0.25
                while time.monotonic() < registration_deadline:
                    assert client.identify().get("focused") == focused
                assert all(not future.done() for future in futures), "Wait returned before cancellation"
                if action == "clear":
                    client._call("browser.picked.clear", params)
                elif action == "navigate":
                    client._call("browser.navigate", {**params, "url": "data:text/html,<p>new document</p>"})
                else:
                    client._call("surface.close", params)
                responses = [future.result(timeout=2) for future in futures]
                assert all(error_code(response) == "cancelled" for response in responses), (action, responses)
                assert client.identify().get("focused") == focused, action
                if action != "close":
                    client._call("surface.close", params)
            print(json.dumps({"passed": True, "native_state_isolated": True,
                              "wait_responsive": True, "concurrent_cancellations": 6,
                              "focus_preserved": True}))
        finally:
            client.close_workspace(workspace)


if __name__ == "__main__":
    main()
