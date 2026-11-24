"""Private owner of one staging chat, on the disposable machine as its normal work user."""

import base64
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
ROOM = "https://share-staging.cmux.dev"
ISSUER = "https://cloud-api-staging.cmux.dev"


class Refusal(Exception):
    """Only fixed step errors and structured protocol codes leave this process."""


def setup():
    home = Path.home()
    if os.getuid() == 0 or Path.cwd() != home:
        raise Refusal("expected_work_user_in_own_home")
    binary = home / ".cmux/bin/cmux-tui"
    if not os.access(binary, os.X_OK):
        binary = shutil.which("cmux-tui")
    if not binary:
        raise Refusal("machine_cmux_binary_missing")
    # Explicit ACPMUX_SOCKET makes this a client of the machine's acpmux. cmux-tui
    # neither starts nor upgrades it (acp.rs::daemon_acpmux_starter / handoff).
    paths = [home / ".cmux/acpmux/acpmux.sock", home / ".acpmux/acpmux.sock"]
    acp = next((p for p in paths if p.is_socket()), None)
    if acp is None:
        raise Refusal("machine_acpmux_socket_missing")
    sock = ROOT / "owner.sock"
    env = {**os.environ, "ACPMUX_SOCKET": str(acp), "CMUX_SHARE_ROOM_URL": ROOM,
           "CMUX_TUI_STATE_DIR": str(ROOT / "state"), "HOME": str(ROOT)}
    proc = subprocess.Popen(
        [binary, "--headless", "--session", ROOT.name, "--socket", sock], env=env, cwd=home,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, umask=0o077,
    )
    for _ in range(150):
        if proc.poll() is not None:
            raise Refusal("private_owner_exited")
        if sock.is_socket():
            return {"ok": True}
        time.sleep(0.1)
    proc.terminate()
    raise Refusal("private_owner_start_timed_out")


def held(record, marker):
    msg = record.get("msg") or {}
    return (record.get("kind") == "queued" and msg.get("awaitingOwner") is True
            and msg.get("text") == marker and str(msg.get("promptId", "")).startswith("g-"))


def drive(stream, request):
    def read():
        line = stream.readline()
        if not line:
            raise Refusal("owner_socket_closed")
        return json.loads(line)

    def call(cmd, on_event=None, **args):
        tag = uuid.uuid4().hex
        stream.write((json.dumps(dict(cmd=cmd, id=tag, **args)) + "\n").encode())
        stream.flush()
        while True:
            frame = read()
            if frame.get("id") == tag:
                if frame.get("ok") is not True:
                    raise Refusal(frame.get("error_code") or "owner_rpc_refused")
                return frame["data"]
            if on_event:
                on_event(frame)

    op = request["operation"]
    if op == "open":
        config = call("agent-session-share-room")
        if config.get("room") != ROOM or config.get("owner_api") != ISSUER:
            raise Refusal("private_owner_did_not_select_staging_room_and_issuer")
        registry = call("identify")["registry_id"]
        workspace = call("create-workspace", name="Staging sharing proof")["workspace"]
        surface = call("new-conversation-tab", workspace=workspace, agent_session={
            "host": "registry:" + registry, "harness": "opencode"
        })["surface"]
        chat = call("agent-session-start", surface=surface, harness="opencode", vm_kind="owner")["session"]
        share = call("agent-session-share-create", surface=surface, session=chat, signed_in_role="talk",
                     role="talk", ttl_secs=900, owner_token=request["token"])
        # Provider exec may retain stdout. Mask the returned link with a fresh pad delivered
        # on the same private stdin as the install token. Neither secret is ever in stdout.
        link = share["url"].encode()
        pad = base64.b64decode(request["link_pad"], validate=True)
        if not 0 < len(link) <= len(pad):
            raise Refusal("invalid_staging_link_length")
        sealed = bytes(a ^ b for a, b in zip(link, pad))
        return {"surface": surface, "share_id": share["share_id"], "sealed_link": base64.b64encode(sealed).decode()}

    if op == "revoke":
        call("agent-session-share-revoke", share_id=request["share_id"])
        return {"ok": True}
    surface, marker = request["surface"], request["text"]
    if op == "prompt":
        call("agent-session-attach", surface=surface, limit=1)
        call("agent-session-prompt", surface=surface, text=marker, prompt_id=uuid.uuid4().hex)
        return {"ok": True}
    if op == "wait_guest":
        seen = False

        def observe(frame):
            nonlocal seen
            if frame.get("surface") != surface:
                return
            if frame.get("event") == "agent-session-closed":
                raise Refusal("owner_chat_attachment_closed")
            if frame.get("event") == "agent-session-record" and held(frame["record"], marker):
                seen = True

        # The daemon may push a newly committed record before the attach response; that
        # snapshot need not contain it. Remember only whether the exact marker has arrived.
        page = call("agent-session-attach", on_event=observe, surface=surface, limit=200)
        if not any(held(record, marker) for record in page["events"]):
            while not seen:
                observe(read())
        return {"ok": True}
    raise Refusal("unknown_operation")


def timed_out(_signal, _frame):
    raise Refusal("owner_socket_timed_out")


if __name__ == "__main__":
    try:
        signal.signal(signal.SIGALRM, timed_out)
        if sys.argv[1:] == ["setup"]:
            signal.alarm(25)
            result = setup()
        else:
            request = json.load(sys.stdin)
            signal.alarm(145 if request["operation"] == "open" else 25)
            with socket.socket(socket.AF_UNIX) as sock:
                sock.connect(str(ROOT / "owner.sock"))
                with sock.makefile("rwb") as stream:
                    result = drive(stream, request)
        print(json.dumps(result), flush=True)
    except Exception as error:
        code = str(error) if isinstance(error, Refusal) else ""
        if not re.fullmatch("[a-z][a-z0-9_.]{1,75}", code):
            code = "staging_owner_command_failed"
        print(json.dumps({"error": code}), flush=True)
        sys.exit(1)
