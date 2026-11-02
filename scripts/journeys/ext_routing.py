"""Focus and input routing: which pane a person's typed text lands in (VIDEO EXTRA item 5, lead 2026-11-02 00:29Z).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

The P0 wrong-pane bugs (#29262, #29530, #30827, #30271): after an action that moves the focus (Cmd-N, Ctrl-`, Cmd-D,
Cmd-W, Cmd-1..9, Ctrl-Tab, a click while a split or close animates), the next keys go to another pane, to a page,
or nowhere. Each attempt of a routing journey types one unique marker line at once after the action (real HID keys:
the journey option key_path=real, smoke_type_now) and then asks where it landed.

Steps (`do`):
  routing_click   {pane: NAME, settle?: 0, mark?}
                  a real click (ext_realkey real_click, desktop scope) in the pane named NAME (smoke_adopt_line) at a
                  quarter of its width from its left edge and half its height: inside the pane before and after a
                  split right of it, whichever layout debug.surfaces reports while the split animates. No settle by
                  default: the next step types at once, while the animation still runs.
  routing_map_workspace_keys {names: [NAME...]}
                  set-up: presses Cmd-1 .. Cmd-8 (the journey's key path) and reads after each which workspace the
                  journey's window shows (debug.windows `selected`), until each named pane's workspace has its digit.
                  The app's own numbering (Home and other sidebar items may take digits first; sidebar.numbering).
                  A name no digit reaches: not run.
  routing_select_workspace {pane: NAME, mark?}
                  Cmd-<digit> of the workspace of the pane named NAME, from routing_map_workspace_keys.

Conditions (inside `expect.all`):
  routing_marker  {line, on, attempt?}
                  (evidence daemon) LINE is on exactly one terminal of the whole topology (its daemon screen), and
                  that terminal is the expected one; the app's viewport text of its pane shows LINE too (what the
                  person sees), and no other pane's viewport shows it. ON is:
                    NAME          a terminal named before the action (smoke_adopt_line);
                    "new:SNAP"    the one terminal that is new since smoke_snapshot SNAP (exactly one new);
                    "focused"     the selected terminal of the pane the app shows focused now.
                  The detail names the verdict of the attempt: `right` (on the expected terminal only), `wrong` (on
                  another terminal), `lost` (on no terminal), `split` (on more than one), and where it landed
                  (workspace, pane, the name of the pane if it has one); `unjudged` when the harness cannot name one
                  expected terminal (never a product verdict). IN_NEW_WORKSPACE (with new:SNAP): the new terminal must
                  also be in a workspace the snapshot did not have (Cmd-N made it). The tally of a run is read from
                  these details (routing/tally.py).
"""
import json
import time

D = None


def install(driver):
    global D
    D = driver


def _smoke():
    import ext_smoke
    return ext_smoke


def _realkey():
    import ext_realkey
    return ext_realkey


def _names_by_term(j):
    return {v["term"]: k for k, v in (getattr(j, "smoke_named", {}) or {}).items()}


def _expected(j, on, terms, focused_pane):
    """(terminal key or None, why) the marker must land on."""
    if on == "focused":
        hits = [t for t, place in terms.items() if place[1] == focused_pane and place[2]]
        return (hits[0] if len(hits) == 1 else None), f"the selected terminal of the focused pane {focused_pane}"
    if on.startswith("new:"):
        snap = (getattr(j, "smoke_snapshots", {}) or {}).get(on[4:])
        if snap is None:
            return None, f"no smoke_snapshot named {on[4:]!r} ran before this check"
        new = sorted(t for t in terms if t not in set(snap["terms"]))
        return (new[0] if len(new) == 1 else None), f"the one terminal new since {on[4:]} ({len(new)} new: {new})"
    named = (getattr(j, "smoke_named", {}) or {}).get(on)
    if not named:
        return None, f"no pane named {on!r} (smoke_adopt_line first)"
    # Named by its daemon terminal (smoke_adopt_line keeps the public id); the topology keys on terminal_key.
    hits = [t for t, place in terms.items() if place[3] == named["term"] or t == named["term"]]
    return (hits[0] if len(hits) == 1 else None), f"the terminal named {on!r} ({named['term']})"


def cond_routing_marker(j, want, cache):
    sm = _smoke()
    line = j.sub(want["line"])
    terms, _tabs = sm._layout(j)
    focused_pane = sm._focused_pane(j)
    holders = []
    for key, place in terms.items():
        try:
            screen = set(sm._lines(j.app.screen(place[3])["text"]))
        except D.StepError:
            continue
        if line in screen:
            holders.append(key)
    panes = cache.setdefault("routing_panes", j.app.panes())
    shown = [p.get("pane") for p in panes if line in set(sm._lines(p.get("text")))]
    expect, why = _expected(j, str(want["on"]), terms, focused_pane)
    names = _names_by_term(j)
    landed = [{"terminal": t, "workspace": terms[t][0], "pane": terms[t][1], "selected": terms[t][2],
               "name": names.get(terms[t][3]) or names.get(t)} for t in holders]
    if expect is None:
        # The harness could not name one expected terminal (0 or 2+ new terminals, no selected terminal in the
        # focused pane): no verdict about the product (review N2 at 2d05ea3072e).
        verdict = "unjudged"
    elif not holders:
        verdict = "lost"
    elif len(holders) > 1:
        verdict = "split"
    elif holders[0] == expect:
        verdict = "right"
    else:
        verdict = "wrong"
    problems = []
    if expect is None:
        problems.append(f"no expected terminal: {why}")
    elif want.get("in_new_workspace") and str(want["on"]).startswith("new:"):
        snap = (getattr(j, "smoke_snapshots", {}) or {}).get(str(want["on"])[4:]) or {}
        if terms[expect][0] in set(snap.get("workspaces") or []):
            problems.append(f"the new terminal is in workspace {terms[expect][0]}, which the snapshot had: Cmd-N made "
                            "no new workspace for it")
    if verdict not in ("right", "unjudged"):
        problems.append(f"{line} is {verdict}: on {len(holders)} terminals {[l['name'] or l['pane'] for l in landed]}, "
                        f"expected {why}")
    elif verdict == "right":
        want_pane = terms[expect][1]
        if want_pane not in shown:
            problems.append(f"the daemon has {line} on the expected terminal, but its pane {want_pane} does not show it "
                            f"in the app (shown in panes {shown})")
        if any(p != want_pane for p in shown):
            problems.append(f"another pane shows {line} in the app: {shown}")
    return not problems, {"verdict": verdict, "attempt": want.get("attempt"), "line": line, "expected": why,
                          "expected_terminal": expect, "landed": landed, "app_panes_showing": shown,
                          "focused_pane": focused_pane, "problems": problems}


def step_routing_click(j, step):
    named = (getattr(j, "smoke_named", {}) or {}).get(step["pane"])
    if not named:
        raise D.StepError(f"routing_click: no pane named {step['pane']!r} (smoke_adopt_line first)")
    rows = [p for w in (j.app.rpc("debug.surfaces") or {}).get("windows", []) for p in w.get("panes", [])
            if isinstance(p, dict) and p.get("pane") == named["pane"]]
    grid = (rows[0].get("grid") if rows else None) or {}
    if not all(k in grid for k in ("frame_x", "frame_y", "frame_width", "frame_height")):
        raise D.NotRun(f"routing_click: no frame for pane {step['pane']} ({named['pane']}) in debug.surfaces")
    # A quarter of the width: inside the pane both before a split right of it (full width) and after (half width), so
    # a read that comes before the split's layout still clicks the pane (review N4 at 2d05ea3072e).
    point = [grid["frame_x"] + grid["frame_width"] / 4, grid["frame_y"] + grid["frame_height"] / 2]
    rec = _realkey().step_real_click(j, dict(step, window_point=point, settle=float(step.get("settle", 0))))
    return dict(rec, named=step["pane"], frame=[grid["frame_x"], grid["frame_y"], grid["frame_width"], grid["frame_height"]])


def _shown_workspace(j):
    """The workspace the journey's window shows (debug.windows `selected`): its key or id, or None."""
    report = j.app.rpc("debug.windows") or {}
    wins = [w for w in report.get("windows") or [] if isinstance(w, dict) and w.get("open")]
    key = getattr(j, "key_window", None)
    win = next((w for w in wins if w.get("id") == key), None) or next((w for w in wins if w.get("visible")), None)
    if (win or {}).get("shown_page"):
        return f"page:{win['shown_page']}"  # Home or another page over the workspace: not the workspace
    return (win or {}).get("selected")


def _workspace_aliases(j):
    """{key or id: id} of every workspace of the topology (debug.windows names a workspace by its key or its id)."""
    out = {}
    for ws in j.topology().get("workspaces", []):
        for k in (ws.get("key"), ws.get("id")):
            if k:
                out[k] = ws.get("id")
    return out


def step_routing_map_workspace_keys(j, step):
    named = getattr(j, "smoke_named", {}) or {}
    wanted = {}
    for name in step["names"]:
        if name not in named:
            raise D.StepError(f"routing_map_workspace_keys: no pane named {name!r} (smoke_adopt_line first)")
        wanted[name] = named[name]["workspace"]
    sm = _smoke()
    terms_before = set(sm._layout(j)[0])
    digits, seen, taken = {}, [], set()
    # A digit counts only when the shown workspace CHANGED after it (a digit with no item, or the digit of the
    # workspace already shown, changes nothing and proves nothing); a second pass, from another shown workspace,
    # maps the digit of the workspace that was shown at its first press.
    for digit in [d for _ in range(2) for d in range(1, 9)]:
        if len(digits) == len(wanted):
            break
        if digit in taken:
            continue
        before = _shown_workspace(j)
        sm.step_smoke_key(j, {"key": str(digit), "modifiers": ["cmd"]})
        shown, stable_since, end = None, None, D.now() + 2.0
        while D.now() < end:  # the shown workspace, once it holds still for 0.3 s
            now_shown = _shown_workspace(j)
            if now_shown != shown:
                shown, stable_since = now_shown, D.now()
            elif D.now() - stable_since >= 0.3:
                break
            time.sleep(0.05)
        ws = _workspace_aliases(j).get(shown, shown)
        seen.append({"digit": digit, "before": before, "shown": shown, "workspace": ws})
        if shown == before:
            continue
        taken.add(digit)
        for name, target in wanted.items():
            if ws == target and name not in digits:
                digits[name] = digit
    grown = sorted(set(sm._layout(j)[0]) - terms_before)
    if grown:
        # A digit ran a launcher item (New Terminal Tab, ...) as a click does: a new tab may now be the selected tab
        # of a named pane, so the later checks would name the wrong terminal (review should-fix 1 at 4adadd2e28e).
        raise D.NotRun(f"routing_map_workspace_keys: the digits made {len(grown)} new terminals ({grown[:3]}): a "
                       f"launcher item has a digit; the map is not usable ({json.dumps(seen)[:300]})")
    missing = [n for n in wanted if n not in digits]
    if missing:
        raise D.NotRun(f"routing_map_workspace_keys: Cmd-1..8 reached no workspace of {missing} ({json.dumps(seen)[:400]})")
    j.routing_digits = digits
    return {"digits": digits, "seen": seen}


def step_routing_select_workspace(j, step):
    digit = (getattr(j, "routing_digits", {}) or {}).get(step["pane"])
    if digit is None:
        raise D.StepError(f"routing_select_workspace: no digit for {step['pane']!r} (routing_map_workspace_keys first)")
    rec = _smoke().step_smoke_key(j, {"key": str(digit), "modifiers": ["cmd"], "mark": step.get("mark")})
    return dict(rec, digit=digit, pane=step["pane"])


def step_routing_type_now(j, step):
    """TEXT and Return as real HID keys at once, like smoke_type_now, but it never refuses: a person's keys go
    wherever the app has the keyboard, so the routing check must see where they land. It records which window was
    key when the first key went out (debug.windows: a New Tab page's child Chromium window, a panel) and the
    debug.focus model, for the finding. Real keys only (key_path=real)."""
    if (j.spec.get("options") or {}).get("key_path") != "real":
        raise D.NotRun("routing_type_now: real keys only (journey option key_path=real)")
    sm, rk = _smoke(), _realkey()
    key_now, windows = sm._main_key(j)
    try:
        focus = (j.app.rpc("debug.focus") or {}).get("windows", [{}])[0].get("model", {}).get("resolved")
    except (D.StepError, AttributeError, IndexError):
        focus = None
    text = j.sub(step["text"])
    j.hold_from = None
    rk.require_front(j)
    sent = D.now()
    for ch in text:
        rk.press_char(j, ch)
    rk.press(j, "return")
    return {"typed": text, "keys": len(text) + 1, "at": round(sent, 4), "send_ms": round((D.now() - sent) * 1000, 1),
            "key_path": "real_hid", "main_window_key": key_now, "focus_resolved": focus,
            "key_windows": [w for w in windows if w.get("key") is True]}


STEPS = {"routing_type_now": step_routing_type_now, "routing_click": step_routing_click, "routing_map_workspace_keys": step_routing_map_workspace_keys,
         "routing_select_workspace": step_routing_select_workspace}
CONDITIONS = {"routing_marker": ("daemon", cond_routing_marker)}
