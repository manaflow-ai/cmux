#!/usr/bin/env python3
"""A deterministic `codex app-server` that replays one recorded-shape turn.

Same fixture for every adapter under test, so the adapter is the only
variable. Env: FIX_DELTAS (agent message deltas, default 4000), FIX_REASON
(reasoning deltas, 200), FIX_OUT (command output deltas, 200), FIX_LOG
(file that gets each method the adapter sent, command params, the approval
decision and the delta count), FIX_TEXT (file that gets the whole agent
message). Command methods (skills, mcp, review, compact, goal, rename,
logout, settings, title thread) answer as codex 0.162 does.
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
# Command methods whose params the log keeps (the oracle compares them).
CMD_LOG = {"thread/compact/start": [], "review/start": ["target", "delivery"], "thread/name/set": ["name"],
           "account/logout": [], "skills/list": [], "mcpServerStatus/list": [], "account/rateLimits/read": [],
           "thread/goal/set": ["objective", "status"], "thread/goal/clear": [], "thread/settings/update": ["collaborationMode"]}

def send(m):
    sys.stdout.write(json.dumps(m, separators=(",", ":")) + "\n"); sys.stdout.flush()

def read():
    line = inbuf.readline()
    if not line: sys.exit(0)
    m = json.loads(line)
    if LOG and "method" in m:
        meth = m["method"]
        if meth in CMD_LOG:
            LOG.write("%s %s\n" % (meth, json.dumps({k: (m.get("params") or {}).get(k) for k in CMD_LOG[meth]}, sort_keys=True)))
        else:
            LOG.write(meth + "\n")
        LOG.flush()
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

def simple_reply(th, tid, text):
    ev("item/started", threadId=th, turnId=tid, item={"type": "agentMessage", "id": "a-" + tid, "text": ""})
    ev("item/agentMessage/delta", threadId=th, turnId=tid, itemId="a-" + tid, delta=text)
    ev("item/completed", threadId=th, turnId=tid, item={"type": "agentMessage", "id": "a-" + tid, "text": text})

TURNS = [0]
STATE = {}
HELD = []
def command_turn(th, kind, reply=None):
    TURNS[0] += 1
    tid = "turn-cmd-%d" % TURNS[0]
    tobj = {"id": tid, "status": "inProgress", "items": [], "error": None}
    return tid, tobj

def run_command_turn(th, tid, tobj, items):
    ev("turn/started", threadId=th, turn=tobj)
    for it in items:
        if it[0] == "item":
            ev("item/started", threadId=th, turnId=tid, item=it[1]); ev("item/completed", threadId=th, turnId=tid, item=it[1])
        elif it[0] == "say":
            simple_reply(th, tid, it[1])
        elif it[0] == "compacted":
            ev("thread/compacted", threadId=th, turnId=tid)
    ev("turn/completed", threadId=th, turn=dict(tobj, status="completed"))

def turn(rid, params):
    th = params.get("threadId", THREAD); tid = "turn-%s" % rid
    text = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
    tobj = {"id": tid, "status": "inProgress", "items": [], "error": None}
    collab = (params.get("collaborationMode") or {}).get("mode")
    if LOG: LOG.write("turn/start collaborationMode=%s text=%s\n" % (collab, json.dumps(text))); LOG.flush()
    send({"id": rid, "result": {"turn": tobj}})
    ev("turn/started", threadId=th, turn=tobj)
    if th.startswith("title-thread-"):
        if LOG: LOG.write("title-turn model=%s schema=%s\n" % (params.get("model"), bool(params.get("outputSchema")))); LOG.flush()
        msg = json.dumps({"title": "Greeting from the oracle"})
        simple_reply(th, tid, msg)
        # As codex does: turn/completed carries the last agent message (itemsView summary).
        ev("turn/completed", threadId=th, turn=dict(tobj, status="completed", itemsView="summary",
           items=[{"type": "agentMessage", "id": "a-" + tid, "text": msg}]))
        return
    if collab == "plan" or "plan-turn" in text or "short" in text or "hello" in text or "Implement the approved plan" in text:
        if collab == "plan":
            plan = "1. Read the code\n2. Change it\n3. Test it"
            ev("item/started", threadId=th, turnId=tid, item={"type": "plan", "id": "p1", "text": ""})
            ev("item/completed", threadId=th, turnId=tid, item={"type": "plan", "id": "p1", "text": plan})
        else:
            simple_reply(th, tid, "done: " + text)
        ev("turn/completed", threadId=th, turn=dict(tobj, status="completed"))
        return
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
        send({"id": rid, "result": {"account": {"type": "chatgpt", "email": "dev@example.com", "planType": "pro"}, "requiresOpenaiAuth": True}})
    elif meth == "account/rateLimits/read":
        send({"id": rid, "result": {"rateLimits": {"limitId": "codex", "limitName": None, "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": None},
              "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": None}, "credits": None, "planType": "pro"}, "rateLimitsByLimitId": None}})
    elif meth == "account/logout":
        send({"id": rid, "result": {}})
        ev("account/updated", authMode=None, planType=None)
    elif meth == "skills/list":
        send({"id": rid, "result": {"data": [{"cwd": cwd, "skills": [
            {"name": "deploy", "description": "Deploy the app to staging", "shortDescription": "Deploy", "path": "/s/deploy/SKILL.md", "scope": "user", "enabled": True},
            {"name": "triage", "description": "Triage a bug report", "path": "/s/triage/SKILL.md", "scope": "repo", "enabled": True}], "errors": []}]}})
    elif meth == "mcpServerStatus/list":
        send({"id": rid, "result": {"data": [{"name": "docs", "tools": {"search": {}, "fetch": {}}, "resources": [{"uri": "x"}], "resourceTemplates": [], "authStatus": "unsupported"}], "nextCursor": None}})
    elif meth == "thread/name/set" and p.get("name") == "die":
        sys.exit(1)
    elif meth == "thread/name/set":
        send({"id": rid, "result": {}})
        ev("thread/name/updated", threadId=p.get("threadId"), threadName=p.get("name"))
    elif meth == "thread/compact/start":
        th = p.get("threadId"); tid, tobj = command_turn(th, "compact")
        send({"id": rid, "result": {}})
        run_command_turn(th, tid, tobj, [("item", {"type": "contextCompaction", "id": "cc-" + tid}), ("compacted",)])
    elif meth == "review/start":
        th = p.get("threadId"); tid, tobj = command_turn(th, "review")
        send({"id": rid, "result": {"turn": tobj, "reviewThreadId": th}})
        run_command_turn(th, tid, tobj, [("item", {"type": "enteredReviewMode", "id": "rv-in-" + tid, "review": "changes"}),
                                         ("say", "Review: no issues found."), ("item", {"type": "exitedReviewMode", "id": "rv-out-" + tid, "review": "ok"})])
    elif meth == "thread/goal/set":
        th = p.get("threadId")
        status = p.get("status") or "active"
        if "already-done" in (p.get("objective") or ""): status = "complete"
        goal = {"threadId": th, "objective": p.get("objective") or "Ship it", "status": status, "tokenBudget": None, "tokensUsed": 0, "timeUsedSeconds": 0, "createdAt": 1, "updatedAt": 1}
        send({"id": rid, "result": {"goal": goal}})
        ev("thread/goal/updated", threadId=th, turnId=None, goal=goal)
        if goal["status"] == "active" and "no-turn" not in (p.get("objective") or ""):
            tid, tobj = command_turn(th, "goal")
            run_command_turn(th, tid, tobj, [("say", "Working toward the goal.")])
    elif meth == "thread/goal/clear":
        th = p.get("threadId")
        send({"id": rid, "result": {"cleared": True}})
        ev("thread/goal/cleared", threadId=th)
    elif meth == "config/read":
        send({"id": rid, "result": {"config": {"model": "gpt-6-astra"}, "origins": {}}})
    elif meth == "thread/start" and p.get("ephemeral"):
        r = ts_result(cwd); r["thread"] = dict(r["thread"], id="title-thread-%s" % rid)
        send({"id": rid, "result": r})
    elif meth in ("thread/start", "thread/fork"):
        send({"id": rid, "result": ts_result(cwd)})
    elif meth in ("thread/resume", "thread/read"):
        hist = [{"id": "turn-old", "status": "completed", "error": None, "items": [
            {"type": "userMessage", "id": "u0", "content": [{"type": "text", "text": "earlier question", "text_elements": []}]},
            {"type": "agentMessage", "id": "a0", "text": "earlier answer"}]}]
        r = ts_result(cwd); r["thread"] = thread(cwd, hist)
        if meth == "thread/read": r = {"thread": r["thread"]}
        send({"id": rid, "result": r})
    elif meth == "thread/unsubscribe":
        send({"id": rid, "result": {}})
        while HELD: send({"id": HELD.pop(), "result": {}})
    elif meth == "thread/settings/update" and os.environ.get("FIX_REJECT_SETTINGS"):
        send({"id": rid, "error": {"code": -32600, "message": "thread/settings/update requires experimentalApi"}})
    elif meth == "thread/settings/update" and os.environ.get("FIX_HOLD_SETTINGS") and (p.get("collaborationMode") or {}).get("mode") == "default":
        HELD.append(rid)  # answered after the client closed the session (thread/unsubscribe)
    elif meth == "thread/settings/update":
        if p.get("collaborationMode"): STATE["collab"] = p["collaborationMode"].get("mode")
        send({"id": rid, "result": {}})
    elif meth == "turn/start":
        if not p.get("collaborationMode") and STATE.get("collab"):
            p = dict(p, collaborationMode={"mode": STATE["collab"]})
        turn(rid, p)
    elif meth in ("mcpServerStatus/list", "thread/list", "thread/loaded/list", "skills/list"):
        send({"id": rid, "result": {"data": [], "nextCursor": None}})
    else:
        send({"id": rid, "result": {}})
