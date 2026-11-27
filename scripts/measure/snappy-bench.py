#!/usr/bin/env python3
"""snappy-bench: how fast an agent chat answers the Enter key, in a tagged app, the one harness the snappy lanes measure with.

Leo 2026-11-25: "when you press enter, the stuff should just start playing. we dont need to wait/get blocked by
anything on rendering."
Launches a tagged bench `cmux DEV <tag>.app` (bench_launch.py `BenchApp`: the agent page runs its in-page mock, so no
agent and no credentials), opens agent chats in new workspaces and, under each duress of --duress, sends --sends
prompts with a real Return (DevTools Input.dispatchKeyEvent on the chat's page) while webviews/bench/snappy-probe.js
watches every frame:
  send_paint          Enter keydown to the frame that paints the sent row          (target: under 16 ms)
  reserved_same_frame the assistant's reserved turn painted in that same frame       (target: every send)
  shifts_per_send     layout shifts from the keydown to the first token's frame      (target: 0)
  send_first_token    Enter keydown to the first frame with reply text (the mock's reply: the page's own floor)
  chat_switch_paint   a chat's workspace shown to the first frame with its rows     (target: under 16 ms)
  shifts_per_transition  one counter of layout shifts over every turn transition    (target: 0)
                      (shadow-leo for Leo, 2026-11-25: "count layout shifts across every turn transition (send, steer,
                      compaction) in one counter"; Leo: "layout shifts and awkward looking animations"): each send,
                      each mid-turn send (--transitions of them: Enter while a turn runs, a steer where the agent
                      steers, else the queued prompt until its row paints and 1 s after) and each compaction
                      (--transitions /compact runs, until the note ends and 0.5 s after)
                      and each prompt sent while a /compact runs (until its row paints and 1 s after)
Duress (Leo's rule: test under duress):
  none          a 4-turn chat
  long-session  a 1000-turn chat (the mock's loadSeed)
  many-tabs     a 4-turn chat with --tabs other chats open in their own workspaces
  offline       a 4-turn chat with the page's network off (DevTools Network.emulateNetworkConditions)
The CPU-loaded twin is the fleet entry's --cpu-load (a `yes` on every core, as host-line-shift-duress.sh).
Out: <out>/snappy.json, schema snappy-bench/v1 (one report per duress, each its rows and every send), its last line
on stdout too. The passive twin, the same rows from the app's own perf watch in a real NIGHTLY (local or cloud):
  snappy-bench.py --summarize ~/.acpmux/perf-watch.jsonl
which reads the page's "send" and "chat switch" spans (acpmux perf on).
Usage: snappy-bench.py --app PATH --out DIR [--duress none,long-session,many-tabs,offline] [--sends 12] [--tabs 12]
Fleet: scripts/measure/snappy-bench.sh (builds the tagged app first).
"""
import argparse, importlib.util, json, os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.join(HERE, "..", "cmux-next")
ROOT = os.path.join(HERE, "..", "..")
SCHEMA = "snappy-bench/v1"
DURESS = ("none", "long-session", "many-tabs", "offline")
FIELD = ".acpmux-composer-prompt [contenteditable='true'], .ProseMirror.acpmux-md[contenteditable='true']"
# The page's frame budget: one 60 Hz frame. A 120 Hz display gives two frames for it, so a send under it is in-frame.
FRAME_MS = 16.0


def say(*parts):
    print("snappy-bench:", *parts, flush=True)


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (k - lo), 1)


def transition_rows(sends, transitions):
    """The one shift counter: every send's shifts and every other transition's (mid-turn sends, compactions)."""
    counted = lambda rows: [r.get("shifts") for r in rows if not r.get("error") and isinstance(r.get("shifts"), (int, float))]
    every = counted(sends) + counted(transitions)
    out = {
        "transitions": len(every),
        "failed_transitions": sum(1 for t in transitions if t.get("error")),
        "shifts_per_transition_mean": round(sum(every) / len(every), 3) if every else None,
        "shifts_per_transition_max": max(every) if every else None,
    }
    for kind in ("mid-turn", "compaction", "mid-compaction"):
        some = counted([t for t in transitions if t.get("kind") == kind])
        out[f"shifts_per_{kind.replace('-', '_')}_mean"] = round(sum(some) / len(some), 3) if some else None
    return out


def rows_of(sends, switches, transitions=()):
    """The snappy-bench/v1 rows of a set of sends (the probe's results, or the perf watch's send spans)."""
    ok = [s for s in sends if not s.get("error")]
    paint = [s.get("userPaintMs") for s in ok]
    # Frames the sent row missed: vsyncs after the Enter whose frame did not hold it (the probe's rAF log). Raw ms
    # carries the key's phase in the frame (0 to 16.7 ms at 60 Hz, below 0 when the frame's main work starts late), so
    # a send that paints in the next frame can read 16 ms; a missed frame is the snappy failure.
    missed = [s.get("framesMissed") for s in ok if isinstance(s.get("framesMissed"), (int, float))]
    token = [s.get("firstTokenMs") for s in ok]
    shifts = [s.get("shifts") for s in ok if isinstance(s.get("shifts"), (int, float))]
    same = [bool(s.get("sameFrame")) for s in ok if s.get("reservedPaintMs") is not None or "sameFrame" in s]
    switch = [s.get("visibleToPaintMs") for s in switches if not s.get("error")]
    return {
        "sends": len(ok),
        "failed_sends": len(sends) - len(ok),
        "send_paint_p50_ms": pct(paint, 0.5),
        "send_paint_p95_ms": pct(paint, 0.95),
        "send_frames_missed_p50": pct(missed, 0.5),
        "send_frames_missed_p95": pct(missed, 0.95),
        "late_sends": sum(1 for m in missed if m > 0) if missed else None,
        "reserved_same_frame_share": round(sum(same) / len(same), 3) if same else None,
        "shifts_per_send_mean": round(sum(shifts) / len(shifts), 3) if shifts else None,
        "shifts_per_send_max": max(shifts) if shifts else None,
        "send_first_token_p50_ms": pct(token, 0.5),
        "send_first_token_p95_ms": pct(token, 0.95),
        **transition_rows(ok, transitions),
        "chat_switch_paint_p50_ms": pct(switch, 0.5),
        "chat_switch_paint_p95_ms": pct(switch, 0.95),
        "chat_switches": len(switch),
    }


def cron_rows(reports):
    """perf-cron's budgets rows (chat_snappy.<duress>.<metric>): the snappy targets as budgets, the noise as floors."""
    out = []

    def row(name, p50, p95, unit, budget, floor):
        if p95 is not None:
            out.append({"name": name, "p50": p50, "p95": p95, "unit": unit, "budget": budget, "floor": floor})
    for report in reports:
        r, base = report["rows"], f"chat_snappy.{report['duress'].replace('-', '_')}."
        row(base + "send_paint", r["send_paint_p50_ms"], r["send_paint_p95_ms"], "ms", FRAME_MS, 4.0)
        if r.get("late_sends") is not None:
            row(base + "send_frames_missed", r["send_frames_missed_p50"], r["send_frames_missed_p95"], "frames", 0, 0.5)
            row(base + "late_sends", r["late_sends"], r["late_sends"], "sends", 0, 0.5)
        split = None if r["reserved_same_frame_share"] is None else round((1 - r["reserved_same_frame_share"]) * r["sends"])
        row(base + "reserved_late_sends", split, split, "sends", 0, 0.5)
        row(base + "shifts_per_send", r["shifts_per_send_mean"], r["shifts_per_send_max"], "shifts", 0, 0.5)
        row(base + "send_first_token", r["send_first_token_p50_ms"], r["send_first_token_p95_ms"], "ms", None, 20.0)
        row(base + "chat_switch_paint", r["chat_switch_paint_p50_ms"], r["chat_switch_paint_p95_ms"], "ms", FRAME_MS, 4.0)
        row(base + "failed_sends", r["failed_sends"], r["failed_sends"], "sends", 0, 0.5)
        if r.get("transitions"):
            row(base + "shifts_per_transition", r["shifts_per_transition_mean"], r["shifts_per_transition_max"], "shifts", 0, 0.5)
            row(base + "failed_transitions", r["failed_transitions"], r["failed_transitions"], "transitions", 0, 0.5)
    return out


def git_sha():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def report_of(duress, surface, mode, sends, switches, transitions=(), **extra):
    return {"schema": SCHEMA, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "sha": git_sha(),
            "host": socket.gethostname().split(".")[0], "platform": "mac", "surface": surface, "mode": mode,
            "duress": duress, "rows": rows_of(sends, switches, transitions), "sendList": sends, "switchList": switches,
            "transitionList": list(transitions), **extra}


def summarize(path, since_s=None):
    """The perf watch's page spans (perf-watch.jsonl) as snappy-bench/v1 reports, one for each transport. A "send"
    span: parts "user row painted", "reserved turn painted", "first token" (ms from the keydown), detail.detail its
    shifts, sameFrame and transport. A "chat switch" span: its ms."""
    by = {}
    cutoff = time.time() - since_s if since_s else None
    with open(os.path.expanduser(path)) as lines:
        for line in lines:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("kind") != "span":
                continue
            at = event.get("at") or event.get("atMs")
            if cutoff and isinstance(at, (int, float)) and (at / 1000 if at > 1e11 else at) < cutoff:
                continue
            detail = (event.get("detail") or {}).get("detail") or {}
            detail = detail if isinstance(detail, dict) else {}
            transport = detail.get("transport") or "local"
            bucket = by.setdefault(transport, {"sends": [], "switches": []})
            if event.get("name") == "send":
                parts = {p.get("name"): p for p in event.get("parts") or [] if isinstance(p, dict)}
                end = lambda name: (lambda p: p.get("startMs", 0) + p.get("ms", 0) if p else None)(parts.get(name))
                user, reserved = end("user row painted"), end("reserved turn painted")
                bucket["sends"].append({
                    "userPaintMs": user if user is not None else event.get("ms"),
                    "reservedPaintMs": reserved,
                    "sameFrame": detail.get("sameFrame", user is not None and reserved == user),
                    "firstTokenMs": detail.get("firstTokenMs", end("first token")),
                    "shifts": detail.get("shifts"), "shiftScore": detail.get("shiftScore"),
                    "freshChat": detail.get("freshChat"), "rows": detail.get("rows"),
                })
            elif event.get("name") == "chat switch":
                bucket["switches"].append({"visibleToPaintMs": event.get("ms")})
    return [report_of("live", "cloud" if transport == "cloud" else "local", "passive", b["sends"], b["switches"],
                      transport=transport) for transport, b in sorted(by.items())]


parser = argparse.ArgumentParser()
parser.add_argument("--app")
parser.add_argument("--out")
parser.add_argument("--duress", default=",".join(DURESS))
parser.add_argument("--sends", type=int, default=12)
parser.add_argument("--switches", type=int, default=8)
parser.add_argument("--transitions", type=int, default=4, help="mid-turn sends and compactions, each, per duress")
parser.add_argument("--tabs", type=int, default=12)
parser.add_argument("--cpu-load", action="store_true", help="recorded only: the fleet entry starts the load")
parser.add_argument("--summarize", metavar="PERF_WATCH_JSONL")
parser.add_argument("--since", type=float, help="with --summarize: only spans of the last N seconds")
parser.add_argument("--json", help="also a perf-cron report (budgets kind): split-spring's --suite=chat-snappy passes it")
opts, _rest = parser.parse_known_args()  # split-spring's own args (--tag) are not this bench's

if opts.summarize:
    reports = summarize(opts.summarize, opts.since)
    print(json.dumps({"schema": SCHEMA, "reports": reports}))
    sys.exit(0 if reports else 1)
if not opts.app or not opts.out:
    parser.error("--app and --out (or --summarize)")

sys.path.insert(0, NEXT)
import bench_launch  # noqa: E402
SPEC = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(NEXT, "perf-stress-session.py"))
STRESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STRESS)
PROBE = open(os.path.join(ROOT, "webviews", "bench", "snappy-probe.js")).read()
wait = STRESS.wait
os.makedirs(opts.out, exist_ok=True)


class Page:
    """A chat's page, by its Chromium browser id: JavaScript and input through DevTools (as send-pop-films.py)."""

    def __init__(self, app, browser):
        self.app, self.browser = app, browser

    def devtools(self, method, params, timeout=40):
        reply = self.app.rpc("debug.cef_page_devtools", {"browser": self.browser, "method": method, "params": params}, timeout)
        if not isinstance(reply, dict) or reply.get("error"):
            raise RuntimeError(f"{method}: {str(reply)[:300]}")
        return json.loads(reply.get("result") or "{}")

    def js(self, expression, timeout=40):
        answer = self.devtools("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True}, timeout)
        if answer.get("exceptionDetails"):
            raise RuntimeError(f"page threw: {json.dumps(answer['exceptionDetails'])[:400]}")
        return (answer.get("result") or {}).get("value")

    def type(self, text):
        self.devtools("Input.insertText", {"text": text})

    def enter(self):
        for kind in ("keyDown", "keyUp"):
            self.devtools("Input.dispatchKeyEvent", {"type": kind, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13,
                                                     "nativeVirtualKeyCode": 13, **({"text": "\r"} if kind == "keyDown" else {})})

    def focus_end(self):
        self.js(f"(() => {{ const f = document.querySelector({json.dumps(FIELD)}); f.focus(); const s = getSelection(); "
                "s.selectAllChildren(f); s.collapseToEnd(); return true; })()")

    def clear(self):
        self.js(f"(() => {{ const f = document.querySelector({json.dumps(FIELD)}); f.focus(); "
                "document.execCommand('selectAll'); document.execCommand('delete'); return true; })()")

    def running(self):
        return self.js("[...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Stop' || "
                       "b.getAttribute('aria-label') === 'Stop' || b.getAttribute('title') === 'Stop')")

    def idle(self, seconds=30):
        wait(lambda: not self.running(), seconds, step=0.3)
        time.sleep(0.4)


def agent_page(app, pane):
    """The agent page that draws `pane`'s chat: each candidate page gets a mark naming its browser id, and
    `debug.agent_pane` query on the pane reads the mark of the pane's own page (as send-pop-films.py)."""
    seen = []

    def find():
        seen.clear()
        candidates = {}
        for page in (app.rpc("debug.cef_pages", timeout=30) or {}).get("pages") or []:
            if not str(page.get("origin", "")).startswith("cmux-page://cmux.agent"):
                continue
            candidate = Page(app, page["browser"])
            try:
                if not candidate.js("'cmuxAcpmuxDebug' in window && !!window.cmuxAcpmuxDebug?.loadSeed && !!document.querySelector("
                                    + json.dumps(FIELD) + ")"):
                    continue
                candidate.js("(() => { let m = document.getElementById('snappy-bench-mark'); if (!m) { m = document.createElement('div');"
                             " m.id = 'snappy-bench-mark'; m.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;"
                             "overflow:hidden;opacity:0.01'; document.body.append(m); } m.textContent = 'browser-"
                             + str(page["browser"]) + "'; return true; })()")
                candidates[page["browser"]] = candidate
            except RuntimeError as error:
                seen.append((page["browser"], str(error)[:120]))
        reply = json.dumps(app.rpc("debug.agent_pane", {"action": "query", "pane": pane, "selector": "#snappy-bench-mark"}, 20))
        for browser, candidate in candidates.items():
            if f"browser-{browser}\"" in reply or f"browser-{browser}'" in reply:
                return candidate
        return None
    found = wait(find, 60, step=1)
    if found:
        return found
    raise RuntimeError(f"no agent page with the pane's mark: {seen}")


def chat(app, st):
    """A new workspace holding one agent chat: (workspace, pane, page)."""
    workspace = st.new_workspace()
    if not workspace:
        raise RuntimeError("no new workspace")
    st.show(workspace)
    pane = wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 30, step=0.05)
    shell = next((t.get("id") for t in st.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
    st.add_tab(workspace, pane, "chat")
    if shell:
        st.action("closeTab", target=f"tab:{shell}", focus=False)
    ready = wait(lambda: (lambda r: r if isinstance(r, dict) and not r.get("error") else None)(
        app.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, 30)), 40, step=0.5)
    if not ready:
        raise RuntimeError("the chat page was not ready in 40 s")
    return workspace, pane, agent_page(app, pane)


def seed(page, turns):
    loaded = page.js(f"window.cmuxAcpmuxDebug.loadSeed({turns}).then((r) => JSON.stringify(r ?? null))", timeout=90)
    page.js(PROBE)
    say("seed", turns, str(loaded)[:160])


def send(page, marker):
    """One send: the marker typed, the probe armed, a real Return, the reply's first token waited for (30 s)."""
    page.focus_end()
    page.type(marker)
    time.sleep(0.25)  # the composer's own input frames settle before the measured key
    page.js(f"window.__snappyProbe.arm({json.dumps(marker)})")
    page.enter()
    wait(lambda: (page.js("window.__snappyProbe.status()") or {}).get("token"), 30, step=0.1)
    time.sleep(0.3)  # the frames just after the first token: a reserve that does not hold it shifts here
    return page.js("window.__snappyProbe.result()") or {"error": "no result"}


def mid_turn(page, marker):
    """Enter while a turn runs: a turn started (its first token seen), then `marker` sent into it, its shifts watched
    from the Enter to 1 s after `marker`'s row paints (a steer's row now, a queued prompt's when it dequeues)."""
    send(page, f"{marker}-turn")
    page.clear()
    page.focus_end()
    page.type(marker)
    time.sleep(0.25)
    page.js("window.__snappyProbe.watchArm('mid-turn')")
    page.enter()
    painted = wait(lambda: page.js(f"window.__snappyProbe.seen({json.dumps(marker)})"), 30, step=0.1)
    time.sleep(1.0)
    out = page.js("window.__snappyProbe.watchResult()") or {"error": "no result"}
    if not painted:
        out["error"] = "the mid-turn prompt's row never painted"
    return out


def compaction(page):
    """/compact: its shifts from the Enter to 0.5 s after its note ends. A first Return that picks the command in the
    slash menu leaves `/compact` in the composer: a second sends it."""
    page.focus_end()
    page.type("/compact")
    time.sleep(0.25)
    page.js("window.__snappyProbe.watchArm('compaction')")
    page.enter()
    if not wait(lambda: page.running() or page.js("window.__snappyProbe.compacted()"), 1.5, step=0.1):
        page.enter()
    ended = wait(lambda: page.js("window.__snappyProbe.compacted()"), 30, step=0.1)
    time.sleep(0.5)
    out = page.js("window.__snappyProbe.watchResult()") or {"error": "no result"}
    if not ended:
        out["error"] = "no compaction note ended"
    return out


def mid_compaction(page, marker):
    """A prompt sent while /compact runs (shadow-leo for Leo: "a message sent mid-compaction shifts layout"): /compact
    sent, its note seen running, then `marker` sent into it; shifts from that Enter to 1 s after `marker`'s row paints."""
    page.focus_end()
    page.type("/compact")
    time.sleep(0.25)
    page.enter()
    if not wait(lambda: page.running(), 1.5, step=0.05):
        page.enter()
    # A running compaction draws as the turn's live line ("Compacting conversation…", Thinking.tsx data-compacting),
    # a note only once a steer or reply comes after it.
    running = wait(lambda: page.js("document.querySelector('[data-compacting], .cv-compaction[data-state=running]') !== null"),
                   5, step=0.03)
    page.focus_end()
    page.type(marker)
    page.js("window.__snappyProbe.watchArm('mid-compaction')")
    page.enter()
    painted = wait(lambda: page.js(f"window.__snappyProbe.seen({json.dumps(marker)})"), 30, step=0.1)
    time.sleep(1.0)
    out = page.js("window.__snappyProbe.watchResult()") or {"error": "no result"}
    if not running:
        out["error"] = "no compaction note ran"
    elif not painted:
        out["error"] = "the prompt sent mid-compaction never painted"
    return out


def switch_once(st, page, here, there):
    """`there`'s workspace shown, then `here`'s again: `here`'s page from turning visible to its first frame with rows."""
    st.show(there)
    time.sleep(0.6)
    page.js("window.__snappyProbe.switchArm()")
    started = time.monotonic()
    st.show(here)
    # A page the app keeps visible while hidden never fires visibilitychange: that is an error row, not a hang.
    wait(lambda: page.js("window.__snappyProbe.switchStatus().painted"), 5, step=0.05)
    out = page.js("window.__snappyProbe.switchResult()") or {"error": "no result"}
    out["showMs"] = round((time.monotonic() - started) * 1000, 1)
    return out


reports = []
app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, log_name="app.log")
app.launch()
try:
    st = STRESS.Stress(app.rpc)
    other = None
    for duress in opts.duress.split(","):
        if duress not in DURESS:
            raise SystemExit(f"unknown duress {duress}: one of {', '.join(DURESS)}")
        say("duress", duress)
        workspace, pane, page = chat(app, st)
        seed(page, 1000 if duress == "long-session" else 4)
        extra = {"cpuLoad": opts.cpu_load}
        if duress == "many-tabs":
            opened = 0
            for _ in range(opts.tabs):
                try:
                    chat(app, st)
                    opened += 1
                except RuntimeError as error:
                    say("extra chat:", str(error)[:160])
            extra["tabs"] = opened
            st.show(workspace)
            page = agent_page(app, pane)
            page.js(PROBE)
        if duress == "offline":
            page.devtools("Network.enable", {})
            page.devtools("Network.emulateNetworkConditions", {"offline": True, "latency": 0, "downloadThroughput": -1,
                                                               "uploadThroughput": -1})
        # A warm-up send, not judged: the first send loads the transcript's lazy chunks.
        send(page, f"snappy-warmup-{duress}")
        page.idle()
        sends = []
        for index in range(opts.sends):
            marker = f"snappy-{duress}-{index}"
            try:
                row = send(page, marker)
            except RuntimeError as error:
                row = {"error": str(error)[:300]}
                page = agent_page(app, pane)
                page.js(PROBE)
            row["marker"] = marker
            sends.append(row)
            say(json.dumps(row))
            try:
                page.idle()
                page.clear()
            except RuntimeError as error:
                say("after the send:", str(error)[:160])
        transitions = []
        for index in range(opts.transitions):
            for kind, run in (("mid-turn", lambda: mid_turn(page, f"snappy-{duress}-mid-{index}")), ("compaction", lambda: compaction(page)),
                              ("mid-compaction", lambda: mid_compaction(page, f"snappy-{duress}-midc-{index}"))):
                try:
                    row = run()
                except RuntimeError as error:
                    row = {"kind": kind, "error": str(error)[:300]}
                    page = agent_page(app, pane)
                    page.js(PROBE)
                row["kind"] = kind
                transitions.append(row)
                say(json.dumps(row))
                try:
                    page.idle()
                    page.clear()
                except RuntimeError as error:
                    say(f"after the {kind}:", str(error)[:160])
        switches = []
        if opts.switches:
            other = other or chat(app, st)[0]
            for _ in range(opts.switches):
                try:
                    switches.append(switch_once(st, page, workspace, other))
                except (RuntimeError, STRESS.StressShapeError) as error:
                    switches.append({"error": str(error)[:200]})
            say("switches", json.dumps(switches)[:400])
        if duress == "offline":
            page.devtools("Network.emulateNetworkConditions", {"offline": False, "latency": 0, "downloadThroughput": -1,
                                                               "uploadThroughput": -1})
        report = report_of(duress, "local", "active", sends, switches, transitions, app=os.path.basename(opts.app), **extra)
        reports.append(report)
        say(duress, json.dumps(report["rows"]))
finally:
    summary = {"schema": SCHEMA, "reports": reports}
    with open(os.path.join(opts.out, "snappy.json"), "w") as out:
        json.dump(summary, out, indent=2)
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump({**summary, "rows": cron_rows(reports), "incomplete": len(reports) < len(opts.duress.split(","))}, out, indent=2)
    app.stop()
print(json.dumps({"schema": SCHEMA, "rows": {r["duress"]: r["rows"] for r in reports}}))
sys.exit(0 if reports and all(r["rows"]["sends"] for r in reports) else 1)
