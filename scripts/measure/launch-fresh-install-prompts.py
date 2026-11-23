#!/usr/bin/env python3
"""The "downloaded from the Internet" prompts launch-fresh-install.sh raises, answered by the job itself.

usage: launch-fresh-install-prompts.py CUA ids
       launch-fresh-install-prompts.py CUA press Open|Cancel BASELINE_IDS WHEN

Runs in the console session (the script's `console`), with CUA the console's CuaDriver, which holds the
Accessibility grant. `ids` prints the window ids of the prompt owners' windows on screen now, the baseline: a
prompt that was there before the job is not the job's, and is never pressed. `press` presses BUTTON on each
prompt owner's window on screen that is not in the baseline and whose text says "downloaded from the Internet":
Open for a prompt the job needs (the quarantined DMG's own check while it mounts), Cancel for one it does not (a
prompt left after the measured open). One LF-PROMPT line per window, with WHEN (the row and the step).

A SecurityAgent or coreautha window (a keychain or password panel) is only named in an LF-PROMPT line with
action "left": nothing in it is pressed and nothing is typed, ever. The fleet's dialog alarm pages for those
whatever any job declares.
"""
import json
import subprocess
import sys

PROMPT_OWNERS = ("CoreServicesUIAgent", "DiskImageMounter")
NEVER_TOUCH = ("SecurityAgent", "coreautha")
PROMPT_TEXT = "downloaded from the internet"


def run(argv, timeout=30):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, str(error)


def cua(binary, tool, args):
    code, out = run([binary, "call", tool, json.dumps(args)], timeout=60)
    try:
        answer = json.loads(out) if code == 0 else {"error": out[-300:]}
    except ValueError:
        return {"error": out[-300:]}
    content = answer.get("structuredContent") if isinstance(answer, dict) else None
    return content if isinstance(content, dict) else answer


def pids(name):
    code, out = run(["pgrep", "-x", name], timeout=10)
    return [int(p) for p in out.split() if p.isdigit()] if code == 0 else []


def windows(binary, names):
    """(owner, pid, window) for every on-screen window of the processes named NAMES."""
    found = []
    for name in names:
        for pid in pids(name):
            listed = cua(binary, "list_windows", {"pid": pid})
            for window in listed.get("windows") or []:
                if isinstance(window, dict) and "window_id" in window and window.get("is_on_screen", True):
                    found.append((name, pid, window))
    return found


def texts(state):
    """Every title, label, value and description in a get_window_state answer."""
    out = []
    for element in state.get("elements") or []:
        for key in ("title", "label", "value", "description"):
            value = element.get(key)
            if isinstance(value, str) and value.strip():
                out.append(value.strip())
    return out


def button(state, title):
    for element in state.get("elements") or []:
        if element.get("role") == "AXButton" and title in (str(element.get("title")), str(element.get("label"))) \
                and element.get("element_token"):
            return element["element_token"]
    return None


def press(binary, title, baseline, when):
    rows = []
    for owner, pid, window in windows(binary, PROMPT_OWNERS):
        wid = window["window_id"]
        if wid in baseline:
            continue
        state = cua(binary, "get_window_state", {"pid": pid, "window_id": wid, "include_accessibility_tree": True})
        words = texts(state) + [str(window.get("title") or "")]
        text = " | ".join(w for w in words if w)[:240]
        row = {"when": when, "owner": owner, "pid": pid, "window_id": wid, "text": text}
        if PROMPT_TEXT not in text.lower():
            row["action"] = "not a download prompt: left"
        elif not (token := button(state, title)):
            row["action"] = f"no {title} button: left"
        else:
            click = cua(binary, "click", {"pid": pid, "window_id": wid, "element_token": token, "action": "press"})
            row["action"] = f"pressed {title}" if "error" not in click else f"press {title} failed: {click['error'][:120]}"
        rows.append(row)
    for owner, pid, window in windows(binary, NEVER_TOUCH):
        rows.append({"when": when, "owner": owner, "pid": pid, "window_id": window["window_id"],
                     "text": str(window.get("title") or "")[:240],
                     "action": "left: a keychain or password panel is never pressed or typed into"})
    for row in rows:
        print("LF-PROMPT", json.dumps(row, sort_keys=True), flush=True)
    return rows


def main(argv):
    if len(argv) == 3 and argv[2] == "ids":
        print(" ".join(str(w["window_id"]) for _, _, w in windows(argv[1], PROMPT_OWNERS)))
        return 0
    if len(argv) == 6 and argv[2] == "press" and argv[3] in ("Open", "Cancel"):
        baseline = {int(i) for i in argv[4].split() if i.isdigit()}
        press(argv[1], argv[3], baseline, argv[5])
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
