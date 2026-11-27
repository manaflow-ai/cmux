#!/usr/bin/env python3
"""Each user action's spans against its speed-of-light floor, end to end (scripts/measure/action-trace.sh).

Leo, 2026-11-25: "we should do whatever u think is best piecemeal and then we can evolve and expand it to be
more useful as things happen and we can use the numbers to work on ongoing goals as they are raised and we
consider what the metaphorical speed of light is against our implementations".

Launches the app with the daemon's CMUX_TRACE_FILE set to a scratch file (acpmux perf_trace.rs: the daemon
writes its own spans there, and the app and its webviews hand theirs over with `_acpmux/trace/spans`), then
drives, on acpmux's test agent (chat_open_agent.py):

  launch to interactive, a new chat, one send to its first token, a second chat, a chat switch each way,
  and one more new chat.

Then prints the trace between ACTION-TRACE-BEGIN and ACTION-TRACE-END, and one line per span:

  ACTION-GAP name dur_us floor_us gap_us

(floor_us and gap_us `-` for a span with no floor). --burn=N runs N busy loops at default priority for the
whole run (the duress run: an agent-like load on every core). --json writes the spans and the run's facts.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--app", required=True, help="the app bundle to measure")
parser.add_argument("--json", help="write the spans and the run's facts here")
parser.add_argument("--burn", type=int, default=0, help="busy loops at default priority during the run (duress)")
parser.add_argument("--settle", type=float, default=1.5, help="seconds after each action for its paint spans")
opts = parser.parse_args()
APP = os.path.abspath(opts.app)
AGENT = os.path.join(HERE, "chat_open_agent.py")


def say(text):
    print(text, flush=True)


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: polling the app's debug state
    return None


def read_trace(path):
    """The daemon's trace: a JSON array of `{event},` lines it never closes while it runs."""
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError:
        return []
    events = []
    for line in text.splitlines():
        line = line.strip().rstrip(",")
        if not line or line in ("[", "]"):
            continue
        try:
            events.append(json.loads(line))
        except ValueError:
            continue
    return events


def burners(count):
    code = "while True: pass"
    return [subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.DEVNULL) for _ in range(count)]


def main():
    scratch_trace = None
    loads = burners(opts.burn)
    facts = {"burn": opts.burn, "steps": {}}
    pid = None
    try:
        work = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"action-trace-work-{os.getpid()}")
        os.makedirs(work, exist_ok=True)
        trace_dir = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"action-trace-{os.getpid()}")
        os.makedirs(trace_dir, exist_ok=True)
        scratch_trace = os.path.join(trace_dir, "trace.json")
        started = time.monotonic()
        pid, sock, scratch = bm.launch(APP, {}, {"CMUX_TRACE_FILE": scratch_trace})
        app = bm.App(APP, sock)
        wait(app.ping, 60, 0.5)
        facts["steps"]["launch_to_socket_s"] = round(time.monotonic() - started, 3)

        def pane(action, timeout=40, **params):
            params = {k: v for k, v in params.items() if v is not None}
            result = app.call("debug.agent_pane", dict(params, action=action), timeout=timeout)
            return result if isinstance(result, dict) else {"result": result}

        bm.FakeChats(app, APP, AGENT)  # registers the test agent as a harness
        opened = app.action("palette.newAgentChat", focus=True)
        ready = wait(lambda: (lambda r: r if r.get("document_ready") else None)(pane("readiness", timeout=5)), 60, 0.5)
        facts["steps"]["launch_to_chat_ready_s"] = round(time.monotonic() - started, 3)
        engine = pane("engine", timeout=10)
        pane_id = engine.get("pane")
        if not pane_id:
            raise SystemExit(f"action-trace: no agent pane opened ({json.dumps(opened)[:300]}; {json.dumps(ready)[:200]})")
        say(f"action-trace: pane {pane_id} engine {engine.get('engine')}")

        def chat_state():
            return pane("chat_state", pane=pane_id, timeout=10)

        trust_clicks = []

        def attached_or_trust():
            """The attached chat's state; else answers the folder's trust ask when it shows (it can come after
            new_chat's 1.5 s accept window, so a single click attempt right after `pending` missed it)."""
            s = chat_state()
            if s.get("connection") == "attached" and s.get("sessionId"):
                return s
            if pane("click", pane=pane_id, selector=".acpmux-trust-ask-action", timeout=10).get("clicked"):
                trust_clicks.append(time.monotonic())
            return None

        def why_not_attached(made):
            """The fields that say why a chat has no session (chat_state's dict is key-sorted, so a cut dump ends
            in composer fields before reaching connection)."""
            s = chat_state()
            keep = ("connection", "sessionId", "harness", "isWorking", "rows", "missingSession", "unavailable", "error")
            shown = pane("query", pane=pane_id, selector=".acpmux-trust-ask-action", timeout=10)
            return json.dumps({"new_chat": made, "state": {k: s.get(k) for k in keep if k in s},
                               "errors": {k: v for k, v in s.items() if "error" in k.lower() and v},
                               "trust_ask_shown": bool(isinstance(shown, dict) and shown.get("elements")),
                               "trust_clicks": len(trust_clicks)})[:1200]

        def new_chat():
            made = pane("new_chat", pane=pane_id, harness=bm.FAKE_AGENT_ID, cwd=work, timeout=90)
            if made.get("error"):
                raise SystemExit(f"action-trace: new_chat: {made['error']}")
            state = wait(attached_or_trust, 90, 0.25)
            if not state:
                raise SystemExit(f"action-trace: the new chat never attached {why_not_attached(made)}")
            time.sleep(opts.settle)  # test script: the action's paint spans land after its last frame
            return state["sessionId"]

        def send(text):
            before = chat_state()
            sent = pane("send_prompt", pane=pane_id, text=text)
            if sent.get("error"):
                raise SystemExit(f"action-trace: send_prompt: {sent['error']}")
            wait(lambda: (lambda s: s if not s.get("isWorking") and s != before else None)(chat_state()), 60, 0.25)
            time.sleep(opts.settle)  # test script: the first token's paint span lands after its frame

        def switch(session):
            pane("select_session", pane=pane_id, session=session)
            wait(lambda: (lambda s: s if s.get("sessionId") == session and s.get("connection") == "attached" else None)(chat_state()), 30, 0.1)
            time.sleep(opts.settle)  # test script: the switch's paint spans land after its frame

        first = new_chat()
        send("hello")
        second = new_chat()
        send("hello again")
        switch(first)
        switch(second)
        new_chat()
        facts["sessions"] = [first, second]
        facts["steps"]["total_s"] = round(time.monotonic() - started, 3)
    except SystemExit as failed:
        # The spans recorded before a failure (launch, the first chat) still go to the artifact.
        facts["failed"] = str(failed)
        raise
    finally:
        for load in loads:
            load.kill()
        if pid:
            bm.end_bundle(APP)
        if opts.json and facts.get("failed"):
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            with open(opts.json, "w") as handle:
                json.dump({"facts": facts, "trace": read_trace(scratch_trace) if scratch_trace else []}, handle)
    events = read_trace(scratch_trace) if scratch_trace else []
    spans = [e for e in events if e.get("ph") == "X"]
    say("ACTION-TRACE-BEGIN")
    say(json.dumps(events))
    say("ACTION-TRACE-END")
    for span in sorted(spans, key=lambda e: e.get("ts", 0)):
        args = span.get("args") or {}
        floor = args.get("floor_us")
        gap = args.get("gap_us")
        say(f"ACTION-GAP {span.get('name')} {int(span.get('dur', 0))} {floor if floor is not None else '-'} {gap if gap is not None else '-'}")
    facts["spans"] = len(spans)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump({"facts": facts, "trace": events}, handle)
    say(f"action-trace: {len(spans)} spans; {json.dumps(facts['steps'])}")
    if not spans:
        raise SystemExit("action-trace: the daemon wrote no spans (CMUX_TRACE_FILE never reached it?)")


main()
