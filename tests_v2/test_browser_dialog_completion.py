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
            assert client.identify().get("focused") == focused
            print(json.dumps({"passed": len(cases) + 1, "hidden_workspace": True,
                              "focus_preserved": True, "results": results}, indent=2))
        finally:
            client.close_workspace(workspace)


if __name__ == "__main__":
    main()
