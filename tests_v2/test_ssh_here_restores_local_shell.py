#!/usr/bin/env python3
"""SSH --here keeps the pane/group and returns to the original running shell.

Requires an already launched tagged app: CMUX_TAG, CMUX_SOCKET_PATH,
CMUXTERM_CLI, and a disposable Linux CMUX_SSH_TEST_HOST with cmux-tui/python3.
Optional host settings match test_ssh_tui_workspace_selection.py. Never targets
the default socket, launches an app, or examines unrelated terminal output.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import tempfile
import time

from cmux import cmux


REMOTE = r"""
import os, signal, sys
# A failed test or deliberate detach must not leave a fixture workload alive.
signal.alarm(60)
token = sys.argv[1]
print('@' + token + ':remote=' + str(os.getpid()), flush=True)
for line in sys.stdin:
    if line.strip() == token + ':quit':
        break
    if line.strip() == token + ':ping':
        print('@' + token + ':pong=' + str(os.getpid()), flush=True)
"""


def main() -> None:
    tag = os.environ["CMUX_TAG"]
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)+", tag), "Use an isolated dev tag"
    socket_path = os.environ["CMUX_SOCKET_PATH"]
    assert socket_path == f"/tmp/cmux-debug-{tag}.sock", "Socket must match the tag"
    cli = Path(os.environ["CMUXTERM_CLI"]).resolve(strict=True)
    host = os.environ["CMUX_SSH_TEST_HOST"]
    token = secrets.token_hex(8)
    evidence = {"tag": tag, "head": os.environ.get("CMUX_TEST_SHA"), "visits": []}
    continuation_file = Path(tempfile.gettempdir()) / ("cmux-here-continuation-" + token)
    with cmux(socket_path) as client:
        def identify():
            identity = client._call("system.identify")
            assert identity["socket_path"] == socket_path, "Unexpected running app socket"
            bundle = Path(identity["app_bundle_path"]).resolve(strict=True)
            assert bundle.name == f"cmux DEV {tag}.app", "Refusing an untagged app"
            with (bundle / "Contents/Info.plist").open("rb") as file:
                metadata = plistlib.load(file)
            assert metadata["CFBundleIdentifier"] == identity["bundle_identifier"]
            assert cli == bundle / "Contents/Resources/bin/cmux", "CLI/app artifact mismatch"
            return identity

        def mutate(method, params):
            identify()
            return client._call(method, params)

        def wait_for(predicate, message, timeout=90):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                result = predicate()
                if result:
                    return result
                time.sleep(0.05)
            raise AssertionError(message)

        def line(surface, pattern):
            for text in client.read_terminal_text(surface).splitlines():
                match = re.fullmatch(pattern, text.strip())
                if match:
                    return match
            return None

        evidence["identity"] = identify()
        window = mutate("window.create", {})["window_id"]
        try:
            def workspaces():
                return client._call("workspace.list", {"window_id": window})["workspaces"]

            workspace = workspaces()[0]["id"]
            group = mutate("workspace.group.create", {
                "window_id": window, "name": "SSH here regression", "child_workspace_ids": [workspace],
            })["group"]["id"]
            original_workspaces = [row["id"] for row in workspaces()]

            def surfaces():
                return client._call("surface.list", {"workspace_id": workspace})["surfaces"]

            def pane_ids():
                return [row["id"] for row in client._call("pane.list", {"workspace_id": workspace})["panes"]]

            local_surface = surfaces()[0]["id"]
            original_panes = pane_ids()

            def send(surface, text):
                mutate("surface.send_text", {"workspace_id": workspace, "surface_id": surface, "text": text})

            def check_location():
                assert [row["id"] for row in workspaces()] == original_workspaces, "SSH here created/replaced a workspace"
                assert next(row for row in workspaces() if row["id"] == workspace)["group_id"] == group
                assert pane_ids() == original_panes, "SSH here replaced the Bonsplit pane"

            # A shell-local value plus $$ proves the process survived; a new
            # shell in the same panel cannot manufacture either value.
            # Enter a known POSIX shell first: the user's configured login
            # shell may be fish and must not determine this fixture's syntax.
            send(local_surface, shlex.join(["/bin/sh", "-c", f"printf '\\n@{token}:posix-ready\\n'; exec /bin/sh"]) + "\n")
            wait_for(lambda: line(local_surface, "@" + token + ":posix-ready"),
                     "The fixture's POSIX shell did not start", 15)
            send(local_surface, f"CMUX_HERE_PROBE={shlex.quote(token)}; printf '\\n@%s:local=%s\\n' \"$CMUX_HERE_PROBE\" \"$$\"\n")
            local_pid = wait_for(lambda: line(local_surface, "@" + token + r":local=(\d+)"),
                                 "Original shell did not answer", 15).group(1)

            # Two visits exercise normal process exit and explicit disconnect.
            # Each CLI runs in the actual original terminal shell, not in a
            # subprocess with invented CMUX_WORKSPACE_ID/CMUX_SURFACE_ID values.
            for sequence, finish in enumerate(("exit", "disconnect")):
                visit = token + str(sequence)
                command = shlex.join(["python3", "-u", "-c", REMOTE, visit])
                args = [str(cli), "--socket", socket_path, "ssh", "--here", host, "--command", command]
                if os.environ.get("CMUX_SSH_TEST_PORT"):
                    args += ["--port", os.environ["CMUX_SSH_TEST_PORT"]]
                if os.environ.get("CMUX_SSH_TEST_IDENTITY"):
                    args += ["--identity", os.environ["CMUX_SSH_TEST_IDENTITY"]]
                options = json.loads(os.environ.get("CMUX_SSH_TEST_OPTIONS_JSON", "[]"))
                assert isinstance(options, list) and all(isinstance(option, str) for option in options)
                for option in options:
                    args += ["--ssh-option", option]
                continuation_file.unlink(missing_ok=True)
                continuation = (f"printf '\\n@%s:return-{sequence}=%s\\n' \"$CMUX_HERE_PROBE\" \"$$\"; "
                                + "printf resumed > " + shlex.quote(str(continuation_file)))
                send(local_surface, shlex.join(args) + "; " + continuation + "\n")
                remote_surface = wait_for(
                    lambda: next((row["id"] for row in surfaces() if row["id"] != local_surface), None),
                    "SSH here did not install a remote terminal",
                )
                remote_pid = wait_for(lambda: line(remote_surface, "@" + visit + r":remote=(\d+)"),
                                      "Remote workload did not produce output").group(1)
                check_location()
                send(remote_surface, visit + ":ping\n")
                wait_for(lambda: line(remote_surface, "@" + visit + ":pong=" + remote_pid),
                         "Native remote terminal did not accept input", 10)
                assert not continuation_file.exists(), "Chained local command ran while SSH was active"
                if finish == "exit":
                    send(remote_surface, visit + ":quit\n")
                else:
                    # Disconnect intentionally retains the daemon terminal.
                    # The fixture's alarm bounds its remaining lifetime.
                    mutate("workspace.remote.disconnect", {"workspace_id": workspace, "clear": True})
                wait_for(lambda: any(row["id"] == local_surface for row in surfaces()),
                         "Original local surface was not restored", 15)
                wait_for(lambda: line(local_surface, "@" + token + f":return-{sequence}=" + local_pid),
                         "The original local shell/continuation did not resume", 15)
                wait_for(continuation_file.exists, "Chained command did not resume after SSH", 5)
                check_location()
                send(local_surface, f"printf '\\n@%s:input-{sequence}=%s\\n' \"$CMUX_HERE_PROBE\" \"$$\"\n")
                wait_for(lambda: line(local_surface, "@" + token + f":input-{sequence}=" + local_pid),
                         "Restored local shell did not accept input", 10)
                evidence["visits"].append({"finish": finish, "workspace": workspace, "pane_ids": original_panes,
                                           "group": group, "local_surface": local_surface,
                                           "local_pid": local_pid, "remote_surface": remote_surface,
                                           "remote_pid": remote_pid})
            evidence["result"] = "same workspace, pane, group and running local shell after exit/disconnect"
        finally:
            mutate("window.close", {"window_id": window})
            continuation_file.unlink(missing_ok=True)
            print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
