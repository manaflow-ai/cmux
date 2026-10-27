#!/usr/bin/env python3
"""Live proof of the sidebar document drag engine (sidebar-v2 S3-S5) on a tagged app.

Run it on cmux-lawrence-2 in an nx-remote GUI job with a fleet-built app of a
commit that has both the client lane and the doc lane (`sidebar-doc-v1`):

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-v2-drag-live.py --out "$NX_ARTIFACTS"
  python3 scripts/cmux-next/sidebar-v2-drag-live.py --app APP --out DIR   (the perf-lab story runner)

The app (--app, else $NX_APP) launches and stops through bench_launch.BenchApp
(the bench env, an empty cmux.json, a fresh saved session for the tag, the
tag's daemons ended at the stop); the relaunch step quits it keeping its
sessions and launches it again on the saved state.

Every drag goes through `debug.mouse` (lift, held moves, drop), never a
command. Each step prints PASS/FAIL/SKIP with its evidence: the sidebar rows
and band items (`debug.sidebar_rows`), the mirror's FFI call counts by entry
(two per drag: `drag_begin` and the drop's `intent`) and the refusal HUD.
Steps: a workspace into Pinned at index 1; a group into Pinned (it lists as
its header and member rows under the tiles, and collapses and opens by a click
on its header); a group into a custom section; a pinned tile back into the
list at the drop index; a link item into the list (it lists as a row, and a
click opens its page); a cross-machine drop (refused; SKIP without a second
machine); Cmd-Z after each step (the undo toast's path); the order after a
relaunch. Every section draws in the one list (Pinned and custom tiles in
their section's own arrangement, at their place in the document order), and
each held drag checks the drop look `debug.sidebar_rows` reports
(`drop.indicator`: `gap` where the rows or tiles make way, `into` a group
header): one drop behavior for every section. Exit 1 when any step FAILs.

The steps and the FFI calls of each held drag are also written as
cmux-perf-result/v1 in --out (story sidebar-drag-live:
`sidebar_drag_live.ffi_calls_off_contract` and `sidebar_drag_live.failed_steps`,
sidebar_drag_bench_report.py).
"""
import argparse, json, os, re, socket, subprocess, sys, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import BenchApp  # noqa: E402
import sidebar_drag_bench_report as results  # noqa: E402


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    # `--only remove-undo`: only the Remove from Sidebar step and its Cmd-Z, `--repeat` times (a focused rerun).
    parser.add_argument("--only", choices=["remove-undo"])
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--story", default=results.SIDEBAR_DRAG_LIVE_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts = parser.parse_args(argv)
    if not opts.app:
        parser.error("name the tagged app with --app, or run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP)")
    return opts


# Set by main(): the options, the launched app (BenchApp) and its socket and CLI.
opts = LAUNCHER = SOCKET = CLI = None
RESULTS = []
FFI_CALLS = []  # the FFI calls of each held drag (drag()), for result-v1


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(SOCKET)
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


def cli(*args):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=env)
    return (out.stdout + out.stderr).strip()


DOC_ERRORS = set()


def doc_operation(operation, **params):
    """One sidebar document operation through the tagged app's bundled cmux-tui (`raw operation`, its own key): a
    change from another client as far as the app's own document store is concerned. The reply's JSON, or None."""
    tui = os.path.join(os.path.dirname(CLI), "cmux-tui")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    params = {"machine": "current", "session": "current", **params}
    out = subprocess.run([tui, "--app-socket", SOCKET, "--json", "raw", "operation", operation, "--params-json", json.dumps(params)],
                         capture_output=True, text=True, timeout=30, env=env)
    try:
        return json.loads(out.stdout)
    except ValueError:
        print(operation + ":", (out.stdout + out.stderr)[:300], flush=True)
        return None


def doc_icon_url(host):
    """The icon_url the home daemon's sidebar document stores on the link item for `host` (sidebar.get, through the
    tagged app's bundled cmux-tui)."""
    tui = os.path.join(os.path.dirname(CLI), "cmux-tui")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    # Through the app socket an operation names its machine and its session (live14 without either, live21 without the
    # session: "required selector is missing", so icon_url read None while the row drew the stored favicon).
    params = '{"machine":"current","session":"current"}'
    out = subprocess.run([tui, "--app-socket", SOCKET, "--json", "raw", "operation", "sidebar.get", "--params-json", params],
                         capture_output=True, text=True, timeout=30, env=env)
    try:
        doc = json.loads(out.stdout)
    except ValueError:
        doc = None
    if not isinstance(doc, dict) or ("code" in doc and "message" in doc):  # not a document: a refusal or no JSON
        error = (out.stdout + out.stderr)[:300]
        if error not in DOC_ERRORS:  # once per distinct error, not once per poll
            DOC_ERRORS.add(error)
            print("sidebar.get:", error, flush=True)
        return None
    found = []

    def walk(value):
        if isinstance(value, dict):
            body = value.get("body")
            if isinstance(body, dict) and body.get("type") == "url" and str(body.get("url")).rstrip("/") == host:
                found.append(body.get("icon_url"))
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(doc)
    return next((value for value in found if value), None)


def github_panes():
    """(workspace, pane, focused) of each pane of the shown workspaces whose web page is on github.com (debug.surfaces
    `url`, a browser pane's current address)."""
    found = []
    for win in (rpc("debug.surfaces") or {}).get("windows") or []:
        for pane in win.get("panes") or []:
            host = urllib.parse.urlparse(str(pane.get("url") or "")).hostname or ""
            if host == "github.com" or host.endswith(".github.com"):
                found.append((pane.get("workspace"), pane.get("pane"), bool(pane.get("focused"))))
    return sorted(found)


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


def report():
    value = rpc("debug.sidebar_rows") or {}
    return value if isinstance(value, dict) else {}


def window():
    windows = report().get("windows") or [{}]
    return windows[0]


def ffi():
    return dict((report().get("doc") or {}).get("ffi_calls") or {})


def rows():
    """List rows by title: window frame, group."""
    return {r["title"]: r for r in window().get("rows", []) if r.get("title")}


def items():
    """Band items: id, ref kind, ref, section, frame."""
    return window().get("items", [])


def section_items(section):
    return [i for i in items() if i.get("section") == section]


def list_titles():
    return [r["title"] for r in window().get("rows", []) if r.get("title") and r.get("in_list")]


def toast(**params):
    return rpc("debug.toast", params) or {}


def shot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, name + ".png")})


def record(step, ok, evidence, skip=False):
    state = "SKIP" if skip else ("PASS" if ok else "FAIL")
    RESULTS.append((step, state))
    print(f"{state} {step}: {evidence}", flush=True)


def center(frame):
    return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2


def drag(frm, to, label, indicator=None):
    """One held drag through debug.mouse; returns the FFI calls it made.
    `indicator`: the drop look the held drag must report (`line`, `gap`, `into`)."""
    before = ffi()
    rpc("debug.mouse", {"x": frm[0], "y": frm[1], "action": "drag", "to_x": to[0], "to_y": to[1], "steps": 16, "release": False})
    time.sleep(0.4)  # test harness: hold so the drop indicator shows
    shot(label + "-held")
    held = window().get("drop") or {}
    if indicator:
        record(f"{label}: drop indicator == {indicator}", held.get("indicator") == indicator,
               f"drop={ {k: held.get(k) for k in ('indicator', 'row', 'target', 'refusal')} }")
    during = ffi()
    rpc("debug.mouse", {"x": to[0], "y": to[1], "action": "up"})
    time.sleep(1.2)  # test harness: let the move land
    shot(label + "-dropped")
    after = ffi()
    calls_during = {k: during.get(k, 0) - before.get(k, 0) for k in set(during) | set(before) if during.get(k, 0) != before.get(k, 0)}
    calls_drop = {k: after.get(k, 0) - during.get(k, 0) for k in set(after) | set(during) if after.get(k, 0) != during.get(k, 0)}
    per_drag = calls_during.get("drag_begin", 0) + calls_during.get("intent", 0) + calls_drop.get("drag_begin", 0) + calls_drop.get("intent", 0)
    record(f"{label}: ffi calls per drag == {results.FFI_CALLS_PER_DRAG}",
           per_drag == results.FFI_CALLS_PER_DRAG and set(calls_during) <= {"drag_begin"},
           f"during the held drag {calls_during}, at the drop {calls_drop}")
    FFI_CALLS.append(per_drag)
    return per_drag


def undo(label, check):
    before = toast()
    shown = [t.get("message") for w in before.get("windows", []) for t in w.get("toasts", []) if t.get("undo")]
    reply = toast(undo=True)
    time.sleep(1.0)  # test harness: let the inverse land
    ok = bool(check())
    late = "" if ok else f" later={bool(wait(lambda: bool(check()) or None, 5))}"
    record(f"{label}: Cmd-Z restores", ok, f"list={list_titles()} pinned={[i.get('ref') for i in section_items('sec_pinned')]}"
           f" undo_toasts={shown} undo_steps={before.get('undo_steps')} undone={reply.get('undone')}{late}")
    toast(undo=True)  # redo is the next undo toast; the step's result stays for the next step
    time.sleep(1.0)  # test harness: let the redo land


def undo_toasts():
    return [t for w in toast().get("windows", []) for t in w.get("toasts", []) if t.get("undo")]


def window_number():
    windows = (rpc("debug.surfaces") or {}).get("windows") or []
    first = windows[0] if windows else {}
    number = first.get("window") if isinstance(first, dict) else None
    try:
        return int(number)
    except (TypeError, ValueError):
        return None


def late_undo(label, undone, redone):
    """Cmd-Z after the undo toast has hidden still undoes the step (the window's undo stack keeps it, like any macOS
    undo); Shift-Cmd-Z redoes it, so the step's result stays for the next step."""
    gone = wait(lambda: not undo_toasts() or None, 20)  # the toast hides after its own time (6 s)
    time.sleep(10.0)  # test harness: Cmd-Z comes 10 s after the toast hid, not inside its time
    # Edit > Undo through the window's responder chain (the test window is not key, so the menu itself has no target).
    key = rpc("debug.menu_item", {"action": "undo:", "window_number": window_number()}) or {}
    ok = wait(lambda: bool(undone()) or None, 5)
    record(f"{label}: Edit > Undo 10 s after the toast hid restores", bool(gone) and bool(ok),
           f"toast hidden={bool(gone)} key={json.dumps(key)[:300]} list={list_titles()} "
           f"pinned={[i.get('ref') for i in section_items('sec_pinned')]}")
    key = rpc("debug.menu_item", {"action": "redo:", "window_number": window_number()}) or {}
    again = wait(lambda: (bool(redone()) and not bool(undone())) or None, 5) if ok else None
    if not again and undo_toasts():
        toast(undo=True)  # keep the next steps' state; the redo check above stays FAIL
    record(f"{label}: Edit > Redo redoes the late undo", bool(again), f"key={json.dumps(key)[:300]} list={list_titles()}")


class FocusedDone(Exception):
    """The `--only` steps ran; the rest is skipped."""


def marked():
    return [i for i in section_items("sec_pinned") if str(i.get("ref")) == "bookmarks"]


def remove_from_sidebar():
    """A built-in item (sidebar.item.add takes workspaces, apps and built-ins, not links) into Pinned, then Remove from
    Sidebar: every item that shows it goes, through the document. Cmd-Z comes at once, as a person may press it before
    the daemon's reply: it must undo the removal, not the step before it."""
    toast(perform="sidebar.item.add", arguments={"item": "bookmarks", "section": "sec_pinned"})
    added = wait(lambda: next(iter(marked()), None), 5)
    if added:
        steps = toast(perform="sidebar.item.removeEverywhere", target_kind="sidebar-item", target_id=added["id"]).get("undo_steps")
        gone = wait(lambda: not any(str(i.get("ref")) == "bookmarks" for i in items()), 5)
        record("Remove from Sidebar goes to the document", bool(gone),
               f"item={added.get('id')} items={[i.get('ref') for i in items()]} undo_steps at the remove={steps}")
        undo("Remove from Sidebar", lambda: bool(marked()))
    else:
        record("Remove from Sidebar goes to the document", False, f"no bookmarks item in Pinned after sidebar.item.add: {[i.get('ref') for i in items()]}")


def launch():
    """Starts the app through BenchApp (it refuses a live app of the tag and says why one did not come up); the
    socket and the CLI are the launch's."""
    global SOCKET, CLI
    LAUNCHER.launch(timeout=120)  # ready once debug.windows lists a window
    if LAUNCHER.teardown:
        LAUNCHER.teardown.remember()  # this launch's daemon and hosts, so the final stop ends them too
    SOCKET, CLI = LAUNCHER.socket, LAUNCHER.cli
    wait(lambda: (report().get("doc") or {}).get("active"), 30)
    time.sleep(1.5)  # test harness: let the window settle


def relaunch():
    """Quits the app keeping its sessions (as a person's quit: the tag's daemon and its sidebar document run on),
    then launches it again on that saved state."""
    process = LAUNCHER.process
    reply = rpc("debug.quit", {"fixture_quit": "keep"})
    try:
        process.wait(30)
    except subprocess.TimeoutExpired:
        print(f"the app did not quit in 30 s ({json.dumps(reply)[:200]}): SIGTERM", flush=True)
        process.terminate()  # the PID this script started
        process.wait(15)
    LAUNCHER.fresh_state = False  # the relaunch restores what the first launch saved
    launch()


def record_results():
    """The steps and the drags' FFI calls as cmux-perf-result/v1 in --out (BenchApp.record)."""
    series = results.drag_live_series(RESULTS, FFI_CALLS, story=opts.story)
    for key, where in results.record_all(LAUNCHER, series).items():
        if not where.startswith("not recorded"):
            print(f"result-v1 {key}: {where}", flush=True)


def by_title(title):
    return rows().get(title)


def row_id(row):
    """The id inside a row key such as `workspace(<id>)`."""
    key = str((row or {}).get("key", ""))
    return key[key.find("(") + 1:key.rfind(")")] if "(" in key else key


def main(argv=None):
    global opts, LAUNCHER
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    LAUNCHER = BenchApp(opts.app, out=opts.out, config={}, window=(40, 40, 1100, 720), screen="last",
                        build_config=opts.build_config)
    try:
        launch()
    except BaseException:
        LAUNCHER.stop()  # a launch that never answered: its process and the tag's daemons still end
        raise
    doc = report().get("doc") or {}
    print("doc:", json.dumps(doc), flush=True)
    if not doc.get("active"):
        record("sidebar-doc-v1 active", False, "debug.sidebar_rows doc.active is false: the daemon lacks sidebar-doc-v1 or the FFI lacks the mirror")
        LAUNCHER.stop()
        record_results()
        return 1
    try:
        for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot"):
            cli("workspace", "create", "--name", name)
        wait(lambda: {"Alpha", "Foxtrot"} <= set(rows()), 20)
        for name in ("Beta", "Gamma"):  # two tiles first, so index 1 is between them
            toast(perform="palette.toggleWorkspacePin", target_kind="workspace", target_id=row_id(by_title(name)))
        time.sleep(1.0)  # test harness: let the pins land
        shot("v2-0-start")
        if opts.only == "remove-undo":
            # Focused rerun: the spacing edit, its Cmd-Z and redo (the toasts the full run has just before), then the step.
            def gap():
                return next((s for s in window().get("layout_sections", []) if s.get("id") == "sec_pinned"), {}).get("gap")
            for run in range(opts.repeat):
                value, was = (12, None) if run == 0 else (16, 12) if run % 2 else (12, 16)
                toast(perform="sidebar.section.setGap", target_kind="sidebar-section", target_id="sec_pinned", arguments={"gap": value})
                wait(lambda: gap() == value or None, 5)
                undo("spacing goes to the document", lambda: gap() == was)
                remove_from_sidebar()
                toast(perform="sidebar.item.removeEverywhere", target_kind="sidebar-item", target_id=next(iter(marked()), {}).get("id", ""))
                wait(lambda: not marked() or None, 5)
                time.sleep(1.0)  # test harness: let the clean-up land
            raise FocusedDone
        pinned = section_items("sec_pinned")
        print("pinned before:", [(i.get("ref"), i.get("window_frame")) for i in pinned], flush=True)

        # 1. A workspace into Pinned at index 1 (after the first tile).
        alpha = by_title("Alpha")
        if alpha and len(pinned) >= 2:
            first = pinned[0]["window_frame"]
            to = (first["x"] + first["width"] * 0.8, first["y"] + first["height"] / 2)
            drag(center(alpha["window_frame"]), to, "v2-1-workspace-into-pinned", indicator="gap")
            order = [i.get("ref") for i in section_items("sec_pinned")]
            tiles = [i.get("ref") for i in pinned]
            record("workspace into Pinned at index 1",
                   len(order) == len(tiles) + 1 and order[0] == tiles[0] and order[2:] == tiles[1:] and "Alpha" not in list_titles(),
                   f"pinned before={tiles} after={order} list={list_titles()}")
            undo("workspace into Pinned", lambda: "Alpha" in list_titles())
            late_undo("workspace into Pinned", lambda: "Alpha" in list_titles(), lambda: "Alpha" not in list_titles())
        else:
            record("workspace into Pinned at index 1", False, f"rows={list(rows())} pinned={pinned}")

        # 2. A group into Pinned.
        group_id = None
        print(cli("workspace", "group", "create", "--name", "Grp"), flush=True)
        print(cli("workspace", "group", "Grp", "add", "--workspace", "Delta"), flush=True)
        time.sleep(1.0)  # test harness: let the group show
        group = next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("group")), None)
        pinned = section_items("sec_pinned")
        if group and pinned:
            group_id = group.get("group")
            last = pinned[-1]["window_frame"]
            drag(center(group["window_frame"]), (last["x"] + last["width"] * 0.8, last["y"] + last["height"] / 2), "v2-2-group-into-pinned",
                 indicator="gap")

            def pinned_group():
                """The group as a list section under the band: its header and Delta, above every machine row."""
                listed = window().get("rows", [])
                header = next((r for r in listed if str(r.get("key", "")).startswith("group") and r.get("group") == group_id), None)
                delta = by_title("Delta")
                loose = [r for r in listed if r.get("title") and not r.get("group")]
                if not header or not delta or not loose:
                    return None
                top = min(r["window_frame"]["y"] for r in loose)
                return header if header["window_frame"]["y"] < top and delta["window_frame"]["y"] < top and delta.get("group") == group_id else None

            header = wait(pinned_group, 5)
            record("group into Pinned lists header and members under the tiles", bool(header),
                   f"rows={[(r.get('key'), r.get('title'), r.get('group')) for r in window().get('rows', [])]}")
            # A loose list row is the selection, so the collapsed group keeps no member row (a collapsed group lists its
            # active member). Not Alpha: step 1's undo toast redoes, so Alpha stays a Pinned tile.
            alpha = by_title("Foxtrot")
            if header and alpha:
                rpc("debug.mouse", {"x": center(alpha["window_frame"])[0], "y": center(alpha["window_frame"])[1], "action": "click"})
                time.sleep(0.5)  # test harness: let the selection land
                rpc("debug.mouse", {"x": center(header["window_frame"])[0], "y": center(header["window_frame"])[1], "action": "click"})
                collapsed = wait(lambda: by_title("Delta") is None, 5)
                shot("v2-2-group-in-pinned-collapsed")
                header = wait(pinned_group, 1) or next((r for r in window().get("rows", []) if r.get("group") == group_id), header)
                rpc("debug.mouse", {"x": center(header["window_frame"])[0], "y": center(header["window_frame"])[1], "action": "click"})
                opened = wait(lambda: by_title("Delta") is not None, 5)
                record("group in Pinned collapses and opens", bool(collapsed) and bool(opened), f"collapsed={bool(collapsed)} opened={bool(opened)}")
            else:
                record("group in Pinned collapses and opens", False, f"header={bool(header)} selection row={bool(alpha)}")
            undo("group into Pinned", lambda: not pinned_group())
        else:
            record("group into Pinned", False, f"no group row or no Pinned tile: group={group} pinned={pinned}")

        # 3. A group into a custom section.
        print(toast(perform="sidebar.section.add", arguments={"title": "Work", "region": "top"}).get("performed"), flush=True)
        print(cli("workspace", "group", "create", "--name", "Grp2"), flush=True)
        print(cli("workspace", "group", "Grp2", "add", "--workspace", "Echo"), flush=True)
        time.sleep(1.0)  # test harness: let the section and group show
        work = next((i for i in items() if i.get("section_title") == "Work"), None)
        header = next((s for s in window().get("sections", []) if s.get("title") == "Work"), None) if not work else None
        # Group header rows carry no title: Grp2 is the group row that is not step 2's group.
        group2 = next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("group") and r.get("group") != group_id), None)
        target = (work or header or {}).get("window_frame")
        if group2 and target:
            group2_id = group2.get("group")

            def in_custom():
                """Grp2 lists under the band: its header above every machine row (a group of a custom section)."""
                listed = window().get("rows", [])
                header = next((r for r in listed if str(r.get("key", "")).startswith("group") and r.get("group") == group2_id), None)
                loose = [r for r in listed if r.get("title") and not r.get("group")]
                return bool(header and loose and header["window_frame"]["y"] < min(r["window_frame"]["y"] for r in loose))

            drag(center(group2["window_frame"]), center(target), "v2-3-group-into-custom", indicator="gap")
            record("group into a custom section", bool(wait(in_custom, 5)),
                   f"rows={[(r.get('key'), r.get('title'), r.get('group')) for r in window().get('rows', [])]}")
            undo("group into a custom section", lambda: not in_custom())
        else:
            record("group into a custom section", False, f"no Work section frame in debug.sidebar_rows or no Grp2 row: group2={group2}")

        # 4. A pinned tile back into the list at the drop index: between two adjacent loose rows (new workspaces list
        # newest first, so the pair is read off the screen, not assumed).
        pinned = section_items("sec_pinned")
        loose = sorted((r for r in window().get("rows", []) if r.get("title") and r.get("in_list") and not r.get("group")),
                       key=lambda r: r["window_frame"]["y"])
        upper, lower = (loose[0], loose[1]) if len(loose) >= 2 else (None, None)
        if pinned and upper and lower:
            tile = pinned[0]
            gap_y = (upper["window_frame"]["y"] + upper["window_frame"]["height"] + lower["window_frame"]["y"]) / 2
            drag(center(tile["window_frame"]), (lower["window_frame"]["x"] + 40, gap_y), "v2-4-tile-into-list", indicator="gap")
            titles = list_titles()
            moved = "Beta"  # the first tile: pinned first, and steps 1-3 keep it first
            ok = moved in titles and lower["title"] in titles and titles.index(moved) == titles.index(lower["title"]) - 1 \
                and titles.index(upper["title"]) == titles.index(moved) - 1
            record("pinned tile into the list at the drop index", ok, f"moved={moved} between {upper['title']} and {lower['title']} list={titles}")
            undo("pinned tile into the list", lambda: moved not in list_titles())
        else:
            record("pinned tile into the list at the drop index", False, f"pinned={pinned} loose={[r.get('title') for r in loose]}")

        # 5. A link item into the main list, added as a user adds it: `cmux action run sidebar.item.add` with an address
        # (the bundled cmux of the tagged app). Its row draws the page's favicon once a tab has shown the page.
        added = cli("action", "run", "sidebar.item.add", "--item", "https://github.com", "--section", "sec_pinned")
        print("link add:", added[:400], flush=True)
        link = wait(lambda: next((i for i in section_items("sec_pinned") if i.get("ref_kind") == "url"), None), 10)
        # The drop goes above the first workspace row of the machine list: not Alpha (a Pinned tile by now, live11) and not a
        # group member (a Pinned group lists its members in the list too: live12 dropped the link into that group).
        anchor = next((r for r in window().get("rows", []) if r.get("in_list") and str(r.get("key", "")).startswith("workspace")
                       and not r.get("group")), None)
        if link and anchor:
            drag(center(link["window_frame"]), (anchor["window_frame"]["x"] + 40, anchor["window_frame"]["y"] + 2), "v2-5-link-into-list",
                 indicator="gap")
            row = wait(lambda: next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("item") and r.get("in_list")), None), 5)
            record("link item into the list lists as a row", bool(row) and not any(i.get("ref_kind") == "url" for i in section_items("sec_pinned")),
                   f"row={row and (row.get('key'), row.get('window_frame'))} items={[(i.get('section'), i.get('ref_kind')) for i in items()]}")
            # The undo toast (what Cmd-Z runs) lives 6 s: undo the drop at once, before the page loads and the favicon
            # waits (live14 ran it after them, when the toast had ended). Its redo puts the link back as a list row.
            undo("link item into the list", lambda: any(i.get("ref_kind") == "url" for i in section_items("sec_pinned")))
            row = row and wait(lambda: next((r for r in window().get("rows", []) if r.get("key") == row.get("key") and r.get("in_list")), None), 5)
            if row:
                key = row.get("key")
                before = github_panes()
                rpc("debug.mouse", {"x": center(row["window_frame"])[0], "y": center(row["window_frame"])[1], "action": "click"})
                opened = wait(lambda: [p for p in github_panes() if p[:2] not in [b[:2] for b in before]], 15)
                shot("v2-5-link-opened")
                record("link row in the list opens its page", bool(opened), f"github.com panes before={before} after={github_panes()}")
                # The open tab teaches the app the page's favicon address; the app stores it on the item (icon_url, read back
                # from the daemon with sidebar.get) and the row draws that icon, not the /favicon.ico fallback.
                # The app keys tab favicons by the page's exact origin (not gist.github.com or another GitHub host).
                tab_icon = wait(lambda: ((rpc("debug.sidebar_rows") or {}).get("open_tab_favicons") or {}).get("https://github.com"), 20)
                stored = wait(lambda: (lambda value: value if value and value == tab_icon else None)(doc_icon_url("https://github.com")), 20)
                drawn = wait(lambda: next((r for r in window().get("rows", []) if r.get("key") == key and r.get("icon") == "favicon"
                                           and r.get("icon_address") == tab_icon), None), 20)
                shot("v2-5-link-row")
                ok = bool(tab_icon) and not str(tab_icon).endswith("/favicon.ico") and stored == tab_icon and bool(drawn)
                record("link row draws the open tab's favicon", ok,
                       f"tab favicon={tab_icon} sidebar.get icon_url={doc_icon_url('https://github.com')} row icon_address="
                       f"{next((r.get('icon_address') for r in window().get('rows', []) if r.get('key') == key), None)}")
        else:
            record("link item into the list", False, f"link={link} list anchor={anchor and anchor.get('title')} after cmux action run sidebar.item.add ({added[:200]})")

        # 5b. A link dropped onto a group in Pinned (step 2's Grp: its undo toast redoes, so Grp stays in Pinned) lists as a
        # member row of that group: the same item row as a loose link, indented in the group, with the open tab's favicon.
        # The link is step 5's (its undo toast redoes, so it is a list row now), else a new one from the Pinned band.
        def member_link(gid):
            return next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("item") and r.get("in_list")
                         and r.get("group") == gid), None)

        loose_link = next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("item") and r.get("in_list")
                           and not r.get("group") and r.get("kind") == "url"), None)
        source = loose_link and loose_link["window_frame"]
        if not source:
            print("link add:", cli("action", "run", "sidebar.item.add", "--item", "https://github.com", "--section", "sec_pinned")[:400], flush=True)
            tile = wait(lambda: next((i for i in section_items("sec_pinned") if i.get("ref_kind") == "url"), None), 10)
            source = tile and tile["window_frame"]
        grp_header = group_id and next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("group")
                                        and r.get("group") == group_id), None)
        if source and grp_header:
            drag(center(source), center(grp_header["window_frame"]), "v2-5b-link-into-pinned-group")
            member = wait(lambda: member_link(group_id), 5)
            shot("v2-5b-link-member-row")
            record("link onto a Pinned group lists as its member row", bool(member) and member.get("kind") == "url"
                   and member["window_frame"]["x"] > grp_header["window_frame"]["x"],
                   f"member={member and (member.get('key'), member.get('kind'), member.get('group'), member.get('window_frame'))} "
                   f"rows={[(r.get('key'), r.get('title'), r.get('group')) for r in window().get('rows', [])]}")
            # The undo toast lives 6 s: undo the drop at once (live14 ran it after the favicon waits, when the toast had
            # ended); its redo puts the link back in Grp for the checks below.
            undo("link onto a Pinned group", lambda: member_link(group_id) is None)
            member = member and wait(lambda: member_link(group_id), 5)
            if member:
                key = member.get("key")
                tab_icon = wait(lambda: ((rpc("debug.sidebar_rows") or {}).get("open_tab_favicons") or {}).get("https://github.com"), 20)
                stored = wait(lambda: (lambda value: value if value and value == tab_icon else None)(doc_icon_url("https://github.com")), 20)
                drawn = wait(lambda: next((r for r in window().get("rows", []) if r.get("key") == key and r.get("group") == group_id
                                           and r.get("icon") == "favicon" and r.get("icon_address") == tab_icon), None), 20)
                ok = bool(tab_icon) and not str(tab_icon).endswith("/favicon.ico") and stored == tab_icon and bool(drawn)
                record("link member row draws the open tab's favicon", ok,
                       f"tab favicon={tab_icon} sidebar.get icon_url={doc_icon_url('https://github.com')} row icon_address="
                       f"{next((r.get('icon_address') for r in window().get('rows', []) if r.get('key') == key), None)}")
                # Step 5 left github.com open, so "a github.com pane exists" proves nothing: show a workspace without a
                # github.com pane first (not the one step 5 opened the page in), then the click must bring a focused
                # github.com pane that was not there before (a new pane, or the page's workspace shown again).
                open_in = {w for w, _, _ in github_panes()}
                loose = [r for r in window().get("rows", []) if r.get("in_list") and str(r.get("key", "")).startswith("workspace")
                         and not r.get("group")]
                away = next((r for r in loose if not any(w and w in str(r.get("key")) for w in open_in)), None)
                if away:
                    rpc("debug.mouse", {"x": center(away["window_frame"])[0], "y": center(away["window_frame"])[1], "action": "click"})
                    wait(lambda: not any(f for _, _, f in github_panes()), 5)
                before = github_panes()
                member = member_link(group_id) or member
                rpc("debug.mouse", {"x": center(member["window_frame"])[0], "y": center(member["window_frame"])[1], "action": "click"})
                opened = wait(lambda: [p for p in github_panes() if p[2] and p not in before], 15)
                shot("v2-5b-link-member-opened")
                record("link member row opens its page", bool(opened),
                       f"github.com panes before={before} after={github_panes()}"
                       + ("" if away else " (no loose workspace row without github.com to show first: before may already hold a focused github.com pane)"))
        else:
            record("link onto a Pinned group lists as its member row", False, f"link source={source} Grp header={grp_header} group_id={group_id}")

        # 6. Cross-machine drop: needs a second machine section.
        machines = [r for r in window().get("rows", []) if str(r.get("key", "")).startswith("section")]
        if len(machines) >= 2:
            record("cross-machine drop refused", False, "a second machine is listed; drive it by hand: not automated here")
        else:
            record("cross-machine drop refused", False, "one machine on this host (no SSH or Cloud machine); refusal not driven", skip=True)

        # Reorder while filtering: filter "o" shows Echo and Foxtrot; the lower one goes above the upper one, and
        # Cmd-Z puts back the order they had.
        rpc("debug.sidebar_filter", {"text": "o"})
        time.sleep(0.8)  # test harness: let the filtered list lay out
        echo, fox = by_title("Echo"), by_title("Foxtrot")
        if echo and fox:
            upper, lower = sorted((echo, fox), key=lambda r: r["window_frame"]["y"])
            drag(center(lower["window_frame"]), (upper["window_frame"]["x"] + 40, upper["window_frame"]["y"] + 2), "v2-6-reorder-filtered", indicator="gap")
            rpc("debug.sidebar_filter", {"text": ""})
            time.sleep(0.8)  # test harness: let the full list lay out
            titles = list_titles()
            ok = "Echo" in titles and "Foxtrot" in titles and titles.index(lower["title"]) < titles.index(upper["title"])
            record("reorder while filtering", ok, f"{lower['title']} above {upper['title']}: list={titles}")
            undo("reorder while filtering", lambda: list_titles().index(upper["title"]) < list_titles().index(lower["title"]))
        else:
            rpc("debug.sidebar_filter", {"text": ""})
            record("reorder while filtering", False, f"filtered rows={list(rows())}")

        # 7. The order survives a relaunch.
        before = (list_titles(), [i.get("ref") for i in section_items("sec_pinned")])
        relaunch()
        after = (list_titles(), [i.get("ref") for i in section_items("sec_pinned")])
        shot("v2-7-relaunched")
        record("order survives relaunch", before == after, f"before={before} after={after}")

        # 8. Band edits that go to the sidebar document (doc slice 4): alignment, spacing, Remove from Sidebar and
        # Reset each change the shown layout, and Cmd-Z puts it back.
        def layout_section(section_id):
            return next((s for s in window().get("layout_sections", []) if s.get("id") == section_id), None)

        def section_edit(step, action, arguments, check, back):
            refusals = len(toast().get("refusals") or [])
            performed = toast(perform=action, target_kind="sidebar-section", target_id="sec_pinned", arguments=arguments).get("performed")
            ok = wait(check, 5)
            new_refusals = (toast().get("refusals") or [])[refusals:]
            record(step, bool(performed and ok) and not new_refusals,
                   f"performed={performed} pinned={layout_section('sec_pinned')} refusals={new_refusals}")
            undo(step, back)

        if layout_section("sec_pinned"):
            # Two quick sidebar actions, then one Edit > Undo undoes only the second (each step is its own undo group).
            align = lambda: (layout_section("sec_pinned") or {}).get("align")
            gap = lambda: (layout_section("sec_pinned") or {}).get("gap")
            target = {"target_kind": "sidebar-section", "target_id": "sec_pinned"}
            steps_before = toast().get("undo_steps") or 0
            toast(perform="sidebar.section.setAlignment", arguments={"align": "center"}, **target)
            toast(perform="sidebar.section.setGap", arguments={"gap": 12}, **target)
            # The layout shows an edit at once (the mirror); its undo step comes with the daemon's reply. Undo only after
            # both edits show and both steps are on the stack, else Edit > Undo would find the first step alone.
            both = wait(lambda: (align() == "center" and gap() == 12) or None, 5)
            steps = wait(lambda: (lambda n: n if n >= steps_before + 2 else None)(toast().get("undo_steps") or 0), 5)
            both = both and steps
            reply = rpc("debug.menu_item", {"action": "undo:", "window_number": window_number()}) or {}
            one = wait(lambda: (gap() is None and align() == "center") or None, 5)
            time.sleep(1.0)  # test harness: a second step undone by the same Edit > Undo would land by now
            record("two quick sidebar actions: one Edit > Undo undoes only the second", bool(both) and bool(one) and align() == "center",
                   f"applied={bool(both)} undo steps {steps_before}->{toast().get('undo_steps')} reply={json.dumps(reply)[:200]} align={align()} gap={gap()}")
            rpc("debug.menu_item", {"action": "undo:", "window_number": window_number()})
            wait(lambda: (align() == "leading" and gap() is None) or None, 5)
            record("two quick sidebar actions: the next Edit > Undo undoes the first", align() == "leading" and gap() is None,
                   f"align={align()} gap={gap()}")
            section_edit("alignment goes to the document", "sidebar.section.setAlignment", {"align": "center"},
                         lambda: (layout_section("sec_pinned") or {}).get("align") == "center",
                         lambda: (layout_section("sec_pinned") or {}).get("align") == "leading")
            section_edit("spacing goes to the document", "sidebar.section.setGap", {"gap": 12},
                         lambda: (layout_section("sec_pinned") or {}).get("gap") == 12,
                         lambda: (layout_section("sec_pinned") or {}).get("gap") is None)
        else:
            record("alignment goes to the document", False, f"no sec_pinned in layout_sections={window().get('layout_sections')}")

        remove_from_sidebar()

        # Reset: the default sections again (the bookmarks item in Pinned, the "Work" section and Pinned's alignment and
        # spacing from the steps above go); Cmd-Z brings them back. The undo helper redid the removal, so the item goes in again first.
        toast(perform="sidebar.item.add", arguments={"item": "bookmarks", "section": "sec_pinned"})
        wait(lambda: bool(marked()), 5)
        before_reset = [s.get("id") for s in window().get("layout_sections", [])]

        def pinned_default():
            pinned = layout_section("sec_pinned")
            return pinned is None or (pinned.get("align") == "leading" and pinned.get("gap") is None)

        performed = toast(perform="sidebar.layout.reset").get("performed")
        reset_ok = wait(lambda: not marked() and not any(s.get("title") == "Work" for s in window().get("layout_sections", []))
                        and pinned_default(), 5)
        record("Reset goes to the document", bool(performed and reset_ok),
               f"before={before_reset} after={[s.get('id') for s in window().get('layout_sections', [])]}")
        undo("Reset", lambda: [s.get("id") for s in window().get("layout_sections", [])] == before_reset)

        # Structural reloads keep the scroll anchored (hq-2d 10-15, hitch17: the offset moved 758 -> 0 in one step): in a
        # long list scrolled to its middle, a create at the top, a pin and a close above the view move nothing on screen.
        TOP = 120  # window y below the titlebar and the list's top edge: rows from here down are inside the list viewport
        made = {}
        for index in range(200):
            ids = re.findall(r"ws_[0-9a-f]+", cli("workspace", "create", "--empty", "--name", f"V{index:03d}"))
            if ids:
                made[f"V{index:03d}"] = ids[0]
        wait(lambda: {"V000", "V199"} <= set(rows()) or None, 120)

        def first_visible():
            listed = [r for r in window().get("rows", []) if r.get("in_list") and r.get("title") and r["window_frame"]["y"] >= TOP]
            top = min(listed, key=lambda r: r["window_frame"]["y"], default=None)
            return (top["title"], top["window_frame"]["y"]) if top else None

        def above_view(exclude):
            """A V row well above the viewport (not shown), the nearest to it."""
            listed = [r for r in window().get("rows", []) if r.get("in_list") and str(r.get("title", "")).startswith("V")
                      and r["title"] in made and r["title"] not in exclude and r["window_frame"]["y"] < TOP - 200]
            return max(listed, key=lambda r: r["window_frame"]["y"], default=None)

        print("focus middle", cli("workspace", made.get("V100", "V100"), "focus")[:120], flush=True)
        time.sleep(1.0)  # test harness: let the reveal scroll apply
        base = first_visible()
        print("anchor base:", base, "made:", len(made), flush=True)
        used = {"V100"}

        def anchored(label, act, done):
            before = first_visible()
            evidence = act()
            ok_done = wait(done, 10)
            time.sleep(1.0)  # test harness: let the row springs settle
            after = first_visible()
            same = bool(before and after and before[0] == after[0] and abs(before[1] - after[1]) <= 0.5)
            record(f"long list keeps its first visible row on screen: {label}", bool(ok_done) and same,
                   f"before={before} after={after} done={bool(ok_done)} {evidence} selected={[r.get('title') for r in window().get('rows', []) if r.get('selected')]}")
            shot("v2-anchor-" + label.replace(" ", "-"))

        if base and len(made) == 200:
            anchored("create at the top", lambda: cli("workspace", "create", "--empty", "--name", "VTOP")[:80],
                     lambda: "VTOP" in rows() or None)
            pin = above_view(used)
            if pin:
                used.add(pin["title"])
                anchored("pin one above the view",
                         lambda: str(toast(perform="palette.toggleWorkspacePin", target_kind="workspace", target_id=row_id(pin)).get("performed")),
                         lambda: pin["title"] not in list_titles() or None)
            else:
                record("long list keeps its first visible row on screen: pin one above the view", False, "no row above the view")
            close = above_view(used)
            if close:
                used.add(close["title"])
                anchored("close one above the view", lambda: cli("workspace", made[close["title"]], "close")[:80],
                         lambda: close["title"] not in rows() or None)
            else:
                record("long list keeps its first visible row on screen: close one above the view", False, "no row above the view")

            # Scroll reveal (hq-2d DESIGN.md, cx-ml98q): a change from another client that moves the ACTIVE row out of view
            # never moves the view. Another client (cmux-tui `raw operation`, its own key) moves V100 to its section's top.
            print("focus V100 again", cli("workspace", made["V100"], "focus")[:120], flush=True)
            wait(lambda: any(r.get("title") == "V100" and r.get("selected") for r in window().get("rows", [])) or None, 10)
            time.sleep(1.0)  # test harness: let the reveal scroll apply
            listed = window().get("rows", [])
            active = next((r for r in listed if r.get("title") == "V100" and r.get("in_list")), None)
            keep = next((r for r in sorted(listed, key=lambda r: r["window_frame"]["y"]) if r.get("in_list") and r.get("title")
                         and r["title"] != "V100" and r["window_frame"]["y"] >= TOP), None)
            document = doc_operation("sidebar.get") or {}
            ids = {made["V100"], row_id(active)} if active else {made["V100"]}
            item = next((i for i in document.get("items", []) if (i.get("body") or {}).get("type") == "workspace"
                         and ids & {(i["body"].get("ref") or {}).get("workspace_id"), (i["body"].get("ref") or {}).get("workspace_key")}), None)
            top = item and min((i for i in document.get("items", []) if i.get("section") == item.get("section") and not i.get("parent")
                                and i["id"] != item["id"]), key=lambda i: i.get("order", ""), default=None)
            visible = bool(active and active["window_frame"]["y"] >= TOP)
            if item and top and keep and visible:
                moved = doc_operation("sidebar.move", items=[item["id"]], to={"section": item["section"], "before": top["id"]})
                gone = wait(lambda: (next((r for r in window().get("rows", []) if r.get("title") == "V100"), {"window_frame": {"y": 0}})
                                     ["window_frame"]["y"] < TOP) or None, 10)
                time.sleep(1.0)  # test harness: a reveal scroll would apply within this
                after = next((r for r in window().get("rows", []) if r.get("title") == keep["title"]), None)
                still = bool(after and abs(after["window_frame"]["y"] - keep["window_frame"]["y"]) <= 0.5)
                selected = [r.get("title") for r in window().get("rows", []) if r.get("selected")]
                # The move really happened in the document (the check is not trivially true).
                placed = next((i for i in (doc_operation("sidebar.get") or {}).get("items", []) if i["id"] == item["id"]), {})
                first = placed.get("order", "") < top.get("order", "")
                record("another client moves the active row out of view: the view does not move",
                       bool(gone) and still and first and selected in ([], ["V100"]),  # V100 off screen: its row may not be realized
                       f"kept={keep['title']} y {keep['window_frame']['y']} -> {after and after['window_frame']['y']} gone={bool(gone)} "
                       f"selected={selected} first_in_doc={first} reply={str(moved)[:120]}")
                shot("v2-reveal-other-client")
            else:
                record("another client moves the active row out of view: the view does not move", False,
                       f"setup: item={bool(item)} top={bool(top)} keep={keep and keep.get('title')} active visible={visible}")
        else:
            record("long list keeps its first visible row on screen", False, f"setup: base={base} made={len(made)}")
    except FocusedDone:
        pass  # `--only`: the focused steps ran
    except BaseException as error:
        record("the run finished", False, f"stopped by {error!r}")  # failed_steps counts it
        raise
    finally:
        try:
            print("refusals:", toast().get("refusals"), flush=True)
        except Exception as error:  # the stop and the results still run
            print("refusals: unreadable", repr(error), flush=True)
        LAUNCHER.stop()  # debug.quit, then the tag's daemons and terminal hosts (tag_teardown.py)
        print("summary:", json.dumps(RESULTS), flush=True)
        record_results()  # after the stop: the features are the last launch's snapshot
    return 1 if any(state == "FAIL" for _, state in RESULTS) else 0


if __name__ == "__main__":
    sys.exit(main())
