#!/usr/bin/env python3
"""A fake `codex app-server` for live model list tests and the in-process
Codex bridge (`codex_app_server.rs`): JSON-RPC lines without the `jsonrpc`
field. `model/list` answers in two pages; `thread/start` makes one thread and
`turn/start` streams one message ("ok") and completes the turn.
FAKE_CODEX=unauth refuses `model/list` as a signed-out Codex does;
FAKE_CODEX=hang never answers; FAKE_DELAY waits before each answer.
FAKE_CODEX_CATALOG=<path> answers `model/list` with that file's rows, one page, read at
each request (a Codex updated behind the same launcher answers with a new catalog), and
`thread/start` runs the model it asks for, else that catalog's default.
`account/rateLimits/read` answers a Pro plan's 5-hour and weekly windows and credits.

Background terminals (unified exec): a prompt with "bg-codex" runs `npm run
dev` (process 1001), whose item is still open when the turn completes, `ls`
(1002), which completes in the turn, and `cargo watch` (1003), whose item
completes while its process still runs. "bg-codex-exit" then ends 1003 with
exit code 1. `thread/backgroundTerminals/terminate` stops a running one and
completes its item. A prompt with "codex-die" exits the app-server.
A prompt with "codex-limits" sends `account/rateLimits/updated` twice in its turn (a
Pro plan's 5-hour and weekly windows and credits; then the weekly window moved).
"bg-codex-sub" starts a subagent thread (fake-sub-1) whose `npm run watch`
(2001) runs in the background. "bg-codex-gone": Codex forgets 1001, so its
terminate answers `terminated: false`. "bg-codex-interrupt" leaves `sleep 60`
(3001) open when the turn is interrupted. FAKE_CODEX_END_FIRST=1 completes a
terminated item before answering the terminate.
FAKE_CODEX_HOLD_SUGGESTIONS=1 never answers a prompt suggestion's ask
(`thread/prediction/request`, `thread/sample`, a prediction `thread/fork`): what the bridge asks
after a turn completes stays in flight, as on a loaded machine whose answer lands
after the prompt's own.

Approvals as Codex runs them (tests/permission_matrix.rs), with FAKE_CODEX_APPROVALS=1: each
thread keeps the `approvalPolicy` that `thread/start`, `thread/resume`, `turn/start` or
`thread/settings/update` last named; `thread/resume` and `thread/settings/update` are answered
(not refused as unknown), and each `thread/start` makes a thread of its own (fake-thread-PID-N). A
"perm-probe" turn runs `npm test`: under "never" it runs unasked, under any other policy it
sends `item/commandExecution/requestApproval` and ends the turn with the decision it gets.
"""
import json
import os
import sys
import time

# acpmux's sign-in probe at spawn (`codex_signed_out.rs`): signed in, and not a start.
if sys.argv[1:3] == ["login", "status"]:
    print("Logged in using ChatGPT")
    sys.exit(0)

# Global options (`-c key=value`, `--config key=value`) come before the subcommand, as codex
# takes them. FAKE_CODEX_ARGS=<path> gets a line with the arguments of each start.
if os.environ.get("FAKE_CODEX_ARGS"):
    with open(os.environ["FAKE_CODEX_ARGS"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
# Global options before the subcommand, as codex takes them (`-m <model> app-server`).
while len(args) >= 2 and args[0] in ("-c", "--config", "-m", "--model", "-p", "--profile"):
    args = args[2:]
if not args or args[0] != "app-server":
    sys.stderr.write("usage: codex app-server\n")
    sys.exit(2)

PAGES = {
    None: (
        [
            {
                "model": "gpt-6-astra",
                "displayName": "gpt-6-astra",
                "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}],
                "defaultReasoningEffort": "medium",
                "serviceTiers": [{"id": "default"}, {"id": "fast"}],
            },
            {"model": "gpt-secret", "displayName": "Secret", "hidden": True},
        ],
        "p2",
    ),
    "p2": (
        [
            {
                "model": "gpt-6.1-sol",
                "displayName": "GPT-6.1-Sol",
                "isDefault": True,
                "supportedReasoningEfforts": ["low", "high"],
                "serviceTiers": ["default"],
            }
        ],
        None,
    ),
}

mode = os.environ.get("FAKE_CODEX", "")
APPROVALS = os.environ.get("FAKE_CODEX_APPROVALS") == "1"
# FAKE_CODEX_APPROVALS: each thread's approval policy, the threads made, and the approval
# requests sent and not yet answered (request id -> thread, turn).
policies = {}
threads_made = 0
asked = {}


def keep_policy(params):
    thread = params.get("threadId")
    if thread and params.get("approvalPolicy"):
        policies[thread] = params["approvalPolicy"]


# processId -> the open item of each background terminal still running.
running = {}


def exec_item(item_id, command, process_id, cwd, status="inProgress", exit_code=None):
    return {
        "type": "commandExecution",
        "id": item_id,
        "command": command,
        "cwd": cwd,
        "processId": process_id,
        "source": "unifiedExecStartup",
        "status": status,
        "commandActions": [],
        "aggregatedOutput": None,
        "exitCode": exit_code,
        "durationMs": None,
    }


def item_event(kind, thread, turn, item):
    reply({"method": "item/" + kind, "params": {"threadId": thread, "turnId": turn, "item": item}})


def background_turn(thread, turn, cwd, text):
    if "bg-codex-sub" in text:
        sub = "fake-sub-1"
        reply({"method": "thread/started", "params": {"thread": {"id": sub, "parentThreadId": thread, "agentNickname": "helper"}}})
        watch = exec_item("call_sub", "npm run watch", "2001", cwd)
        item_event("started", sub, turn, watch)
        item_event("completed", sub, turn, watch)
        running["2001"] = (sub, turn, watch)
        return
    if "bg-codex-interrupt" in text:
        item_event("started", thread, turn, exec_item("call_sleep", "sleep 60", "3001", cwd))
        return
    dev = exec_item("call_dev", "npm run dev", "1001", cwd)
    item_event("started", thread, turn, dev)
    if "bg-codex-gone" not in text:
        running["1001"] = (thread, turn, dev)
    ls = exec_item("call_ls", "ls", "1002", cwd)
    item_event("started", thread, turn, ls)
    item_event("completed", thread, turn, dict(ls, status="completed", exitCode=0))
    watch = exec_item("call_watch", "cargo watch", "1003", cwd)
    item_event("started", thread, turn, watch)
    item_event("completed", thread, turn, watch)
    if "bg-codex-exit" in text:
        item_event("completed", thread, turn, dict(watch, status="failed", exitCode=1))
    else:
        running["1003"] = (thread, turn, watch)


def reply(message):
    delay = float(os.environ.get("FAKE_DELAY", "0"))
    if delay:
        time.sleep(delay)
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "id" not in message or mode == "hang":
        continue
    method, rid = message.get("method"), message["id"]
    # FAKE_CODEX_APPROVALS: the answer to a "perm-probe" approval ends that turn.
    if APPROVALS and method is None and rid in asked:
        thread, turn = asked.pop(rid)
        decision = (message.get("result") or {}).get("decision")
        said = "perm-probe ran npm test" if decision in ("accept", "acceptForSession") else "perm-probe %s" % decision
        ran = decision in ("accept", "acceptForSession")
        item_event("completed", thread, turn, dict(exec_item("c1", "npm test", None, os.getcwd()), source="agent",
                   status="completed" if ran else "declined", exitCode=0 if ran else None))
        reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": said}})
        reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": "completed", "items": []}}})
        continue
    if APPROVALS and method == "thread/settings/update":
        keep_policy(message.get("params") or {})
        reply({"id": rid, "result": {}})
        continue
    if APPROVALS and method == "thread/resume":
        params = message.get("params") or {}
        keep_policy(params)
        thread = {"id": params.get("threadId"), "cwd": params.get("cwd"), "turns": []}
        reply({"id": rid, "result": {"thread": thread, "model": "gpt-6.1-sol", "reasoningEffort": None,
                                     "approvalPolicy": params.get("approvalPolicy")}})
        continue
    predicting = (message.get("params") or {}).get("experimentalPredictionMode")
    if os.environ.get("FAKE_CODEX_HOLD_SUGGESTIONS") == "1" and (
        method in ("thread/prediction/request", "thread/sample")
        or (method == "thread/fork" and predicting)
    ):
        continue
    if method == "initialize":
        reply({"method": "codex/event", "params": {"note": "a notification first"}})
        reply({"id": rid, "result": {"userAgent": "fake"}})
    elif method == "model/list":
        if mode == "unauth":
            reply({"id": rid, "error": {"code": -32000, "message": "Not logged in. Run `codex login`."}})
            continue
        if os.environ.get("FAKE_CODEX_CATALOG"):
            with open(os.environ["FAKE_CODEX_CATALOG"]) as f:
                data, cursor = json.load(f), None
        else:
            data, cursor = PAGES[message.get("params", {}).get("cursor")]
        reply({"id": rid, "result": {"data": data, "nextCursor": cursor}})
    elif method == "thread/start":
        thread = {"id": "fake-thread-1", "cwd": message.get("params", {}).get("cwd"), "turns": []}
        if APPROVALS:
            # Unique across app-server processes too: a restarted one resumes the old thread and
            # starts new ones (prompt suggestions) beside it.
            threads_made += 1
            thread["id"] = "fake-thread-%d-%d" % (os.getpid(), threads_made)
            keep_policy(dict(message.get("params") or {}, threadId=thread["id"]))
        model = "gpt-6.1-sol"
        if os.environ.get("FAKE_CODEX_CATALOG"):
            # The model asked for, else the catalog's default, as an installed Codex starts.
            with open(os.environ["FAKE_CODEX_CATALOG"]) as f:
                rows = json.load(f)
            asked = message.get("params", {}).get("model")
            model = asked or next((r["id"] for r in rows if r.get("isDefault")), rows[0]["id"])
        reply({"id": rid, "result": {"thread": thread, "model": model, "reasoningEffort": None}})
    elif method == "turn/start":
        params = message.get("params", {})
        thread, turn = params.get("threadId"), "fake-turn-%s" % rid
        text = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
        if "codex-die" in text:
            sys.exit(1)
        reply({"id": rid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        reply({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn, "status": "inProgress", "items": []}}})
        if APPROVALS:
            keep_policy(params)
        if APPROVALS and text.strip() == "perm-probe":
            policy = policies.get(thread, "on-request")
            if policy == "never":
                reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1",
                       "delta": "perm-probe ran npm test unasked (approval %s)" % policy}})
                reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": "completed", "items": []}}})
            else:
                ask_id = "perm-%s" % rid
                asked[ask_id] = (thread, turn)
                # As Codex: the command's item starts, then its approval is asked.
                item_event("started", thread, turn, dict(exec_item("c1", "npm test", None, os.getcwd()), source="agent"))
                reply({"id": ask_id, "method": "item/commandExecution/requestApproval",
                       "params": {"threadId": thread, "turnId": turn, "itemId": "c1", "command": "npm test",
                                  "cwd": os.getcwd(), "reason": "run the tests"}})
            continue
        if "bg-codex" in text:
            background_turn(thread, turn, os.getcwd(), text)
        if "codex-limits" in text:
            limits = {
                "limitId": "codex",
                "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1790000000},
                "secondary": {"usedPercent": 41, "windowDurationMins": 10080, "resetsAt": 1790500000},
                "credits": {"hasCredits": True, "unlimited": False, "balance": "56766"},
                "planType": "pro",
            }
            reply({"method": "account/rateLimits/updated", "params": {"rateLimits": limits}})
            moved = dict(limits, secondary={"usedPercent": 90, "windowDurationMins": 10080, "resetsAt": 1790500000})
            reply({"method": "account/rateLimits/updated", "params": {"rateLimits": moved}})
        reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": "ok"}})
        status = "interrupted" if "bg-codex-interrupt" in text else "completed"
        reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": status, "items": []}}})
    elif method == "account/rateLimits/read":
        # At rest (`_acpmux/account/usage`); FAKE_CODEX_HOME_SEEN=<path> gets the CODEX_HOME it ran in.
        if os.environ.get("FAKE_CODEX_HOME_SEEN"):
            with open(os.environ["FAKE_CODEX_HOME_SEEN"], "w") as f:
                f.write(os.environ.get("CODEX_HOME", "") + "\n")
        limits = {
            "limitId": "codex",
            "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 1790000000},
            "secondary": {"usedPercent": 41, "windowDurationMins": 10080, "resetsAt": 1790500000},
            "credits": {"hasCredits": True, "unlimited": False, "balance": "56766"},
            "planType": "pro",
        }
        reply({"id": rid, "result": {"rateLimits": limits, "rateLimitsByLimitId": None}})
    elif method == "thread/backgroundTerminals/terminate":
        params = message.get("params", {})
        found = running.pop(params.get("processId"), None)
        end_first = os.environ.get("FAKE_CODEX_END_FIRST") == "1"
        if found and end_first:
            thread, turn, item = found
            item_event("completed", thread, turn, dict(item, status="failed", exitCode=143))
        reply({"id": rid, "result": {"terminated": found is not None}})
        if found and not end_first:
            thread, turn, item = found
            item_event("completed", thread, turn, dict(item, status="failed"))
    else:
        reply({"id": rid, "error": {"code": -32601, "message": "unknown method"}})
