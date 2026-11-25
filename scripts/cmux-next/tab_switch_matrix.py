"""The settle matrix of the tab switch harness (tab_switch_frames.py --scenarios matrix): every way a chat page or the
sidebar is moved, timed from the trigger to truly settled, at Leo's scale.

Leo, 2026-11-18: "And have faster truly settled agent transcripts showing up whether from loading in app or switching
between workspaces or making a new one every possible scenario that any tab of anything moves or gets split or adjusted
in any way we need fast / Fundamentally". And: "And then likewise, of course, we want that for the sidebar. And we
want things to be fast."

Truly settled is the harness's settled_ms (tab_switch_settle.py: the last frame that changed anything, when the picture
then held QUIET_MS), taken three times per action: over the whole window, over the page side (right of the sidebar:
the panes, their strips and the chat pages in them) and over the sidebar. The mark is the marker flip just before the
trigger, so every time counts from the frame that showed the flip, not from the input.

Scenarios (MATRIX_SCENARIOS), each once a round, in the measured workspace with its chat shown:
  switch-workspace-cold  goToWorkspace to one of the scale workspaces this launch never showed
  switch-workspace-warm  back to the measured workspace, then to that workspace again, then back (3 a round)
  new-workspace          the harness's own (workspace_round), kept as it is
  new-chat               new.agentChat.tab in the measured pane
  split                  splitRight of the measured pane (the chat shown in it)
  resize-split           resizePaneRight of the measured pane, split
  tab-move               the chat tab moved to the right pane, then back (moveSurfaceToPaneRight / Left; 2 a round)
  unsplit                closePane of the right pane
  window-resize          zoomWindow, then zoomWindow again (2 a round)
  pane-to-window         a scratch pane (splitRight) moved to a new window (pane.moveToNewWindow), then closed
  chat-10k-open          a 10,000-row chat opened as a tab of the measured pane (agent.openSessionTab)
  chat-10k-return        the terminal shown, then that chat again
  launch-restore         Quit and Keep Sessions, then the app again in the same home: from the exec to settled
                         (after every load, in a block of its own)

At scale (--scale leo): before the first launch the app's empty ~/.acpmux gets 10,789 sessions written through the
store (cmux-tui acpmux `examples/scale_home.rs`, god_fixture::write_scale_home), and once the measured workspace is
built, 205 of them open as workspaces (agent.openSessionWorkspace), so the sidebar holds 206 workspaces, as Leo's did
on 2026-11-18.
"""
from __future__ import annotations

import json
import os
import subprocess
import time

import tab_switch_settle as settle
from state_wait import wait_until

MATRIX_SCENARIOS = ("switch-workspace-cold", "switch-workspace-warm", "new-workspace", "new-chat", "split",
                    "resize-split", "tab-move", "unsplit", "window-resize", "pane-to-window", "chat-10k-open",
                    "chat-10k-return", "launch-restore")
SCALES = {"leo": (10789, 206)}  # sessions, workspaces (Leo's daemon and sidebar, 2026-11-18)
BUDGET_MS = 150.0
CHAT_10K_ROWS = 10000


def parse_scale(text):
    """(sessions, workspaces) of --scale: a name in SCALES, or SESSIONSxWORKSPACES (2000x50); None for none."""
    if not text or text == "none":
        return None
    if text in SCALES:
        return SCALES[text]
    sessions, _, workspaces = text.partition("x")
    if not (sessions.isdigit() and workspaces.isdigit()):
        raise ValueError(f"--scale takes {', '.join(SCALES)} or SESSIONSxWORKSPACES, not {text!r}")
    return int(sessions), int(workspaces)


# ---------------------------------------------------------------------------------------------------------------
# Scale.

def seed_home(seeder, home, sessions, log):
    """`sessions` chats written into the acpmux home `home` by the scale_home example; their ids."""
    os.makedirs(home, exist_ok=True)
    started = time.monotonic()
    done = subprocess.run([seeder, home, str(sessions), "1", "4"], capture_output=True, text=True, timeout=1800)
    if done.returncode != 0:
        raise RuntimeError(f"scale_home: {(done.stdout + done.stderr).strip()[-600:]}")
    made = json.loads(done.stdout.strip().splitlines()[-1])
    log(f"scale: {made['chats']} sessions in {home} in {round(time.monotonic() - started, 1)} s")
    return made["ids"]


def open_scale_workspaces(h, ids, workspaces, log):
    """workspaces - 1 of the seeded chats opened as workspaces in the background, the measured one shown again; their
    workspace ids, oldest first, kept on the harness for the cold switches."""
    started = time.monotonic()
    before = set(h.workspace_ids())
    failed = 0
    for session in ids[1:workspaces]:
        reply = h.c.action("agent.openSessionWorkspace", focus=False, session=session)
        failed += bool(reply.get("error"))
    h.c.action("goToWorkspace", workspace=h.workspace_id)
    h.wait_workspace(h.workspace_id, "the measured workspace shown again", timeout=30)
    made = [w for w in h.workspace_ids() if w not in before]
    h.scale_workspaces = list(made)
    log(f"scale: {len(made)} more workspaces ({len(h.workspace_ids())} in all, {failed} opens refused) in "
        f"{round(time.monotonic() - started, 1)} s")
    return made


# ---------------------------------------------------------------------------------------------------------------
# Regions.

def regions(h):
    """{"page": rect, "sidebar": rect} in recorded pixels: the sidebar band and everything right of it."""
    w, rh = h.rec.w, h.rec.h
    side = getattr(h, "sidebar", None)
    out = {"page": (side[2], 0, w, rh) if side else (0, 0, w, rh)}
    if side:
        out["sidebar"] = side
    return out


def crop_frames(frames, w, rect):
    """[(t, gray)] cut to `rect` (raw gray, not quantized: settle quantizes)."""
    x0, y0, x1, y1 = rect
    return [(t, b"".join(g[y * w + x0:y * w + x1] for y in range(y0, y1))) for t, g in frames]


def add_region_settle(h, switch, frames, window, leave, mark, end):
    """settled_ms over each region of `regions` as `<region>_settled_ms` (and its note), beside the window's own."""
    a = settle.AMBIENT_S
    pre_all = h.between(frames, min(leave, mark) - a - 0.05, end)
    for name, rect in regions(h).items():
        rw, rh = rect[2] - rect[0], rect[3] - rect[1]
        if rw <= 0 or rh <= 0:
            continue
        pre = crop_frames(pre_all, h.rec.w, rect)
        amb = settle.ambient(pre, rw, rh, [(leave - a, leave), (mark - a, mark)])
        st = settle.settle(crop_frames(window, h.rec.w, rect), mark, rw, rh, h.rec.frame_ms, end=end, ambient_tiles=amb)
        unchanged = st.get("first_change_ms") is None and not st.get("settled_ms") and "nothing" in (st.get("settle_note") or "")
        # A region the action never changed was settled at the trigger: 0, not never.
        switch[f"{name}_settled_ms"] = 0.0 if unchanged else st.get("settled_ms")
        switch[f"{name}_first_change_ms"] = st.get("first_change_ms")
        if st.get("settle_note") and not unchanged:
            switch[f"{name}_settle_note"] = st["settle_note"]


# ---------------------------------------------------------------------------------------------------------------
# Driving: each step flips `<label>:leave` and `:mark` just before its trigger and `:end` once it recorded.

def step(h, name, load, r, trigger, record=None, n=None):
    """One timed action: flips, `trigger()` (an action.run reply), the record time, the end flip. The item to judge."""
    label = f"{name}/{load} round {r}" + (f" {n}" if n else "")
    seconds = record if record is not None else h.args.record
    perf = chat_perf_start(h, seconds)
    h.flip3(label)
    reply = trigger() or {}
    time.sleep(seconds)  # sleep-ok: the recording window after the trigger (--record)
    h.rec.flip(f"{label}:end")
    error = reply.get("error") if isinstance(reply, dict) else None
    item = {"label": label, "kind": "settled", "strip": "sidebar", "error": f"{name}: {error}" if error else None}
    if perf is not None:
        perf[0].join(timeout=seconds + 20)
        item["chat_perf"] = chat_perf_summary(perf[1].get("result"))
    return name, item


def chat_perf_start(h, seconds):
    """With --chat-perf: the measured chat page's own capture (agent.chat.perf, read-only, every build) over the step,
    in a thread, so a miss says whether the page itself did work (long tasks, layout shift) or only the native side
    moved. None without the flag or a chat tab."""
    import threading
    tab = h.ids.get("chat")
    if not getattr(h.args, "chat_perf", False) or not tab:
        return None
    out = {}
    secs = max(1, min(60, int(seconds + 0.999)))
    thread = threading.Thread(target=lambda: out.update(result=h.c.call("agent.chat.perf", {"tab": tab, "seconds": secs},
                                                                       timeout=secs + 20)), daemon=True)
    thread.start()
    time.sleep(0.15)  # test script: the capture's observers start before the trigger
    return thread, out


def chat_perf_summary(report):
    """The parts of a chat page capture a diagnosis reads: frames, long tasks, layout shift, or why none."""
    if not isinstance(report, dict):
        return {"error": str(report)[:200]}
    if report.get("error"):
        return {"error": str(report["error"])[:200]}
    return {k: report.get(k) for k in ("measured", "unmeasured_reason", "frames", "long_tasks", "layout_shift")}


def wants(scenarios, *names):
    return any(n in scenarios for n in names)


def matrix_round(h, load, r, scenarios, agents):
    """One round of every matrix scenario but launch-restore (launch_block), in the measured workspace."""
    out = []
    pane0 = h.pane_id

    def section(names, run):
        """One group of steps; a fault in it (a refused action, a timeout) becomes an error row of its scenarios and
        the rest of the round still runs, in the measured workspace with its chat shown."""
        if not wants(scenarios, *names):
            return
        try:
            out.extend(run())
        except Exception as error:  # noqa: BLE001 - the row says why
            say_note = f"{type(error).__name__}: {error}"[:300]
            h.matrix_notes = getattr(h, "matrix_notes", {})
            for name in names:
                if name in scenarios:
                    h.matrix_notes.setdefault((name, load), say_note)
        try:
            h.c.action("goToWorkspace", workspace=h.workspace_id)
            h.wait_workspace(h.workspace_id, "the measured workspace shown after a section")
            if "chat" in h.ids:
                h.select("chat")
                h.wait_selected("chat")
        except Exception:  # noqa: BLE001 - the next section reports its own fault
            pass
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)

    section(("switch-workspace-cold", "switch-workspace-warm"), lambda: workspace_switches(h, load, r, scenarios))
    section(("new-chat",), lambda: new_chat(h, load, r, pane0))
    section(("split", "resize-split", "tab-move", "unsplit"), lambda: split_steps(h, load, r, scenarios, pane0))
    section(("window-resize",), lambda: window_resize(h, load, r))
    section(("pane-to-window",), lambda: pane_to_window(h, load, r, pane0))
    if agents is not None:
        section(("chat-10k-open", "chat-10k-return"), lambda: chat_10k(h, load, r, scenarios, agents, pane0))
    return out


def window_resize(h, load, r):
    """zoomWindow and back: the window grows to the screen and returns to its frame."""
    out = []
    for n in (1, 2):
        out.append(step(h, "window-resize", load, r, lambda: h.c.action("zoomWindow"), n=n))
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
    return out


def new_chat(h, load, r, pane0):
    before = {t.get("id") for t in h.pane_tabs()[0]}
    out = [step(h, "new-chat", load, r, lambda: h.c.action("new.agentChat.tab", target=f"pane:{pane0}"))]
    for tab in h.new_tabs(before, 1, limit=3.0):
        h.c.action("closeTab", focus=False, target=f"tab:{tab}")
    return out


def prepare_10k(h, agents, log):
    """The 10,000-row chat, made once before any recording (its rows take minutes on a loaded Mac): a short first
    turn, then the rows (chat_open_agent.py `rows:`) with the long send timeout."""
    if getattr(h, "chat_10k_session", None):
        return h.chat_10k_session
    started = time.monotonic()
    session = agents.new("tab-switch-turns", "turn: 0")
    sent = subprocess.run([agents.cli, "send", session, f"rows: {CHAT_10K_ROWS}"], capture_output=True, text=True,
                          timeout=1200, env=agents.env)
    if sent.returncode != 0:
        raise RuntimeError(f"send rows: {(sent.stdout + sent.stderr).strip()[-300:]}")
    log(f"10k-row chat {session} in {round(time.monotonic() - started, 1)} s")
    h.chat_10k_session = session
    return session


def workspace_switches(h, load, r, scenarios):
    out = []
    ws0 = h.workspace_id
    unseen = getattr(h, "scale_workspaces", None) or []
    cold = unseen.pop(0) if unseen else None
    if cold is None:
        h.cold_note = "no scale workspace left that this launch never showed (--scale none, or more rounds than workspaces)"
        return out
    item = step(h, "switch-workspace-cold", load, r, lambda: h.c.action("goToWorkspace", workspace=cold))
    if "switch-workspace-cold" in scenarios:
        out.append(item)
    h.wait_workspace(cold, "the cold workspace shown")
    for n, target in enumerate((ws0, cold, ws0), 1):
        item = step(h, "switch-workspace-warm", load, r, lambda t=target: h.c.action("goToWorkspace", workspace=t), n=n)
        if "switch-workspace-warm" in scenarios:
            out.append(item)
        h.wait_workspace(target, "the warm switch's workspace shown")
    return out


def split_steps(h, load, r, scenarios, pane0):
    out = []
    before = set(h.all_panes())
    item = step(h, "split", load, r, lambda: h.c.action("splitRight", target=f"pane:{pane0}"))
    if "split" in scenarios:
        out.append(item)
    right = wait_new_pane(h, before)
    if not right:
        return out
    time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
    if "resize-split" in scenarios:
        out.append(step(h, "resize-split", load, r, lambda: h.c.action("resizePaneRight", target=f"pane:{pane0}")))
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
    chat = h.ids.get("chat")
    if chat and "tab-move" in scenarios:
        out.append(step(h, "tab-move", load, r, lambda: h.c.action("moveSurfaceToPaneRight", target=f"tab:{chat}"), n=1))
        wait_until(lambda: not in_pane(h, chat), "the chat tab moved to the right pane", timeout=15, raise_on_timeout=False)
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
        out.append(step(h, "tab-move", load, r, lambda: h.c.action("moveSurfaceToPaneLeft", target=f"tab:{chat}"), n=2))
        wait_until(lambda: in_pane(h, chat), "the chat tab back in the measured pane", timeout=15, raise_on_timeout=False)
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
        if not in_pane(h, chat):
            # Not back in the measured pane: the next steps would close it with the right pane.
            h.c.action("moveSurfaceToPaneLeft", target=f"tab:{chat}")
            wait_until(lambda: in_pane(h, chat), "the chat tab moved back to the measured pane", timeout=15,
                       raise_on_timeout=False)
    item = step(h, "unsplit", load, r, lambda: h.c.action("closePane", target=f"pane:{right}"))
    if "unsplit" in scenarios:
        out.append(item)
    wait_until(lambda: right not in h.all_panes(), "the right pane closed", timeout=15, raise_on_timeout=False)
    return out


def in_pane(h, tab):
    """Whether `tab` is one of the measured pane's tabs."""
    return any(t.get("id") == tab for t in h.pane_tabs()[0])


def wait_new_pane(h, before, limit=10.0):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        made = [p for p in h.all_panes() if p not in before]
        if made:
            return made[0]
        time.sleep(0.2)  # test script: waiting for the pane
    return None


def pane_to_window(h, load, r, pane0):
    before = set(h.all_panes())
    h.c.action("splitRight", target=f"pane:{pane0}")
    scratch = wait_new_pane(h, before)
    if not scratch:
        return []
    time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
    workspaces = set(h.workspace_ids())
    out = [step(h, "pane-to-window", load, r, lambda: h.c.action("pane.moveToNewWindow", target=f"pane:{scratch}"))]
    # The moved pane is a new window's new workspace: that workspace goes (its window with it).
    moved = [w for w in h.workspace_ids() if w not in workspaces]
    for made in moved:
        h.c.action("closeWorkspace", confirm=True, target=f"workspace:{made}")
    if scratch in h.all_panes():
        h.c.action("closePane", target=f"pane:{scratch}")
    # The scratch window closed: its pane and workspace gone from the snapshot.
    wait_until(lambda: scratch not in h.all_panes() and not set(moved) & set(h.workspace_ids()),
               "the scratch window closed", timeout=15, raise_on_timeout=False)
    return out


def chat_10k(h, load, r, scenarios, agents, pane0):
    out = []
    session = getattr(h, "chat_10k_session", None)
    if session is None:
        raise RuntimeError(getattr(h, "chat_10k_note", None) or "no 10k-row chat (prepare_10k did not run)")
    before = {t.get("id") for t in h.pane_tabs()[0]}
    item = step(h, "chat-10k-open", load, r,
                lambda: h.c.action("agent.openSessionTab", session=session, target=f"pane:{pane0}"),
                record=max(h.args.record, 3.0))
    if "chat-10k-open" in scenarios:
        out.append(item)
    made = h.new_tabs(before, 1, limit=5.0)
    if made and "chat-10k-return" in scenarios:
        h.select("terminal")
        h.wait_selected("terminal")
        time.sleep(h.args.settle)  # sleep-ok: --settle, the recorded span before the next step's leave flip (its last AMBIENT_S are the ambient baseline)
        out.append(step(h, "chat-10k-return", load, r, lambda: h.c.action("tab.focus", target=f"tab:{made[0]}")))
    for tab in made:
        h.c.action("closeTab", focus=False, target=f"tab:{tab}")
    h.wait_tabs_gone(made, "the 10k-row chat's tab closed")
    return out


def launch_block(h, rounds, record, log):
    """launch-restore `rounds` times, in one recording block: Quit and Keep Sessions, the app's processes gone, then
    the marker flips and the app is exec'd again in the same home. Returns [(name, item)] and the block."""
    pending = []
    h.rec.begin()
    for r in range(1, rounds + 1):
        label = f"launch-restore/scale round {r}"
        old = h.app.process
        h.c.action("quitKeepSessions", focus=False)
        try:
            old.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pending.append(("launch-restore", {"label": label, "kind": "settled", "error": "the app did not quit in 30 s"}))
            break
        quiesce(h.app.bundle)
        h.app.spawn(before=lambda lb=label: h.flip3(lb))
        if getattr(h, "watch", None) is not None:
            h.watch.log.own_pids.add(h.app.process.pid)  # the new process is the app, not a foreign window
        time.sleep(record)
        h.rec.flip(f"{label}:end")
        pending.append(("launch-restore", {"label": label, "kind": "settled", "strip": "sidebar", "error": None, "foreign_ok": True}))
        log(f"  launch-restore round {r} driven (pid {h.app.process.pid})")
    frames, flips = h.rec.end()
    return pending, frames, flips


def quiesce(bundle, limit=60.0):
    """Until no process runs from the bundle's Contents/MacOS or Contents/Frameworks (the app and its Chromium
    helpers), at most `limit` seconds, then 1 s more; the daemons in Contents/Resources stay, as a quit keeps them."""
    prefixes = (os.path.join(bundle, "Contents/MacOS/"), os.path.join(bundle, "Contents/Frameworks/"))
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        listed = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if not any(line.startswith(prefixes) or any(p in line for p in prefixes) for line in listed.splitlines()):
            break
        time.sleep(0.2)  # test script: the last launch's helpers end
    time.sleep(1)


# ---------------------------------------------------------------------------------------------------------------
# The table.

def table(rows):
    """Per scenario x load: n, settled p50/p95 (window, page, sidebar), never settled, and whether p95 is under
    BUDGET_MS on each."""
    out = []
    for row in rows:
        s = row["switches"]
        line = {"scenario": row["name"], "load": row["load"], "n": len(s)}
        for key in ("settled_ms", "page_settled_ms", "sidebar_settled_ms"):
            vals = [x.get(key) for x in s]
            line[key.replace("_ms", "_p50")] = settle.percentile(vals, 50)
            line[key.replace("_ms", "_p95")] = settle.percentile(vals, 95)
            line[key.replace("_ms", "_never")] = sum(1 for x in s if x.get(key) is None and not x.get("error"))
        line["errors"] = sum(1 for x in s if x.get("error"))
        p95 = line["settled_p95"]
        line["over_budget"] = p95 is None or p95 > BUDGET_MS
        if row.get("notes"):
            line["notes"] = row["notes"][:200]
        out.append(line)
    return out


def table_markdown(lines):
    def ms(v):
        return "-" if v is None else f"{v:.0f}"
    head = ("| scenario | load | n | window settled p50 / p95 ms | page settled p50 / p95 ms | "
            f"sidebar settled p50 / p95 ms | never settled | under {BUDGET_MS:.0f} ms p95 |\n"
            "|---|---|---|---|---|---|---|---|\n")
    body = []
    for x in lines:
        never = x["settled_never"] + x["errors"]
        note = f" ({x['notes'][:60]})" if x.get("notes") and not x["n"] else ""
        body.append(f"| {x['scenario']} | {x['load']} | {x['n']}{note} | {ms(x['settled_p50'])} / {ms(x['settled_p95'])} | "
                    f"{ms(x['page_settled_p50'])} / {ms(x['page_settled_p95'])} | "
                    f"{ms(x['sidebar_settled_p50'])} / {ms(x['sidebar_settled_p95'])} | {never} | "
                    f"{'no' if x['over_budget'] else 'yes'} |")
    return head + "\n".join(body) + "\n"
