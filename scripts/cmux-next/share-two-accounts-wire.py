"""Run on the flow's disposable Cloud machine, using its real owner's Unix socket."""

import base64
import json
import os
import re
import signal
import socket
import sys
import uuid

ROOM = "https://share-staging.cmux.dev"
OWNER_API = "https://cloud-api-staging.cmux.dev"


def held_guest(record, marker):
    msg = record.get("msg") or {}
    return (
        record.get("kind") == "queued"
        and msg.get("awaitingOwner") is True
        and msg.get("text") == marker
        and str(msg.get("promptId", "")).startswith("g-")
    )


def drive(stream, request):
    def read():
        line = stream.readline()
        if not line:
            raise ValueError("owner_socket_closed")
        return json.loads(line)

    def call(cmd, **args):
        request_id = uuid.uuid4().hex
        stream.write((json.dumps(dict(cmd=cmd, id=request_id, **args)) + "\n").encode())
        stream.flush()
        while True:
            reply = read()
            if reply.get("id") != request_id:
                continue
            if reply.get("ok") is not True:
                code = reply.get("error_code", "")
                raise ValueError(code if re.fullmatch(r"[a-z][a-z0-9_.]{1,75}", code) else "owner_rpc_refused")
            return reply["data"]

    op = request["operation"]
    if op == "open":
        room = call("agent-session-share-room")
        if room.get("room") != ROOM or room.get("owner_api") != OWNER_API:
            raise ValueError("owner_daemon_not_using_staging_room")
        registry = call("identify")["registry_id"]
        workspace = call("create-workspace", name="Chat sharing")["workspace"]
        surface = call("new-conversation-tab", workspace=workspace, agent_session={
            "host": "registry:" + registry, "harness": "opencode"
        })["surface"]
        session = call("agent-session-start", surface=surface, harness="opencode", vm_kind="owner")["session"]
        share = call("agent-session-share-create", surface=surface, session=session, ttl_secs=600,
                     signed_in_role="talk", role="talk", owner_token=request["token"])
        # Machine exec captures stdout. The job passes a fresh, single-use pad on secret
        # stdin so the share URL (including its link secret) never appears in that capture.
        link = share["url"].encode()
        pad = base64.b64decode(request["link_pad"], validate=True)
        if len(link) > len(pad):
            raise ValueError("share_link_too_long")
        encrypted = bytes(a ^ b for a, b in zip(link, pad))
        return {"surface": surface, "share_id": share["share_id"],
                "sealed_link": base64.b64encode(encrypted).decode("ascii")}
    if op == "revoke":
        call("agent-session-share-revoke", share_id=request["share_id"])
        return {"ok": True}
    surface, marker = request["surface"], request["text"]
    page = call("agent-session-attach", surface=surface, limit=200 if op == "wait_guest" else 1)
    if op == "prompt":
        call("agent-session-prompt", surface=surface, prompt_id=uuid.uuid4().hex, text=marker)
        return {"ok": True}
    if op == "wait_guest":
        if any(held_guest(r, marker) for r in page.get("events", [])):
            return {"ok": True}
        while True:
            event = read()
            if event.get("event") == "agent-session-closed":
                raise ValueError("owner_chat_attachment_closed")
            if event.get("event") == "agent-session-record" and held_guest(event["record"], marker):
                return {"ok": True}
    raise ValueError("unknown_operation")


if __name__ == "__main__":
    # No frame, transcript, share link, or exception payload enters a diagnostic.
    request = json.load(sys.stdin)
    def timed_out(_signum, _frame):
        raise ValueError("owner_socket_timed_out")

    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(150 if request["operation"] == "open" else 25)
    try:
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(os.path.join(os.path.dirname(__file__), "owner.sock"))
            with sock.makefile("rwb") as stream:
                result = drive(stream, request)
        print(json.dumps(result), flush=True)
    except Exception as error:
        safe_code = str(error)
        if not isinstance(error, ValueError) or not re.fullmatch(r"[a-z][a-z0-9_.]{1,75}", safe_code):
            safe_code = "owner_socket_request_failed"
        print(json.dumps({"error": safe_code}), flush=True)
        sys.exit(1)
