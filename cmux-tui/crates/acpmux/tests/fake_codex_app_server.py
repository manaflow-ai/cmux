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
`thread/fork` (not a prediction's) makes a new thread and `thread/resume` takes
the thread it names; `thread/unsubscribe` lets go of one. FAKE_CODEX_WRITERS=<dir>
keeps Codex's one-writer rule across app-servers: the process that starts, forks
or resumes a thread holds it (a file <dir>/<thread id> with its pid) until it
unsubscribes, and another process's `thread/resume` of a thread whose holder
still runs is refused (-32600 "thread <id> already has an active writer").
"""
import json
import os
import sys
import time

# Global options (`-c key=value`, `--config key=value`) come before the subcommand, as codex
# takes them. FAKE_CODEX_ARGS=<path> gets a line with the arguments of each start.
if os.environ.get("FAKE_CODEX_ARGS"):
    with open(os.environ["FAKE_CODEX_ARGS"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
while len(args) >= 2 and args[0] in ("-c", "--config"):
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


def hold(thread_id):
    """Holds the thread for this process under FAKE_CODEX_WRITERS. Returns the
    pid of another live process that holds it instead, or None."""
    writers = os.environ.get("FAKE_CODEX_WRITERS")
    if not writers:
        return None
    path = os.path.join(writers, thread_id)
    try:
        with open(path) as f:
            holder = int(f.read().strip() or "0")
    except (OSError, ValueError):
        holder = 0
    if holder and holder != os.getpid():
        try:
            os.kill(holder, 0)
            return holder
        except ProcessLookupError:
            pass
        except PermissionError:
            return holder
    os.makedirs(writers, exist_ok=True)
    with open(path, "w") as f:
        f.write(str(os.getpid()))
    return None


def let_go(thread_id):
    """This process stops holding the thread (FAKE_CODEX_WRITERS)."""
    writers = os.environ.get("FAKE_CODEX_WRITERS")
    if not writers or not thread_id:
        return
    path = os.path.join(writers, thread_id)
    try:
        with open(path) as f:
            mine = f.read().strip() == str(os.getpid())
        if mine:
            os.remove(path)
    except OSError:
        pass


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
        model = "gpt-6.1-sol"
        if os.environ.get("FAKE_CODEX_CATALOG"):
            # The model asked for, else the catalog's default, as an installed Codex starts.
            with open(os.environ["FAKE_CODEX_CATALOG"]) as f:
                rows = json.load(f)
            asked = message.get("params", {}).get("model")
            model = asked or next((r["id"] for r in rows if r.get("isDefault")), rows[0]["id"])
        hold(thread["id"])
        reply({"id": rid, "result": {"thread": thread, "model": model, "reasoningEffort": None}})
    elif method == "thread/fork" and not predicting:
        params = message.get("params", {})
        thread = {"id": "fake-fork-%d-%s" % (os.getpid(), rid), "cwd": params.get("cwd"), "turns": []}
        hold(thread["id"])
        reply({"id": rid, "result": {"thread": thread, "model": "gpt-6.1-sol", "reasoningEffort": None}})
    elif method == "thread/resume":
        params = message.get("params", {})
        thread_id = params.get("threadId") or ""
        if hold(thread_id) is not None:
            reply({"id": rid, "error": {"code": -32600, "message": "thread %s already has an active writer" % thread_id}})
            continue
        thread = {"id": thread_id, "cwd": params.get("cwd"), "turns": []}
        reply({"id": rid, "result": {"thread": thread, "model": "gpt-6.1-sol", "reasoningEffort": None}})
    elif method == "thread/unsubscribe":
        let_go((message.get("params") or {}).get("threadId"))
        reply({"id": rid, "result": {"status": "unsubscribed"}})
    elif method == "turn/start":
        params = message.get("params", {})
        thread, turn = params.get("threadId"), "fake-turn-%s" % rid
        text = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
        if "codex-die" in text:
            sys.exit(1)
        reply({"id": rid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        reply({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn, "status": "inProgress", "items": []}}})
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
