#!/usr/bin/env python3
"""A deterministic `codex app-server` that replays one recorded-shape turn.

Same fixture for every adapter under test, so the adapter is the only
variable. Env: FIX_DELTAS (agent message deltas, default 4000), FIX_REASON
(reasoning deltas, 200), FIX_OUT (command output deltas, 200), FIX_LOG
(file that gets each method the adapter sent, the approval decision and the
delta count), FIX_TEXT (file that gets the whole agent message).
A prompt with "cancel-me" streams 10 deltas, then waits for turn/interrupt.
No sleeps: it only reacts to what it reads.
"""
import json, os, sys

args = sys.argv[1:]
while len(args) >= 2 and args[0] in ("-c", "--config"):
    args = args[2:]
if not args or args[0] != "app-server":
    sys.stderr.write("usage: codex app-server\n"); sys.exit(2)

N = int(os.environ.get("FIX_DELTAS", "4000"))
NR = int(os.environ.get("FIX_REASON", "200"))
NO = int(os.environ.get("FIX_OUT", "200"))
LOG = open(os.environ["FIX_LOG"], "a") if os.environ.get("FIX_LOG") else None
WORDS = ("## Plan\n\nThe **daemon** keeps one `Translator` per app-server; each "
         "delta becomes one `session/update`. See [the spec](https://agentclientprotocol.com) "
         "and run `cargo test -p acpmux`.\n\n- first item\n- second item with `code`\n\n"
         "```rust\nfn main() { println!(\"hi\"); }\n```\n").split(" ")
inbuf = sys.stdin.buffer

def send(m):
    sys.stdout.write(json.dumps(m, separators=(",", ":")) + "\n"); sys.stdout.flush()

def read():
    line = inbuf.readline()
    if not line: sys.exit(0)
    m = json.loads(line)
    if LOG and "method" in m: LOG.write(m["method"] + "\n"); LOG.flush()
    return m

MODEL = {"id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "gpt-6-astra", "description": "",
         "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": ""}, {"reasoningEffort": "medium", "description": ""}],
         "defaultReasoningEffort": "medium", "isDefault": True, "hidden": False, "inputModalities": ["text", "image"]}
THREAD = "019a0000-0000-7000-8000-000000000001"

def thread(cwd, turns=()):
    return {"id": THREAD, "preview": "", "modelProvider": "openai", "createdAt": 1, "updatedAt": 1, "path": None,
            "cwd": cwd, "cliVersion": "0.162.1", "source": "appServer", "gitInfo": None, "turns": list(turns), "status": {"type": "idle"}}

def ts_result(cwd):
    return {"thread": thread(cwd), "model": "gpt-6-astra", "modelProvider": "openai", "cwd": cwd,
            "approvalPolicy": "on-request", "sandbox": {"type": "workspaceWrite"}, "reasoningEffort": "medium"}

def ev(method, **p): send({"method": method, "params": p})

def turn(rid, params):
    th = params.get("threadId", THREAD); tid = "turn-%s" % rid
    text = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
    tobj = {"id": tid, "status": "inProgress", "items": [], "error": None}
    send({"id": rid, "result": {"turn": tobj}})
    ev("turn/started", threadId=th, turn=tobj)
    if "cancel-me" in text:
        ev("item/started", threadId=th, turnId=tid, item={"type": "agentMessage", "id": "m0", "text": ""})
        for i in range(10):
            ev("item/agentMessage/delta", threadId=th, turnId=tid, itemId="m0", delta=WORDS[i % len(WORDS)] + " ")
        while True:
            m = read()
            if m.get("method") == "turn/interrupt":
                send({"id": m["id"], "result": {}})
                ev("turn/completed", threadId=th, turn=dict(tobj, status="interrupted")); return
            if "id" in m and "method" in m: send({"id": m["id"], "result": {}})
    n_msg = 10 if "short" in text else N
    ev("item/started", threadId=th, turnId=tid, item={"type": "reasoning", "id": "r1", "summary": [], "content": []})
    for i in range(NR):
        ev("item/reasoning/summaryTextDelta", threadId=th, turnId=tid, itemId="r1", summaryIndex=0, delta=WORDS[i % len(WORDS)] + " ")
    ev("item/completed", threadId=th, turnId=tid, item={"type": "reasoning", "id": "r1", "summary": ["thinking"], "content": []})
    cmd = {"type": "commandExecution", "id": "c1", "command": "cargo test -p acpmux", "cwd": os.getcwd(), "processId": None,
           "status": "inProgress", "commandActions": [{"type": "unknown", "command": "cargo test -p acpmux"}],
           "aggregatedOutput": None, "exitCode": None, "durationMs": None}
    ev("item/started", threadId=th, turnId=tid, item=cmd)
    send({"id": "srv-1", "method": "item/commandExecution/requestApproval",
          "params": {"threadId": th, "turnId": tid, "itemId": "c1", "command": "cargo test -p acpmux", "cwd": os.getcwd(), "reason": "run tests"}})
    while True:
        m = read()
        if m.get("id") == "srv-1" and "method" not in m:
            decision = (m.get("result") or {}).get("decision"); break
        if "id" in m and "method" in m: send({"id": m["id"], "result": {}})
    out = []
    for i in range(NO):
        d = "test case_%04d ... ok\n" % i; out.append(d)
        ev("item/commandExecution/outputDelta", threadId=th, turnId=tid, itemId="c1", delta=d)
    ev("item/completed", threadId=th, turnId=tid, item=dict(cmd, status="completed", aggregatedOutput="".join(out), exitCode=0, durationMs=10))
    ev("item/started", threadId=th, turnId=tid, item={"type": "agentMessage", "id": "m1", "text": ""})
    full = []
    for i in range(n_msg):
        d = WORDS[i % len(WORDS)] + " "; full.append(d)
        ev("item/agentMessage/delta", threadId=th, turnId=tid, itemId="m1", delta=d)
    ev("item/completed", threadId=th, turnId=tid, item={"type": "agentMessage", "id": "m1", "text": "".join(full)})
    # Written before the turn ends, so a client that saw the end can read them.
    if LOG:
        LOG.write("approval-decision %s\nagent-deltas %d\n" % (decision, n_msg)); LOG.flush()
    if os.environ.get("FIX_TEXT"):
        with open(os.environ["FIX_TEXT"], "w") as f: f.write("".join(full))
    ev("thread/tokenUsage/updated", threadId=th, turnId=tid, tokenUsage={
        "total": {"totalTokens": N + 100, "inputTokens": 100, "cachedInputTokens": 0, "outputTokens": n_msg, "reasoningOutputTokens": NR},
        "last": {"totalTokens": N + 100, "inputTokens": 100, "cachedInputTokens": 0, "outputTokens": N, "reasoningOutputTokens": NR},
        "modelContextWindow": 400000})
    ev("turn/completed", threadId=th, turn=dict(tobj, status="completed"))

while True:
    m = read()
    if "id" not in m or "method" not in m: continue
    meth, rid, p = m["method"], m["id"], m.get("params") or {}
    cwd = p.get("cwd") or os.getcwd()
    if meth == "initialize":
        send({"id": rid, "result": {"userAgent": "codex_cli_rs/0.162.1 (Linux; x86_64) fake (bench; 1)", "codexHome": os.environ.get("CODEX_HOME", "/tmp")}})
    elif meth == "model/list":
        send({"id": rid, "result": {"data": [MODEL], "nextCursor": None}})
    elif meth == "account/read":
        send({"id": rid, "result": {"account": {"type": "apiKey"}, "requiresOpenaiAuth": False}})
    elif meth == "account/rateLimits/read":
        send({"id": rid, "result": {"rateLimits": {"primary": None, "secondary": None}}})
    elif meth == "config/read":
        send({"id": rid, "result": {"config": {"model": "gpt-6-astra"}, "origins": {}}})
    elif meth in ("thread/start", "thread/fork"):
        send({"id": rid, "result": ts_result(cwd)})
    elif meth in ("thread/resume", "thread/read"):
        hist = [{"id": "turn-old", "status": "completed", "error": None, "items": [
            {"type": "userMessage", "id": "u0", "content": [{"type": "text", "text": "earlier question", "text_elements": []}]},
            {"type": "agentMessage", "id": "a0", "text": "earlier answer"}]}]
        r = ts_result(cwd); r["thread"] = thread(cwd, hist)
        if meth == "thread/read": r = {"thread": r["thread"]}
        send({"id": rid, "result": r})
    elif meth == "turn/start":
        turn(rid, p)
    elif meth in ("mcpServerStatus/list", "thread/list", "thread/loaded/list", "skills/list"):
        send({"id": rid, "result": {"data": [], "nextCursor": None}})
    else:
        send({"id": rid, "result": {}})
