"""Focus steps for the journeys (group focus, journeys/p1/focus-*.json): after every action, something takes the keys.

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Lawrence 2026-10-29 (felt 1f): "at any point in time (with some very minor exceptions?), something should always be
focused, so that keyboard only operation is possible. for example i do cmd shift l and it opens a browser tab, but
then i start typing, and nothing is focused". The invariant and its exceptions: plans/cmux-next/focus-invariant.md.

Keys: a capture slot's app is never active, so AppKit has no key window there and a key posted to the event queue
reaches no window (debug.key's `key_window: shell` is refused: "the shell window did not become key"). Keys
therefore go through `debug.key`'s dispatch into the front window (debug.windows z_order), the way
NSApplication.sendEvent hands a key to the key window: the key router, key equivalents, the menu, then the
window's first responder; into the palette while it is open. `focus_press {sequence: true}` posts through the event
queue instead, for a Mac where the app is active.

Steps (`do`):
  focus_press   {key, modifiers?, sequence?, make_key?, mark?}
                                        one key press into the front window (or the palette); `sequence`: through
                                        the event queue (an active app only)
  focus_probe   {expect?, settle?, fail?, as?}
                                        waits for focus to settle (no focus expectation pending, no key hold),
                                        then checks the invariant and types one probe key; `expect` is the target
                                        kind the probe must land in (`terminal`, `addressBar`, `browserPage`,
                                        `palette`, `settings`, `home`, `any`); `fail` (default true) raises at a
                                        violation; the result names the action, window, first responder and the
                                        expected target
  focus_fuzz    {seed?, count?, actions?, settle?}
                                        COUNT random actions from ACTIONS (default: every name in ACTIONS below),
                                        a focus_probe after each; fails at the first violation with the seed and
                                        the actions so far (a repro: the same seed plays the same sequence)

Conditions (inside `expect.all`; evidence kind app):
  focus_ok      {}                      the invariant holds now (no probe key typed)
"""
import json
import random
import time

D = None  # the driver module (install)

# ANSI virtual key codes (as DebugKey's table); modifiers are flags-changed events of their own keys.
CODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
         "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
         "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
         "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
         "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
         "left": 123, "right": 124, "down": 125, "up": 126}
MODS = {"cmd": 55, "shift": 56, "option": 58, "control": 59}

# The fuzz's actions: (key, modifiers) a person presses, and the target the keys must reach after it.
# `None` as the target: any key-taking target (the invariant alone).
ACTIONS = {
    "new_terminal_tab": (("t", ["cmd"]), "terminal"),
    "new_browser_tab": (("l", ["cmd", "shift"]), "addressBar"),
    "close_tab": (("w", ["cmd"]), None),
    "split_right": (("d", ["cmd"]), "terminal"),
    "split_down": (("d", ["cmd", "shift"]), "terminal"),
    "zoom": (("return", ["cmd", "shift"]), None),
    "palette": (("p", ["cmd", "shift"]), "palette"),
    "palette_escape": (("escape", []), None),
    "settings": ((",", ["cmd"]), "settings"),
    "settings_close": (("w", ["cmd"]), None),
    "new_window": (("n", ["cmd", "shift"]), None),
    "workspace_1": (("1", ["cmd"]), None),
    "workspace_2": (("2", ["cmd"]), None),
    "new_workspace": (("n", ["cmd"]), None),
    "next_tab": (("]", ["cmd", "shift"]), None),
    "close_window": (("w", ["control", "cmd"]), None),
    "workspace_3": (("3", ["cmd"]), None),
    "move_workspace_to_new_window": ("rpc", None),
}
# Kinds whose landing the probe reads back: the terminal's viewport, the omnibar's field.
TEXT_KINDS = {"terminal", "addressBar"}
# A probe letter: types visibly in a field or at a prompt and runs nothing on its own.
PROBE = "j"
SETTLE_LIMIT = 5.0


def install(driver):
    global D
    D = driver


def front_window(j):
    """The cmux window in front (debug.windows z_order, open and visible): the person's window. A capture slot's app
    is never active, so AppKit has no key window there; its keys go to this window, as debug.key dispatches them."""
    report = j.app.rpc("debug.windows") or {}
    shown = {w.get("id") for w in report.get("windows") or [] if w.get("open") and w.get("visible")}
    for wid in report.get("z_order") or []:
        if wid in shown:
            return wid
    return None


def press(j, key, modifiers=(), make_key=False, window=None, sequence=False):
    """One key press. With the app active (a person's Mac), through the app's event queue to the key window
    (debug.key sequence). In a capture slot (never active, no key window), debug.key's dispatch into the front
    window (as NSApplication.sendEvent does for the key window), or into the palette while it is open."""
    j.last_key_at = D.now()
    if sequence:
        code = CODES.get(key)
        if code is None:
            raise D.StepError(f"focus_press: no key code for {key!r}")
        seq = []
        for m in modifiers:
            seq.append({"key_code": MODS[m], "down": True, "after_ms": 3 if seq else 0})
        seq.append({"key_code": code, "down": True, "after_ms": 5})
        seq.append({"key_code": code, "down": False, "after_ms": 40})
        for m in reversed(list(modifiers)):
            seq.append({"key_code": MODS[m], "down": False, "after_ms": 3})
        params = {"sequence": seq}
        if make_key:
            params["key_window"] = "shell"
            if window:
                params["window"] = window
        reply = j.app.rpc("debug.key", params) or {}
        time.sleep(float(reply.get("duration_ms") or 60) / 1000 + 0.05)
        return reply
    params = {"key": key, "modifiers": list(modifiers)}
    focus = j.app.rpc("debug.focus") or {}
    if (focus.get("context") or {}).get("palette_open"):
        params["target"] = "palette"
    else:
        wid = window or front_window(j)
        if wid:
            params["window"] = wid
    return j.app.rpc("debug.key", params) or {}


def read(j):
    focus = j.app.rpc("debug.focus") or {}
    try:
        check = (j.app.rpc("debug.desync", {"check": True}) or {}).get("check") or {}
    except D.StepError as error:
        check = {"error": str(error)}
    return focus, check


def owner(focus, front=None):
    """The cmux window the keyboard belongs to: the key one, else the front one (FRONT, a capture slot: no key
    window), else the window whose model has an overlay or a child page, else None."""
    windows = focus.get("windows") or []
    for w in windows:
        if w.get("is_key"):
            return w
    for w in windows:
        if front and w.get("id") == front:
            return w
    for w in windows:
        if (w.get("model") or {}).get("overlays") or (w.get("appkit") or {}).get("child_window_page"):
            return w
    return None


def pending(focus):
    """Why focus has not settled yet: an expectation waits to land, or keys wait for a new tab."""
    why = []
    for w in focus.get("windows") or []:
        if (w.get("model") or {}).get("expectation"):
            why.append(f"{w.get('id')}: expectation {(w.get('model') or {}).get('expectation')}")
    why += [f"new-tab key hold in {h}" for h in focus.get("new_tab_key_holds") or []]
    return why


def settle(j, limit):
    """Polls debug.focus until nothing is pending or LIMIT seconds pass; returns (focus, waited_s, still_pending)."""
    t0 = D.now()
    while True:
        focus = j.app.rpc("debug.focus") or {}
        why = pending(focus)
        if not why or D.now() - t0 >= limit:
            return focus, round(D.now() - t0, 3), why
        time.sleep(0.1)


def kind_of(focus, w):
    """The target kind that has the keys: the model's resolved kind, or the panel / window over it."""
    key = str(focus.get("key_window") or "")
    if (focus.get("context") or {}).get("palette_open") or "Palette" in key:
        return "palette"
    if "Settings" in key:
        return "settings"
    if w is None:
        return None
    return (w.get("model") or {}).get("resolved")


def violations(focus, check, expect, front=None):
    """The invariant (plans/cmux-next/focus-invariant.md) on one reading. While the app is not active (a capture
    slot) AppKit has no key window by design (the exception "cmux is not the active app"): the front window's
    model and responder are checked instead."""
    out = []
    w = owner(focus, front)
    active = bool(focus.get("app_active"))
    key = focus.get("key_window")
    if key is None and active:
        out.append("I1 no key window: keys go nowhere")
    kind = kind_of(focus, w)
    if kind in (None, "none", "emptyPane") and (key is not None or not active):
        out.append(f"I2 the key window has no key-taking target (resolved {kind})")
    if w is not None:
        classified = (w.get("appkit") or {}).get("classified")
        if classified in ("sidebar", "sidebarField") and kind not in ("sidebar", "sidebarField"):
            out.append(f"I3 the sidebar has the keys ({classified}) while the model targets {kind}")
        out += [f"I4 {m}" for m in w.get("mismatches") or []]
    for v in (check.get("violations") or []):
        if str(v.get("invariant", "")).startswith(("W1", "W5", "F1", "F3")):
            out.append(f"I4 {v.get('invariant')} {v.get('window')}: {v.get('detail')}")
    if expect and expect != "any" and kind != expect:
        out.append(f"I5 expected {expect} to take the keys, {kind} does")
    return out, w, kind


def terminal_text(j, w):
    """The viewport text of the focused terminal pane of window W (debug.surfaces)."""
    report = j.app.rpc("debug.surfaces", {"text": True}) or {}
    for win in report.get("windows") or []:
        if w is not None and win.get("window") != w.get("id"):
            continue
        for p in win.get("panes") or []:
            if isinstance(p, dict) and p.get("focused") and p.get("text") is not None:
                return p.get("text") or ""
    return None


def omnibar_text(j, w):
    params = {"window": w.get("id")} if w else {}
    try:
        return (j.app.rpc("debug.omnibar", params) or {}).get("field_text")
    except D.StepError:
        return None


def probe(j, kind, w):
    """Types PROBE and reads it back where the kind shows text; then deletes it. Returns (landed, detail)."""
    before = terminal_text(j, w) if kind == "terminal" else omnibar_text(j, w) if kind == "addressBar" else None
    press(j, PROBE)
    if kind not in TEXT_KINDS:
        return None, f"typed {PROBE!r}; {kind} is not read back"
    end = D.now() + 2.0
    after = before
    while D.now() < end:
        after = terminal_text(j, w) if kind == "terminal" else omnibar_text(j, w)
        if after is not None and before is not None and after != before and after.rstrip().endswith(PROBE):
            press(j, "delete")
            return True, f"{kind} shows the probe"
        time.sleep(0.1)
    tail = lambda s: None if s is None else s.rstrip()[-60:]
    return False, f"{kind} did not show {PROBE!r}: before {tail(before)!r}, after {tail(after)!r}"


def describe(focus, w):
    return {"key_window": focus.get("key_window"), "app_active": focus.get("app_active"),
            "window": w.get("id") if w else None,
            "first_responder": (w.get("appkit") or {}).get("first_responder") if w else None,
            "classified": (w.get("appkit") or {}).get("classified") if w else None,
            "model": w.get("model") if w else None, "topology": w.get("topology") if w else None,
            "recent_events": (w.get("recent_events") or [])[-6:] if w else None,
            "new_tab_key_log": (focus.get("new_tab_key_log") or [])[-6:]}


def check_now(j, expect=None, limit=SETTLE_LIMIT, type_probe=True):
    focus, waited, still = settle(j, limit)
    focus, check = read(j)
    found, w, kind = violations(focus, check, expect, front_window(j))
    if still:
        found.insert(0, f"I6 focus did not settle in {limit} s: {'; '.join(still)}")
    landed, detail = (None, "no probe")
    if type_probe and not any(v.startswith(("I1", "I2")) for v in found):
        landed, detail = probe(j, kind, w)
        if landed is False:
            found.append(f"I7 the probe key did not land: {detail}")
    return {"ok": not found, "violations": found, "kind": kind, "expected": expect, "settle_s": waited,
            "probe": detail, "state": describe(focus, w)}


def step_focus_press(j, step):
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    reply = press(j, step["key"], step.get("modifiers", []), make_key=bool(step.get("make_key")), window=step.get("window"),
                  sequence=bool(step.get("sequence")))
    return {"key": step["key"], "modifiers": step.get("modifiers", []), "reply": reply}


def step_focus_probe(j, step):
    result = check_now(j, step.get("expect"), float(step.get("settle", SETTLE_LIMIT)))
    if not result["ok"] and step.get("fail", True):
        raise D.StepError("focus invariant broken: " + " | ".join(result["violations"]) + " :: " + json.dumps(result["state"])[:1500])
    return result


def run_action(j, name):
    how, _ = ACTIONS[name]
    if how == "rpc":
        # A script's move (as the sidebar row's menu runs it): the invariant holds after it too.
        return j.app.rpc("action.run", {"action": "moveWorkspaceToNewWindow", "args": {}})
    key, mods = how
    return press(j, key, mods)


def step_focus_fuzz(j, step):
    seed = int(step.get("seed", random.randrange(1 << 30)))
    rng = random.Random(seed)
    names = step.get("actions") or sorted(ACTIONS)
    count = int(step.get("count", 30))
    played, log = [], []
    for index in range(count):
        if D.now() > j.deadline - 20:
            break
        name = rng.choice(names)
        played.append(name)
        try:
            reply = run_action(j, name)
        except D.StepError as error:
            reply = {"error": str(error)}
        result = check_now(j, ACTIONS[name][1], float(step.get("settle", SETTLE_LIMIT)))
        log.append({"index": index, "action": name, "reply": reply if isinstance(reply, dict) and reply.get("error") else None,
                    "ok": result["ok"], "kind": result["kind"], "probe": result["probe"], "settle_s": result["settle_s"]})
        if not result["ok"]:
            raise D.StepError(f"focus invariant broken after action {index} {name} (seed {seed}, played {played}): "
                              + " | ".join(result["violations"]) + " :: " + json.dumps(result["state"])[:2500])
    return {"seed": seed, "played": played, "log": log}


STEPS = {"focus_press": step_focus_press, "focus_probe": step_focus_probe, "focus_fuzz": step_focus_fuzz}


def cond_focus_ok(j, want, cache):
    focus, check = read(j)
    found, w, kind = violations(focus, check, want.get("expect") if isinstance(want, dict) else None, front_window(j))
    return not found, {"violations": found, "kind": kind, "state": describe(focus, w)}


CONDITIONS = {"focus_ok": ("app", cond_focus_ok)}
