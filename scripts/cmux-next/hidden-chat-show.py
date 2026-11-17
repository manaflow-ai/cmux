#!/usr/bin/env python3
"""A hidden agent chat that streamed megabytes, shown again: does it draw settled at once (PR #44378)?

Launches the tagged DEV app on the tag's own acpmux with acpmux's test agent (cmux-tui/crates/acpmux/tests/
fake_agent.py, wrapped here: `--agent`), so the stream goes through the app's real transport (AcpmuxPaneSocket),
not the page's in-page mock. One pane, three chat tabs: UP (scrolled up a few screens before it is hidden), FOLLOW
(at the bottom) and B. UP and FOLLOW each get a long history, then a prompt whose turn waits, streams --mib MiB of
prose and tool calls while B is shown, and then stays running (no more output) for --pause seconds. Then each is
shown again under the app's own screen recorder (`debug.motion record_*`: every frame the window server composited,
with exact scanlines), and per show the report has: complete frames from the switch until the chat's region stops
changing, which scanlines changed in each frame, the transcript scroll offset before the hide and after the show
(`chat_state`), the page's `_acpmux/lagged` notices (`acp_log`), the pacer, and the app's
"shedding stream notifications" log lines.

  hidden-chat-show.py --app APP --tag TAG --out DIR [--json FILE] [--mib 4] [--pause 50] [--record 3.0]

Fleet (split-spring.sh builds the app; the tgz holds the report, the movies and their frame lists):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=hidden-show --arg=--app-cache --artifact artifacts/split-spring/hidden-show.tgz
"""
import json, os, struct, subprocess, sys, tarfile, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
WORDS = ("the pacer holds the hidden pane's stream within its bound and the socket sheds the notifications past it "
         "so the page reads what it missed from its cursor once the pane shows again and draws the transcript "
         "settled in one frame with the reader's scroll position kept where it was before the tab was hidden").split()


# ------------------------------------------------------------------ the agent (--agent)

def run_agent():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fake_agent", FAKE_AGENT)
    fake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake)
    inner = fake.handle_prompt

    def prose(seed, chars):
        out, i = [], 0
        while sum(len(w) + 1 for w in out) < chars:
            out.append(WORDS[(seed * 7 + i * 3) % len(WORDS)])
            i += 1
        return " ".join(out)

    def handle_prompt(rid, params):
        text = fake.prompt_text(params)
        sid = params["sessionId"]
        sent = {"n": 0, "bytes": 0}

        def emit(upd):
            sent["n"] += 1
            sent["bytes"] += len(json.dumps({"jsonrpc": "2.0", "method": "session/update",
                                             "params": {"sessionId": sid, "update": upd}}))
            fake.update(sid, upd)

        def chunk(t):
            emit({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})

        def tool(tid, title, steps, gap):
            emit({"sessionUpdate": "tool_call", "toolCallId": tid, "title": title, "kind": "execute",
                  "status": "in_progress", "rawInput": {"command": title}})
            out = ""
            for step in range(steps):
                out += "".join(f"test hub::{tid}::case_{step}_{line} ... ok\n" for line in range(12))
                upd = {"sessionUpdate": "tool_call_update", "toolCallId": tid,
                       "content": [{"type": "content", "content": {"type": "text", "text": out}}]}
                if step == steps - 1:
                    upd["status"] = "completed"
                emit(upd)
                if gap:
                    time.sleep(gap)  # probe agent: a command's pace

        if "history:" in text:
            n = int(text[text.index("history:") + 8:].split()[0])
            for i in range(n):
                para = f"**History {i}.** " + prose(i, 560) + "\n\n"
                for at in range(0, len(para), 180):
                    chunk(para[at:at + 180])
                if i % 10 == 9:
                    tool(f"hist-{i}", f"cargo test history {i}", 2, 0)
            fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            return
        if "flood:" in text:
            # flood: DELAY_S MIB PAUSE_S DONE_PATH
            delay, mib, pause, done = text[text.index("flood:") + 6:].split()[:4]
            chunk("Starting the long run now.\n\n")
            time.sleep(float(delay))  # probe agent: the driver hides the chat meanwhile
            start, target, block = time.monotonic(), int(float(mib) * (1 << 20)), 0
            while sent["bytes"] < target:
                para = f"**Block {block}.** " + prose(block, 2400) + "\n\n"
                for at in range(0, len(para), 120):
                    chunk(para[at:at + 120])
                    time.sleep(0.001)  # probe agent: a fast model's token pace
                tool(f"flood-{block}", f"cargo test flood block {block}", 4, 0.002)
                block += 1
            facts = {"notifications": sent["n"], "wire_bytes": sent["bytes"], "blocks": block,
                     "seconds": round(time.monotonic() - start, 2), "at": time.time()}
            with open(done + ".tmp", "w") as f:
                json.dump(facts, f)
            os.replace(done + ".tmp", done)
            time.sleep(float(pause))  # probe agent: the turn runs on with nothing new
            chunk("\n\nDone.")
            fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
            return
        return inner(rid, params)

    fake.handle_prompt = handle_prompt
    fake.main()


if __name__ == "__main__" and "--agent" in sys.argv[1:]:
    sys.argv = [a for a in sys.argv if a != "--agent"]
    run_agent()
    sys.exit(0)

# ------------------------------------------------------------------ the driver

import argparse, shlex  # noqa: E402
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--mib", type=float, default=4.0)
parser.add_argument("--pause", type=float, default=55.0)
parser.add_argument("--record", type=float, default=3.0)
parser.add_argument("--history", type=int, default=80)
opts, _unknown = parser.parse_known_args([a for a in sys.argv[1:] if not a.startswith("--suite=")])
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
WORK = os.path.realpath(tempfile.mkdtemp(prefix="hidden-show-work-"))
R = {"tag": opts.tag, "host": os.uname().nodename, "opts": vars(opts), "log": [], "unknown_args": _unknown}
bench = None


def note(*parts):
    text = " ".join(str(p) for p in parts)
    print(time.strftime("%H:%M:%S"), text, flush=True)
    R["log"].append(text)


def rpc(method, params=None, timeout=60):
    return bench.rpc(method, params or {}, timeout=timeout)


def action(name, args=None, target=None, focus=True, timeout=60):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    return rpc("action.run", params, timeout=timeout)


def agent(act, timeout=60, **params):
    return rpc("debug.agent_pane", {"action": act, **params}, timeout=timeout)


def wait(predicate, seconds, step=0.25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # a read that failed: try again until the bound
            value = None
        if value:
            return value
        time.sleep(step)  # the poll interval
    return None


def short(value, n=300):
    return json.dumps(value)[:n]


def all_tabs():
    snap = rpc("snapshot.get") or {}
    found = []
    for ws in (snap.get("topology") or snap).get("workspaces", []) or []:
        for screen in ws.get("screens", []) or []:
            for pane in screen.get("panes", []) or []:
                for tab in pane.get("tabs", []) or []:
                    found.append({"workspace": ws.get("id"), "pane": pane.get("id"), "tab": tab.get("id"),
                                  "kind": tab.get("kind") or tab.get("type"), "title": tab.get("title")})
    return found


def state():
    s = agent("chat_state")
    keep = ("connection", "sessionId", "isWorking", "rows", "scrollTop", "scrollHeight", "canLoadOlder", "historyFrom",
            "focused", "error")
    out = {k: s.get(k) for k in keep if isinstance(s, dict)}
    if isinstance(s, dict) and s.get("lastAssistant"):
        out["lastAssistantTail"] = (s["lastAssistant"].get("text") or "")[-80:]
        out["lastAssistantLen"] = len(s["lastAssistant"].get("text") or "")
    return out


def trusted(call):
    """Runs `call`; a chat in a folder nobody trusted yet is refused with trust.pending until the
    person clicks Trust, so the probe clicks it as they do and runs `call` again."""
    reply = call()
    # acpmux may instead hold the start for the answer (hub/trust_wait.rs): the call answers
    # `pending` with no session while the "Trust <folder>?" card waits.
    held = isinstance(reply, dict) and reply.get("pending") and not reply.get("sessionId")
    if held:
        clicked = wait(lambda: (lambda r: r if not r.get("error") else None)(
            agent("click", text="Trust", timeout=10) or {"error": "none"}), 30)
        note(f"trust (held start): {short(clicked, 160)}")
        return reply
    if "trust.pending" not in json.dumps(reply):
        return reply
    clicked = wait(lambda: (lambda r: r if not r.get("error") else None)(
        agent("click", text="Trust", timeout=10) or {"error": "none"}), 30)
    note(f"trust: {short(clicked, 160)}")
    return wait(lambda: (lambda r: r if "trust.pending" not in json.dumps(r) else None)(call()), 30) or reply


def make_chat(name):
    before = {t["tab"] for t in all_tabs()}
    opened = action("palette.newAgentChat")
    time.sleep(1.0)  # the action answers while the chat still opens
    ready = wait(lambda: (lambda r: r if r.get("document_ready") else None)(agent("readiness", timeout=10) or {}), 40, 0.5)
    engine = agent("engine")
    made = trusted(lambda: agent("new_chat", harness="fake", cwd=WORK, timeout=90))
    attached = wait(lambda: state().get("connection") == "attached" and state().get("sessionId"), 40, 0.5)
    new = [t for t in all_tabs() if t["tab"] not in before]
    tab = new[-1] if new else None
    note(f"chat {name}: tab {tab} engine {short(engine, 160)} ready {bool(ready)} new_chat {short(made, 200)} "
         f"attached {bool(attached)} opened {short(opened, 160)}")
    return {"name": name, "tab": tab and tab["tab"], "pane_id": tab and tab["pane"], "engine": engine.get("engine"),
            "pane": engine.get("pane"), "session": state().get("sessionId")}


def show(chat):
    reply = action("tab.focus", target=f"tab:{chat['tab']}")
    ok = wait(lambda: agent("engine").get("pane") and state().get("sessionId") == chat["session"], 10, 0.1)
    return reply, bool(ok)


def send(text):
    reply = trusted(lambda: agent("send_prompt", text=text, timeout=60))
    note(f"send {text[:60]!r}: {short(reply, 200)}")
    return reply


def scroll_up(screens_px):
    """Real wheel events over the focused pane until the transcript is `screens_px` above where it was."""
    start = state().get("scrollTop")
    if start is None:
        return {"error": "no transcript scroll", "state": state()}
    tried = []
    for params in ({"dy": 120}, {"dy": -120}, {"dy": 120, "target": "page"}, {"dy": -120, "target": "page"}):
        before = state().get("scrollTop")
        for _ in range(3):
            r = rpc("debug.mouse", {"action": "scroll", "pane": "focused", **params})
            time.sleep(0.05)  # a wheel's pace
        time.sleep(0.3)  # the scroll lands
        after = state().get("scrollTop")
        tried.append({"params": params, "before": before, "after": after, "reply": short(r, 160)})
        if after is not None and before is not None and after < before - 10:
            for _ in range(80):
                if (state().get("scrollTop") or 0) <= start - screens_px:
                    break
                rpc("debug.mouse", {"action": "scroll", "pane": "focused", **params})
                time.sleep(0.04)  # a wheel's pace
            time.sleep(0.5)  # the scroll ends
            return {"start": start, "end": state().get("scrollTop"), "with": params, "tried": tried}
    return {"error": "no wheel moved the transcript up", "tried": tried}


# ---- the recorder and its scanlines

def record_start(path, rows, columns):
    started = rpc("debug.motion", {"action": "record_start", "path": path, "seconds": 20, "mbps": 16,
                                   "rows": rows, "columns": columns})
    if not isinstance(started, dict) or started.get("error"):
        return started
    wait(lambda: (lambda r: r.get("capturing") or r.get("error"))(rpc("debug.motion", {"action": "record_read"})), 10, 0.05)
    return started


def record_stop():
    rpc("debug.motion", {"action": "record_stop"})
    return wait(lambda: (lambda r: r if r.get("written") or r.get("error") else None)(
        rpc("debug.motion", {"action": "record_read"})), 30, 0.25) or {}


def scan_records(path):
    index = json.load(open(path + ".frames.json"))
    rows, cols, width, height = index["rows"], index["columns"], index["width"], index["height"]
    size = 8 + 4 * (len(rows) * width + len(cols) * height)
    data = open(path + ".scan", "rb").read()
    if data[:1] == b"{":
        data = data[data.index(b"\n") + 1:]
    recs = []
    for at in range(0, len(data) - size + 1, size):
        t = struct.unpack_from("<d", data, at)[0]
        lines = [data[at + 8 + 4 * width * i: at + 8 + 4 * width * (i + 1)] for i in range(len(rows))]
        recs.append((t, lines))
    return index, recs


def changed_px(a, b, x0, x1):
    if a[x0 * 4:x1 * 4] == b[x0 * 4:x1 * 4]:
        return 0
    ma, mb = memoryview(a).cast("I"), memoryview(b).cast("I")
    return sum(1 for x in range(x0, x1) if ma[x] != mb[x])


def analyze(path, t_switch, region):
    """Frames of the chat's region (x0..x1 of each kept row) from the switch to the last change."""
    try:
        index, recs = scan_records(path)
    except (OSError, ValueError, KeyError) as error:
        return {"error": f"scan: {error!r}"}
    width = index["width"]
    x0, x1 = int(width * region[0]), int(width * region[1])
    frames = index["frames"]
    out = {"frames_total": len(frames), "complete_total": sum(1 for f in frames if f[1] == "complete"),
           "scan_records": len(recs), "rows": index["rows"], "region_px": [x0, x1], "width": width}
    if not recs:
        return out
    pre = [r for r in recs if r[0] < t_switch]
    post = [r for r in recs if r[0] >= t_switch]
    out["pre_records"], out["post_records"] = len(pre), len(post)
    if not post:
        return out
    base = pre[-1] if pre else post[0]
    final = post[-1]
    # Each post frame: the rows that differ from the frame before, and from the final frame.
    steps, prev, last_diff_final, first_change = [], base, None, None
    for i, (t, lines) in enumerate(post):
        vs_prev = [changed_px(lines[k], prev[1][k], x0, x1) for k in range(len(lines))]
        vs_final = [changed_px(lines[k], final[1][k], x0, x1) for k in range(len(lines))]
        if any(vs_prev) and first_change is None:
            first_change = i
        if any(vs_final):
            last_diff_final = i
        steps.append({"i": i, "ms": round((t - t_switch) * 1000, 1), "changed_vs_prev": vs_prev,
                      "diff_vs_final": sum(vs_final)})
        prev = (t, lines)
    out["first_change_index"] = first_change
    out["first_change_ms"] = steps[first_change]["ms"] if first_change is not None else None
    # Frames that changed the region after the first one that changed it (0: it drew settled in one frame).
    changed_after = [s for s in steps[(first_change or 0) + 1:] if any(s["changed_vs_prev"])]
    out["changing_frames_after_first"] = len(changed_after)
    out["last_change_ms"] = changed_after[-1]["ms"] if changed_after else out["first_change_ms"]
    out["settled_index"] = (last_diff_final + 1) if last_diff_final is not None else first_change
    out["frames_switch_to_settled"] = (out["settled_index"] - (first_change or 0) + 1) if first_change is not None else None
    # Rows that change again and again (a spinner, a caret) versus once.
    per_row = [sum(1 for s in changed_after if s["changed_vs_prev"][k]) for k in range(len(index["rows"]))]
    out["changes_per_row_after_first"] = per_row
    out["steps_head"] = steps[:40]
    out["changed_after_head"] = changed_after[:40]
    # The pre-hide frame against the settled one (the reader's view kept: 0 changed px in the transcript rows).
    if pre:
        out["pre_vs_final_px_per_row"] = [changed_px(pre[0][1][k], final[1][k], x0, x1) for k in range(len(index["rows"]))]
    return out


def recorder_rows(scale, height_pt):
    # Device-pixel rows over the window: header through transcript to the composer (12 % .. 92 %).
    return [int(height_pt * scale * f) for f in (0.08, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.82, 0.88, 0.94)]


def shedding_log(since):
    try:
        out = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", since, "--predicate",
                              'eventMessage CONTAINS "agent pane transport"'],
                             capture_output=True, text=True, timeout=180).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": repr(error)}
    lines = [l for l in out.splitlines() if "agent pane transport" in l]
    return {"count": len(lines), "shedding": sum("shedding stream notifications" in l for l in lines),
            "lines": lines[:30]}


def lagged_on_page():
    log = agent("acp_log", limit=2000, timeout=60)
    text = json.dumps(log)
    stats = log.get("stats") if isinstance(log, dict) else None
    entries = log.get("entries") if isinstance(log, dict) else None
    lagged = [e for e in (entries or []) if "_acpmux/lagged" in json.dumps(e)]
    return {"stats": stats, "entries": len(entries or []), "lagged_entries": len(lagged),
            "lagged_head": [json.dumps(e)[:400] for e in lagged[:4]], "mentions": text.count("_acpmux/lagged")}


def show_and_record(chat, name, rows, columns, region):
    path = os.path.join(OUT, f"show-{name}.mov")
    started = record_start(path, rows, columns)
    rpc("debug.frames", {"action": "start"})
    time.sleep(0.6)  # the recorder's first frames: the chat still hidden
    t_switch = time.monotonic()  # CACurrentMediaTime's clock (mach absolute time), as frames.json's
    reply = rpc("action.run", {"action": "tab.focus", "target": f"tab:{chat['tab']}", "focus": True, "origin": "script"})
    t_reply = time.monotonic()
    time.sleep(opts.record)  # the recording runs on after the switch
    frames = rpc("debug.frames", {"action": "stop"}, timeout=20)
    done = record_stop()
    result = {"t_switch": t_switch, "switch_reply_ms": round((t_reply - t_switch) * 1000, 1), "switch": short(reply, 200),
              "recorder": {k: done.get(k) for k in ("frames", "complete", "idle", "movie_status", "scan_dropped",
                                                     "write_error", "first_t", "last_t", "filter")},
              "started": short(started, 300), "debug_frames": frames, "movie": os.path.basename(path)}
    result["analysis"] = analyze(path, t_switch, region)
    return result


def main():
    global bench
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    bench = BenchApp(opts.app, out=OUT, window=(40, 40, 1400, 900), log_name="app.log",
                     env={"CMUX_NEXT_AGENT_PANE_MOCK": None, "ACPMUX_AGENT_LAUNCH": None})
    try:
        bench.launch(timeout=180)
    except LaunchError as error:
        R["launch_error"] = {"reason": error.reason, "detail": error.report.get("detail")}
        note(f"launch failed: {error.reason}")
        return
    try:
        added = action("agent.harness.add", {"id": "fake", "name": "Fake", "command": sys.executable,
                                             "args": f"{shlex.quote(os.path.abspath(__file__))} --agent",
                                             "protocol": "acp", "replace": "true"})
        note(f"harness add: {short(added)}")
        # The recorder's geometry (a calibration recording also proves it delivers frames).
        cal = os.path.join(OUT, "calibrate.mov")
        started = record_start(cal, [100], [100])
        time.sleep(0.5)  # a frame or two
        cal_done = record_stop()
        scale = float((started or {}).get("scale") or 1)
        note(f"recorder calibration: {short(started, 300)} -> {short(cal_done, 300)}")
        rows = recorder_rows(scale, 900)
        columns = [int(1400 * scale * 0.6)]
        region = (0.30, 0.97)  # right of the sidebar, to the window's edge
        R["recorder"] = {"scale": scale, "rows": rows, "columns": columns, "region": region}

        up, follow, other = make_chat("up"), make_chat("follow"), make_chat("b")
        R["chats"] = [up, follow, other]
        R["tabs"] = all_tabs()
        note(f"tabs: {short(R['tabs'], 600)}")
        for chat in (up, follow):
            show(chat)
            send(f"history: {opts.history}")
            ended = wait(lambda: state().get("isWorking") is False and (state().get("rows") or 0) > 10, 90, 0.5)
            note(f"{chat['name']} history in: {bool(ended)} {short(state(), 300)}")
            if not ended:
                raise RuntimeError(f"chat {chat['name']} never streamed its history: {short(state(), 300)}")

        done_up, done_follow = os.path.join(WORK, "done-up.json"), os.path.join(WORK, "done-follow.json")
        # UP: the turn starts, the reader scrolls up a few screens, then another tab is shown.
        show(up)
        send(f"flood: 14 {opts.mib} {opts.pause} {done_up}")
        time.sleep(1.0)  # the prompt's bubble and the first chunk land
        R["up_scroll"] = scroll_up(2400)
        note(f"up scroll: {short(R['up_scroll'], 400)}")
        R["up_before"] = state()
        R["up_before_pacer"] = agent("pacer")
        note(f"up before hide: {short(R['up_before'])}")
        hide_path = os.path.join(OUT, "hide-up.mov")
        record_start(hide_path, rows, columns)
        time.sleep(0.5)  # the frame of UP as the reader left it
        t_hide = time.monotonic()
        show(follow)
        time.sleep(0.4)
        R["hide_up_recording"] = {"recorder": record_stop(), "t_hide": t_hide}
        try:
            index, recs = scan_records(hide_path)
            R["hide_up_recording"]["pre_records"] = sum(1 for r in recs if r[0] < t_hide)
        except (OSError, ValueError, KeyError) as error:
            R["hide_up_recording"]["error"] = repr(error)
        # FOLLOW: at the bottom, its turn starts, then B is shown.
        send(f"flood: 6 {opts.mib} {opts.pause} {done_follow}")
        time.sleep(0.8)
        R["follow_before"] = state()
        note(f"follow before hide: {short(R['follow_before'])}")
        show(other)
        t_hidden = time.monotonic()
        note("B shown: UP and FOLLOW hidden, their floods start in a few seconds")
        floods = wait(lambda: os.path.exists(done_up) and os.path.exists(done_follow), 240, 0.5)
        R["floods"] = {"up": json.load(open(done_up)) if os.path.exists(done_up) else None,
                       "follow": json.load(open(done_follow)) if os.path.exists(done_follow) else None,
                       "hidden_s": round(time.monotonic() - t_hidden, 1)}
        note(f"floods done {bool(floods)}: {short(R['floods'], 400)}")
        time.sleep(4.0)  # acpmux delivers the tail to the app's sockets
        R["show_follow"] = show_and_record(follow, "follow", rows, columns, region)
        R["follow_after"] = state()
        R["follow_after_pacer"] = agent("pacer")
        R["follow_lagged"] = lagged_on_page()
        note(f"follow shown: {short(R['show_follow']['analysis'], 500)} after {short(R['follow_after'])}")
        R["show_up"] = show_and_record(up, "up", rows, columns, region)
        R["up_after"] = state()
        R["up_after_pacer"] = agent("pacer")
        R["up_lagged"] = lagged_on_page()
        note(f"up shown: {short(R['show_up']['analysis'], 500)} after {short(R['up_after'])}")
        time.sleep(2.0)
        R["up_after_later"] = state()
        # The reader's view: the pre-hide frame (hide-up.mov's first) against the settled frame after the show.
        try:
            _, hide_recs = scan_records(hide_path)
            _, show_recs = scan_records(os.path.join(OUT, "show-up.mov"))
            width = json.load(open(hide_path + ".frames.json"))["width"]
            x0, x1 = int(width * region[0]), int(width * region[1])
            pre = [r for r in hide_recs if r[0] < t_hide]
            if pre and show_recs:
                R["up_view_pre_hide_vs_after_show_px"] = [changed_px(pre[-1][1][k], show_recs[-1][1][k], x0, x1)
                                                          for k in range(len(rows))]
        except (OSError, ValueError, KeyError) as error:
            R["up_view_compare_error"] = repr(error)
        R["app_log"] = shedding_log(since)
        note(f"app log: {R['app_log'].get('count')} transport lines, {R['app_log'].get('shedding')} shedding")
    except Exception as error:  # the report says what failed; the step still returns its files
        import traceback
        R["error"] = traceback.format_exc()
        note(f"failed: {error!r}")
    finally:
        try:
            bench.stop()
        except Exception as error:  # the teardown still runs in bench.stop's finally
            note(f"stop: {error!r}")


if __name__ == "__main__":
    try:
        main()
    finally:
        report = opts.json or os.path.join(OUT, "report.json")
        with open(report, "w") as f:
            json.dump(R, f, indent=1)
        with open(os.path.join(OUT, "hidden-show.json"), "w") as f:
            json.dump(R, f, indent=1)
        with tarfile.open(os.path.join(OUT, "hidden-show.tgz"), "w:gz") as tar:
            for name in sorted(os.listdir(OUT)):
                full = os.path.join(OUT, name)
                if name.endswith((".mov", ".frames.json", ".json", ".log")) and os.path.getsize(full) < (60 << 20):
                    tar.add(full, arcname=name)
        print("HIDDEN-SHOW " + json.dumps({k: R.get(k) for k in ("floods", "up_before", "up_after", "follow_after")})[:2000],
              flush=True)
    # A run that streamed nothing measured nothing: it fails, so its report never reads as a result.
    floods = R.get("floods") or {}
    unstreamed = [k for k in ("up_after", "follow_after") if ((R.get(k) or {}).get("rows") or 0) <= 10]
    missing = [k for k in ("up", "follow") if not floods.get(k)]
    if R.get("error") or unstreamed or missing:
        print(f"HIDDEN-SHOW FAILED: measured nothing: error={bool(R.get('error'))} "
              f"chats at <=10 rows={unstreamed} floods missing={missing}", flush=True)
        sys.exit(1)
    sys.exit(0)
