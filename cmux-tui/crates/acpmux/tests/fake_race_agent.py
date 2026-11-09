#!/usr/bin/env python3
"""Hermetic ACP race fixture: real worktree writes and an event-driven overlap barrier."""
import json
import os
import pathlib
import socket
import sys
import threading

model = "a"
cwd = None
cancel = threading.Event()
output_lock = threading.Lock()


def send(value):
    with output_lock:
        print(json.dumps({"jsonrpc": "2.0", **value}), flush=True)


def prompt(request):
    params = request["params"]
    # The task's own blocks: acpmux appends context blocks (`_meta.acpmux.context`) after them.
    # A race child's task comes from its parent agent, so acpmux puts its sender mark
    # ("From another agent (...), not the person:", #37190) first, in a block tagged
    # `_meta.acpmux.attribution`: skip it too.
    def task_block(block):
        mux = (block.get("_meta") or {}).get("acpmux", {})
        return not (mux.get("context") or mux.get("attribution") is True)
    text = "".join(block.get("text", "") for block in params.get("prompt", []) if task_block(block))
    if model in ("review", "invalid"):
        candidates = json.loads(text.split("\nCandidates:\n", 1)[1])
        # Read the files, not the summaries. Model a writes the expected implementation.
        winner = next(c["id"] for c in candidates
                      if pathlib.Path(c["worktree"], "implementation.txt").read_text() == "a")
        reply = json.dumps({"winnerId": winner if model == "review" else "not-a-candidate",
                            "reason": "Read implementation.txt in each candidate worktree"})
    else:
        pathlib.Path(cwd, "implementation.txt").write_text(model)
        first = text.splitlines()[0]
        if first.startswith("barrier:"):
            with socket.socket(socket.AF_UNIX) as barrier:
                barrier.settimeout(25)
                barrier.connect(first.removeprefix("barrier:"))
                barrier.sendall(model.encode())
                barrier.recv(1)
        elif first == "hold":
            cancel.wait(25)
        reply = f"Wrote implementation.txt as {model}"
    send({"method": "session/update", "params": {"sessionId": params["sessionId"],
          "update": {"sessionUpdate": "agent_message_chunk",
                     "content": {"type": "text", "text": reply}}}})
    send({"id": request["id"], "result": {
        "stopReason": "cancelled" if cancel.is_set() else "end_turn"}})


for line in sys.stdin:
    request = json.loads(line)
    method, params, rid = request.get("method"), request.get("params", {}), request.get("id")
    if method == "initialize":
        # FAKE_ASK_CLAIM=1: it says it asks before every tool call (it runs none), so any acpmux
        # policy holds on it. Off by default, as in fake_agent.py.
        caps = {"loadSession": True}
        if os.environ.get("FAKE_ASK_CLAIM") == "1":
            caps["_meta"] = {"acpmux": {"asksBeforeTools": True}}
        send({"id": rid, "result": {"protocolVersion": 1, "agentCapabilities": caps, "authMethods": []}})
    elif method in ("session/new", "session/load"):
        cwd = params["cwd"]
        send({"id": rid, "result": {"sessionId": "race-fixture",
              "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}]},
              "models": {"currentModelId": model, "availableModels": [
                  {"modelId": item, "name": item} for item in ("a", "b", "review", "invalid")]}}})
    elif method == "session/set_model":
        model = params["modelId"]
        send({"id": rid, "result": {}})
    elif method == "session/prompt":
        cancel.clear()
        threading.Thread(target=prompt, args=(request,), daemon=True).start()
    elif method == "session/cancel":
        cancel.set()
        if rid is not None:
            send({"id": rid, "result": {}})
    elif rid is not None:
        send({"id": rid, "result": {}})
