"""The `--modes dragout` row of chromium-host-bench.py (task p01-process-051): a link and an image dragged out of a
Chromium page whose browser runs in the Chromium Host, with feature chromiumHostDragOut on. The host's page window
never shows, so cmux's page view starts the drag session from the host's DRAG_START (Chrome's split:
WebContentsViewMac::StartDragging hands the drag to the app shim's -startDragWithDropData:). A real pointer drag
(pointer-probe.swift `drag`, HID events on an input host) carries each one:

  finder_link     the link onto a Finder window of an empty folder: a .webloc of the link's URL appears there
  finder_image    the <img> onto the same window: the image file (the page's PNG, byte for byte) appears there
  terminal_link   the link onto a cmux terminal: the terminal shows the link's URL (pasted at the prompt)
  terminal_image  the <img> onto the terminal: the terminal shows the image's name (its URL or path)
  page_zone       the link back over its own page, onto a drop zone that takes it (dragover cancelled): the zone's
                  drop sees the custom data the page set at dragstart (the page's own drag, entered with
                  drag_target_enter_source) and the link's URL
  page_refused    the link back over its own page, onto a part that takes no drop: the session ends with no
                  operation (`page_drag` last_session_operation 0), and dragend sees dropEffect "none"

Each drop out of the page passes only when the page's dragend sees the dropEffect of the operation the session ended
with (not "none" for a drop that was taken) and `debug.cef`'s `page_drag` counts one more session: cmux started it,
not Chromium. In process, the row says not_measurable (Chromium starts its own session there); below fork API 30
there is no drag source handler, and below 31 the page rows have no DragTarget path (p01-process-178).
"""
import json, os, plistlib, struct, subprocess, zlib

HREF = "https://example.com/cmux-drag-out"
IMAGE_NAME = "drag-out.png"
# The fork API of the drag source handler (DRAG_START), and of DragTarget calls into a detached page.
DRAG_SOURCE_FORK_API = 30
DRAG_TARGET_FORK_API = 31
FEATURES = ("chromiumHostDragOut",)
ROWS = ("finder_link", "finder_image", "terminal_link", "terminal_image", "page_zone", "page_refused")
PAGE_ROWS = ("page_zone", "page_refused")
DROP_EFFECTS = {1: "copy", 2: "link", 16: "move"}

PAGE = f"""<!doctype html><meta charset=utf-8><title>drag-out probe</title>
<style>html,body{{margin:0;height:100%;font:16px system-ui}}#link,#img,#refuse,#zone{{position:fixed;box-sizing:border-box;
margin:0}}#link{{left:5%;top:5%;width:40%;height:30%;display:flex;align-items:center;justify-content:center;background:#ddf}}
#img{{left:55%;top:5%;width:40%;height:30%}}#refuse{{left:5%;top:55%;width:40%;height:40%;background:#eee}}
#zone{{left:55%;top:55%;width:40%;height:40%;background:#2a6}}</style>
<a id=link href="{HREF}">cmux drag-out link</a><img id=img src="{IMAGE_NAME}" alt="">
<div id=refuse>no drop here</div><div id=zone>drop zone</div>
<script>
const log = window.dragOutLog = {{starts: [], ends: [], zone: null}};
for (const id of ['link', 'img']) {{
  const element = document.getElementById(id);
  element.addEventListener('dragstart', event => {{ event.dataTransfer.setData('application/x-cmux-probe', id); log.starts.push(id); }});
  element.addEventListener('dragend', event => log.ends.push([id, event.dataTransfer.dropEffect]));
}}
const zone = document.getElementById('zone');
zone.addEventListener('dragover', event => {{ event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; }});
zone.addEventListener('drop', event => {{
  event.preventDefault();
  log.zone = {{probe: event.dataTransfer.getData('application/x-cmux-probe'), uri: event.dataTransfer.getData('text/uri-list')}};
}});
</script>"""


def image_png(width=96, height=64):
    """An opaque PNG (stdlib only): the page's <img>, which a Finder drop must write byte for byte."""
    # One filter byte per row, then the row's pixels.
    rows = b"".join(b"\x00" + b"".join(bytes((x * 2 % 256, y * 3 % 256, 160, 255)) for x in range(width)) for y in range(height))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def write_page(out):
    """The probe page and its image in `out`; the page's file URL."""
    with open(os.path.join(out, "drag-out.html"), "w") as page:
        page.write(PAGE)
    with open(os.path.join(out, IMAGE_NAME), "wb") as image:
        image.write(image_png())
    return "file://" + os.path.join(os.path.abspath(out), "drag-out.html")


# ------------------------------------------------------------------ verdicts (pure; tests/test_chromium_host_dragout.py)

def new_files(before, folder):
    """The files in `folder` that were not in `before` (a set of names)."""
    return sorted(set(os.listdir(folder)) - set(before)) if os.path.isdir(folder) else []


def webloc_url(path):
    """The URL a .webloc names, or None."""
    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle).get("URL")
    except (OSError, plistlib.InvalidFileException, AttributeError, ValueError):
        return None


def drop_end(ends, element, before):
    """The dropEffect of `element`'s dragend after the first `before` dragends, or None when none came."""
    return next((effect for name, effect in (ends or [])[before:] if name == element), None)


def session(counts_before, counts_after):
    """The sessions the page view started between two `page_drag`s, and the last one's operation."""
    started = (counts_after or {}).get("sessions", 0) - (counts_before or {}).get("sessions", 0)
    return started, (counts_after or {}).get("last_session_operation")


def effect_of(operation):
    """The dropEffect Chromium reports for the session's NSDragOperation: none, or the first of copy, link, move."""
    for bit, name in DROP_EFFECTS.items():
        if (operation or 0) & bit:
            return name
    return "none"


def finder_verdict(kind, folder, before, effect, started, operation, png):
    """A Finder drop: the .webloc of HREF (link) or the image's bytes (image) is new in `folder`, the session was
    cmux's, it ended with an operation, and dragend saw that operation's dropEffect."""
    added = new_files(before, folder)
    if kind == "link":
        got = [name for name in added if name.endswith(".webloc") and webloc_url(os.path.join(folder, name)) == HREF]
    else:
        got = [name for name in added if os.path.isfile(os.path.join(folder, name)) and open(os.path.join(folder, name), "rb").read() == png]
    ok = bool(got) and started == 1 and bool(operation) and effect == effect_of(operation)
    return {"added": added, "got": got, "drop_effect": effect, "sessions": started, "operation": operation, "pass": ok}


def terminal_verdict(needle, text_before, text_after, effect, started, operation):
    """A terminal drop: `needle` shows in the terminal (pasted) where it did not before, and the session was cmux's
    with an operation whose dropEffect dragend saw."""
    shown = needle in (text_after or "") and needle not in (text_before or "")
    ok = shown and started == 1 and bool(operation) and effect == effect_of(operation)
    return {"needle": needle, "shown": shown, "drop_effect": effect, "sessions": started, "operation": operation, "pass": ok}


def page_verdict(row, zone, effect, started, operation, answers):
    """Back over its own page. page_zone: the zone's drop has the page's own drag data and the link, and dragend sees
    copy. page_refused: the session ends with no operation and dragend sees none. Both need the page's answers."""
    out = {"zone": zone, "drop_effect": effect, "sessions": started, "operation": operation, "answers": answers}
    if row == "page_zone":
        ok = (zone or {}).get("probe") == "link" and HREF in ((zone or {}).get("uri") or "") and effect == "copy" and bool(operation)
    else:
        ok = zone is None and effect == "none" and operation == 0
    out["pass"] = ok and started == 1 and answers >= 1
    return out


# ------------------------------------------------------------------ the row (an input host with a GUI)

def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)


def open_finder(folder, bounds):
    """A Finder window of `folder` at `bounds` (left, top, right, bottom; screen points from the top left)."""
    left, top, right, bottom = (int(v) for v in bounds)
    return osascript(f'tell application "Finder"\nactivate\nopen (POSIX file "{folder}" as alias)\n'
                     f'set bounds of front window to {{{left}, {top}, {right}, {bottom}}}\nend tell')


def close_finder(folder):
    osascript(f'tell application "Finder" to close (every window whose target is (POSIX file "{folder}" as alias))')


def panes(rpc):
    """{pane: (kind, border)} of the visible panes of the main window: debug.surfaces kinds, debug.pane_chrome
    borders (window points from the top left)."""
    kinds = {p.get("pane"): p.get("kind") for w in (rpc("debug.surfaces") or {}).get("windows") or []
             for p in w.get("panes") or [] if p.get("visible")}
    return {p.get("pane"): (kinds[p.get("pane")], p.get("border")) for w in (rpc("debug.pane_chrome") or {}).get("windows") or []
            for p in w.get("panes") or [] if p.get("pane") in kinds and isinstance(p.get("border"), list)}


def terminal_text(rpc, pane):
    for window in (rpc("debug.surfaces", {"text": True}) or {}).get("windows") or []:
        for entry in window.get("panes") or []:
            if entry.get("pane") == pane:
                return entry.get("text") or ""
    return None


def run(rpc, wait, page, probe, out, url):
    """The row: lays the cmux window on the left of the screen and a Finder window of an empty folder on the right,
    splits a terminal under the page, and drags each element to each target. `page(script)` evaluates in the probe's
    tab; `probe` is the built pointer-probe."""
    result = {}
    fit = rpc("debug.window_frame", {}) or {}
    visible = fit.get("visible_frame")
    screen = fit.get("screen_frame")
    if not visible or not screen:
        return {"error": f"no screen geometry (debug.window_frame): {fit}"}
    vx, vy, vw, vh = visible
    screen_h = screen[1] + screen[3]
    split = vx + vw * 0.6
    rpc("debug.window_frame", {"frame": [vx, vy, split - vx, vh]})
    rpc("action.run", {"action": "splitDown", "origin": "script"})
    found = wait(lambda: (lambda p: p if {k for k, _ in p.values()} >= {"browser", "terminal"} else None)(panes(rpc)), 20, 0.25)
    if not found:
        return {"error": f"no browser and terminal pane side by side: {panes(rpc)}"}
    browser = next(border for kind, border in found.values() if kind == "browser")
    terminal_pane, terminal = next((pane, border) for pane, (kind, border) in found.items() if kind == "terminal")
    window = next((w for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("kind") == "main" and w.get("visible")), None)
    frame = (window or {}).get("frame") or {}
    # Window points from the top left to screen points from the top left.
    origin = (frame.get("x", 0), screen_h - (frame.get("y", 0) + frame.get("height", 0)))
    to_screen = lambda border, x, y: (origin[0] + border[0] + x, origin[1] + border[1] + y)

    folder = os.path.join(os.path.abspath(out), "drag-out-finder")
    os.makedirs(folder, exist_ok=True)
    top = screen_h - (vy + vh)
    opened = open_finder(folder, (split + 20, top + 40, vx + vw - 20, top + vh * 0.7))
    if opened.returncode != 0:
        result["finder_error"] = opened.stderr.strip()[:300]
    finder_point = ((split + 20 + vx + vw - 20) / 2, top + 40 + (vh * 0.7 - 40) / 2 + 30)

    def element(element_id):
        rect = page(f"(() => {{ const r = document.getElementById('{element_id}').getBoundingClientRect(); "
                    "return [r.x + r.width / 2, r.y + r.height / 2]; })()")
        return to_screen(browser, rect[0], rect[1]) if rect else None

    def page_ends():
        return json_list(page("JSON.stringify(window.dragOutLog.ends)"))

    def page_drag():
        cef = rpc("debug.cef") or {}
        mine = [e for e in cef.get("devtools") or [] if (e.get("url") or "").startswith(url)]
        return (mine or [{}])[0].get("page_drag"), (cef.get("windows") or {}).get("fork_api")

    counts, fork_api = page_drag()
    result.update({"backend": "host" if counts else "in_process", "fork_api": fork_api, "page_drag": counts})
    if not counts:
        result["not_measurable"] = "the tab runs in process, where Chromium starts its own drag session"
        return result
    if not isinstance(fork_api, (int, float)) or fork_api < DRAG_SOURCE_FORK_API:
        result["not_measurable"] = f"fork API {fork_api} is below {DRAG_SOURCE_FORK_API}: no drag source handler"
        return result
    png = image_png()
    targets = {
        "finder_link": ("link", finder_point), "finder_image": ("img", finder_point),
        "terminal_link": ("link", to_screen(terminal, terminal[2] / 2, terminal[3] / 2)),
        "terminal_image": ("img", to_screen(terminal, terminal[2] / 2, terminal[3] / 2)),
        "page_zone": ("link", element("zone")), "page_refused": ("link", element("refuse")),
    }
    for row, (source_id, target) in targets.items():
        if row in PAGE_ROWS and fork_api < DRAG_TARGET_FORK_API:
            result[row] = {"not_measurable": f"fork API {fork_api} is below {DRAG_TARGET_FORK_API}: no DragTarget path (p01-process-178)"}
            continue
        source = element(source_id)
        if not source or not target:
            result[row] = {"error": "no source or target point", "pass": False}
            continue
        before_files = os.listdir(folder)
        before_text = terminal_text(rpc, terminal_pane)
        before_ends = len(page_ends())
        before_counts = page_drag()[0]
        page("window.dragOutLog.zone = null")
        dragged = subprocess.run([probe, "drag", f"{source[0]:.0f}", f"{source[1]:.0f}", f"{target[0]:.0f}", f"{target[1]:.0f}",
                                  "60", "400"], capture_output=True, text=True, timeout=60)
        ends = wait(lambda: (lambda e: e if len(e) > before_ends else None)(page_ends()), 10, 0.1) or []
        effect = drop_end(ends, source_id, before_ends)
        after_counts = page_drag()[0]
        started, operation = session(before_counts, after_counts)
        if row.startswith("finder"):
            wait(lambda: new_files(before_files, folder) or None, 5, 0.2)
            verdict = finder_verdict("link" if source_id == "link" else "image", folder, before_files, effect, started, operation, png)
        elif row.startswith("terminal"):
            needle = HREF if source_id == "link" else IMAGE_NAME
            after_text = wait(lambda: (lambda t: t if t and needle in t else None)(terminal_text(rpc, terminal_pane)), 5, 0.2)
            verdict = terminal_verdict(needle, before_text, after_text or terminal_text(rpc, terminal_pane), effect, started, operation)
            # Clears the pasted text from the prompt (Ctrl-U) so the next drop is seen on its own.
            rpc("action.run", {"action": "terminal.sendText", "target": f"pane:{terminal_pane}", "args": {"text": "\x15"}, "origin": "script"})
        else:
            answers = (after_counts or {}).get("answers", 0) - (before_counts or {}).get("answers", 0)
            verdict = page_verdict(row, page("window.dragOutLog.zone"), effect, started, operation, answers)
        verdict.update({"source": source, "target": target, "probe": dragged.returncode})
        result[row] = verdict
    close_finder(folder)
    measured = [result[row] for row in ROWS if isinstance(result.get(row), dict) and "not_measurable" not in result[row]]
    result["pass"] = bool(measured) and all(r.get("pass") for r in measured)
    return result


def json_list(text):
    """The JSON array `text` holds, else []."""
    try:
        value = json.loads(text) if text else []
    except ValueError:
        return []
    return value if isinstance(value, list) else []
