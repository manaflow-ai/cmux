#!/usr/bin/env python3
"""Fork Conversation to a usable fork, per destination and chat size (Leo, 2026-11-06: "just the fork
does what you'd expect: either opening a new workspace or opening up a new tab split or whatever ... just
make it fast and make it work well").

Each run opens a fresh copy of a seeded chat in a new workspace (`agent.openSessionWorkspace`, then
shown), waits for it to show, then runs the app's own Fork Conversation action for one destination
(`palette.forkAgentConversationRight`, `...NewTab`, `...NewWorkspace`: what the chat's right-click menu,
the palette step and the shortcut run, AgentHandlers.fork -> the page's `chat.forkTo`), and times:

  pane_ms     the action to the fork's pane made (`debug.chat_open_trace` `pane_made`)
  content_ms  the action to the first frame the fork's pane shows its chat (`first_content_ms`)
  usable_ms   the action to the focused pane showing the fork's session (not the parent's) with its
              transcript rows and a visible composer (`debug.agent_pane chat_state` and `readiness`,
              polled about once a frame by this script)

and the stages between them: the action to the page's fork request (`acp.session.fork` in the parent
page's wire log), its acpmux reply, the host's `chat.openTab` (`fork_open_asked`), the pane made and the
first content.

Every fork is also checked: acpmux's store gained exactly one chat, the focused pane shows it, and it
opened where asked (right: one more pane in the chat's workspace; tab: the same panes, the chat's pane
now on another tab; workspace: one more workspace, shown). A fork that opens nothing, opens twice or
opens elsewhere is a failure the summary counts.

Chats are the chat-open bench's (chat_open_agent.py's realistic turns, seeded by acpmux itself on a
seeding daemon, cached per worker: chat_open_seed_cache.py under a `fork-open` folder), copied under
fresh ids into the app's store. The app's acpmux runs the same test agent for the forks (an agent that
forks by its own `session/fork`). `--warm` (default) starts the chat's agent before the fork with one more
turn, as a chat a person just used has it; `--no-warm` forks a chat whose agent is not running.

Runs on a fleet mini through scripts/measure/fork-open.sh (or, at a commit not on feat-cmux-next,
scripts/measure/chat-open.sh --arg=--fork-open), never on an interactive Mac:
  fork-open-bench.py --app BUNDLE [--runs 10] [--placements right,tab,workspace] [--sizes small,big]
                     [--small-turns 40] [--big-turns 1000] [--json FILE] [--md FILE]
Kills only the processes it started (the app it launched through bench_memory and the seeding daemon).
"""
import argparse
import json
import os
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402
import idle_cost_load as icl  # noqa: E402
import chat_open_seed_cache as seed_cache  # noqa: E402

PLACEMENTS = {"right": "palette.forkAgentConversationRight", "tab": "palette.forkAgentConversationNewTab",
              "workspace": "palette.forkAgentConversationNewWorkspace", "down": "palette.forkAgentConversationBottom",
              "left": "palette.forkAgentConversationLeft"}

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=10)
parser.add_argument("--placements", default="right,tab,workspace")
parser.add_argument("--sizes", default="small,big")
parser.add_argument("--small-turns", type=int, default=40)
parser.add_argument("--big-turns", type=int, default=1000)
parser.add_argument("--warm", action=argparse.BooleanOptionalAction, default=True,
                    help="start the chat's agent before the fork (one more turn), as a chat just used has it")
parser.add_argument("--timeout", type=float, default=15, help="seconds a fork may take to be usable")
parser.add_argument("--no-seed-cache", action="store_true")
parser.add_argument("--config", default="{}", help="cmux.json for the app (JSON)")
parser.add_argument("--json")
parser.add_argument("--md")
opts = parser.parse_args()
APP = os.path.realpath(opts.app.rstrip("/"))
SIZES = [s.strip() for s in opts.sizes.split(",") if s.strip()]
WANTED = [p.strip() for p in opts.placements.split(",") if p.strip()]
for name in WANTED:
    if name not in PLACEMENTS:
        parser.error(f"--placements: {name} is not one of {', '.join(PLACEMENTS)}")
TURNS = {"small": opts.small_turns, "big": opts.big_turns}
AGENT = os.path.join(HERE, "chat_open_agent.py")
# New workspaces go last, so a shown workspace is the one just made.
CONFIG = bm.merged(json.loads(opts.config), {"workspaces": {"newPlacement": "bottom"}})


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


# ---------------------------------------------------------------------------------------------
# The chats.

def seed_templates(root):
    """One seeded chat per size, from the worker's cache when it has it (chat_open_seed_cache.py)."""
    cache_root = None if opts.no_seed_cache else os.path.join(os.path.dirname(seed_cache.default_root()), "fork-open")
    specs = {size: {"turns": TURNS[size]} for size in SIZES}
    got, keys = {}, {}
    if cache_root:
        digest = seed_cache.source_digest(icl.bundled_acpmux(APP))
        for size, inputs in specs.items():
            keys[size] = seed_cache.entry_key(size, inputs, digest)
            got[size] = seed_cache.get(cache_root, keys[size])
    missing = [size for size in specs if not got.get(size)]
    if missing:
        peer = icl.PeerDaemon(APP, root, AGENT)
        peer.start()
        made = {}
        try:
            for size in missing:
                made_at = time.monotonic()
                session = peer.new_chat("turn: 0")
                if not session:
                    raise SystemExit("fork-open: the seeding daemon made no chat")
                for i in range(1, TURNS[size]):
                    sent = peer.acpmux("send", session, f"turn: {i}", timeout=120)
                    if sent.returncode != 0:
                        raise SystemExit(f"fork-open: send: {(sent.stdout + sent.stderr).strip()[-2000:]}")
                made[size] = (session, time.monotonic() - made_at)
                say(f"seeded {size}: {TURNS[size]} turns in {made[size][1]:.1f} s")
        finally:
            # The store is journaled: a chat's session.json is written by the checkpoint a shutdown makes.
            peer.stop()
        for size, (session, seconds) in made.items():
            got[size] = {size: icl.read_chat(peer.home, session)}
            if cache_root:
                seed_cache.put(cache_root, keys[size], specs[size], got[size], seconds)
    if cache_root:
        seed_cache.prune(cache_root, keep=tuple(keys.values()))
    return {size: got[size][size] for size in SIZES}


def copy_chat(home, template, title):
    """`template` under a fresh id in the store at `home`; the new id."""
    session = str(uuid.uuid4())
    swap = lambda data: data.replace(template["id"].encode(), session.encode())  # noqa: E731
    meta = json.loads(swap(template["meta"]))
    meta.update({"id": session, "name": title, "title": title, "updatedAt": int(time.time() * 1000), "status": "idle"})
    folder = os.path.join(home, "sessions", session)
    icl.private_dir(folder)
    icl.private_dir(os.path.join(folder, "events"))
    icl.private_write(os.path.join(folder, "session.json"), json.dumps(meta, indent=2).encode())
    for name, data in template["events"].items():
        icl.private_write(os.path.join(folder, "events", name), swap(data))
    return session


def store_sessions(_home):
    """Every chat the app's acpmux lists (`session/list`, every page): its store is journaled, so a new
    chat has no folder on disk until a checkpoint."""
    sock = acpmux_socket()
    found, cursor = set(), None
    for _ in range(100):
        page = icl.rpc(sock, "session/list", {"cursor": cursor} if cursor else {}) or {}
        for item in page.get("sessions") or []:
            sid = item.get("sessionId") or item.get("id")
            if sid:
                found.add(sid)
        cursor = page.get("nextCursor")
        if not cursor:
            break
    return found


_socket = None


def acpmux_socket():
    global _socket
    _socket = _socket or bm.FakeChats.acpmux_socket(APP)
    return _socket


# ---------------------------------------------------------------------------------------------
# The app.

class Run:
    def __init__(self, acpmux_home):
        self.home = acpmux_home
        self.pid, self.sock, self.scratch = bm.launch(APP, CONFIG, {"ACPMUX_HOME": acpmux_home})
        self.app = bm.App(APP, self.sock)
        deadline = time.monotonic() + 60
        while not self.app.ping() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the app's socket answers once it runs

    def rpc(self, method, params=None, timeout=40):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(self.sock)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            answer = json.loads(buf or b"{}")
        except (OSError, ValueError) as error:
            return {"error": f"{method}: {error}"}
        return {"error": answer["error"]} if answer.get("error") else (answer.get("result") or {})

    def pane(self, action, **params):
        return self.rpc("debug.agent_pane", dict(params, action=action), timeout=20) or {}

    def end(self):
        self.rpc("action.run", {"action": "quitKeepSessions", "origin": "script"}, timeout=10)
        if self.pid and not bm.wait_gone(self.pid, 30):
            bm.end_bundle(APP)
        bm.end_bundle(APP)
        shutil.rmtree(self.scratch, ignore_errors=True)


def shown_layout(run):
    """The shown workspace of the first window and its panes: (workspace, [pane...], focused pane)."""
    report = run.rpc("debug.surfaces") or {}
    windows = report.get("windows") or []
    panes = (windows[0].get("panes") or []) if windows else []
    workspace = next((p.get("workspace") for p in panes if p.get("workspace")), None)
    focused = next((p.get("pane") for p in panes if p.get("focused")), None)
    return workspace, panes, focused


def workspace_count(run):
    rows = [row for window in (run.rpc("debug.sidebar_rows") or {}).get("windows") or [] for row in window.get("rows") or []]
    return sum(1 for row in rows if str(row.get("key") or "").startswith("workspace("))


def open_parent(run, session):
    """Opens `session` in a new workspace, shows it and waits for its transcript and composer."""
    key = str(uuid.uuid4())
    opened = run.app.action("agent.openSessionWorkspace", focus=True, wait=False, session=session, key=key)
    if opened.get("error"):
        return {"error": f"open: {opened['error']}"}
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        shown = run.app.action("goToWorkspace", focus=True, workspace=key)
        if not shown.get("error") or "not_found" not in json.dumps(shown.get("error")):
            break
        time.sleep(0.02)  # test script: the workspace is not listed yet
    while time.monotonic() < deadline:
        state = run.pane("chat_state")
        ready = run.pane("readiness")
        if state.get("sessionId") == session and (state.get("rows") or 0) > 0 and ready.get("composer_visible"):
            return {"pane": ready.get("pane"), "rows": state.get("rows"), "key": key}
        time.sleep(0.1)  # test script: the chat is not shown yet
    return {"error": f"the chat never showed: {json.dumps(run.pane('chat_state'))[:300]}"}


def warm(run, session):
    """One more turn on the chat through the app's acpmux, so its agent runs (as a chat just used has it)."""
    env = dict(os.environ, ACPMUX_SOCKET=acpmux_socket(), ACPMUX_HOME=run.home)
    sent = subprocess.run([icl.bundled_acpmux(APP), "send", session, "turn: warm"], capture_output=True, text=True,
                          timeout=120, env=env)
    return None if sent.returncode == 0 else (sent.stdout + sent.stderr).strip()[-500:]


def fork_stage(log, armed_wall):
    """The parent page's `acp.session.fork` request and reply, in ms after arming (wire.ts entries)."""
    entries = (log or {}).get("entries") or []
    sent = next((e for e in reversed(entries) if e.get("dir") == "out" and e.get("method") == "acp.session.fork"), None)
    if not sent or not isinstance(armed_wall, (int, float)):
        return {}
    reply = next((e for e in entries if e.get("id") == sent.get("id") and e.get("dir") == "in"), None)
    at = round(sent["at"] - armed_wall * 1000, 1)
    out = {"fork_sent_ms": at}
    if reply and isinstance(reply.get("latencyMs"), (int, float)):
        out["fork_reply_ms"] = round(at + reply["latencyMs"], 1)
        out["fork_rpc_ms"] = round(reply["latencyMs"], 1)
    return out


def fork_once(run, placement, parent, before_sessions):
    """Forks the shown chat to `placement`; times, stages and the placement check."""
    workspace0, panes0, focused0 = shown_layout(run)
    workspaces0 = workspace_count(run)
    armed = run.rpc("debug.chat_open_trace", {"action": "arm"})
    if armed.get("error"):
        return {"error": f"arm: {armed['error']}"}
    began = time.monotonic()
    acted = run.app.action(PLACEMENTS[placement], focus=True, wait=False)
    if acted.get("error"):
        run.rpc("debug.chat_open_trace", {"action": "finish"})
        return {"error": f"action: {acted['error']}"}
    usable = None
    fork_session = None
    deadline = began + opts.timeout
    while time.monotonic() < deadline:
        state = run.pane("chat_state")
        sid = state.get("sessionId")
        if sid and sid != parent["session"] and (state.get("rows") or 0) > 0:
            ready = run.pane("readiness")
            if ready.get("composer_visible") and ready.get("document_ready"):
                usable = round((time.monotonic() - began) * 1000, 1)
                fork_session = sid
                break
        time.sleep(0.01)  # test script: about once a frame
    trace = run.rpc("debug.chat_open_trace", {"action": "wait", "timeout_ms": 5000, "settle_ms": 300}, timeout=30) or {}
    marks = trace.get("marks_ms") or {}
    time.sleep(0.5)  # test script: anything a fork opens twice opens by now
    workspace1, panes1, focused1 = shown_layout(run)
    workspaces1 = workspace_count(run)
    made = store_sessions(run.home) - before_sessions
    state = run.pane("chat_state")
    record = {
        "placement": placement, "usable_ms": usable, "pane_ms": marks.get("pane_made"),
        "content_ms": trace.get("first_content_ms"), "timed_out": trace.get("timed_out"),
        "stages": {**fork_stage(run.pane("acp_log", pane=parent["pane"], limit=80), trace.get("armed_wall")),
                   **{k: marks.get(k) for k in ("fork_open_asked", "pane_made", "spare_adopted",
                                                 "spare_empty", "spare_unready", "spare_refused", "navigation_start",
                                                 "page_painted", "loading_left") if marks.get(k) is not None}},
        "frames": trace.get("frames"), "note": trace.get("note"), "engine": trace.get("engine"),
        "fork_session": fork_session, "focused_session": state.get("sessionId"), "fork_rows": state.get("rows"),
        "parent_rows": parent["rows"], "store_new": sorted(made),
        "layout": {"workspace_same": workspace1 == workspace0, "panes": [len(panes0), len(panes1)],
                   "focused_same": focused1 == focused0, "workspaces": [workspaces0, workspaces1]},
    }
    record["problems"] = problems(placement, record, parent)
    return record


def problems(placement, r, parent):
    found = []
    if r["usable_ms"] is None:
        found.append("not usable in time")
    if len(r["store_new"]) != 1:
        found.append(f"{len(r['store_new'])} new chats in the store")
    if r["focused_session"] in (None, parent["session"]):
        found.append("the focused pane does not show the fork")
    elif r["store_new"] and r["focused_session"] not in r["store_new"]:
        found.append("the focused pane shows another chat than the fork")
    layout = r["layout"]
    before, after = layout["panes"]
    ws_before, ws_after = layout["workspaces"]
    if placement in ("right", "left", "down"):
        if not layout["workspace_same"] or after != before + 1 or ws_after != ws_before:
            found.append(f"not one new split in the chat's workspace ({layout})")
    elif placement == "tab":
        if not layout["workspace_same"] or after != before or not layout["focused_same"] or ws_after != ws_before:
            found.append(f"not one new tab in the chat's pane ({layout})")
    elif placement == "workspace":
        if layout["workspace_same"] or ws_after != ws_before + 1:
            found.append(f"not one new shown workspace ({layout})")
    return found


def close_shown(run, keys):
    for key in keys:
        bm.close_workspace(run.app, key)


# ---------------------------------------------------------------------------------------------
# The summary.

def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, max(0, int(round(q * (len(values) - 1)))))], 1)


def summarize(records):
    ok = [r for r in records if not r.get("error")]
    out = {"forks": len(records), "failed": sum(1 for r in records if r.get("error") or r.get("problems")),
           "problems": [p for r in records for p in (r.get("problems") or [])] + [r["error"] for r in records if r.get("error")]}
    for name in ("pane_ms", "content_ms", "usable_ms"):
        out[name] = {"p50": pct([r.get(name) for r in ok], 0.5), "p95": pct([r.get(name) for r in ok], 0.95),
                     "max": pct([r.get(name) for r in ok], 1.0)}
    stages = sorted({k for r in ok for k in (r.get("stages") or {})})
    out["stages_p50"] = {k: pct([(r.get("stages") or {}).get(k) for r in ok], 0.5) for k in stages}
    return out


def table(results):
    lines = ["| size | placement | forks | failed | pane p50/p95 | content p50/p95 | usable p50/p95 | fork rpc p50 | open asked p50 |",
             "|---|---|---|---|---|---|---|---|---|"]
    for size, by_place in results.items():
        for placement, s in by_place.items():
            pair = lambda m: f"{s[m]['p50']} / {s[m]['p95']}"  # noqa: E731
            stages = s.get("stages_p50") or {}
            lines.append(f"| {size} | {placement} | {s['forks']} | {s['failed']} | {pair('pane_ms')} | {pair('content_ms')} | "
                         f"{pair('usable_ms')} | {stages.get('fork_rpc_ms')} | {stages.get('fork_open_asked')} |")
    return "\n".join(lines)


def main():
    root = tempfile.mkdtemp(prefix="fork-open-")
    templates = seed_templates(root)
    home = os.path.join(root, "acpmux")
    icl.private_dir(home)
    icl.private_dir(os.path.join(home, "sessions"))
    chats = {size: [[copy_chat(home, templates[size], f"Fork {size} {p} {i}") for i in range(opts.runs)] for p in WANTED]
             for size in SIZES}
    run = Run(home)
    records = {size: {p: [] for p in WANTED} for size in SIZES}
    try:
        added = run.app.run("agent.harness.add", id=bm.FAKE_AGENT_ID, name="Fork bench", command=sys.executable,
                            args=shlex.quote(os.path.abspath(AGENT)), protocol="acp", replace="true")
        if added.get("error") or added.get("code"):
            raise SystemExit(f"fork-open: agent.harness.add: {added.get('message') or added.get('error')}")
        time.sleep(3)  # test script: the app settles after launch
        for size in SIZES:
            for index, placement in enumerate(WANTED):
                for i, session in enumerate(chats[size][index]):
                    parent = open_parent(run, session)
                    if parent.get("error"):
                        records[size][placement].append({"error": parent["error"]})
                        say(size, placement, i, "parent:", parent["error"])
                        continue
                    parent["session"] = session
                    if opts.warm:
                        failed = warm(run, session)
                        if failed:
                            say(size, placement, i, "warm:", failed)
                        deadline = time.monotonic() + 20
                        while time.monotonic() < deadline and run.pane("chat_state").get("isWorking"):
                            time.sleep(0.1)  # test script: the warm turn ends
                        parent["rows"] = run.pane("chat_state").get("rows")
                    time.sleep(1)  # test script: the chat's page settles before the fork
                    before_ws, _, _ = shown_layout(run)
                    record = fork_once(run, placement, parent, store_sessions(home))
                    records[size][placement].append(record)
                    say(size, placement, i, json.dumps({k: record.get(k) for k in
                                                        ("error", "pane_ms", "content_ms", "usable_ms", "stages", "problems")}))
                    after_ws, _, _ = shown_layout(run)
                    close_shown(run, [parent["key"]] + ([after_ws] if after_ws and after_ws != before_ws else []))
                    time.sleep(0.5)  # test script: the closes land
    finally:
        run.end()
        shutil.rmtree(root, ignore_errors=True)
    summary = {size: {p: summarize(rs) for p, rs in by.items()} for size, by in records.items()}
    say("FORK-OPEN-TABLE-BEGIN")
    say(table(summary))
    say("FORK-OPEN-TABLE-END")
    say("SUMMARY", json.dumps(summary, indent=1))
    result = {"host": os.uname().nodename, "app": APP, "runs": opts.runs, "turns": {s: TURNS[s] for s in SIZES},
              "warm": opts.warm, "summary": summary, "records": records}
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(result, handle, indent=1)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write(table(summary) + "\n")
    return all(s["failed"] == 0 for by in summary.values() for s in by.values())


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
