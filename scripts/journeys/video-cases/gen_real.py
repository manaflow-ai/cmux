#!/usr/bin/env python3
"""gen_real.py [--out DIR]: cmux-ad m28 (Lawrence 2026-11-05: "video evidence of the test where it actually triggers like ctrl
shift hjkl and both terminals and browsers (lots of columns/splits/tabs) is pixel perfect"). One journey, px-real-4c-s1r: a
real layout, not the loud ring fixture:
  4 columns: (p0 T in 2 tabs) | (p1 P text / p2 T man page) | (p3 P fixed header+scrollbar / p4 P dark) | (p5 T in 2 tabs / p6 P heavy)
  terminals: a long `ls -la` listing, a man page in its pager, long log lines (they wrap), a recursive listing;
  pages (Chromium, local files so the film never waits on the network): a text-heavy article, a page with a fixed header and a
  visible scrollbar scrolled to its middle, a dark page, a heavy page (thousands of nodes, shadows and a canvas drawn every frame).
Every page draws a 3 px #00FF80 frame at its own viewport edges (position: fixed), so a film shows where each page laid out:
the judge compares it with its pane edge (page lag, a page past its pane, a non-page color beside a page). The app's shell is
#FF00FF: any magenta inside a pane's area is a gap a person would see. Terminals keep the default dark theme.
Film (x1 and Reduce Motion, 120 Hz, whole window, real HID keys and drags): single Ctrl-Shift-L, H on p0 (columns), J, K on p2
(rows), L, H on p4; Ctrl-Shift-L held 1 s then Ctrl-Shift-H x15 every 33 ms on p0; divider 1 dragged 150 pt right in 1 s and back
in 0.1 s; the first row divider dragged 100 pt down in 1 s and back in 0.1 s. debug.frames raw per film (missed refreshes)."""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_cases as G  # noqa: E402
import gen_pixel as P  # noqa: E402

JID = "px-real-4c-s1r"
SHELL = "#FF00FF"
MARK = "#00FF80"
FRAME_CSS = (f"html::after{{content:'';position:fixed;left:0;top:0;right:0;bottom:0;border:3px solid {MARK};"
             "pointer-events:none;z-index:2147483647}")

TEXT = ("Resizing a pane must never show a frozen, stretched or misplaced frame. "
        "Each paragraph here is long so that it wraps at any width, and the words move as the column changes size. ")
PAGES = {
    "text": ("/tmp/jr-real-text.html", "<!doctype html><meta charset=utf-8><title>text</title><style>body{font:15px/1.5 -apple-system,"
             "Helvetica,sans-serif;margin:16px 20px;color:#222;background:#fff}h1{font-size:22px}p{text-align:justify}" + FRAME_CSS +
             "</style><h1>A text-heavy page</h1>" + "".join(f"<p>{i}. {TEXT * 3}</p>" for i in range(1, 41))),
    "header": ("/tmp/jr-real-header.html", "<!doctype html><meta charset=utf-8><title>header</title><style>body{margin:0;font:14px/1.6 "
               "-apple-system,Helvetica,sans-serif;background:#f4f4f6;color:#222}header{position:fixed;top:0;left:0;right:0;height:44px;"
               "background:#1f6feb;color:#fff;display:flex;align-items:center;padding:0 14px;font-weight:600;z-index:10}main{padding:56px 18px 18px}"
               "::-webkit-scrollbar{width:12px}::-webkit-scrollbar-thumb{background:#888;border-radius:6px}::-webkit-scrollbar-track{background:#ddd}"
               + FRAME_CSS + "</style><header>Fixed header, scrolled to the middle</header><main>" +
               "".join(f"<p>Row {i}: {TEXT}</p>" for i in range(1, 121)) + "</main><script>addEventListener('load',()=>scrollTo(0,"
               "document.body.scrollHeight/2))</script>"),
    "dark": ("/tmp/jr-real-dark.html", "<!doctype html><meta charset=utf-8><title>dark</title><style>body{margin:0;padding:14px 18px;"
             "background:#121417;color:#d7dae0;font:14px/1.5 Menlo,monospace}td{border-bottom:1px solid #2a2e35;padding:4px 10px}"
             + FRAME_CSS + "</style><h2>A dark page</h2><table>" + "".join(f"<tr><td>{i}</td><td>{TEXT[:70]}</td><td>{i * 37 % 1000}</td></tr>"
             for i in range(1, 160)) + "</table>"),
    "heavy": ("/tmp/jr-real-heavy.html", "<!doctype html><meta charset=utf-8><title>heavy</title><style>body{margin:0;font:12px "
              "-apple-system,sans-serif;background:#fafafa}.c{display:inline-block;width:88px;height:40px;margin:4px;border-radius:8px;"
              "box-shadow:0 2px 8px rgba(0,0,0,.25);background:linear-gradient(135deg,#ffd166,#06d6a0);filter:saturate(1.2)}"
              "canvas{width:100%;height:120px;display:block}" + FRAME_CSS + "</style><canvas id=cv></canvas><div id=g></div><script>"
              "const g=document.getElementById('g');for(let i=0;i<3000;i++){const d=document.createElement('div');d.className='c';"
              "d.textContent='card '+i;g.appendChild(d)}const cv=document.getElementById('cv'),x=cv.getContext('2d');function f(t){"
              "cv.width=cv.clientWidth*devicePixelRatio;cv.height=cv.clientHeight*devicePixelRatio;for(let i=0;i<60;i++){"
              "x.fillStyle='hsl('+((t/10+i*6)%360)+',70%,55%)';x.fillRect(i*cv.width/60,0,cv.width/60+1,cv.height)}requestAnimationFrame(f)}"
              "requestAnimationFrame(f)</script>"),
}
LOG = ("/tmp/jr-real-log.sh", "#!/bin/bash\n# long log lines: each wraps at any pane width\nfor i in $(seq 1 160); do "
       "printf '2026-11-05T12:%02d:%02d.%03dZ INFO resize.frame-owner pane=p%d width=%d step=%d message=\"%s\"\\n' $((i/60)) $((i%60)) "
       "$((i*7%1000)) $((i%7)) $((300+i)) $i 'the quick brown fox jumps over the lazy dog while the column resizes and the text wraps "
       "again at the new width'; done\n")
FIXTURE = {"p0": {"kind": "rtui", "fill": None}, "p1": {"kind": "rpage", "fill": MARK}, "p2": {"kind": "rtui", "fill": None},
           "p3": {"kind": "rpage", "fill": MARK}, "p4": {"kind": "rpage", "fill": MARK}, "p5": {"kind": "rtui", "fill": None},
           "p6": {"kind": "rpage", "fill": MARK}}


def settings():
    return {"do": "settings_file", "title": f"set-up: shell {SHELL} (app theme Nord; any magenta inside a pane is a gap), default "
            "dark terminals, no close warning, new columns share the strip, no hover cards",
            "set": {"sidebar": {"hoverCards": {"enabled": False}},
                    "appearance": {"theme": "Builtin Dark", "appTheme": "Nord", "themeEdits": {"Nord/background": SHELL}},
                    "app": {"warnBeforeClosingTab": False}, "layout": {"newColumnWidth": "fitScreen"}}}


def page(name, kind):
    path = PAGES[kind][0]
    return [P.focus(name), {"do": "rpc", "method": "action.run", "params": {"action": "openBrowser", "args": {"url": "file://" + path,
            "engine": "cef"}, "focus": True}, "title": f"set-up: {kind} page {path} in a Chromium tab of {name}"},
            {"do": "wait", "seconds": 2.5, "title": f"set-up: the {kind} page loads (local file)"}]


def typed(text, mark, why):
    return [{"do": "type", "text": text, "enter": True, "mark": mark, "title": why}, {"do": "wait", "seconds": 1.2, "title": "it prints"}]


def layout():
    s = [settings()] + G.first_pane(JID, False)
    s[-1:] = s[-1:]  # first_pane ends with p0 adopted and its prompt neutral
    place = next(st for st in s if st["do"] == "window_place")
    place.update(fraction=[0.0, 0.05, 1.0, 0.9], title="set-up: the window full width, 90% high")
    s += [{"do": "file", "path": path, "text": html, "title": f"set-up: page {path}"} for path, html in PAGES.values()]
    s += [{"do": "file", "path": LOG[0], "text": LOG[1], "title": f"set-up: {LOG[0]}"}]
    s += typed("ls -la /usr/bin /usr/lib | head -400", "p0ls", "set-up: p0 tab 1: a long ls -la")
    s += P.new_tab("p0") + typed(f"bash {LOG[0]}", "p0log", "set-up: p0 tab 2: long log lines")
    # Four columns that all show in the window (splits: a strip of newColumn columns scrolled past the window, ab-m28r1:
    # one vertical divider shown), each split once more into rows, except p0's column.
    s += P.new_pane("p1", "splitRight") + page("p1", "text")
    s += [P.focus("p1")] + P.new_pane("p3", "splitRight") + page("p3", "header")
    s += [P.focus("p3")] + P.new_pane("p5", "splitRight") + typed(f"bash {LOG[0]}", "p5log", "set-up: p5 tab 1: long log lines")
    s += P.new_tab("p5") + typed("ls -laR /usr/share | head -300", "p5lsr", "set-up: p5 tab 2: a recursive listing")
    s += [P.focus("p1")] + P.new_pane("p2", "splitDown") + typed("man ls", "p2man", "set-up: p2: a man page in its pager")
    s += [P.focus("p3")] + P.new_pane("p4", "splitDown") + page("p4", "dark")
    s += [P.focus("p5")] + P.new_pane("p6", "splitDown") + page("p6", "heavy")
    return s + [G.settle(2.0)]


def play(speed):
    land = P.land(speed)
    k = lambda key, mark: [P.press(key, mark), P.rest(land)]
    out = [P.focus("p0"), P.rest(0.3, "focus settles")] + k(P.L, "c-l") + k(P.H, "c-h")
    out += [P.focus("p2"), P.rest(0.3, "focus settles")] + k(P.J, "r-j") + k(P.K, "r-k")
    out += [P.focus("p4"), P.rest(0.3, "focus settles")] + k(P.L, "c4-l") + k(P.H, "c4-h")
    out += [P.focus("p0"), P.rest(0.3, "focus settles"),
            {"do": "rk_hold", "key": "l", "modifiers": ["control", "shift"], "seconds": 1.0, "mark": "hold",
             "title": "Ctrl-Shift-L held 1 s (key auto-repeat)"}, P.rest(land),
            {"do": "rk_press", "key": "h", "modifiers": ["control", "shift"], "count": 15, "gap_ms": 33, "mark": "burst",
             "title": "Ctrl-Shift-H x15, 33 ms apart (real HID)"}, P.rest(land)]
    out += [P.drag({"divider": 1}, [150, 0], 1000, "dslow", "slow drag: divider 1 150 pt right in 1 s"), P.rest(land),
            P.drag({"divider": 1}, [-150, 0], 100, "dfast", "fast drag: 150 pt back in 0.1 s"), P.rest(land),
            P.drag({"row_divider": 0}, [0, 100], 1000, "rslow", "slow drag: row divider 0 100 pt down in 1 s"), P.rest(land),
            P.drag({"row_divider": 0}, [0, -100], 100, "rfast", "fast drag: 100 pt back up in 0.1 s"), P.rest(land)]
    return out


def seconds(speed):
    land = P.land(speed)
    return 3 * 0.3 + 6 * (0.1 + land) + 0.3 + 1.0 + land + 0.6 + land + 2 * (1.0 + 0.1 + 2 * land) + 1.0


def film(label, speed):
    name = f"{JID}-{label}"
    start = {"do": "px_record_start", "name": name, "seconds": round(1.5 * seconds(speed) + 6, 1), "require_hz": 120,
             "mbps": P.MOVIE_MBPS, "fixture": FIXTURE, "spring": None, "input": "keys and drags (real HID)",
             "title": f"start the 120 Hz movie of the whole window and the trace ({name})"}
    steps = [P.focus("p0"), G.settle(0.8), {"do": "rpc", "method": "debug.frames", "params": {"action": "start"},
             "title": "debug.frames start (main ms and missed refreshes per frame)"}, start] + play(speed) + [
             {"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "keep": "frames",
              "title": "debug.frames stop raw (<film>.frames.json)"}, G.kit_record_stop(name, 0.4)]
    f = {"do": "px_film", "name": name, "steps": steps, "after": [],
         "title": f"film {name}: " + ("Reduce Motion" if speed is None else f"x{speed:g}") + ", the app's defaults"}
    f.update({"reduce": True} if speed is None else {"speed": speed})
    return f


def journey():
    steps = layout() + [film("s1", 1.0), film("reduce", None)] + P.after_check()
    return {"id": JID, "priority": "P1",
            "title": "REAL (cmux-ad m28): 4 columns, row splits, tabs; terminals (ls -la, man, long logs) and pages (text, fixed "
                     "header + scrollbar, dark, heavy); Ctrl-Shift-H/J/K/L single and held, divider drags slow and fast; x1 and Reduce Motion",
            "why": "Lawrence 2026-11-05 (cmux-ad m28): show on video that resizing by keys and drags is pixel perfect with real "
                   "terminals and browsers in many columns, splits and tabs.",
            "source": "PIXEL PERFECT kit (video-cases/gen_real.py)", "budget_seconds": 250, "estimate_seconds": 210,
            "recordings": [f"{JID}-s1", f"{JID}-reduce"], "options": {"key_path": "real"}, "steps": steps,
            "finally": [{"do": "settings_file", "title": "clean-up: settings back", "set": {"appearance": {"appTheme": "followTerminal"}},
                         "unset": ["appearance.themeEdits", "sidebar.hoverCards"]}]}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(HERE), "journeys", "video"))
    o = ap.parse_args()
    j = journey()
    with open(os.path.join(o.out, JID + ".json"), "w") as fh:
        json.dump(j, fh, indent=1)
        fh.write("\n")
    print(f"{JID}: {len(j['steps'])} steps, film seconds x1 {seconds(1.0):.1f}, reduce {seconds(None):.1f}")
