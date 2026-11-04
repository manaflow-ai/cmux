"""R-INPUT scratch (never merge, agent a80216a78adfb7d0f): which focus source a menu item chosen with a REAL mouse gives.

#35275's reply bound counts the person's focus choices (FocusState.personMoveSeq): a responder report counts only with
the mouse source, and a handler's `.intent` source is the event AppKit dispatches (FocusEvent.Source.current), else the
CLI's. The open question (lead, after #35275 landed): when a person picks a main-menu item with the mouse, does the item's
action run inside the dispatch of a mouse event (source mouse) or after the menu's tracking (source programmatic/cli)?
This step answers it on a real build and changes nothing:

  rinput_menu_mouse {menu: "View", item: "Focus Right Sidebar", name: "menu"}
    - CuaDriver tools/list (names and argument schemas) and its accessibility tree of the app, kept as diag files;
    - a desktop-scope (true screen pixels) click on the menu bar title MENU, the tree again, a click on ITEM;
    - the app's focus events since (debug.focus recent_events per window, with their sources), its action log since
      (debug.action_budget recent: entrypoint, outcome), and the frontmost app after.
Never fails on what it sees: what it cannot do (no tree, no title found) is NOT RUN with the reason.
"""
import json
import re
import time

D = None
R = None


def install(driver):
    global D, R
    D = driver
    import ext_realkey as realkey
    R = realkey


FRAME_KEYS = (("x", "y", "width", "height"), ("x", "y", "w", "h"))


def _frame(node):
    """A node's frame (x, y, w, h) in global points from the primary display's top-left, if it names one."""
    for key in ("frame", "bounds", "rect"):
        value = node.get(key)
        if isinstance(value, dict):
            for names in FRAME_KEYS:
                if all(n in value for n in names):
                    return tuple(float(value[n]) for n in names)
        if isinstance(value, (list, tuple)) and len(value) == 4:
            return tuple(float(v) for v in value)
        if isinstance(value, str):
            nums = re.findall(r"-?\d+(?:\.\d+)?", value)
            if len(nums) == 4:
                return tuple(float(v) for v in nums)
    pos, size = node.get("position"), node.get("size")
    if isinstance(pos, dict) and isinstance(size, dict):
        return (float(pos.get("x", 0)), float(pos.get("y", 0)), float(size.get("width", size.get("w", 0))),
                float(size.get("height", size.get("h", 0))))
    return None


def _walk(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from _walk(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from _walk(value)


def _text_of(node):
    return " ".join(str(node.get(k) or "") for k in ("title", "label", "name", "description", "value", "text"))


def _find(tree, title, roles):
    """The first node whose role is one of ROLES and whose title is TITLE, with its frame; else from text lines."""
    for node in _walk(tree):
        role = str(node.get("role") or node.get("AXRole") or "")
        if any(r.lower() in role.lower() for r in roles) and title.lower() in _text_of(node).lower():
            frame = _frame(node)
            if frame and frame[2] > 0 and frame[3] > 0:
                return {"role": role, "title": _text_of(node).strip(), "frame": frame}
    # A compact text tree: lines such as `[12] AXMenuBarItem "View" ... (x, y, w, h)` or `frame: {x, y, w, h}`.
    text = json.dumps(tree) if not isinstance(tree, str) else tree
    for line in text.replace("\\n", "\n").split("\n"):
        if title.lower() in line.lower() and any(r.lower() in line.lower() for r in roles):
            nums = re.findall(r"-?\d+(?:\.\d+)?", line.split(title, 1)[-1])
            if len(nums) >= 4:
                x, y, w, h = (float(v) for v in nums[-4:])
                if w > 0 and h > 0:
                    return {"role": "text", "title": line.strip()[:200], "frame": (x, y, w, h)}
    return None


def _tree(j, name, n):
    """CuaDriver's accessibility tree of the app (first the app's pid, then no argument), saved as diag-NAME<n>.json."""
    tries = [{"pid": j.app.pid}, {}]
    last = None
    for args in tries:
        bad, data, raw = R._session(j).call("get_accessibility_tree", args)
        last = {"args": args, "bad": bad, "data": data, "raw": raw}
        if not bad and (data or raw):
            break
    (j.out / f"diag-{name}tree{'abcdefgh'[n]}.json").write_text(json.dumps(last, default=str)[:4_000_000])
    content = last["data"] or last["raw"]
    if isinstance(content, dict) and isinstance(content.get("content"), list):
        texts = [c.get("text") for c in content["content"] if isinstance(c, dict) and c.get("text")]
        parsed = []
        for t in texts:
            try:
                parsed.append(json.loads(t))
            except ValueError:
                parsed.append(t)
        content = {"structured": last["data"], "texts": parsed}
    return content, last


def _click(j, frame, scale):
    x, y, w, h = frame
    args = {"scope": "desktop", "x": round((x + w / 2) * scale), "y": round((y + h / 2) * scale)}
    before = D.now()
    bad, data, raw = R._session(j).call("click", args)
    return {"args": args, "bad": bad, "effect": (data or {}).get("effect"), "at": round(before, 4),
            "raw": json.dumps(raw, default=str)[:400]}


def _focus_events(j):
    report = j.app.rpc("debug.focus") or {}
    return [{"id": w.get("id"), "is_key": w.get("is_key"), "recent_events": w.get("recent_events"),
             "model": w.get("model")} for w in report.get("windows", [])]


def step_rinput_menu_mouse(j, step):
    name = step.get("name", "menu")
    if not (name.isalpha() and name.islower()):
        raise D.StepError("rinput_menu_mouse: name must be lowercase letters (diag-<name>*.json)")
    R.require_front(j)
    out = {"menu": step.get("menu", "View"), "item": step.get("item", "Focus Right Sidebar")}
    listed = R._session(j).request("tools/list", {})
    tools = [{"name": t.get("name"), "schema": t.get("inputSchema")} for t in (listed.get("tools") or [])]
    (j.out / f"diag-{name}tools.json").write_text(json.dumps(tools, indent=1, default=str))
    out["tools"] = [t["name"] for t in tools]
    bad, size, raw = R._session(j).call("get_screen_size", {})
    scale = float((size or {}).get("scale_factor") or 1.0)
    out["scale"] = scale
    focus_before = _focus_events(j)
    seq_before = R._last_sequence(j)
    tree, meta = _tree(j, name, 0)
    title = _find(tree, out["menu"], ("MenuBarItem",))
    out["menu_title"] = title
    if not title:
        out["tree_head"] = json.dumps(meta, default=str)[:3000]
        (j.out / f"diag-{name}result.json").write_text(json.dumps(out, indent=1, default=str))
        raise D.NotRun(f"rinput_menu_mouse: no menu bar item {out['menu']!r} with a frame in CuaDriver's tree "
                       f"(tools {out['tools']}; diag-{name}treea.json)")
    out["click_title"] = _click(j, title["frame"], scale)
    time.sleep(float(step.get("open_wait", 0.8)))
    tree2, meta2 = _tree(j, name, 1)
    item = _find(tree2, out["item"], ("MenuItem",))
    out["menu_item"] = item
    if not item:
        R._session(j).call("press_key", {"key": "escape"})  # close the open menu
        (j.out / f"diag-{name}result.json").write_text(json.dumps(out, indent=1, default=str))
        raise D.NotRun(f"rinput_menu_mouse: the open menu shows no item {out['item']!r} with a frame "
                       f"(diag-{name}treeb.json)")
    out["click_item"] = _click(j, item["frame"], scale)
    time.sleep(float(step.get("settle", 1.0)))
    out["focus_before"] = focus_before
    out["focus_after"] = _focus_events(j)
    out["actions_since"] = [{"id": r.get("id"), "entrypoint": r.get("entrypoint"), "outcome": r.get("outcome"),
                             "sequence": r.get("sequence")} for r in R._recent_actions(j)
                            if int(r.get("sequence") or 0) > seq_before]
    before = {e for w in focus_before for e in (w.get("recent_events") or [])}
    out["new_focus_events"] = [e for w in out["focus_after"] for e in (w.get("recent_events") or []) if e not in before]
    out["sources_seen"] = sorted({m.group(1) for e in out["new_focus_events"]
                                  for m in re.finditer(r"source: (?:[A-Za-z.]*\.)?([a-z]+)\)", e)})
    out["front_pid_after"] = R.front_pid()
    (j.out / f"diag-{name}result.json").write_text(json.dumps(out, indent=1, default=str))
    return {"menu_title": title, "menu_item": item, "click_title": out["click_title"], "click_item": out["click_item"],
            "new_focus_events": out["new_focus_events"], "sources_seen": out["sources_seen"],
            "actions_since": out["actions_since"], "tools": out["tools"]}


STEPS = {"rinput_menu_mouse": step_rinput_menu_mouse}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
