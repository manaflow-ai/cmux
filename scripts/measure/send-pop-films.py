#!/usr/bin/env python3
"""Films and checks of a sent prompt's pop with every shape a prompt takes, in a tagged app's own agent chat.

Leo 2026-11-22: "oh you better probably also watch that attachments and such are good too when the pop is there".
Launches a tagged bench `cmux DEV <tag>.app` with the repository's bench launcher (bench_launch.py `BenchApp`, whose
launch puts the agent page on its in-page mock: no agent, no credentials), opens one agent chat in a new workspace
and, for each chat length of --turns (the mock's `loadSeed`), sends each case of --cases while the app's own
recorder (`debug.motion` record_start: a movie of the window as the window server composites it, every frame)
films it:
  image        one picture                    images      four pictures
  file         a file chip (a .csv)           pasted-text a paste of 4,000 words (its Pasted text chip)
  image-text   a picture and a sentence       long        a 24-line prompt
  streaming    a prompt sent while the reply before it streams (it waits in the queue and lands as that turn ends)
The attachments go in through the page's own paste path (a ClipboardEvent, as Cmd-V delivers one); the marker text
and the Return are real input (DevTools Input.insertText and Input.dispatchKeyEvent on the chat's page). The page
half of each check is webviews/bench/send-pop-probe.js, the same probe the pane bench runs (bench/send-pop-cases.ts):
the attachments scale with their bubble on every frame of the pop, are drawn from the row's first frame, are not
clipped and do not move after it settles, the transcript lands at its foot with the prompt in view, and the frames
over the send. Out: <out>/<turns>-<case>.mov (+ .frames.json), <out>/cases.json (one row for each send, with the
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
    for page in (app.rpc("debug.cef_pages", timeout=30) or {}).get("pages") or []:
        if not str(page.get("origin", "")).startswith("cmux-page://") or page.get("hidden"):
            continue
        candidate = Page(app, page["browser"])
        try:
            if candidate.js("'cmuxAcpmuxDebug' in window && !!document.querySelector(" + json.dumps(FIELD) + ")"):
                return pane, candidate
        except RuntimeError:
            continue
    raise RuntimeError(f"no shown cmux page with the chat's composer: {app.rpc('debug.cef_pages', timeout=30)}")


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
    attached = page.js(f"window.__sendPopProbe.attach({json.dumps(shape)})", timeout=40)
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
                and row.get("reflowPx", 1) <= 0.5 and row.get("endFootPx", 99) <= 2 and row.get("endRowBottomToViewPx", -1) >= 0
                and row.get("attachments") == row.get("attachmentsAtFirstFrame") and not row.get("error"))


report = {"cases": [], "turns": opts.turns, "app": os.path.basename(opts.app)}
app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, log_name="app.log")
app.launch()
try:
    st = STRESS.Stress(app.rpc)
    pane, page = chat_page(app, st)
    say("chat pane", pane, "browser", page.browser)
    for turns in [int(t) for t in opts.turns.split(",")]:
        loaded = page.js(f"window.cmuxAcpmuxDebug.loadSeed({turns}).then((r) => JSON.stringify(r ?? null))", timeout=60)
        say("seed", turns, str(loaded)[:200])
        page.js(PROBE)
        send(page, f"warmup-{turns}", {})
        page.idle()
        for name in opts.cases.split(","):
            shape = CASES[name]
            path = os.path.join(opts.out, f"{turns}-{name}.mov")
            stop = film(app, path, 20 if shape.get("streaming") else 8)
            time.sleep(0.4)
            try:
                if shape.get("streaming"):
                    page.focus_end()
                    page.type(f"{name}-first: tell me a long story")
                    page.enter()
                    wait(page.running, 5, step=0.1)
                    time.sleep(0.25)
                    row = {"streamingAtSend": bool(page.running()), **send(page, f"{name}-second-{turns}", {})}
                else:
                    row = send(page, f"{name}-{turns}", {k: v for k, v in shape.items() if k != "streaming"})
            except RuntimeError as error:
                row = {"error": str(error)[:400]}
            movie = stop()
            row.update(turns=turns, case=name, movie=os.path.basename(path), movie_frames=movie.get("frames"),
                       movie_error=movie.get("error") or movie.get("write_error"))
            row["clean"] = clean(row)
            report["cases"].append(row)
            say(json.dumps(row))
            page.idle()
            # A case that left the composer full (its send was held) leaves the next one its own composer.
            page.js(f"(() => {{ const f = document.querySelector({json.dumps(FIELD)}); f.focus(); "
                    "document.execCommand('selectAll'); document.execCommand('delete'); return true; })()")
finally:
    with open(os.path.join(opts.out, "cases.json"), "w") as out:
        json.dump(report, out, indent=2)
    app.stop()
dirty = [f"{row['turns']}-{row['case']}" for row in report["cases"] if not row.get("clean")]
say("clean" if not dirty else f"not clean: {', '.join(dirty)}")
sys.exit(0 if not dirty else 2)
