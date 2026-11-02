#!/usr/bin/env python3
"""Writes the BROWSER VIDEO journeys (bv-*.json) beside this file. Run it after an edit; the JSON is what run.py plays."""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DOCK_ACTION = {"right": "devtools.openDockedRight", "bottom": "devtools.openDocked", "window": "devtools.openInWindow"}
OPEN_KEY = {"do": "hid_key", "key": "i", "modifiers": ["cmd", "option"]}
SOURCE = "handoff/resize-videos (BROWSER VIDEO suite, lead STATUS 4282; Lawrence's DevTools case)"


def setup(theme, page=None):
    steps = [{"do": "smoke_ready", "timeout": 60}, {"do": "smoke_make_key"},
             {"do": "rpc", "title": f"set-up: the app in {theme} (debug.appearance; Chromium and pages follow NSApp)",
              "method": "debug.appearance", "params": {"mode": theme}},
             {"do": "wait", "seconds": 0.8}, {"do": "bv_serve"}]
    if page:
        steps += [{"do": "bv_open", "page": page}, {"do": "wait", "seconds": 1.5}]
    return steps


def devtools(dock, page, theme, rounds=5, mbps=80):
    jid = f"bv-dt-{dock}-{page}-{theme}"
    steps = setup(theme, page)
    # Round 0: the first open of DevTools in this app, by the dock's own action (it sets the dock and remembers it),
    # closed by the real key. Later rounds open and close by the real Cmd-Opt-I (warm).
    for r in range(rounds + 1):
        name = f"{jid}-r{r}"
        steps += [{"do": "bv_scroll", "page": page}, {"do": "wait", "seconds": 0.3},
                  {"do": "video_start", "name": name, "mbps": mbps, "seconds": 20},
                  {"do": "bv_state", "page": page, "as": "before"}, {"do": "wait", "seconds": 0.3}]
        if r == 0:
            steps.append({"do": "bv_action", "action": DOCK_ACTION[dock], "as": "open"})
        else:
            steps.append(dict(OPEN_KEY, mark=f"open-r{r}", title="open DevTools: real Cmd-Opt-I"))
        steps += [{"do": "bv_devtools", "page": page, "open": True, "timeout": 5},
                  {"do": "wait", "seconds": 1.2 if r == 0 else 0.6}, {"do": "bv_state", "page": page, "as": "open"},
                  {"do": "wait", "seconds": 0.3},
                  dict(OPEN_KEY, mark=f"close-r{r}", title="close DevTools: real Cmd-Opt-I"),
                  {"do": "bv_devtools", "page": page, "open": False, "timeout": 5},
                  {"do": "wait", "seconds": 0.4}, {"do": "bv_state", "page": page, "as": "after"},
                  {"do": "video_stop", "name": name, "tail": 0.2}, {"do": "wait", "seconds": 0.5}]
    return {"id": jid, "priority": "P1",
            "title": f"Video: DevTools docked {dock} open and close (real Cmd-Opt-I), {page} page, {theme}, recorded every frame",
            "why": "Lawrence's case: the first DevTools frame in the next refresh after the key, no white flash, the page "
                   "does not jump or stretch while DevTools opens or closes, and close restores the exact layout. Round 0 is "
                   "the first open in the app (by the dock action), rounds 1-5 the real key.",
            "source": SOURCE, "budget_seconds": 60 + 14 * (rounds + 1), "options": {"key_path": "real"}, "steps": steps}


def pane(page, theme, rounds=3, mbps=60):
    jid = f"bv-pane-{page}-{theme}"
    steps = setup(theme) + [
        {"do": "rpc", "title": "set-up: a second workspace to switch to", "method": "action.run",
         "params": {"action": "newTab", "args": {"name": "bv-away", "focus": False}}},
        {"do": "wait", "seconds": 1.0}]
    for r in range(1, rounds + 1):
        name = f"{jid}-r{r}"
        steps += [{"do": "hid_key", "key": "1", "modifiers": ["cmd"], "title": "set-up: the first workspace"},
                  {"do": "wait", "seconds": 0.8},
                  {"do": "video_start", "name": name, "mbps": mbps, "seconds": 30},
                  {"do": "hid_key", "key": "d", "modifiers": ["cmd", "option"], "mark": f"open-{r}", "title": "open a browser pane (Opt-Cmd-D)"},
                  {"do": "wait", "seconds": 1.6},
                  {"do": "bv_open", "page": page, "title": "navigate the new pane's tab (a focused Chromium tab on the page)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "bv_state", "page": page, "as": f"open-{r}"},
                  {"do": "hid_key", "key": "2", "modifiers": ["cmd"], "mark": f"away-{r}", "title": "switch away (Cmd-2)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "hid_key", "key": "1", "modifiers": ["cmd"], "mark": f"back-{r}", "title": "switch back (Cmd-1)"},
                  {"do": "wait", "seconds": 1.2},
                  {"do": "hid_key", "key": "left", "modifiers": ["control", "cmd"], "mark": f"resize-a-{r}", "title": "resize the pane (Ctrl-Cmd-Left)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "hid_key", "key": "right", "modifiers": ["control", "cmd"], "mark": f"resize-b-{r}", "title": "resize the pane (Ctrl-Cmd-Right)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "bv_state", "page": page, "as": f"resized-{r}"},
                  {"do": "hid_key", "key": "w", "modifiers": ["cmd"], "mark": f"close-tab-{r}", "title": "close the page tab (Cmd-W)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "hid_key", "key": "w", "modifiers": ["cmd"], "mark": f"close-{r}", "title": "close the browser pane (Cmd-W)"},
                  {"do": "wait", "seconds": 1.2},
                  {"do": "video_stop", "name": name, "tail": 0.2}]
    return {"id": jid, "priority": "P1",
            "title": f"Video: browser pane open, navigate, switch away and back, resize, close ({page} page, {theme})",
            "why": "VIDEO EXTRA item 3: no blank or white frame on re-show, no stretched frame while the pane resizes with "
                   "a heavy page, no flash on open or close.",
            "source": SOURCE, "budget_seconds": 60 + 25 * rounds, "options": {"key_path": "real"}, "steps": steps}


def agent(load, theme, rounds=3, mbps=60):
    jid = f"bv-agent-{load}-{theme}"
    steps = setup(theme, "heavy" if load == "heavy" else None) + [
        {"do": "rpc", "title": "set-up: a second workspace to switch to", "method": "action.run",
         "params": {"action": "newTab", "args": {"name": "bv-away", "focus": False}}},
        {"do": "wait", "seconds": 1.0}]
    for r in range(1, rounds + 1):
        name = f"{jid}-r{r}"
        steps += [{"do": "hid_key", "key": "1", "modifiers": ["cmd"], "title": "set-up: the first workspace"},
                  {"do": "wait", "seconds": 0.8},
                  {"do": "video_start", "name": name, "mbps": mbps, "seconds": 30},
                  {"do": "bv_action", "action": "palette.newAgentChat", "as": f"open-{r}"},
                  {"do": "wait", "seconds": 2.0},
                  {"do": "bv_agent", "action": "focus_composer"},
                  {"do": "hid_key", "key": "h", "mark": f"type-{r}"}, {"do": "hid_key", "key": "i"},
                  {"do": "hid_key", "key": "return", "mark": f"send-{r}", "title": "send (Return)"},
                  {"do": "wait", "seconds": 0.8},
                  {"do": "bv_agent", "action": "stream", "rows": 400, "seconds": 6, "chunk_chars": 24, "chunk_ms": 16, "as": f"stream-{r}"},
                  {"do": "wait", "seconds": 1.5},
                  {"do": "bv_agent", "action": "readiness", "as": f"streaming-{r}"},
                  {"do": "hid_key", "key": "2", "modifiers": ["cmd"], "mark": f"away-{r}", "title": "switch away (Cmd-2)"},
                  {"do": "wait", "seconds": 0.8},
                  {"do": "hid_key", "key": "1", "modifiers": ["cmd"], "mark": f"back-{r}", "title": "switch back (Cmd-1)"},
                  {"do": "wait", "seconds": 2.5},
                  {"do": "bv_agent", "action": "readiness", "as": f"after-{r}"},
                  {"do": "hid_key", "key": "w", "modifiers": ["cmd"], "mark": f"close-{r}", "title": "close the chat (Cmd-W)"},
                  {"do": "wait", "seconds": 1.0},
                  {"do": "video_stop", "name": name, "tail": 0.2}]
    return {"id": jid, "priority": "P1",
            "title": f"Video: agent chat open, type and send, streamed reply, switch away and back ({load} load, {theme})",
            "why": "VIDEO EXTRA item 2: first content frame after the open, no flash on switch away and back, the transcript "
                   "stays pinned to the bottom while it streams.",
            "source": SOURCE, "budget_seconds": 60 + 25 * rounds, "options": {"key_path": "real"}, "steps": steps}


END = [{"do": "new_terminal", "via": "key", "name": "bvend"}, {"do": "neutral_prompt"},
       {"do": "type", "text": "echo bv-done-${nonce}", "enter": True, "mark": "done"},
       {"do": "expect", "title": "after the recordings the app still answers: the line shows in the app, the daemon and the frame",
        "since": "done", "timeout": 15,
        "all": [{"app_text_contains": "bv-done-${nonce}"}, {"daemon_prompt": True}, {"pane_frame_text": "bv-done-${nonce}"}]}]


def main():
    out = []
    for theme in ("dark", "light"):
        for dock in ("right", "bottom", "window"):
            for page in ("light", "heavy"):
                out.append(devtools(dock, page, theme))
        for page in ("light", "heavy"):
            out.append(pane(page, theme))
        for load in ("light", "heavy"):
            out.append(agent(load, theme))
    for j in out:
        j["steps"] += END
        with open(os.path.join(HERE, j["id"] + ".json"), "w") as f:
            json.dump(j, f, indent=1)
            f.write("\n")
    print("\n".join(j["id"] for j in out))


if __name__ == "__main__":
    main()
