"""R-INPUT scratch (never merge, agent a80216a78adfb7d0f): which focus source a menu item chosen with a REAL mouse gives.

#35275's reply bound counts the person's focus choices (FocusState.personMoveSeq): a responder report counts only with
the mouse source, and a handler's `.intent` source is the event AppKit dispatches (FocusEvent.Source.current), else the
CLI's. The open question (lead, after #35275 landed): when a person picks a main-menu item with the mouse, does the item's
action run inside the dispatch of a mouse event (source mouse) or after the menu's tracking (source programmatic/cli)?
This step answers it on a real build and changes nothing:

  rinput_menu_mouse {menu: "View", item: "Focus Right Sidebar", name: "menu"}
    - a desktop screenshot (CuaDriver get_desktop_state) and its text boxes (ocr_boxes.swift, Vision), kept as diag
      files; a desktop-scope (true screen pixels) click on the menu bar title MENU; the same again; a click on ITEM;
    - the app's focus events since (debug.focus recent_events per window, with their sources), its action log since
      (debug.action_budget recent: entrypoint, outcome), and the frontmost app after.
Never fails on what it sees: what it cannot do (no screenshot, no title found) is NOT RUN with the reason.
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


def _focus_events(j):
    report = j.app.rpc("debug.focus") or {}
    return [{"id": w.get("id"), "is_key": w.get("is_key"), "recent_events": w.get("recent_events"),
             "model": w.get("model")} for w in report.get("windows", [])]


def _ocr_bin():
    """ocr_boxes.swift built once on the mini (Vision text with its box)."""
    import os
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    exe = os.path.join(os.path.dirname(here), "ocrboxes", "ocr_boxes")
    if not os.path.exists(exe):
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        built = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macos14.4",
                                os.path.join(here, "ocr_boxes.swift"), "-o", exe], capture_output=True, text=True, timeout=300)
        if built.returncode:
            raise D.StepError(f"rinput_menu_mouse: ocr_boxes build failed: {built.stderr[-600:]}")
    return exe


def _desktop_boxes(j, name, n):
    """A desktop screenshot (CuaDriver get_desktop_state, native pixels) and its text boxes [(x, y, w, h, text)]."""
    import subprocess
    shot = j.out / f"diag-{name}shot{'abcdefgh'[n]}.png"
    bad, data, raw = R._session(j).call("get_desktop_state", {"screenshot_out_file": str(shot)})
    if bad or not shot.exists():
        raise D.NotRun(f"rinput_menu_mouse: no desktop screenshot: {json.dumps(raw, default=str)[:300]}")
    done = subprocess.run([_ocr_bin(), str(shot)], capture_output=True, text=True, timeout=120)
    boxes = []
    for line in done.stdout.splitlines():
        head, _, text = line.partition("\t")
        nums = head.split()
        if len(nums) == 4:
            boxes.append((*(float(v) for v in nums), text))
    (j.out / f"diag-{name}ocr{'abcdefgh'[n]}.txt").write_text("\n".join(f"{b[0]:.0f} {b[1]:.0f} {b[2]:.0f} {b[3]:.0f}\t{b[4]}" for b in boxes))
    return boxes, shot


def _box(boxes, text, top_band=None, below=None):
    """The box of TEXT (case-insensitive): in the top TOP_BAND pixels (the menu bar), or under BELOW's y (the open
    menu); the leftmost first. Vision reads neighbor menu titles as one line ("View Server Window Help"): a box whose
    words contain TEXT gives TEXT's part of it, placed by its share of the line's characters."""
    want = text.strip().lower()
    places = lambda b: (top_band is None or b[1] < top_band) and (below is None or b[1] > below)
    exact = [b for b in boxes if b[4].strip().lower() == want and places(b)]
    if exact:
        return sorted(exact, key=lambda b: (b[1], b[0]))[0]
    for x, y, w, h, line in sorted((b for b in boxes if places(b)), key=lambda b: (b[1], b[0])):
        at = line.lower().find(want)
        words = line.lower().split()
        if at < 0 or want.split()[0] not in words or not line.strip():
            continue
        per = w / max(len(line), 1)
        return (x + at * per, y, len(want) * per, h, text)
    return None


def _desktop_click(j, box):
    x, y, w, h, _ = box
    args = {"scope": "desktop", "x": round(x + w / 2), "y": round(y + h / 2)}
    before = D.now()
    bad, data, raw = R._session(j).call("click", args)
    return {"args": args, "bad": bad, "effect": (data or {}).get("effect"), "at": round(before, 4),
            "raw": json.dumps(raw, default=str)[:300]}


def step_rinput_menu_mouse(j, step):
    name = step.get("name", "menu")
    if not (name.isalpha() and name.islower()):
        raise D.StepError("rinput_menu_mouse: name must be lowercase letters (diag-<name>*.json)")
    R.require_front(j)
    out = {"menu": step.get("menu", "View"), "item": step.get("item", "Focus Right Sidebar")}
    focus_before = _focus_events(j)
    seq_before = R._last_sequence(j)
    boxes, shot = _desktop_boxes(j, name, 0)
    band = float(step.get("menu_bar_px", 80))
    title = _box(boxes, out["menu"], top_band=band)
    out["menu_title"] = title
    if not title:
        (j.out / f"diag-{name}result.json").write_text(json.dumps(out, indent=1, default=str))
        raise D.NotRun(f"rinput_menu_mouse: the desktop screenshot shows no menu bar title {out['menu']!r} in its top "
                       f"{band:.0f} px (diag-{name}ocra.txt)")
    out["click_title"] = _desktop_click(j, title)
    time.sleep(float(step.get("open_wait", 0.8)))
    boxes2, _ = _desktop_boxes(j, name, 1)
    item = _box(boxes2, out["item"], below=title[1] + title[3])
    out["menu_item"] = item
    if not item:
        R._session(j).call("press_key", {"key": "escape"})  # close the open menu
        (j.out / f"diag-{name}result.json").write_text(json.dumps(out, indent=1, default=str))
        raise D.NotRun(f"rinput_menu_mouse: the open menu shows no item {out['item']!r} (diag-{name}ocrb.txt)")
    out["click_item"] = _desktop_click(j, item)
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
            "actions_since": out["actions_since"]}


STEPS = {"rinput_menu_mouse": step_rinput_menu_mouse}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
