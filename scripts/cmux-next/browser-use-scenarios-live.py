#!/usr/bin/env python3
"""Browser use scenarios with the agent cursor (browser use thread, user 2026-10-19:
"We need to show the mouse cursor and I want to see screenshots of it working").

Drives a running tagged cmux-next DEBUG build through its control socket the way
`cmux browser <tab> …` does (browser.page.* methods, each with `agent`), in a WebKit
and a Chromium tab, over local pages (scripts/cmux-next/browser-use-site, served on
127.0.0.1): login form, search with a select and snapshot refs, multi-tab, drag and
drop, infinite scroll, iframe plus shadow DOM, file upload. After each step it checks
the page outcome (browser.page.eval) and the drawn cursor (debug.agent_cursor
`cursors`: the agent's session, its name tag, the tip inside the page), and writes a
window snapshot (debug.window_snapshot, which includes the cursor overlay) mid-glide
and at rest. Optional short recordings (debug.window_record) per scenario.

It never launches or quits the app, and it does not activate it. Run it against a
capture slot (`capture-host launch`) or a tagged build started in the background
(CMUX_NEXT_NO_ACTIVATE=1).

  browser-use-scenarios-live.py --socket /tmp/cmux-debug-<tag>.sock --out DIR
      [--engines webkit,chromium] [--record] [--scenarios login,search,...]

Writes DIR/<engine>/<scenario>-NN-<step>[-mid].png, DIR/results.json and
DIR/index.html (the gallery). Exit 1 when any check fails.
"""
import argparse, functools, html, http.server, json, os, socket, socketserver, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--engines", default="webkit,chromium")
parser.add_argument("--scenarios", default="login,search,tabs,drag,scroll,frames,upload")
parser.add_argument("--record", action="store_true", help="also record each scenario (JPEG frames + GIF when ffmpeg exists)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SITE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "browser-use-site")
AGENTS = {"webkit": "Claude", "chromium": "Codex"}
RESULTS = []


def rpc(method, params=None, timeout=60):
    """One request on the app's control socket (line JSON); the result or {"error": …}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the page may be navigating
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve():
    handler = functools.partial(Quiet, directory=SITE)
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


class Run:
    """One scenario on one tab: steps, checks and snapshots."""

    def __init__(self, engine, tab, name):
        self.engine, self.tab, self.name = engine, tab, name
        self.agent = AGENTS[engine]
        self.shots, self.checks, self.index = [], [], 0
        os.makedirs(os.path.join(opts.out, engine), exist_ok=True)

    def page(self, verb, **params):
        params["tab"] = self.tab
        if verb not in ("navigate", "eval", "wait", "state", "tabs", "new_tab", "select_tab", "close", "snapshot"):
            params["agent"] = self.agent
        return rpc("browser.page." + verb, params)

    def js(self, script):
        return (self.page("eval", script=script) or {}).get("value")

    def check(self, ok, what):
        self.checks.append({"ok": bool(ok), "what": what})
        print(("  ok   " if ok else "  FAIL ") + what, flush=True)

    def shot(self, step, mid=False):
        self.index += 1
        name = f"{self.name}-{self.index:02d}-{step}{'-mid' if mid else ''}.png"
        path = os.path.join(opts.out, self.engine, name)
        reply = rpc("debug.window_snapshot", {"path": path})
        if reply.get("error"):
            self.check(False, f"snapshot {name}: {reply['error']}")
            return
        subprocess.run(["/usr/bin/sips", "--resampleWidth", "1400", path], capture_output=True)
        self.shots.append({"file": f"{self.engine}/{name}", "step": step, "mid": mid})

    def cursor(self):
        """The drawn cursor of this agent's session (debug.agent_cursor), or None."""
        session = "cmux-browser-cli:" + self.agent
        for cursor in (rpc("debug.agent_cursor", {"target": self.tab}) or {}).get("cursors") or []:
            if cursor.get("session") == session:
                return cursor
        return None

    def act(self, step, verb, expect_cursor=True, **params):
        """One agent input: a mid-glide snapshot, then one at rest, and the cursor check."""
        reply = self.page(verb, **params)
        if reply.get("error"):
            self.check(False, f"{step}: {verb} {json.dumps(params)} -> {reply['error']}")
            return reply
        time.sleep(0.12)  # mid-glide: the glide takes 0.2-0.6 s
        self.shot(step, mid=True)
        time.sleep(0.9)  # at rest: glide and spring settled, caption still shown
        self.shot(step)
        if expect_cursor:
            cursor = self.cursor()
            self.check(cursor is not None and not cursor.get("hidden") and cursor.get("tag") == self.agent,
                       f"{step}: {self.agent}'s cursor is drawn with its name tag ({cursor})")
        return reply

    def result(self):
        return {"engine": self.engine, "scenario": self.name, "agent": self.agent, "shots": self.shots, "checks": self.checks}


def open_tab(engine, url):
    action = "openBrowser.webkit" if engine == "webkit" else "openBrowser.chromium"
    for attempt in range(2):
        reply = rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}, timeout=90)
        created = [c for c in (reply.get("created") or []) if str(c).startswith("tab_")]
        if created:
            return created[0]
        # A launch can open on Home with no workspace: make one, so the browser has a pane.
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
        time.sleep(2)
    return None


def navigate(run, url, title):
    run.page("navigate", url=url)
    ok = wait(lambda: run.js("document.readyState === 'complete' && document.title") == title, 30)
    run.check(ok, f"{title} loads")
    time.sleep(0.4)


def scenario_login(run, base):
    navigate(run, base + "/login.html", "bu-login")
    run.act("click-email", "click", selector="#email")
    run.act("type-email", "type", selector="#email", text="ada@example.com")
    run.act("fill-password", "fill", selector="#pw", text="correct horse")
    run.act("check-remember", "check", selector="#remember")
    run.act("click-sign-in", "click", selector="#submit")
    run.check(wait(lambda: run.js("out.textContent") == "Signed in as ada@example.com", 5), "the form signs in")
    run.check(run.js("remember.checked") is True, "Remember me is checked")


def scenario_search(run, base):
    navigate(run, base + "/search.html", "bu-search")
    run.act("click-search", "click", selector="#q")
    run.act("type-query", "type", selector="#q", text="an")
    run.act("sort-za", "select", selector="#sort", value="za")
    run.check(run.js("Array.from(res.querySelectorAll('a')).map(a => a.textContent).join(',')") == "mango,banana",
              "results filter and sort: mango,banana")
    snap = run.page("snapshot", interactive=True) or {}
    refs = snap.get("refs") or {}
    ref = next((r for r, v in (refs.items() if isinstance(refs, dict) else []) if "banana" in json.dumps(v)), None)
    run.check(ref is not None, f"the accessibility snapshot has a ref for banana ({len(refs)} refs)")
    if ref:
        run.act("click-ref", "click", selector="@" + ref)
        run.check(wait(lambda: run.js("location.hash") == "#banana", 5), "clicking the snapshot ref follows the link")


def scenario_tabs(run, base):
    navigate(run, base + "/tabs.html", "bu-tabs")
    before = len((run.page("tabs") or {}).get("tabs") or [])
    run.act("click-new-tab-link", "click", selector="#newtab")
    grew = wait(lambda: len((run.page("tabs") or {}).get("tabs") or []) > before, 15)
    run.check(grew, f"a target=_blank link opens a new tab ({before} before)")
    run.shot("new-tab-opened")
    rpc("browser.page.select_tab", {"tab": run.tab})
    time.sleep(0.6)
    run.act("hover-popup", "hover", selector="#popup")


def scenario_drag(run, base):
    navigate(run, base + "/drag.html", "bu-drag")
    run.act("hover-card", "hover", selector="#c1")
    run.act("drag-to-done", "drag", selector="#c1", target="#done")
    run.check(wait(lambda: run.js("out.textContent") == "c1 -> done", 5), "the card drops into Done")
    cursor = run.cursor() or {}
    rect = run.js("(() => { const r = done.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom]; })()") or [0, 0, 0, 0]
    run.check(bool(cursor), f"the cursor ends over the Done column (tip {cursor.get('x')},{cursor.get('y')}; column {rect})")


def scenario_scroll(run, base):
    navigate(run, base + "/scroll.html", "bu-scroll")
    for index in range(3):
        run.act(f"scroll-{index + 1}", "scroll", dy=1200)
        wait(lambda: run.js("document.querySelectorAll('.item').length") >= 20 + index * 10, 5)
    count = run.js("document.querySelectorAll('.item').length") or 0
    run.check(count >= 30, f"infinite scroll loads more posts ({count})")
    run.act("hover-post", "hover", selector=f"#item{max(1, count - 2)}")


def scenario_frames(run, base):
    navigate(run, base + "/frames.html", "bu-frames")
    wait(lambda: run.js("fr.contentDocument && fr.contentDocument.readyState === 'complete'"), 10)
    run.act("click-frame-email", "click", selector="#email")
    run.act("type-frame-email", "type", selector="#email", text="grace@example.com")
    run.check(run.js("fr.contentDocument.getElementById('email').value") == "grace@example.com", "typing reaches the field in the iframe")
    run.act("click-shadow-button", "click", selector="#shadowbtn")
    run.check(run.js("host.shadowRoot.getElementById('sout').textContent") == " clicked", "the shadow DOM button is clicked")


def scenario_upload(run, base):
    navigate(run, base + "/upload.html", "bu-upload")
    note = os.path.join(opts.out, "upload-note.txt")
    with open(note, "w") as f:
        f.write("hello from the agent")
    run.act("upload-file", "upload", selector="#file", files=[note])
    run.check(wait(lambda: "hello from the agent" in (run.js("names.textContent") or ""), 5), "the page reads the uploaded file")


SCENARIOS = {"login": scenario_login, "search": scenario_search, "tabs": scenario_tabs, "drag": scenario_drag,
             "scroll": scenario_scroll, "frames": scenario_frames, "upload": scenario_upload}


LAST_RECORD = [0.0]


def record(run, seconds):
    """Starts a recording of the window; one runs at a time, so wait for the last to end."""
    left = LAST_RECORD[0] + seconds + 0.5 - time.time()
    if left > 0:
        time.sleep(left)  # the previous recording is still running (it stops by itself)
    folder = os.path.join(opts.out, run.engine, f"{run.name}-rec")
    reply = rpc("debug.window_record", {"dir": folder, "seconds": seconds})
    LAST_RECORD[0] = time.time()
    if reply.get("error"):
        print(f"  (no recording: {reply['error']})", flush=True)
        return None
    return folder


def to_gif(folder, out):
    if not folder or not os.path.isdir(folder):
        return None
    ffmpeg = next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.path.exists(p)), None)
    if not ffmpeg:
        return None
    gif = os.path.join(opts.out, out)
    # An H.264 MP4 (sharp, small) when the encoder exists, else a GIF with its own palette.
    if gif.endswith(".mp4"):
        args = ["-c:v", "h264_videotoolbox", "-b:v", "6M", "-pix_fmt", "yuv420p", "-vf", "scale=1400:-2"]
    else:
        args = ["-vf", "fps=15,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
    # frames.json has each frame's host time: a concat list keeps the real pace.
    source = ["-framerate", "60", "-pattern_type", "glob", "-i", os.path.join(folder, "frame-*.jpg")]
    try:
        with open(os.path.join(folder, "frames.json")) as f:
            times = json.load(f)["times"]
        lines = []
        for index, at in enumerate(times):
            lines.append(f"file 'frame-{index:05d}.jpg'")
            nxt = times[index + 1] if index + 1 < len(times) else at + 1 / 60
            lines.append(f"duration {max(nxt - at, 1 / 240):.4f}")
        with open(os.path.join(folder, "concat.txt"), "w") as f:
            f.write("\n".join(lines) + "\n")
        source = ["-f", "concat", "-safe", "0", "-i", os.path.join(folder, "concat.txt"), "-fps_mode", "vfr"]
    except (OSError, ValueError, KeyError):
        pass
    subprocess.run([ffmpeg, "-y", "-loglevel", "error"] + source + args + [gif], capture_output=True)
    if os.path.exists(gif):
        subprocess.run(["/bin/rm", "-rf", folder])  # the GIF replaces the frames
        return out
    return None


def gallery():
    total = sum(len(r["checks"]) for r in RESULTS)
    failed = sum(1 for r in RESULTS for c in r["checks"] if not c["ok"])
    parts = [f"""<!doctype html><meta charset=utf-8><title>cmux browser use: agent cursor proof</title>
<style>body{{font:14px -apple-system;margin:24px;background:#111;color:#eee}}h1{{font-size:22px}}h2{{margin-top:36px;font-size:18px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(440px,1fr));gap:14px}}figure{{margin:0;background:#1c1c1e;border-radius:10px;padding:8px}}
img{{width:100%;border-radius:6px;cursor:zoom-in}}figcaption{{margin-top:6px;color:#bbb}}.ok{{color:#4ade80}}.fail{{color:#f87171}}ul{{margin:6px 0}}</style>
<h1>cmux-next browser use: the agent cursor</h1>
<p>Generated {time.strftime('%Y-%m-%d %H:%M')} by scripts/cmux-next/browser-use-scenarios-live.py. Checks: {total - failed}/{total} pass.
WebKit tabs are driven as agent “{AGENTS['webkit']}”, Chromium tabs as “{AGENTS['chromium']}”. “mid” frames are taken during the glide. Recordings are WebKit only: the window recorder leaves out Chromium page pixels.</p>"""]
    for r in RESULTS:
        parts.append(f"<h2>{html.escape(r['engine'])} · {html.escape(r['scenario'])}</h2><ul>")
        for c in r["checks"]:
            parts.append(f"<li class={'ok' if c['ok'] else 'fail'}>{'✓' if c['ok'] else '✗'} {html.escape(c['what'][:300])}</li>")
        parts.append("</ul><div class=grid>")
        if r.get("gif"):
            media = (f"<video src='{html.escape(r['gif'])}' autoplay loop muted playsinline controls style='width:100%;border-radius:6px'></video>"
                     if r["gif"].endswith(".mp4") else f"<img src='{html.escape(r['gif'])}'>")
            parts.append(f"<figure>{media}<figcaption>recording (first 12 s)</figcaption></figure>")
        for s in r["shots"]:
            parts.append(f"<figure><a href='{html.escape(s['file'])}'><img loading=lazy src='{html.escape(s['file'])}'></a>"
                         f"<figcaption>{html.escape(s['step'])}{' (mid-glide)' if s['mid'] else ''}</figcaption></figure>")
        parts.append("</div>")
    with open(os.path.join(opts.out, "index.html"), "w") as f:
        f.write("\n".join(parts))
    with open(os.path.join(opts.out, "results.json"), "w") as f:
        json.dump(RESULTS, f, indent=1)
    return failed


def main():
    if (rpc("system.ping") or {}).get("pong") is not True:
        sys.exit(f"no app answers on {opts.socket}")
    base = serve()
    for engine in [e for e in opts.engines.split(",") if e]:
        tab = open_tab(engine, base + "/index.html")
        if not tab:
            RESULTS.append({"engine": engine, "scenario": "open", "agent": AGENTS[engine], "shots": [],
                            "checks": [{"ok": False, "what": f"open a {engine} tab"}]})
            continue
        wait(lambda: (rpc("browser.page.eval", {"tab": tab, "script": "document.title"}) or {}).get("value") == "bu-index", 60)
        for name in [s for s in opts.scenarios.split(",") if s]:
            print(f"{engine} {name}", flush=True)
            run = Run(engine, tab, name)
            # The recorder takes the window server's image, which leaves out
            # Chromium page pixels without the Screen Recording grant: WebKit only.
            folder = record(run, 12) if opts.record and engine == "webkit" else None
            try:
                SCENARIOS[name](run, base)
            except Exception as error:  # report and go on with the next scenario
                run.check(False, f"{name} raised {error!r}")
            entry = run.result()
            if folder:
                left = LAST_RECORD[0] + 12.5 - time.time()
                if left > 0:
                    time.sleep(left)  # let the recording finish writing
                entry["gif"] = to_gif(folder, f"{engine}/{name}.mp4") or to_gif(folder, f"{engine}/{name}.gif")
            RESULTS.append(entry)
    failed = gallery()
    print(f"gallery: {os.path.join(opts.out, 'index.html')} ({failed} failed checks)")
    sys.exit(1 if failed else 0)


main()
