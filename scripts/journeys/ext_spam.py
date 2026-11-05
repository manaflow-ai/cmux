"""Shortcut-spam steps and conditions for the journeys (group shortcut-spam, journeys/p0/spam-*.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Lawrence 2026-10-28 (handoff/input-principles.md, hold-shortcuts-ux.md, repeat-runoff.md): "spamming cmd w needs to
work, same thing for all other shortcuts. spamming it very fast must work perfectly, very fast." Each spam journey
holds one shortcut down (key repeat) and hammers it (20 presses in 1 s), and judges what the person sees:

  - held: one action per repeat delivered while the key is down, none after it goes up (no backlog), and Cmd-W
    stops before the pane's last tab (key repeat never crosses a boundary);
  - hammered: every physical press does exactly one action, none dropped, none doubled.

Keys are sent as the system makes them: each on its own schedule (a thread per key, the event's `timestamp` its
scheduled time on this Mac's uptime clock), so a main thread that falls behind sees a queue of old repeats, as
with a real held key. `debug.key {repeat: true}` sends an auto-repeat; the app's repeat gate reads that key as down
(a slot has no physical key) and still drops repeats that waited longer than one repeat interval.

Each hold and hammer reply has a `bench` row (the shortcut-spam bench): presses handled per second and each run's
main-thread time to its commit (debug.action_budget, p50 / p99 / max). Target on an optimized build: p99 < 2 ms.

Steps (`do`):
  spam_remember {as}                   keeps the journey workspace's counts (tabs, panes, the focused pane's tabs,
                                       its selected tab, the workspaces of the window, the workspace shown) as AS
  hold_key      {key, modifiers?, seconds?, delay?, interval?, as, mark?}
                                       one press, then auto-repeats every INTERVAL (default 0.033 s, the fastest
                                       System Settings rate) from DELAY (default 0.25 s) until SECONDS (default 2);
                                       then the key is up. Keeps AS_release (the counts one frame after the key-up)
                                       and AS (the reply counts: `ran`, the actions that ran; `sent`). MARK (default
                                       AS) is the key-up moment
  hammer_key    {key, modifiers?, presses?, within?, as, mark?}
                                       PRESSES (default 20) physical presses spread over WITHIN seconds (default 1)

Conditions (inside `expect.all`; evidence kind app):
  spam_counts   {from: NAME, field, delta | equals | delta_runs: HOLD | delta_presses: HAMMER, sign?}
                                       the field now (tabs, panes, pane_tabs, workspaces) against NAME's: `delta` a
                                       number, `delta_runs` SIGN times the runs a hold or hammer reported, `equals`
  spam_unchanged {since: NAME, fields?} negative: the counts still equal NAME's (with `settle`: nothing happened
                                       after the key-up)
  spam_selected {from: NAME, by: N | by_runs: HOLD, sign?}
                                       the focused pane's selected tab moved that many places in NAME's tab order
  spam_runs     {of: NAME, ran | ran_le | ran_ge: N | "sent" | "sent-1"}
                                       the actions a hold or hammer ran
"""
import threading
import time

D = None  # the driver module (install)
FRAME = 1 / 60.0


def install(driver):
    global D
    D = driver


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def _init(j):
    if not hasattr(j, "spam"):
        j.spam = {}
        j.spam_workspace = None


def counts(j, cache=None):
    """The journey workspace's counts from the app's topology (snapshot.get)."""
    topo = j.topology() if cache is None or "spam_topo" not in cache else cache["spam_topo"]
    if cache is not None:
        cache["spam_topo"] = topo
    wid = getattr(j, "spam_workspace", None)
    if wid is None:
        place = j.place_of(j.need_term(), topo)
        if not place:
            raise D.StepError("the journey's terminal is in no tab of the topology")
        wid = place[0].get("id")
        j.spam_workspace = wid
    ws = next((w for w in topo.get("workspaces", []) if w.get("id") == wid), None)
    windows = topo.get("windows", [])
    out = {"workspaces": len(topo.get("workspaces", [])), "workspace_open": ws is not None}
    if ws is None:
        return dict(out, tabs=0, panes=0, pane_tabs=0, selected=None, pane_tab_ids=[])
    panes = [p for s in ws.get("screens", []) for p in s.get("panes", [])]
    focused = None
    for w in windows:
        focused = focused or w.get("focused_pane")
    pane = next((p for p in panes if p.get("id") == focused), panes[0] if panes else None)
    out.update(tabs=sum(len(p.get("tabs", [])) for p in panes), panes=len(panes),
               pane_tabs=len(pane.get("tabs", [])) if pane else 0, selected=pane.get("selected_tab") if pane else None,
               pane_tab_ids=[t.get("id") for t in pane.get("tabs", [])] if pane else [])
    return out


def step_spam_remember(j, step):
    _init(j)
    got = counts(j)
    j.spam[step["as"]] = got
    j.marks[step["as"]] = D.now()
    return got


def _send(j, key, modifiers, at, is_repeat, window):
    """One key at its scheduled uptime `at` (sleeps until then); returns the reply."""
    wait = at - uptime()
    if wait > 0:
        time.sleep(wait)
    params = {"key": key, "modifiers": modifiers, "timestamp": at}
    if is_repeat:
        params["repeat"] = True
    if window or j.key_window:
        params["window"] = window or j.key_window
    try:
        return j.app.rpc("debug.key", params)
    except Exception as error:  # a reply that timed out still ran or queued its key
        return {"error": str(error)}


def _play(j, key, modifiers, schedule, window):
    """Sends each (time, is_repeat) of `schedule` on its own thread, so a slow reply never delays the next key."""
    replies = [None] * len(schedule)

    def run(index, at, is_repeat):
        replies[index] = _send(j, key, modifiers, at, is_repeat, window)

    threads = [threading.Thread(target=run, args=(i, at, rep), daemon=True) for i, (at, rep) in enumerate(schedule)]
    for t in threads:
        t.start()
    return threads, replies


def _budget_mark(j):
    """The newest action-budget sample's sequence now (debug.action_budget), or None when the build has none."""
    try:
        report = j.app.rpc("debug.action_budget", {"limit": 1}) or {}
    except Exception:
        return None
    recent = report.get("recent") or []
    return max((r.get("sequence", 0) for r in recent), default=0)


def _bench(j, since, seconds, ran):
    """The bench row of one hold or hammer: presses handled per second and each run's main-thread time to its
    commit (debug.action_budget `commit_ms`: ActionBudgetMonitor), p50 / p99 / max, for runs after `since`."""
    if since is None:
        return None
    try:
        report = j.app.rpc("debug.action_budget", {"limit": 512}) or {}
    except Exception as error:
        return {"error": str(error)}
    ms = sorted(r.get("commit_ms", 0.0) for r in report.get("recent") or [] if r.get("sequence", 0) > since)
    if not ms:
        return {"runs_sampled": 0}

    def pct(p):
        return round(ms[min(len(ms) - 1, int(p * len(ms)))], 3)
    return {"presses_per_s": round(ran / seconds, 1) if seconds else None, "runs_sampled": len(ms),
            "main_ms_p50": pct(0.5), "main_ms_p99": pct(0.99), "main_ms_max": round(ms[-1], 3)}


def _summary(replies):
    ran = sum(1 for r in replies if isinstance(r, dict) and r.get("action"))
    refused = sum(1 for r in replies if isinstance(r, dict) and r.get("refused_action"))
    errors = [r.get("error") for r in replies if isinstance(r, dict) and r.get("error")][:3]
    dropped = next((r.get("repeats_dropped") for r in reversed(replies) if isinstance(r, dict) and r.get("repeats_dropped")), None)
    return {"sent": len(replies), "ran": ran, "refused": refused, "errors": errors, "repeats_dropped": dropped}


def step_hold_key(j, step):
    _init(j)
    j.before_keys()
    window = j.window_for(step.get("window"))
    seconds, delay, interval = float(step.get("seconds", 2)), float(step.get("delay", 0.25)), float(step.get("interval", 0.033))
    start = uptime() + 0.05
    schedule = [(start, False)]
    t = start + delay
    while t < start + seconds:
        schedule.append((t, True))
        t += interval
    key_up = start + seconds
    mark = _budget_mark(j)
    threads, replies = _play(j, step["key"], step.get("modifiers", []), schedule, window)
    # The key goes up at key_up: debug.key stops reading it as held (repeats still queued then are a backlog).
    time.sleep(max(0.0, key_up - uptime()))
    try:
        up = {"key": step["key"], "modifiers": step.get("modifiers", []), "up": True}
        if window or j.key_window:
            up["window"] = window or j.key_window
        j.app.rpc("debug.key", up)
    except Exception:
        pass
    # One frame after the key-up: what the person sees when they let go.
    time.sleep(max(0.0, key_up + FRAME - uptime()))
    name = step["as"]
    j.marks[step.get("mark", name)] = D.now()
    j.spam[name + "_release"] = counts(j)
    for thread in threads:
        thread.join(30)
    summary = _summary(replies)
    summary["bench"] = _bench(j, mark, seconds, summary["ran"])
    j.spam[name] = summary
    j.last_key_at = D.now()
    return dict(summary, at_release=j.spam[name + "_release"])


def step_hammer_key(j, step):
    _init(j)
    j.before_keys()
    window = j.window_for(step.get("window"))
    presses, within = int(step.get("presses", 20)), float(step.get("within", 1))
    start = uptime() + 0.05
    schedule = [(start + i * within / max(presses, 1), False) for i in range(presses)]
    mark = _budget_mark(j)
    threads, replies = _play(j, step["key"], step.get("modifiers", []), schedule, window)
    for thread in threads:
        thread.join(30)
    name = step["as"]
    j.marks[step.get("mark", name)] = D.now()
    summary = _summary(replies)
    summary["bench"] = _bench(j, mark, within, summary["ran"])
    j.spam[name] = summary
    j.last_key_at = D.now()
    return summary


def _remembered(j, name):
    _init(j)
    if name not in j.spam:
        raise D.StepError(f"no spam_remember / hold_key / hammer_key named {name!r}")
    return j.spam[name]


def _target(j, want, base):
    if "equals" in want:
        return want["equals"]
    sign = int(want.get("sign", 1))
    if "delta_runs" in want:
        return base + sign * int(_remembered(j, want["delta_runs"])["ran"]) + int(want.get("plus", 0))
    return base + int(want.get("delta", 0))


def cond_spam_counts(j, want, cache):
    before = _remembered(j, want["from"])
    now = counts(j, cache)
    field = want.get("field", "tabs")
    wanted = _target(j, want, before.get(field) or 0)
    return now.get(field) == wanted, {"field": field, "now": now.get(field), "wanted": wanted, "before": before.get(field)}


def cond_spam_unchanged(j, want, cache):
    before = _remembered(j, want["since"])
    now = counts(j, cache)
    fields = want.get("fields") or ["tabs", "panes", "pane_tabs", "workspaces"]
    changed = {f: [before.get(f), now.get(f)] for f in fields if before.get(f) != now.get(f)}
    return not changed, {"changed": changed}


def cond_spam_selected(j, want, cache):
    """The focused pane's selected tab is NAME's selected tab moved by `by` (or SIGN times a hold's or hammer's
    runs, `by_runs`) places in NAME's tab order, wrapping (Ctrl-Tab, Cmd-Shift-[ and ])."""
    before = _remembered(j, want["from"])
    ids = before.get("pane_tab_ids") or []
    if before.get("selected") not in ids:
        return False, {"error": "no selected tab at the mark", "before": before.get("selected")}
    by = int(want.get("by", 0))
    if "by_runs" in want:
        by = int(want.get("sign", 1)) * int(_remembered(j, want["by_runs"])["ran"])
    wanted = ids[(ids.index(before["selected"]) + by) % len(ids)]
    now = counts(j, cache)
    return now.get("selected") == wanted, {"now": now.get("selected"), "wanted": wanted, "by": by, "order": ids}


def cond_spam_runs(j, want, cache):
    got = _remembered(j, want["of"])
    ran, sent = got["ran"], got["sent"]

    def value(v):
        if v == "sent":
            return sent
        if v == "sent-1":
            return sent - 1
        return int(v)

    ok = True
    if "ran" in want:
        ok = ok and ran == value(want["ran"])
    if "ran_le" in want:
        ok = ok and ran <= value(want["ran_le"])
    if "ran_ge" in want:
        ok = ok and ran >= value(want["ran_ge"])
    return ok, {"ran": ran, "sent": sent, "refused": got.get("refused"), "dropped": got.get("repeats_dropped")}


STEPS = {"spam_remember": step_spam_remember, "hold_key": step_hold_key, "hammer_key": step_hammer_key}
CONDITIONS = {"spam_counts": ("app", cond_spam_counts), "spam_unchanged": ("app", cond_spam_unchanged),
              "spam_runs": ("app", cond_spam_runs), "spam_selected": ("app", cond_spam_selected)}
NEGATIVE = {"spam_unchanged"}
