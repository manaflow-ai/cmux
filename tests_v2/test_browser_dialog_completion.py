#!/usr/bin/env python3
"""Native dialog completion while eval blocks on a hidden CLI-driven surface.

Run only against an isolated tagged app with CMUX_SOCKET_PATH set explicitly.
"""

import json
import os

from cmux import cmux, cmuxError
from browser_dialog_test_support import run_with_dialogs


def main():
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    if not socket_path.startswith("/tmp/cmux-debug-"):
        raise RuntimeError("This regression requires an isolated tagged socket")
    with cmux(socket_path) as client:
        focused = client.identify().get("focused")
        workspace = client._call("workspace.create", {"focus": False})["workspace_id"]
        results = []
        try:
            opened = client._call("browser.tab.new", {
                "workspace_id": workspace, "url": "about:blank", "focus": False,
            })
            surface = opened["surface_id"]
            params = {"workspace_id": workspace, "surface_id": surface}
            client._call("browser.eval", {**params, "script": "window.completedDialogs = 0; true"})
            cases = [
                ("confirm('accept')", True, None, True),
                ("confirm('dismiss')", False, None, False),
                ("(alert('alert'), 'done')", True, None, "done"),
                ("(alert('dismiss alert'), 'done')", False, None, "done"),
                ("prompt('prompt', 'initial')", True, "answer", "answer"),
                ("prompt('prompt', 'initial')", True, "", ""),
                ("prompt('prompt', 'initial')", True, None, "initial"),
                ("prompt('prompt', 'initial')", False, None, None),
            ]
            for script, accept, text, expected in cases:
                value, responses = run_with_dialogs(socket_path, "browser.eval", {
                    **params,
                    "script": f"(() => {{ const answer = {script}; window.completedDialogs++; return answer; }})()",
                }, [(accept, text)])
                assert value.get("value") == expected, (script, value)
                assert responses[0]["accepted"] == accept, responses
                assert client.identify().get("focused") == focused, "Dialog changed the selected workspace/surface"
                try:
                    client._call("browser.dialog.dismiss", params)
                except cmuxError as error:
                    assert "not_found" in str(error), str(error)
                else:
                    raise AssertionError("A completed dialog remained pending")
                results.append({"script": script, "result": expected})

            value, responses = run_with_dialogs(socket_path, "browser.eval", {
                **params,
                "script": "[confirm('first'), prompt('second', 'default'), (alert('third'), 'done')]",
            }, [(True, None), (False, None), (True, None)])
            assert value["value"] == [True, None, "done"], value
            assert [r["dialog"]["type"] for r in responses] == ["confirm", "prompt", "alert"]
            count = client._call("browser.eval", {**params, "script": "window.completedDialogs"})
            assert count["value"] == len(cases), count

            # A posted event can raise its dialog after the triggering command has
            # returned. The surface must retain automation ownership.
            armed, _ = run_with_dialogs(socket_path, "browser.eval", {
                **params,
                "script": """(() => {
                    const channel = new MessageChannel();
                    channel.port1.onmessage = () => {
                        window.deferredAnswer = confirm('deferred');
                        channel.port1.close();
                        channel.port2.close();
                    };
                    channel.port2.postMessage(null);
                    return 'armed';
                })()""",
            }, [(True, None)])
            assert armed["value"] == "armed", armed
            assert client._call("browser.eval", {**params, "script": "window.deferredAnswer"})["value"] is True

            # A caller may answer only after its original eval has timed out.
            # Recovery must not replace the document or lose its completion.
            try:
                client._call("browser.eval", {
                    **params, "script": "window.timeoutAnswer = confirm('timeout')",
                })
            except cmuxError as error:
                assert "timed out" in str(error).lower(), str(error)
            else:
                raise AssertionError("Unanswered confirm should keep eval blocked")
            assert client._call("browser.dialog.accept", params)["accepted"] is True
            assert client._call("browser.eval", {**params, "script": "window.timeoutAnswer"})["value"] is True
            assert client.identify().get("focused") == focused
            print(json.dumps({"passed": len(cases) + 3, "hidden_workspace": True,
                              "focus_preserved": True, "results": results}, indent=2))
        finally:
            client.close_workspace(workspace)


if __name__ == "__main__":
    main()
