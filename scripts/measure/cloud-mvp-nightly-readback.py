#!/usr/bin/env python3
"""The app half of scripts/measure/cloud-mvp-nightly-readback.sh: the Auto/Cloud MVP driven in a NIGHTLY side instance.

  cloud-mvp-nightly-readback.py prepare --app APP --config DIR --out DIR
  cloud-mvp-nightly-readback.py run --app APP --pid-file F --config DIR --folder DIR --out DIR [--control-socket S]

prepare, before the copy's first launch: experiments.cloudToggle and cloud.autoCloud on in the copy's own
cmux-next.json, and the step's agent session (CMUX_CI_SIGNIN_FILE) in the copy's own token store file
(stage-signin.py's way); the token is in no argv, environment, stdout or artifact.
run, once the copy is up: every step read through the accessibility tree CuaDriver reports (a NIGHTLY has no debug.*
methods), as a person sees it:
  1 sign-in   the copy traded the step's refresh token for an access token (its token store file)
  2 settings  both keys read back on in the copy (settings.get)
  3 auto      a terminal on the demo folder (action.run newTab cwd), Cmd-N there (the New Tab page inherits the
              folder), the page's Runs On control set to Hybrid, a prompt typed and sent: seconds to the first reply
  4 move      that chat moved with Only in Cloud: the Moved to Cloud line and its Undo, as they appear
  5 cloud     a second New Tab page set to Only in Cloud: seconds to the first reply, and the control's start states
              (Starting Here, Cloud Ready, Moving to Cloud, In Cloud) with the second each first showed
A blocked label (Start Free Trial, Sign In to Use Cloud, ...) or a missing control is a product failure: the step
says what was on screen (outline.txt, shots) and the run stops there.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import plistlib
import pwd
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
spec = importlib.util.spec_from_file_location("lkr", HERE / "look-keys-readback.py")
lkr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lkr)

SETTINGS = {"experiments.cloudToggle": True, "cloud.autoCloud": True}


def set_dotted(root: dict, key: str, value) -> None:
    *parents, leaf = key.split(".")
    node = root
    for part in parents:
        node = node.setdefault(part, {})
    node[leaf] = value


def prepare(app: Path, config: Path, out: Path) -> int:
    config.mkdir(parents=True, exist_ok=True)
    settings = config / "cmux-next.json"
    root = json.loads(settings.read_text()) if settings.is_file() and settings.read_text().strip() else {}
    for key, value in SETTINGS.items():
        set_dotted(root, key, value)
    settings.write_text(json.dumps(root, indent=2) + "\n")
    print(f"CMR settings {' '.join(f'{k}={json.dumps(v)}' for k, v in SETTINGS.items())} in the copy's own cmux-next.json")
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import cmux_next_pair_e2e as e2e  # noqa: E402  (the Mac token store's path and format)
    try:
        session = e2e.signin_session()
        if session is None:
            print("CMR FAIL rig: no CMUX_CI_SIGNIN_FILE (cmux-ci run --sign-in agent)")
            return 3
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        bundle, exe = info["CFBundleIdentifier"], info["CFBundleExecutable"]
        env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_SIGNIN_FILE"}
        env.update({k: str(v) for k, v in (info.get("LSEnvironment") or {}).items()})
        store = e2e.mac_token_store(str(app), bundle, str(app / "Contents" / "MacOS" / exe), env, session["project"],
                                    pwd.getpwuid(os.getuid()).pw_dir)
        e2e.write_mac_session(store, session["refresh_token"])
    except SystemExit as stop:
        print(f"CMR FAIL rig: sign-in: {stop.code}")
        return 3
    (out / "token-store-path").write_text(store + "\n")
    print(f"CMR sign-in: the step's agent session in the copy's own token store ({session['email'].split('@')[-1]} account)")
    return 0


BLOCKED = ["Sign In to Use Cloud", "Start Free Trial", "Set Up Cloud", "Cloud Hours Used Up", "Trial Ended",
           "Trials Full Today", "Could Not Move", "Paused While This Mac Slept"]
STARTS = ["Starting Here", "Cloud Ready", "Moving to Cloud", "In Cloud"]
PROMPTS = {"auto": ("Spell the word ocean backwards in capital letters. Reply with only that word.", "NAECO"),
           "cloud": ("Spell the word forest backwards in capital letters. Reply with only that word.", "TSEROF")}


class ProductFailure(Exception):
    pass


def nodes(pid: int) -> list:
    """Every AX node of the copy's windows that names something (role plus any text), clickable or not, in tree order."""
    found: list = []

    def visit(node, window_id):
        if isinstance(node, dict):
            if "role" in node:
                found.append(dict(node, _window=window_id))
            for key, value in node.items():
                if isinstance(value, (dict, list)):
                    visit(value, window_id)
        elif isinstance(node, list):
            for value in node:
                visit(value, window_id)

    for window in lkr.cua("list_windows", {"pid": pid}).get("windows") or []:
        if isinstance(window, dict) and window.get("window_id") is not None:
            state = lkr.cua("get_window_state", {"pid": pid, "window_id": window["window_id"],
                                                 "include_screenshot": False, "max_depth": 120, "max_elements": 12000})
            visit(state, window["window_id"])
    return found


def texts(element: dict) -> list:
    return [str(element[k]).strip() for k in ("label", "title", "value", "description", "name", "help", "placeholder")
            if isinstance(element.get(k), (str, int, float)) and str(element[k]).strip()]


def text_of(element: dict) -> str:
    return " | ".join(dict.fromkeys(texts(element)))


def clickable(element: dict) -> bool:
    return "element_token" in element or "element_index" in element


def find(seen: list, match, role_has: str = "") -> dict | None:
    for element in seen:
        if clickable(element) and role_has.lower() in str(element.get("role", "")).lower() \
                and any(match(t) for t in texts(element)):
            return element
    return None


def press(pid: int, element: dict) -> dict:
    token = {"element_token": element["element_token"]} if "element_token" in element else {"element_index": element["element_index"]}
    return lkr.cua("click", {"pid": pid, "window_id": element["_window"], **token})


def window_id(pid: int):
    return lkr.window_of(pid)


def dump(pid: int, folder: Path, name: str, seen: list | None = None) -> dict:
    """The step's shot and the AX outline it saw (outline-NAME.txt), so a miss shows what was on screen."""
    folder.mkdir(parents=True, exist_ok=True)
    seen = nodes(pid) if seen is None else seen
    rows = [f"{e.get('role')} | {text_of(e)}"[:160] for e in seen
            if text_of(e) and not str(e.get("role", "")).startswith("AXMenuBar")]
    (folder / f"outline-{name}.txt").write_text("\n".join(rows) + "\n")
    return {"shots": lkr.shoot(pid, folder, name), "outline": f"outline-{name}.txt", "rows": len(rows)}


def blocked_label(seen: list) -> str | None:
    for element in seen:
        for t in texts(element):
            for label in BLOCKED:
                if t == label or t.startswith(label) or t.endswith(": " + label):
                    return f"{element.get('role')} '{t}'"
    return None


def has_text(seen: list, needle: str, exact: bool = False) -> str | None:
    for element in seen:
        for t in texts(element):
            if (t == needle) if exact else (needle in t):
                return t
    return None


def composer(seen: list) -> dict | None:
    fields = [e for e in seen if clickable(e) and any(r in str(e.get("role", "")) for r in ("AXTextArea", "AXTextField"))]
    for e in fields:
        if any("Type a question" in t or "Type / for commands" in t for t in texts(e)):
            return e
    return fields[-1] if fields else None


def new_tab_page(sock: str, pid: int, folder: str) -> dict:
    """A terminal on FOLDER, then the person's Cmd-N there: the New Tab page, which inherits the terminal's folder."""
    made = lkr.rpc(sock, "action.run", {"action": "newTab", "cwd": folder, "focus": True}, timeout=30)
    time.sleep(3)
    wid = window_id(pid)
    key = lkr.cua("hotkey", {"pid": pid, "window_id": wid, "keys": ["cmd", "n"]})
    page = lkr.wait_for(lambda: (lambda seen: seen if composer(seen) and has_text(seen, "Runs On") else None)(nodes(pid)), 40, step=1)
    if not page:
        page = lkr.wait_for(lambda: (lambda seen: seen if composer(seen) else None)(nodes(pid)), 10, step=1)
    return {"terminal": made, "cmd_n": key, "seen": page or nodes(pid)}


def send_prompt(pid: int, seen: list, text: str) -> dict:
    field = composer(seen)
    if not field:
        raise ProductFailure("no composer field on the New Tab page")
    clicked = press(pid, field)
    time.sleep(0.5)
    typed = lkr.cua("type_text", {"text": text, "scope": "desktop"})
    time.sleep(0.3)
    sent_at = time.monotonic()
    key = lkr.cua("press_key", {"pid": pid, "key": "return"})
    return {"field": text_of(field)[:80], "click": clicked, "type": typed, "return": key, "sent_at": sent_at}


def first_reply(pid: int, answer: str, sent_at: float, seconds: float, starts: dict | None = None) -> dict:
    """Polls the tree until ANSWER shows (the prompt never contains it); records start states seen meanwhile."""
    last: list = []
    while time.monotonic() - sent_at < seconds:
        last = nodes(pid)
        if starts is not None:
            note_starts(last, starts, sent_at)
        if has_text(last, answer):
            return {"reply_s": round(time.monotonic() - sent_at, 1), "seen": last}
        blocked = blocked_label(last)
        if blocked:
            return {"reply_s": None, "blocked": blocked, "seen": last}
        time.sleep(0.5)
    return {"reply_s": None, "seen": last}


def note_starts(seen: list, starts: dict, t0: float) -> None:
    for label in STARTS:
        if label not in starts and (has_text(seen, label, exact=True) or has_text(seen, "Runs On: " + label, exact=True)):
            starts[label] = round(time.monotonic() - t0, 1)
    face = has_text(seen, "Runs On: ") or ""
    if face:
        starts.setdefault("_faces", [])
        if not starts["_faces"] or starts["_faces"][-1] != face:
            starts["_faces"].append(face)


def pick_runs_on(pid: int, seen: list, label: str) -> dict:
    radio = find(seen, lambda t: t == label, "radio") or find(seen, lambda t: t == label)
    if not radio:
        raise ProductFailure(f"no '{label}' choice in the Runs On control")
    reply = press(pid, radio)
    time.sleep(1)
    return {"picked": label, "role": radio.get("role"), "reply": reply}


def step_chat(sock: str, pid: int, folder: str, out: Path, name: str, runs_on: str, starts: dict | None) -> dict:
    page = new_tab_page(sock, pid, folder)
    seen = page.pop("seen")
    step: dict = {"step": name, "runs_on": runs_on, **{k: v for k, v in page.items()}, **dump(pid, out / name, "01-new-tab", seen)}
    step["folder_shown"] = has_text(seen, Path(folder).name)
    step["agent_shown"] = has_text(seen, "Claude")
    blocked = blocked_label(seen)
    if blocked:
        raise ProductFailure(f"{name}: the New Tab page shows {blocked}")
    if not has_text(seen, "Runs On"):
        raise ProductFailure(f"{name}: no Runs On control on the New Tab page (cloudToggle and autoCloud on; "
                             "the control shows only with an active Cloud plan)")
    step["pick"] = pick_runs_on(pid, seen, runs_on)
    seen = nodes(pid)
    step.update(dump(pid, out / name, "02-picked", seen))
    blocked = blocked_label(seen)
    if blocked:
        raise ProductFailure(f"{name}: after {runs_on} the page shows {blocked}")
    prompt, answer = PROMPTS[name]
    sent = send_prompt(pid, seen, prompt)
    t0 = sent.pop("sent_at")
    step["send"] = sent
    step["_t0"] = t0
    reply = first_reply(pid, answer, t0, 300, starts)
    seen = reply.pop("seen")
    step.update(reply)
    step["after_reply"] = dump(pid, out / name, "03-reply", seen)
    step["face_after_reply"] = has_text(seen, "Runs On: ") or has_text(seen, "Auto · ") or has_text(seen, "Where this chat runs")
    if reply.get("blocked"):
        raise ProductFailure(f"{name}: the chat shows {reply['blocked']}")
    return step


def step_move(pid: int, out: Path) -> dict:
    seen = nodes(pid)
    step: dict = {"step": "move", **dump(pid, out / "move", "01-before", seen)}
    step["face_before"] = has_text(seen, "Runs On: ") or has_text(seen, "Auto · ")
    step["pick"] = pick_runs_on(pid, seen, "Only in Cloud")
    t0 = time.monotonic()
    seen_moving: dict = {}
    moved = None
    while time.monotonic() - t0 < 600:
        seen = nodes(pid)
        note_starts(seen, seen_moving, t0)
        moved = has_text(seen, "Moved to Cloud")
        if moved and ("In Cloud" in seen_moving or has_text(seen, "Auto · Cloud") or has_text(seen, "Runs On: In Cloud")):
            break
        blocked = blocked_label(seen)
        if blocked:
            step.update(dump(pid, out / "move", "02-blocked", seen))
            raise ProductFailure(f"move: the chat shows {blocked}")
        time.sleep(1)
    step["moved_line"] = moved
    step["moved_s"] = round(time.monotonic() - t0, 1) if moved else None
    step["states"] = seen_moving
    step["after"] = dump(pid, out / "move", "02-moved", seen)
    undo = find(seen, lambda t: t == "Undo" or t.startswith("Undo"))
    step["undo_shown"] = text_of(undo) if undo else None
    if undo:
        step["undo_click"] = press(pid, undo)
        back = lkr.wait_for(lambda: (lambda s: s if (has_text(s, "Moved to This Mac") or has_text(s, "Moved to this Mac")
                                                     or has_text(s, "Moved to Local")) else None)(nodes(pid)), 300, step=1)
        step["undo_result"] = (has_text(back, "Moved to This Mac") or has_text(back, "Moved to this Mac")
                               or has_text(back, "Moved to Local")) if back else None
        step["after_undo"] = dump(pid, out / "move", "03-undo", back or None)
    return step


def verdict(name: str, ok: bool, detail: str) -> None:
    print(f"CMR {'PASS' if ok else 'FAIL'} {name}: {detail}", flush=True)


def run(args) -> int:
    app, out = Path(args.app), Path(args.out)
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    pid = int(lkr.wait_for(lambda: Path(args.pid_file).is_file() and Path(args.pid_file).read_text().strip(), 60) or 0)
    receipt: dict = {"dmg": args.dmg, "app_version": info.get("CFBundleVersion"),
                     "app_short_version": info.get("CFBundleShortVersionString"), "app_commit": info.get("CMUXCommit"),
                     "steps": []}
    status = 0
    try:
        sock = lkr.wait_for(lambda: lkr.control_socket(pid, args.control_socket), 120, step=0.5) if pid else None
        if not sock:
            print("CMR FAIL rig: the copy's control socket never answered")
            receipt["error"] = "no control socket"
            return 3
        time.sleep(4)  # the first window settles
        receipt["steps"].append({"step": "launch", **dump(pid, out / "launch", "00-start")})

        store = Path((out / "token-store-path").read_text().strip())
        refreshed = lkr.wait_for(lambda: store.is_file() and "accessToken" in json.loads(store.read_text() or "{}"), 60, step=1)
        receipt["steps"].append({"step": "sign-in", "ok": bool(refreshed)})
        verdict("sign-in", bool(refreshed), "the copy holds an access token for the step's agent session"
                if refreshed else "no access token in the copy's token store after 60 s")
        if not refreshed:
            raise ProductFailure("sign-in: the copy did not trade the refresh token")

        read = {key: lkr.read_key(sock, key) for key in SETTINGS}
        ok = all(lkr.same(read[k], v) for k, v in SETTINGS.items())
        receipt["steps"].append({"step": "settings", "ok": ok, "read": read})
        verdict("settings", ok, " ".join(f"{k}={json.dumps(v)}" for k, v in read.items()))
        if not ok:
            raise ProductFailure("settings: the keys did not read back on")

        auto = step_chat(sock, pid, args.folder, out, "auto", "Hybrid", None)
        auto.pop("_t0", None)
        receipt["steps"].append(auto)
        ok = auto.get("reply_s") is not None
        verdict("auto chat", ok, f"submit-to-first-reply {auto.get('reply_s')} s; control after reply: {auto.get('face_after_reply')}"
                f"; folder shown: {bool(auto.get('folder_shown'))}; agent: {auto.get('agent_shown')}")
        if not ok:
            raise ProductFailure("auto chat: no reply in 300 s")

        move = step_move(pid, out)
        receipt["steps"].append(move)
        ok = bool(move.get("moved_line"))
        verdict("move Only in Cloud", ok, f"'{move.get('moved_line')}' after {move.get('moved_s')} s; states {move.get('states')}")
        verdict("undo", bool(move.get("undo_shown")) and bool(move.get("undo_result")),
                f"shown: {move.get('undo_shown')}; result: {move.get('undo_result')}")
        if not ok:
            raise ProductFailure("move: no Moved to Cloud line in 600 s")

        starts: dict = {}
        cloud = step_chat(sock, pid, args.folder, out, "cloud", "Only in Cloud", starts)
        t0 = cloud.pop("_t0")
        while "In Cloud" not in starts and time.monotonic() - t0 < 900:  # the move may land after the reply
            seen = nodes(pid)
            note_starts(seen, starts, t0)
            if blocked_label(seen):
                break
            time.sleep(1)
        cloud["states"] = starts
        cloud["after_states"] = dump(pid, out / "cloud", "04-states")
        receipt["steps"].append(cloud)
        verdict("cloud chat", cloud.get("reply_s") is not None, f"submit-to-first-reply {cloud.get('reply_s')} s")
        order = [s for s in STARTS if s in starts]
        verdict("cloud states", order == STARTS, (" -> ".join(f"{s} @{starts[s]} s" for s in order) or "none seen")
                + f"; faces {starts.get('_faces')}")
        if cloud.get("reply_s") is None or "In Cloud" not in starts:
            status = 1
        if not (move.get("undo_shown") and move.get("undo_result")):
            status = 1
    except ProductFailure as failure:
        print(f"CMR FAIL product: {failure}", flush=True)
        receipt["product_failure"] = str(failure)
        try:
            receipt["steps"].append({"step": "failure", **dump(pid, out / "failure", "00-failure")})
        except Exception as error:  # the failure stands; the shot is a bonus
            receipt["failure_dump_error"] = str(error)
        status = 1
    except Exception as error:
        print(f"CMR FAIL rig: {type(error).__name__}: {error}", flush=True)
        receipt["rig_error"] = f"{type(error).__name__}: {error}"
        status = 3
    finally:
        receipt["status"] = status
        (out / "result.json").write_text(json.dumps(receipt, indent=2, default=str))
        print("CLOUD_MVP_READBACK " + json.dumps({k: v for k, v in receipt.items() if k != "steps"}
                                                 | {"steps": [s.get("step") for s in receipt["steps"]]}, default=str), flush=True)
    return status


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["prepare", "run"])
    parser.add_argument("--app", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pid-file")
    parser.add_argument("--control-socket")
    parser.add_argument("--folder")
    parser.add_argument("--dmg", default="")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if args.mode == "prepare":
        return prepare(Path(args.app), Path(args.config), out)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
