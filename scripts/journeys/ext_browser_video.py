"""BROWSER VIDEO suite steps (handoff resize-videos/BROWSER-VIDEO.md): local test pages and browser/agent set-up for the
DevTools, browser pane and agent pane movies. driver.py loads this file on the mini under /usr/bin/python3 (standard
library only; no 3.10 syntax). The movies themselves come from ext_video (video_start, hid_key, video_stop).

Pages (served from 127.0.0.1, no network): `light` is a static, left-anchored 520 px column (rows with colored chips),
a magenta 32 px marker at the document's (8, 408) (the viewport's (8, 8) after the scroll to y=400) and a cyan 20 px
badge fixed 6 px from the viewport's bottom-right; `heavy` adds a 12,000-cell grid that reflows with the width, a canvas
drawn every animation frame and a CSS animation. Both follow prefers-color-scheme: navy in dark, cream in light (each
distinct from DevTools' own background and from the pane fill, so the judge tells page, DevTools and placeholder apart).

Steps (`do`):
  bv_serve       {}                         starts the page server once; ${bv_base} is its URL
  bv_open        {page, scroll?: 400}       a Chromium tab on the page (openBrowser.chromium, focused), waits for its
                                            title, scrolls; ${bv_tab_<page>} is its tab id
  bv_scroll      {page, y?: 400}
  bv_state       {page, as}                 the page's innerWidth, innerHeight, scrollY, devicePixelRatio and color
                                            scheme, plus debug.cef's DevTools frames; kept in the recording's notes
  bv_action      {action, as?, args?}        action.run with origin user; its send time kept under `as`
  bv_devtools    {page, open?: true, timeout?: 5, quiet?: 0.6}  waits for the DevTools state; a StepError when it does not come
  bv_agent       {action, as?, ...params}   debug.agent_pane ACTION (stream, readiness, focus_composer, ...); the reply is
                                            kept in the recording's notes under `as`
"""
import functools
import http.server
import json
import threading
import time

D = None
PAGES = {"light": '<!doctype html>\n<html>\n<head>\n<meta charset="utf-8">\n<meta name="color-scheme" content="light dark">\n<title>bv light</title>\n<style>\n  /* browser-video light page: static, left-anchored, fixed-width content, so a narrower or shorter viewport\n     must not move a single pixel of the column (any change there is a jump or a stretch). */\n  :root { --bg: #fff8e0; --fg: #15171a; --line: #d9c98f; }\n  @media (prefers-color-scheme: dark) { :root { --bg: #0b2a4a; --fg: #d8e4f0; --line: #2f5478; } }\n  html, body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/18px Menlo, monospace; }\n  #col { position: absolute; left: 0; top: 0; width: 520px; }\n  .row { box-sizing: border-box; height: 64px; border-bottom: 1px solid var(--line); padding: 6px 10px; }\n  .chip { display: inline-block; width: 40px; height: 40px; vertical-align: middle; margin-right: 12px; }\n  #marker { position: absolute; left: 8px; top: 408px; width: 32px; height: 32px; background: #ff00ff; }\n  #badge { position: fixed; right: 6px; bottom: 6px; width: 20px; height: 20px; background: #00e0ff; }\n  #tall { position: absolute; left: 0; top: 0; width: 1px; height: 5200px; }\n</style>\n</head>\n<body>\n<div id="tall"></div>\n<div id="col"></div>\n<div id="marker"></div>\n<div id="badge"></div>\n<script>\n  const col = document.getElementById("col");\n  const hues = [0, 32, 64, 120, 180, 220, 270, 310];\n  for (let i = 0; i < 80; i++) {\n    const row = document.createElement("div");\n    row.className = "row";\n    const chip = document.createElement("span");\n    chip.className = "chip";\n    chip.style.background = `hsl(${hues[i % hues.length]}, 70%, 50%)`;\n    row.appendChild(chip);\n    row.appendChild(document.createTextNode(`row ${String(i).padStart(2, "0")}  the quick brown fox ${i * 7919 % 1000}`));\n    col.appendChild(row);\n  }\n</script>\n</body>\n</html>\n', "heavy": '<!doctype html>\n<html>\n<head>\n<meta charset="utf-8">\n<meta name="color-scheme" content="light dark">\n<title>bv heavy</title>\n<style>\n  /* browser-video heavy page: the light page\'s static column, plus a 24,000-node grid that reflows with the\n     viewport width, a canvas drawn every animation frame and a CSS animation. The judge masks what moves\n     before the key (canvas, spinner) and checks the static column as on the light page. */\n  :root { --bg: #fff8e0; --fg: #15171a; --line: #d9c98f; }\n  @media (prefers-color-scheme: dark) { :root { --bg: #0b2a4a; --fg: #d8e4f0; --line: #2f5478; } }\n  html, body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/18px Menlo, monospace; }\n  #col { position: absolute; left: 0; top: 0; width: 520px; }\n  .row { box-sizing: border-box; height: 64px; border-bottom: 1px solid var(--line); padding: 6px 10px; }\n  .chip { display: inline-block; width: 40px; height: 40px; vertical-align: middle; margin-right: 12px; }\n  #marker { position: absolute; left: 8px; top: 408px; width: 32px; height: 32px; background: #ff00ff; }\n  #badge { position: fixed; right: 6px; bottom: 6px; width: 20px; height: 20px; background: #00e0ff; }\n  #grid { position: absolute; left: 540px; right: 0; top: 0; display: flex; flex-wrap: wrap; }\n  #grid span { width: 22px; height: 14px; font-size: 9px; line-height: 14px; overflow: hidden; border: 1px solid var(--line); }\n  #anim { position: absolute; left: 280px; top: 420px; width: 200px; height: 120px; }\n  #spin { position: absolute; left: 60px; top: 420px; width: 120px; height: 120px; border-radius: 60px;\n          border: 10px solid #4a8; border-top-color: transparent; box-sizing: border-box; animation: spin 0.9s linear infinite; }\n  @keyframes spin { to { transform: rotate(360deg); } }\n</style>\n</head>\n<body>\n<div id="col"></div>\n<div id="grid"></div>\n<canvas id="anim" width="400" height="240"></canvas>\n<div id="spin"></div>\n<div id="marker"></div>\n<div id="badge"></div>\n<script>\n  const col = document.getElementById("col");\n  const hues = [0, 32, 64, 120, 180, 220, 270, 310];\n  for (let i = 0; i < 80; i++) {\n    const row = document.createElement("div");\n    row.className = "row";\n    const chip = document.createElement("span");\n    chip.className = "chip";\n    chip.style.background = `hsl(${hues[i % hues.length]}, 70%, 50%)`;\n    row.appendChild(chip);\n    row.appendChild(document.createTextNode(`row ${String(i).padStart(2, "0")}  the quick brown fox ${i * 7919 % 1000}`));\n    col.appendChild(row);\n  }\n  const grid = document.getElementById("grid");\n  const frag = document.createDocumentFragment();\n  for (let i = 0; i < 12000; i++) {\n    const cell = document.createElement("span");\n    cell.textContent = (i * 2654435761 % 997).toString(36);\n    frag.appendChild(cell);\n  }\n  grid.appendChild(frag);\n  const canvas = document.getElementById("anim");\n  const ctx = canvas.getContext("2d");\n  function draw(t) {\n    ctx.fillStyle = "#202830";\n    ctx.fillRect(0, 0, 400, 240);\n    for (let i = 0; i < 60; i++) {\n      ctx.fillStyle = `hsl(${(i * 6 + t / 10) % 360}, 80%, 55%)`;\n      ctx.fillRect((i * 37 + t / 4) % 400, (i * 53) % 240, 18, 18);\n    }\n    requestAnimationFrame(draw);\n  }\n  requestAnimationFrame(draw);\n</script>\n</body>\n</html>\n'}
_server = {}


def install(driver):
    global D
    D = driver


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split(".")[0].split("?")[0]
        body = PAGES.get(name)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def step_bv_serve(j, step):
    if "base" not in _server:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _server["base"] = "http://127.0.0.1:%d" % server.server_address[1]
    j.vars["bv_base"] = _server["base"]
    return {"base": _server["base"]}


def _eval(j, script, tab=None):
    params = {"script": script}
    if tab:
        params["tab"] = tab
    reply = j.app.rpc("browser.page.eval", params) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def _wait(fn, seconds, step=0.1):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = fn()
        if value:
            return value
        time.sleep(step)
    return None


def step_bv_open(j, step):
    page = step["page"]
    if "base" not in _server:
        step_bv_serve(j, {})
    url = "%s/%s.html" % (_server["base"], page)
    reply = j.app.rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True}) or {}
    tab = ((reply.get("created") if isinstance(reply, dict) else None) or [None])[0]
    if not _wait(lambda: _eval(j, "document.title", tab) == "bv " + page, 90, 0.25):
        raise D.StepError("bv_open: the %s page never loaded (tab %s; %s)" % (page, tab, json.dumps(reply)[:300]))
    j.vars["bv_tab_" + page] = tab or ""
    y = int(step.get("scroll", 400))
    _eval(j, "scrollTo(0, %d)" % y, tab)
    time.sleep(0.3)
    return {"tab": tab, "url": url, "state": _state(j, tab)}


def step_bv_scroll(j, step):
    tab = j.vars.get("bv_tab_" + step["page"]) or None
    _eval(j, "scrollTo(0, %d)" % int(step.get("y", 400)), tab)
    return {"tab": tab}


def _state(j, tab):
    value = _eval(j, "JSON.stringify({w: innerWidth, h: innerHeight, y: scrollY, x: scrollX, dpr: devicePixelRatio,"
                     " dark: matchMedia('(prefers-color-scheme: dark)').matches})", tab)
    try:
        return json.loads(value) if isinstance(value, str) else value
    except ValueError:
        return value


def _note(j, name, value):
    rec = getattr(j, "video", None)
    if rec is not None:
        rec["notes"][name] = value


def step_bv_state(j, step):
    tab = j.vars.get("bv_tab_" + step["page"]) or None
    cef = j.app.rpc("debug.cef") or {}
    devtools = cef.get("devtools") if isinstance(cef, dict) else None
    value = {"t": D.now(), "page": _state(j, tab), "devtools": devtools}
    _note(j, step["as"], value)
    return value


def step_bv_agent(j, step):
    params = dict((k, v) for k, v in step.items() if k not in ("do", "as", "title"))
    sent = D.now()
    reply = j.app.rpc("debug.agent_pane", params) or {}
    value = {"t_sent": sent, "t_returned": D.now(), "reply": reply}
    if step.get("as"):
        _note(j, step["as"], value)
    return value


def step_bv_action(j, step):
    """`action.run` ACTION (origin user, as a menu or palette pick) with its send time kept in the recording's notes
    under `as` (the judge counts refreshes from it, as from a hid_key's t_sent)."""
    sent = D.now()
    reply = j.app.rpc("action.run", {"action": step["action"], "origin": "user", "args": step.get("args") or {}})
    value = {"t_sent": sent, "t_returned": D.now(), "action": step["action"], "reply": reply}
    if step.get("as"):
        _note(j, step["as"], value)
    return value


def step_bv_devtools(j, step):
    """Waits (up to `timeout` s, default 5) until the page tab's DevTools is open (`open: true`) or closed, from debug.cef:
    a round whose open or close did not happen must not go on (a missed open would turn the next toggle around)."""
    tab = j.vars.get("bv_tab_" + step["page"]) or None
    want = bool(step.get("open", True))

    def match():
        rows = (j.app.rpc("debug.cef") or {}).get("devtools") or []
        row = next((r for r in rows if isinstance(r, dict) and (not tab or r.get("tab") == tab)), None)
        return row if row is not None and bool(row.get("open")) == want else None
    # No socket call in the first `quiet` s after the key: the frames under test are not shared with a main-actor report.
    time.sleep(float(step.get("quiet", 0.6)))
    row = _wait(match, float(step.get("timeout", 5)), 0.1)
    if row is None:
        raise D.StepError("bv_devtools: DevTools of tab %s did not become %s: %s" % (
            tab, "open" if want else "closed", json.dumps((j.app.rpc("debug.cef") or {}).get("devtools"))[:400]))
    return row


STEPS = {"bv_devtools": step_bv_devtools, "bv_action": step_bv_action, "bv_serve": step_bv_serve, "bv_open": step_bv_open, "bv_scroll": step_bv_scroll, "bv_state": step_bv_state,
         "bv_agent": step_bv_agent}
