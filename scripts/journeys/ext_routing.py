"""Focus and input routing: which pane a person's typed text lands in (VIDEO EXTRA item 5, lead 2026-11-02 00:29Z).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

The P0 wrong-pane bugs (#29262, #29530, #30827, #30271): after an action that moves the focus (Cmd-N, Ctrl-`, Cmd-D,
Cmd-W, Cmd-1..9, Ctrl-Tab, a click while a split or close animates), the next keys go to another pane, to a page,
or nowhere. Each attempt of a routing journey types one unique marker line at once after the action (real HID keys:
the journey option key_path=real, smoke_type_now) and then asks where it landed.

Steps (`do`):
  routing_click   {pane: NAME, settle?: 0, mark?}
                  a real click (ext_realkey real_click, desktop scope) at the center of the pane named NAME
                  (smoke_adopt_line), with no settle by default: the next step types at once, while an animation
                  that the step before started still runs.

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
                  (workspace, pane, the name of the pane if it has one). The tally of a run is read from these
                  details (routing-tally.py).
"""
import json

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
    if not holders:
        verdict = "lost"
    elif len(holders) > 1:
        verdict = "split"
    elif expect is not None and holders[0] == expect:
        verdict = "right"
    else:
        verdict = "wrong"
    problems = []
    if expect is None:
        problems.append(f"no expected terminal: {why}")
    if verdict != "right":
        problems.append(f"{line} is {verdict}: on {len(holders)} terminals {[l['name'] or l['pane'] for l in landed]}, "
                        f"expected {why}")
    else:
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
    rec = _realkey().step_real_click(j, dict(step, pane=named["pane"], settle=float(step.get("settle", 0))))
    return dict(rec, named=step["pane"])


def step_routing_select_workspace(j, step):
    """Cmd-<number> of the workspace that holds the pane named PANE: its 1-based place in the topology's workspace
    order (the sidebar's order), pressed on the journey's key path (smoke_key: real HID with key_path=real)."""
    named = (getattr(j, "smoke_named", {}) or {}).get(step["pane"])
    if not named:
        raise D.StepError(f"routing_select_workspace: no pane named {step['pane']!r} (smoke_adopt_line first)")
    order = [ws.get("id") for ws in j.topology().get("workspaces", [])]
    if named["workspace"] not in order:
        raise D.StepError(f"routing_select_workspace: workspace {named['workspace']} is not in the topology {order}")
    number = order.index(named["workspace"]) + 1
    if number > 8:
        # Cmd-9 is the last workspace, not the ninth: the kit only presses 1..8.
        raise D.NotRun(f"routing_select_workspace: workspace {step['pane']} is number {number}; Cmd-1..8 only")
    rec = _smoke().step_smoke_key(j, {"key": str(number), "modifiers": ["cmd"], "mark": step.get("mark")})
    return dict(rec, workspace=named["workspace"], number=number, order=order)


STEPS = {"routing_click": step_routing_click, "routing_select_workspace": step_routing_select_workspace}
CONDITIONS = {"routing_marker": ("daemon", cond_routing_marker)}
