#!/usr/bin/env python3
"""Films and checks of a sent prompt's pop with every shape a prompt takes, in a tagged app's own agent chat.

Leo 2026-11-22: "oh you better probably also watch that attachments and such are good too when the pop is there".
Launches a tagged bench `cmux DEV <tag>.app` with the repository's bench launcher (bench_launch.py `BenchApp`, whose
launch puts the agent page on its in-page mock: no agent, no credentials), opens one agent chat in a new workspace
and, for each chat length of --turns (the mock's `loadSeed`), sends each case of --cases while the app's own
recorder (`debug.motion` record_start: a movie of the window as the window server composites it, every frame)
films it:
  image        one picture                    images      four pictures
  tall         a 900x6000 picture             decoding    a 6000x4000 noise picture, still decoding as it pops
  file         a file chip (a .csv)           pasted-text a paste of 4,000 words (its Pasted text chip)
  image-text   a picture and a sentence       long        a 24-line prompt
  streaming    a prompt sent while the reply before it streams (it waits in the queue and lands as that turn ends)
The attachments go in through the page's own paste path (a ClipboardEvent, as Cmd-V delivers one); the marker text
and the Return are real input (DevTools Input.insertText and Input.dispatchKeyEvent on the chat's page). The page
half of each check is webviews/bench/send-pop-probe.js, the same probe the pane bench runs (bench/send-pop-cases.ts):
the attachments scale with their bubble on every frame of the pop, are drawn from the row's first frame, are not
clipped and do not move after it settles, the transcript lands at its foot with the prompt in view, and the frames
over the send (bench/send-pop-shapes.ts holds the pane's copy of these shapes). Each case runs in each arm of --arms (product, and none: the instant send before, from the same build, for
the frames' baseline). Out: <out>/<turns>-<case>-<arm>.mov (+ .frames.json), <out>/cases.json (one row for each send, with the
probe's facts and `clean`).
Usage: send-pop-films.py --app PATH --out DIR [--turns 4,1000] [--cases image,images,...]
Fleet: scripts/measure/send-pop-films.sh (builds the tagged app first).
"""
import argparse, importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.join(HERE, "..", "cmux-next")
sys.path.insert(0, NEXT)
import bench_launch  # noqa: E402
SPEC = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(NEXT, "perf-stress-session.py"))
STRESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STRESS)
PROBE = open(os.path.join(HERE, "..", "..", "webviews", "bench", "send-pop-probe.js")).read()
LONG = "\n".join(f"line {index + 1}: and the send behaviour too, it pops" for index in range(24))
CASES = {
    "image": {"images": 1},
    "images": {"images": 4},
    "file": {"file": True},
    "tall": {"tall": True},
    "decoding": {"decoding": True},
    "pasted-text": {"pastedText": 4000},
    "image-text": {"images": 1, "text": "here's an example with an attachment too, tho it doesnt necessarily change too much"},
    "long": {"text": LONG},
    "streaming": {"streaming": True},
}
FIELD = ".acpmux-composer-prompt [contenteditable='true'], .ProseMirror.acpmux-md[contenteditable='true']"

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--turns", default="4,1000")
parser.add_argument("--cases", default=",".join(CASES))
parser.add_argument("--mbps", type=int, default=40)
parser.add_argument("--arms", default="product,none",
                    help="product = the pop; none = data-send-pop=none, the instant send before (#42669), same build")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
wait = STRESS.wait


def say(*parts):
    print("send-pop-films:", *parts, flush=True)


class Page:
    """The chat's page, by its Chromium browser id: JavaScript and input through DevTools."""

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

    def running(self):
        return self.js("!!document.querySelector('button[aria-label=\"Stop\"], button[title=\"Stop\"]') || "
                       "[...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Stop' || b.getAttribute('aria-label') === 'Stop')")

    def idle(self, seconds=30):
        wait(lambda: not self.running(), seconds, step=0.3)
        time.sleep(0.4)


def chat_page(app, st):
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
    return pane, agent_page(app, pane)


def agent_page(app, pane):
    """The agent page that draws `pane`'s chat (its browser id changes when the app replaces the page). Several agent
    pages live at once (a spare, the Chief's), all `visible`: each candidate gets a mark naming its browser id, and
    `debug.agent_pane` query on the pane reads the mark of the pane's own page."""
    seen = []

    def find():
        seen.clear()
        candidates = {}
        for page in (app.rpc("debug.cef_pages", timeout=30) or {}).get("pages") or []:
            if not str(page.get("origin", "")).startswith("cmux-page://cmux.agent"):
                continue
            candidate = Page(app, page["browser"])
            try:
                # Only a page whose chat is up: its debug hook and its composer.
                if not candidate.js("'cmuxAcpmuxDebug' in window && !!window.cmuxAcpmuxDebug?.loadSeed && !!document.querySelector("
                                    + json.dumps(FIELD) + ")"):
                    seen.append((page["browser"], "no chat yet"))
                    continue
                candidate.js("(() => { let m = document.getElementById('send-pop-films-mark'); if (!m) { m = document.createElement('div');"
                             " m.id = 'send-pop-films-mark'; m.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;"
                             "overflow:hidden;opacity:0.01'; document.body.append(m); } m.textContent = 'browser-"
                             + str(page["browser"]) + "'; return true; })()")
                candidates[page["browser"]] = candidate
            except RuntimeError as error:
                seen.append((page["browser"], str(error)[:120]))
        reply = app.rpc("debug.agent_pane", {"action": "query", "pane": pane, "selector": "#send-pop-films-mark"}, 20)
        seen.append(("query", json.dumps(reply)[:300]))
        for browser, candidate in candidates.items():
            if f"browser-{browser}\"" in json.dumps(reply) or f"browser-{browser}'" in str(reply):
                return candidate
        return None
    found = wait(find, 60, step=1)
    if found:
        return found
    raise RuntimeError(f"no agent page with the pane's mark: {seen} pages {app.rpc('debug.cef_pages', timeout=30)}")


def film(app, path, seconds):
    read = lambda: (lambda r: r if isinstance(r, dict) else {})(app.rpc("debug.motion", {"action": "record_read"}))
    started = app.rpc("debug.motion", {"action": "record_start", "path": path, "seconds": seconds, "mbps": opts.mbps})
    if not isinstance(started, dict) or started.get("error"):
        raise RuntimeError(f"record_start: {started}")
    wait(lambda: read().get("capturing") or read().get("error"), 10, step=0.1)

    def stop():
        app.rpc("debug.motion", {"action": "record_stop"})
        return wait(lambda: (lambda r: r if r.get("written") or r.get("error") else None)(read()), 60, step=0.25) or {}
    return stop


def send(page, marker, shape):
    page.focus_end()
    # The attach runs on in the page (a 24-megapixel picture takes longer to make than one DevTools call may wait);
    # the script reads its answer when it lands.
    page.js(f"(window.__spAttached = undefined, window.__sendPopProbe.attach({json.dumps(shape)})"
            ".then((r) => { window.__spAttached = r; }, (e) => { window.__spAttached = {error: String(e)}; }), true)")
    attached = wait(lambda: page.js("window.__spAttached ?? null"), 90, step=0.5)
    if attached is None:
        raise RuntimeError("the attach did not end in 90 s")
    page.focus_end()
    page.type(f" {marker}")
    time.sleep(0.2)
    page.js(f"window.__sendPopProbe.arm({json.dumps(marker)})")
    page.enter()
    # A prompt sent while a reply streams waits in the queue and joins the transcript when that turn ends.
    wait(lambda: page.js("[...document.querySelectorAll('.acpmux-row.acpmux-user')].some((r) => r.textContent.includes("
                         + json.dumps(marker) + "))"), 30, step=0.1)
    time.sleep(1.6)
    return {"attached": attached, **(page.js("window.__sendPopProbe.result()") or {})}


def clean(row):
    """The send is clean: it popped, its attachments moved as one with the bubble, drawn from the first frame, not
    clipped, not moved after it settled, and the transcript landed at its foot with the prompt's foot in view."""
    return bool(row.get("popRan") and row.get("allInsideWrapper") and row.get("unitWorst", 1) <= 0.01
                and row.get("firstFrameDrawn") and row.get("lateDrawFrames", 1) == 0 and row.get("clippedPx", 1) <= 0.5
                and row.get("reflowPx", 1) <= 0.5 and row.get("heightJumpPx", 1) <= 0.5 and row.get("endFootPx", 99) <= 2 and row.get("endRowBottomToViewPx", -1) >= 0
                and row.get("attachments") == row.get("attachmentsAtFirstFrame") and not row.get("error"))


report = {"cases": [], "turns": opts.turns, "app": os.path.basename(opts.app)}
app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, log_name="app.log")
app.launch()
try:
    st = STRESS.Stress(app.rpc)
    pane, page = chat_page(app, st)
    say("chat pane", pane, "browser", page.browser)
    def prepare(page, turns):
        loaded = page.js(f"window.cmuxAcpmuxDebug.loadSeed({turns}).then((r) => JSON.stringify(r ?? null))", timeout=60)
        say("seed", turns, str(loaded)[:200])
        page.js(PROBE)
        # Warm-ups, not judged: the first send and the first picture load lazy chunks and the picture path.
        send(page, f"warmup-{turns}", {})
        page.idle()
        send(page, f"warmup-picture-{turns}", {"images": 1})
        page.idle()

    for turns in [int(t) for t in opts.turns.split(",")]:
        prepare(page, turns)
        for name in opts.cases.split(","):
            shape = CASES[name]
            for arm in opts.arms.split(","):
                # The product's pop is off unless switched on (agentPane.display.sendPop): its root gate.
                page.js(f"document.documentElement.setAttribute('data-send-pop', {json.dumps('claude' if arm == 'product' else arm)}), true")
                path = os.path.join(opts.out, f"{turns}-{name}-{arm}.mov")
                stop = film(app, path, 20 if shape.get("streaming") else 8)
                time.sleep(0.4)
                marker = f"{name}-{arm}-{turns}"
                try:
                    if shape.get("streaming"):
                        page.focus_end()
                        page.type(f"{marker}-first: tell me a long story")
                        page.enter()
                        wait(page.running, 5, step=0.1)
                        time.sleep(0.25)
                        row = {"streamingAtSend": bool(page.running()), **send(page, f"{marker}-second", {})}
                    else:
                        row = send(page, marker, {k: v for k, v in shape.items() if k != "streaming"})
                except RuntimeError as error:
                    row = {"error": str(error)[:400]}
                    if "no live page" in str(error) or "closed" in str(error):
                        say("page lost:", str(error)[:200], "crashes:", json.dumps(app.rpc("debug.crashes", timeout=20))[:600])
                        # The app replaced the chat's page (a new browser id): find it again, seed it again.
                        page = agent_page(app, pane)
                        report.setdefault("page_replaced", []).append(f"{turns}-{name}-{arm}: {str(error)[:120]}")
                        say("page replaced; now browser", page.browser)
                        prepare(page, turns)
                movie = stop()
                row.update(turns=turns, case=name, arm=arm, movie=os.path.basename(path), movie_frames=movie.get("frames"),
                           movie_error=movie.get("error") or movie.get("write_error"))
                # The before arm has no pop to judge: its row is the frames' baseline.
                row["clean"] = clean(row) if arm == "product" else None
                report["cases"].append(row)
                say(json.dumps(row))
                try:
                    page.idle()
                    # A case that left the composer full (its send was held) leaves the next one its own composer.
                    page.js(f"(() => {{ const f = document.querySelector({json.dumps(FIELD)}); f.focus(); "
                            "document.execCommand('selectAll'); document.execCommand('delete'); return true; })()")
                except RuntimeError as error:
                    row["after_error"] = str(error)[:300]
                    say("after the case:", str(error)[:200], "crashes:", json.dumps(app.rpc("debug.crashes", timeout=20))[:600])
                    page = agent_page(app, pane)
                    report.setdefault("page_replaced", []).append(f"{turns}-{name}-{arm} after: {str(error)[:120]}")
                    prepare(page, turns)
finally:
    with open(os.path.join(opts.out, "cases.json"), "w") as out:
        json.dump(report, out, indent=2)
    app.stop()
dirty = [f"{row['turns']}-{row['case']}" for row in report["cases"] if row.get("clean") is False]
say("clean" if not dirty else f"not clean: {', '.join(dirty)}")
sys.exit(0 if not dirty else 2)
