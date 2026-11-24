#!/usr/bin/env python3
"""Page hosting probe: where the pixels of a cmux page on Chromium are while a pane beside it zooms.

  scripts/cmux-next/page-hosting-probe.py --tag TAG --app APP --out DIR [--json FILE]

Through `scripts/measure/split-spring.sh --suite=page-hosting` (the entry builds the app and ends it at its exit).
One launch, one new workspace: a terminal and ONE agent chat by a split. SCENE 1 zooms the terminal and unzooms;
SCENE 2 zooms the chat's pane and unzooms. Each scene reads `debug.cef` before, while zoomed and after, samples
the page's host view in each display frame over the zoom and the unzoom (`debug.motion` trace, target `page`) and
prints the notes of the commit motion.

A hosted page (fork API 26, plans/cmux-next/cef-layer-hosting-DESIGN.md) has a hosted root in the layers of the
app's window: the 2 sizes of that root are above 0 in each `page` row. A page that is not hosted draws in a page
window of its own: the 2 sizes read -1. The page window's 2 sizes do not tell the 2 answers apart, because a hosted
page keeps its page window for input.

It proves the app's state, not the screen. Each line of this script starts with `PAGE-HOSTING`. It prints counts,
sizes, true or false and the app's motion notes: no setting, no path, no name and no text of a page. A SETUP row
that fails gives `NO ANSWER: <row>` and exit 1 (the rows that can still be read are printed first). With each
SETUP row good the last line is `ANSWER: hosted`, `ANSWER: in a window of its own` or `NO ANSWER: mixed rows`.
"""
import argparse, contextlib, io, json, os, platform, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
opts, _ = parser.parse_known_args()
FACTS = {"suite": "page-hosting", "setup": [], "reads": [], "traces": [], "notes": [], "answer": None}
FAILED = []
BENCH = None
PAGE = {}  # the chat: its pane, its page and instance, the name of its `hosted.` field


class Stop(Exception):
    """A SETUP row failed and the next step cannot run."""


def say(text):
    print("PAGE-HOSTING " + text, flush=True)


def setup(name, ok, value=""):
    FACTS["setup"].append({"row": name, "ok": bool(ok), "value": str(value)})
    say(f"SETUP {'ok  ' if ok else 'FAIL'} {name}: {value}")
    if not ok:
        FAILED.append(name)
    return bool(ok)


def need(name, ok, value=""):
    if not setup(name, ok, value):
        raise Stop(name)


def rpc(method, params=None, timeout=60):
    reply = BENCH.rpc(method, params, timeout)
    return reply if isinstance(reply, dict) else {}


def refusal(reply):
    """None, or why an action did not run: the app's code, never the socket's text (it has a path)."""
    error = reply.get("error") if isinstance(reply, dict) else None
    if error is None:
        return None
    return f"refused ({error.get('code')})" if isinstance(error, dict) and error.get("code") else "no answer on the socket"


def act(name, target=None, focus=True, args=None):
    params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
    if target:
        params["target"] = target
    return refusal(rpc("action.run", params, timeout=120))


def wait(check, seconds, step=0.1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # a probe of a live app: it polls the app's state over its socket
    return None


def topology():
    return rpc("snapshot.get").get("topology") or {}


def workspace(ident, top=None):
    return next((w for w in (top or topology()).get("workspaces") or [] if w.get("id") == ident), {})


def panes(ident):
    return [p for s in workspace(ident).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]


def tabs(ident, pane):
    return next((p.get("tabs") or [] for p in panes(ident) if p.get("id") == pane), [])


def zoomed(ident):
    return next((s.get("zoomed_pane") for s in workspace(ident).get("screens") or [] if s.get("zoomed_pane")), None)


def shown_pages():
    """(page, instance) -> state of each cmux page that shows in a window now. The state's `text` is never kept."""
    found = {}
    for row in rpc("debug.page", {"action": "list"}).get("pages") or []:
        if row.get("parked"):
            continue
        state = rpc("debug.page", {"page": row.get("page"), "instance": row.get("instance")}, timeout=30)
        if state.get("in_window") and not state.get("view_hidden"):
            found[(row.get("page"), row.get("instance"))] = {k: state.get(k) for k in (
                "engine", "webkit_reason", "in_window", "view_hidden", "painted", "window_visible", "window_occluded")}
    return found


def hosted_fields():
    tracker = rpc("debug.cef").get("tracker") or {}
    return {k for k in tracker if k.startswith("hosted.") and not k.endswith(".devtools")}


def code_of(value):
    return "none" if value is None else str(value.get("code") if isinstance(value, dict) else "set")


def read_cef(label):
    cef = rpc("debug.cef")
    tracker = cef.get("tracker") or {}
    fallback = cef.get("fallback")
    row = {"at": label, "hosted_pages": tracker.get("hosted_pages"), "hosting_refused": tracker.get("hosting_refused"),
           "page_field": tracker.get(PAGE["field"]) if PAGE.get("field") else "not mapped",
           "fork_api": (cef.get("windows") or {}).get("fork_api"), "unavailable": code_of(cef.get("unavailable")),
           "fallback": "none" if fallback is None else f"count {fallback.get('count')}, {code_of(fallback.get('reason'))}"}
    FACTS["reads"].append(row)
    say(f"R1 {label}: hosted_pages {row['hosted_pages']}; the field of the page's tab {row['page_field']}; hosting_refused "
        f"{row['hosting_refused']}; fork_api {row['fork_api']}; unavailable {row['unavailable']}; fallback {row['fallback']}")
    return row


def read_page(label):
    state = shown_pages().get(PAGE.get("key")) or {}
    FACTS["reads"].append({"at": label, "page": state})
    say(f"R4 {label}: " + ("the page does not show" if not state else "; ".join(f"{k} {state[k]}" for k in sorted(state))))
    return state


def span(rows, index):
    values = [row[index] for row in rows if len(row) > index]
    return f"{min(values)} to {max(values)}" if values else "no row"


def trace_rows(label, samples, marks):
    """Prints the `page` rows of each part of a trace. A row: 0, 1 the host view; 2, 3 the page window; 4 the wall
    time in ms; 8 detached; 9, 10 the hosted root (-1: not hosted); 13 the browser."""
    offsets = [row[4] - s.get("t", 0) for s in samples for row in s.get("page") or [] if len(row) > 4]
    offset = offsets[0] if offsets else None
    for name, start, end in (("at rest", None, marks[0]), ("zoom", marks[0], marks[1]), ("unzoom", marks[1], None)):
        part = [s for s in samples if offset is None or ((start is None or s.get("t", 0) + offset >= start)
                                                       and (end is None or s.get("t", 0) + offset < end))]
        rows = [row for s in part for row in s.get("page") or []]
        with_root = sum(1 for row in rows if len(row) > 10 and row[9] > 0 and row[10] > 0)
        fact = {"scene": label, "part": name if offset is not None else "whole trace", "frames": len(part), "page_rows": len(rows),
                "rows_with_hosted_root": with_root, "rows_with_no_hosted_root": sum(1 for row in rows if len(row) > 10 and row[9] < 0),
                "hosted_root_w": span(rows, 9), "hosted_root_h": span(rows, 10), "page_window_w": span(rows, 2),
                "page_window_h": span(rows, 3), "host_view_w": span(rows, 0), "host_view_h": span(rows, 1),
                "rows_detached": sum(1 for row in rows if len(row) > 8 and row[8]), "browsers": len({row[13] for row in rows if len(row) > 13})}
        FACTS["traces"].append(fact)
        say(f"R2 {label} {fact['part']}: " + "; ".join(f"{k} {v}" for k, v in fact.items() if k not in ("scene", "part")))
        if offset is None:
            break


def scene(number, ident, pane, what):
    label = f"scene {number}"
    say(f"SCENE {number}: zoom {what}, then unzoom")
    read_page(f"{label} before")
    read_cef(f"{label} before")
    started = rpc("debug.motion", {"action": "trace_start", "targets": ["page"]})
    wait(lambda: len(rpc("debug.motion", {"action": "trace_read"}).get("samples") or []) >= 5, 5, 0.05)
    rpc("debug.motion", {"action": "start"})
    marks, good = [], True
    for verb in ("zoom", "unzoom"):
        marks.append(time.time() * 1000)
        error = act("toggleSplitZoom", target=f"pane:{pane}")
        took = wait(lambda: bool(zoomed(ident)) == (verb == "zoom"), 5, 0.05)
        good = setup(f"{label}: the {verb} took effect", took, error or f"a zoomed pane in the screen: {bool(zoomed(ident))}") and good
        time.sleep(1.5)  # the measured time of a probe: past the rest of the move (under 0.5 s)
        if verb == "zoom":
            read_cef(f"{label} zoomed")
    motion = rpc("debug.motion", {"action": "stop"})
    trace = rpc("debug.motion", {"action": "trace_stop"}, timeout=120)
    setup(f"{label}: the trace ran", bool(trace.get("samples")), f"views {started.get('views')}; frames {len(trace.get('samples') or [])}; "
          f"refresh_ms {trace.get('refresh_ms')}")
    trace_rows(label, trace.get("samples") or [], marks)
    notes = [n for n in motion.get("notes") or [] if "layout.commit" in str(n.get("text"))]
    moving = sum(1 for s in motion.get("samples") or [] if s.get("name") == "layout.commit" and (s.get("v") or 0) > 0)
    FACTS["notes"].append({"scene": label, "notes": notes, "frames_with_a_move": moving})
    say(f"MOTION {label}: frames with a move {moving}; notes {len(notes)}; pane_animations {motion.get('pane_animations')}; "
        f"reduce_motion {motion.get('reduce_motion')}; animations_enabled {motion.get('animations_enabled')}")
    for note in notes:
        say(f"MOTION {label} note at {note.get('t_ms')} ms: {str(note.get('text'))[:300]}")
    read_cef(f"{label} after")
    read_page(f"{label} after")
    return good


def build_screen():
    """A new workspace with a terminal and, beside it by a split, ONE agent chat whose tab shows."""
    before = {w.get("id") for w in topology().get("workspaces") or []}
    error = act("workspace.newAtBottom")
    ident = wait(lambda: next((w.get("id") for w in topology().get("workspaces") or [] if w.get("id") not in before), None), 30)
    need("a new workspace", ident, error or "made")
    act("goToWorkspace", args={"workspace": ident})
    need("the new workspace shows in a window", wait(lambda: any(w.get("workspace") == ident for w in topology().get("windows") or []), 10), "")
    first = wait(lambda: panes(ident), 20) or []
    need("1 pane with a terminal", len(first) == 1 and any(t.get("kind") == "terminal" for t in first[0].get("tabs") or []), f"panes {len(first)}")
    terminal = first[0].get("id")
    error = act("splitRight", target=f"pane:{terminal}")
    made = wait(lambda: [p.get("id") for p in panes(ident) if p.get("id") != terminal], 15) or []
    need("the split gives 2 panes", len(made) == 1, error or f"panes {1 + len(made)}")
    pages_before, fields_before = set(shown_pages()), hosted_fields()
    tabs_before = {t.get("id") for t in tabs(ident, made[0])}
    error = act("palette.newAgentChat", target=f"pane:{made[0]}", focus=False)

    def chat():
        return next((t for t in tabs(ident, made[0]) if t.get("id") not in tabs_before and t.get("kind") == "conversation"
                     and not str(t.get("id")).startswith("pending_tab_")), None)

    def selected():
        tab, pane = chat() or {}, next((p for p in panes(ident) if p.get("id") == made[0]), {})
        return bool(tab) and (tab.get("selected") is True or pane.get("selected_tab") == tab.get("id"))
    tab = wait(chat, 40)
    need("ONE agent chat tab in the new pane", tab, error or ("made" if tab else "no chat tab in 40 s"))
    if not selected():
        act("tab.focus", target=f"tab:{tab.get('id')}")
    need("the chat's tab is the selected tab of its pane", wait(selected, 15), "")

    def fresh(painted):
        return [k for k, v in shown_pages().items() if k not in pages_before and (v.get("painted") or not painted)]
    new = wait(lambda: fresh(True), 60, 0.5) or fresh(False)
    need("ONE new cmux page shows", len(new) == 1, f"new pages that show {len(new)}")
    PAGE.update(pane=made[0], key=new[0])
    state = read_page("setup")
    need("the page's engine is chromium", state.get("engine") == "chromium", f"engine {state.get('engine')}; webkit_reason {state.get('webkit_reason')}")
    fields = sorted(hosted_fields() - fields_before)
    PAGE["field"] = fields[0] if len(fields) == 1 else None
    say(f"new `hosted.` fields after the chat: {len(fields)} (1 = the field of the page's tab is mapped)")
    return ident, terminal


def run():
    global BENCH
    try:
        version = subprocess.run(["/usr/bin/sw_vers", "-productVersion"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        version = platform.mac_ver()[0]
    setup("macOS major version", True, version.split(".")[0] or "not read")
    quiet = io.StringIO()  # the launch tool's own lines have the Mac's facts: they stay in a file of the out folder
    BENCH = BenchApp(opts.app, out=opts.out)
    try:
        with contextlib.redirect_stdout(quiet):
            BENCH.launch(timeout=180)
    except LaunchError as error:
        need("the app launches", False, f"reason {error.reason}")
    finally:
        with open(os.path.join(opts.out, "page-hosting-launch.txt"), "w") as f:
            f.write(quiet.getvalue())
    setup("the app launches", True, "it answers on its socket")
    rpc("debug.motion", {"action": "kind", "name": "paneAnimations", "value": True})
    ident, terminal = build_screen()
    cef = read_cef("setup")
    setup("no `unavailable`", cef["unavailable"] == "none", cef["unavailable"])
    setup("no `fallback`", cef["fallback"] == "none", cef["fallback"])
    setup("fork_api is 26 or more", (cef["fork_api"] or 0) >= 26, cef["fork_api"])
    motion = rpc("debug.motion")
    setup("the pane motion is on (set by this script for this launch)", motion.get("pane_animations") is True, motion.get("pane_animations"))
    setup("reduce motion is off (read, not set)", motion.get("reduce_motion") is False, motion.get("reduce_motion"))
    setup("animations are enabled (read, not set)", motion.get("animations_enabled") is True, motion.get("animations_enabled"))
    scene(1, ident, terminal, "the TERMINAL beside the chat")
    scene(2, ident, PAGE["pane"], "the CHAT's pane")


def answer():
    rows = [t for t in FACTS["traces"] if t["part"] != "at rest"]
    hosted, own = sum(t["rows_with_hosted_root"] for t in rows), sum(t["rows_with_no_hosted_root"] for t in rows)
    reads = [r for r in FACTS["reads"] if "hosted_pages" in r and r["at"] != "setup"]
    fields = {r["page_field"] for r in reads if r["page_field"] != "not mapped"}
    refused = {r["hosting_refused"] for r in reads}
    say(f"SUM: `page` rows of the 2 zooms and the 2 unzooms with a hosted root {hosted}, with none {own}; values of the field of "
        f"the page's tab {sorted(str(v) for v in fields)}; least hosted_pages {min([r['hosted_pages'] or 0 for r in reads] or [0])}; "
        f"values of hosting_refused {sorted(str(v) for v in refused)}")
    if FAILED:
        return f"NO ANSWER: {FAILED[0]}"
    if hosted > 0 and own == 0 and fields <= {1, 1.0} and all((r["hosted_pages"] or 0) >= 1 for r in reads) and len(refused) == 1:
        return "ANSWER: hosted"
    if own > 0 and hosted == 0 and fields <= {0, 0.0}:
        return "ANSWER: in a window of its own"
    return "NO ANSWER: mixed rows"


def main():
    os.makedirs(opts.out, exist_ok=True)
    say("WANTED IF HOSTED: hosted_pages 1 or more in each R1 of a scene; the field of the page's tab 1 (if it is mapped); "
        "hosting_refused does not change; each `page` row of a zoom and an unzoom has a hosted root with 2 sizes above 0")
    say("WANTED IF IN A WINDOW OF ITS OWN: the field of the page's tab 0 (if it is mapped); each `page` row of a zoom and an "
        "unzoom reads -1 for the 2 sizes of the hosted root")
    say("WANTED IN SCENE 2, by the code: the zoom of the chat's pane shows in one frame (a note `layout.commit: zoom in one frame`)")
    try:
        run()
    except Stop:
        pass
    except Exception as error:  # the kind and the line only: a traceback has paths
        trace, line = error.__traceback__, None
        while trace:
            line = trace.tb_lineno if trace.tb_frame.f_code.co_filename == __file__ else line
            trace = trace.tb_next
        setup("the script runs to its end", False, f"{type(error).__name__} at this file's line {line}")
    finally:
        if BENCH is not None:
            with contextlib.redirect_stdout(io.StringIO()):
                BENCH.stop()
    FACTS["answer"] = answer()
    with open(opts.json or os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(FACTS, f, indent=1, default=str)
    say(FACTS["answer"])
    return 0 if FACTS["answer"].startswith("ANSWER") else 1


if __name__ == "__main__":
    sys.exit(main())
