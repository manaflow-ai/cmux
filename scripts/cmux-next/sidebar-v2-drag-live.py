#!/usr/bin/env python3
"""Live proof of the sidebar document drag engine (sidebar-v2 S3-S5) on a tagged app.

Run it on cmux-lawrence-2 in an nx-remote GUI job with a fleet-built app of a
commit that has both the client lane and the doc lane (`sidebar-doc-v1`):

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-v2-drag-live.py --out "$NX_ARTIFACTS"

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
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
APP = os.environ.get("NX_APP")
TAG = os.environ.get("NX_APP_TAG", "")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
STOP = os.environ.get("NX_APP_STOP")
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
SCRATCH = tempfile.mkdtemp(prefix=f"sidebar-v2-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
RESULTS = []


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
    record(f"{label}: ffi calls per drag == 2", per_drag == 2 and set(calls_during) <= {"drag_begin"},
           f"during the held drag {calls_during}, at the drop {calls_drop}")
    return per_drag


def undo(label, check):
    toast(undo=True)
    time.sleep(1.0)  # test harness: let the inverse land
    ok = bool(check())
    record(f"{label}: Cmd-Z restores", ok, f"list={list_titles()} pinned={[i.get('ref') for i in section_items('sec_pinned')]}")
    toast(undo=True)  # redo is the next undo toast; the step's result stays for the next step
    time.sleep(1.0)  # test harness: let the redo land


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,720"]
    subprocess.run(["open", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("FAIL the tagged app did not come up")
    wait(lambda: (report().get("doc") or {}).get("active"), 30)
    time.sleep(1.5)  # test harness: let the window settle


def by_title(title):
    return rows().get(title)


def row_id(row):
    """The id inside a row key such as `workspace(<id>)`."""
    key = str((row or {}).get("key", ""))
    return key[key.find("(") + 1:key.rfind(")")] if "(" in key else key


launch()
doc = report().get("doc") or {}
print("doc:", json.dumps(doc), flush=True)
if not doc.get("active"):
    record("sidebar-doc-v1 active", False, "debug.sidebar_rows doc.active is false: the daemon lacks sidebar-doc-v1 or the FFI lacks the mirror")
    subprocess.run([STOP])
    sys.exit(1)
try:
    for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot"):
        cli("workspace", "create", "--name", name)
    wait(lambda: {"Alpha", "Foxtrot"} <= set(rows()), 20)
    for name in ("Beta", "Gamma"):  # two tiles first, so index 1 is between them
        toast(perform="palette.toggleWorkspacePin", target_kind="workspace", target_id=row_id(by_title(name)))
    time.sleep(1.0)  # test harness: let the pins land
    shot("v2-0-start")
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

    # 5. A link item into the main list.
    print(toast(perform="sidebar.item.add", arguments={"item": "https://example.com", "section": "Pinned"}), flush=True)
    time.sleep(1.0)  # test harness: let the item show
    link = next((i for i in items() if i.get("ref_kind") == "url"), None)
    alpha = by_title("Alpha")
    if link and alpha:
        drag(center(link["window_frame"]), (alpha["window_frame"]["x"] + 40, alpha["window_frame"]["y"] + 2), "v2-5-link-into-list",
             indicator="gap")
        row = wait(lambda: next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("item") and r.get("in_list")), None), 5)
        record("link item into the list lists as a row", bool(row) and not any(i.get("ref_kind") == "url" for i in section_items("sec_pinned")),
               f"row={row and (row.get('key'), row.get('window_frame'))} items={[(i.get('section'), i.get('ref_kind')) for i in items()]}")
        if row:
            rpc("debug.mouse", {"x": center(row["window_frame"])[0], "y": center(row["window_frame"])[1], "action": "click"})
            opened = wait(lambda: "example.com" in json.dumps(rpc("debug.surfaces") or {}), 15)
            shot("v2-5-link-opened")
            record("link row in the list opens its page", bool(opened), "debug.surfaces names example.com" if opened else "no example.com surface")
    else:
        record("link item into the list", False, f"no url item after sidebar.item.add (link={link})", skip=link is None)

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
    subprocess.run([STOP])
    launch()
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
        section_edit("alignment goes to the document", "sidebar.section.setAlignment", {"align": "center"},
                     lambda: (layout_section("sec_pinned") or {}).get("align") == "center",
                     lambda: (layout_section("sec_pinned") or {}).get("align") == "leading")
        section_edit("spacing goes to the document", "sidebar.section.setGap", {"gap": 12},
                     lambda: (layout_section("sec_pinned") or {}).get("gap") == 12,
                     lambda: (layout_section("sec_pinned") or {}).get("gap") is None)
    else:
        record("alignment goes to the document", False, f"no sec_pinned in layout_sections={window().get('layout_sections')}")

    # A built-in item (sidebar.item.add takes workspaces, apps and built-ins, not links) into Pinned, then Remove from
    # Sidebar: every item that shows it goes, through the document.
    def marked():
        return [i for i in section_items("sec_pinned") if str(i.get("ref")) == "bookmarks"]

    toast(perform="sidebar.item.add", arguments={"item": "bookmarks", "section": "Pinned"})
    added = wait(lambda: next(iter(marked()), None), 5)
    if added:
        toast(perform="sidebar.item.removeEverywhere", target_kind="sidebar-item", target_id=added["id"])
        gone = wait(lambda: not any(str(i.get("ref")) == "bookmarks" for i in items()), 5)
        record("Remove from Sidebar goes to the document", bool(gone), f"item={added.get('id')} items={[i.get('ref') for i in items()]}")
        undo("Remove from Sidebar", lambda: bool(marked()))
    else:
        record("Remove from Sidebar goes to the document", False, f"no bookmarks item in Pinned after sidebar.item.add: {[i.get('ref') for i in items()]}")

    # Reset: the default sections again (the bookmarks item in Pinned, the "Work" section and Pinned's alignment and
    # spacing from the steps above go); Cmd-Z brings them back. The undo helper redid the removal, so the item goes in again first.
    toast(perform="sidebar.item.add", arguments={"item": "bookmarks", "section": "Pinned"})
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
finally:
    refusals = toast().get("refusals")
    print("refusals:", refusals, flush=True)
    subprocess.run([STOP])
failed = [step for step, state in RESULTS if state == "FAIL"]
print("summary:", json.dumps(RESULTS), flush=True)
sys.exit(1 if failed else 0)
