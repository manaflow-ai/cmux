#!/usr/bin/env python3
"""cmux NEXT Remote over SSH, driven in the app's GUI on a throwaway Mac (remote-gui-proof.yml).

    remote-gui-proof.py --app APP --tag TAG --host-dir DIR --out OUT [--drop-seconds S]

Leo, 2026-11-10: "we're not a terminal-first app anymore. cmux-next is a gui." This launches the NEXT DEV
app on its own control socket, in light mode, and walks a person's Remote journey through the app's own
UI: every press is a synthesized key or mouse event in the app's window (debug.key, debug.mouse,
debug.page click/type), never a CLI shortcut, except where a step says it fell back and why.

  1. add the SSH host: Add Device > Add Machine, the field `e2ehost` (remote-gui-proof-host.sh's alias for
     rhost@127.0.0.1), Return; until the card's run says ready
  2. a new chat on that host: the composer's environment picker, the host, a prompt; the stand-in claude
     answers PONG. Timed: pick host -> first reply
  3. move a started chat there and back (Move to...)
  4. drop the network (pf on lo0 for the sshd's port), wait, restore it, send again. Timed: restore ->
     the chat answers again (and drop -> answer)

Each step saves the app window (debug.window_snapshot, which needs no Screen Recording grant) as
OUT/NN-step.png. OUT/evidence.json has every step (ok, ms, detail, and the exact text of anything that
went wrong: a snag); OUT/summary.md is the run summary. Exit 0 when every step passed.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--host-dir", required=True, help="remote-gui-proof-host.sh's DIR")
parser.add_argument("--out", required=True)
parser.add_argument("--alias", default="e2ehost")
parser.add_argument("--drop-seconds", type=float, default=30)
args = parser.parse_args()

HERE = Path(__file__).resolve().parent
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
APP = Path(args.app).resolve()
CLI = APP / "Contents/Resources/bin/cmux"
SOCK = f"/tmp/cmux-rgp-{args.tag}.sock"
# Both names, as cloud-chat-proof.py sets them: the bundled CLI reads CMUX_SOCKET_PATH (run 42870121112: `cmux app
# identify` found no app with CMUX_NEXT_SOCKET_PATH alone).
ENV = {**os.environ, "CMUX_NEXT_SOCKET_PATH": SOCK, "CMUX_SOCKET_PATH": SOCK}
PROMPT = "Reply with exactly: PONG"
REPLY = "PONG"
T0 = time.monotonic()
evidence: dict = {"tag": args.tag, "app": str(APP), "alias": args.alias, "steps": [], "snags": [], "times_ms": {}}
shot_no = [0]


def now_ms() -> int:
    return round((time.monotonic() - T0) * 1000)


def log(*parts) -> None:
    print(f"[{now_ms() / 1000:8.1f}s]", *parts, flush=True)


def save() -> None:
    (OUT / "evidence.json").write_text(json.dumps(evidence, indent=2))


def snag(text: str, **extra) -> None:
    """A finding: an error message, a loading state, a slow step. Its exact text and the time."""
    row = {"at_ms": now_ms(), "text": str(text)[:2000], **extra}
    evidence["snags"].append(row)
    log("SNAG", json.dumps(row)[:600])
    save()


def step(name: str, ok: bool, **detail) -> bool:
    row = {"step": name, "ok": ok, "at_ms": now_ms(), **detail}
    evidence["steps"].append(row)
    log("STEP", "ok" if ok else "FAIL", json.dumps(row)[:800])
    save()
    return ok


def rpc(method: str, params: dict | None = None, timeout: float = 30) -> dict:
    """One request on the app's control socket: its result, or {"error": ...}."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCK)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"error": f"{type(error).__name__}: {error}"}
    if reply.get("ok") is False or reply.get("error"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"value": result}


def cli(*words: str, timeout: float = 120) -> tuple[int, str, str]:
    try:
        done = subprocess.run([str(CLI), *words], env=ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as error:
        return 124, (error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or ""), f"timed out after {timeout}s"


def action(name: str, action_args: dict | None = None) -> dict:
    params: dict = {"action": name, "focus": True}
    if action_args:
        params["args"] = action_args
    return rpc("action.run", params, timeout=60)


def shot(name: str) -> str | None:
    shot_no[0] += 1
    path = OUT / f"{shot_no[0]:02d}-{name}.png"
    reply = rpc("debug.window_snapshot", {"path": str(path)}, timeout=30)
    if reply.get("error") or not path.exists():
        snag(f"still {name}: {reply.get('error') or reply}")
        return None
    log("still", path.name)
    return path.name


def page(page_id: str | None, act: str, **params) -> dict:
    body = {"action": act, **params}
    if page_id:
        body["page"] = page_id
    return rpc("debug.page", body, timeout=95 if act == "wait" else 30)


def key(name: str, modifiers: list[str] | None = None) -> dict:
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers or []})
    time.sleep(0.15)  # harness: the key lands
    return reply


def host_sh(cmd: str) -> None:
    subprocess.run([str(HERE / "remote-gui-proof-host.sh"), cmd, args.host_dir], check=True)


def wait_until(what: str, probe, timeout: float, interval: float = 0.25):
    """probe() -> truthy value when done. Returns (value, ms) or (None, ms) at the deadline."""
    start = time.monotonic()
    while True:
        value = probe()
        if value:
            return value, round((time.monotonic() - start) * 1000)
        if time.monotonic() - start > timeout:
            return None, round((time.monotonic() - start) * 1000)
        time.sleep(interval)  # harness: the app has no push channel for a script


# --- launch -------------------------------------------------------------------------------------------------

def launch() -> bool:
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    subprocess.Popen(["/usr/bin/open", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={SOCK}", str(APP)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pong, ms = wait_until("socket", lambda: (lambda r: r if not r.get("error") else None)(rpc("system.ping", timeout=5)), 180, 1)
    if not pong:
        return step("launch", False, ms=ms, error=rpc("system.ping").get("error"))
    step("launch", True, ms=ms)
    appearance = rpc("debug.appearance", {"mode": "light"})
    if appearance.get("error"):
        snag(f"debug.appearance light: {appearance['error']}")
    time.sleep(2)  # harness: the first window settles
    shot("launched")
    return True


def dump_state(label: str) -> None:
    """What the app shows now, for the findings: windows and every live page's visible text."""
    windows = rpc("debug.window_list")
    (OUT / f"state-{label}-windows.json").write_text(json.dumps(windows, indent=2)[:200000])
    pages = {}
    for pid in ("cmux.server-cards", "cmux.machines", "cmux.onboarding", None):
        state = page(pid, "state")
        pages[str(pid)] = {k: state.get(k) for k in ("page", "id", "url", "fragment", "text", "error") if k in state}
    (OUT / f"state-{label}-pages.json").write_text(json.dumps(pages, indent=2)[:400000])


# --- GUI helpers ----------------------------------------------------------------------------------------------

def card(act: str, **params) -> dict:
    return page("cmux.server-cards", act, **params)


def card_shot(name: str) -> None:
    """The Add Machine card is its own floating panel: the main window's still and the card's own."""
    shot(name)
    path = OUT / f"{shot_no[0]:02d}-{name}-card.png"
    reply = card("snapshot", path=str(path))
    if reply.get("error"):
        snag(f"card still {name}: {reply['error']}")


def native_press(selector: str) -> dict:
    """A person's click on a page element: hover finds it, press posts native mouse events there (a
    debug.page click is page script, which Add refuses: "Only a click or key in the card adds ...")."""
    where = card("hover", selector=selector)
    if where.get("error") or "x" not in where:
        return {"error": f"hover {selector}: {where.get('error') or where}"}
    return card("press", x=where["x"], y=where["y"], native=True)


def pane(act: str, **params) -> dict:
    reply = rpc("debug.agent_pane", {"action": act, **params}, timeout=60)
    if isinstance(reply.get("result"), str):
        try:
            reply = dict(reply, result=json.loads(reply["result"]))
        except ValueError:
            pass
    return reply


def chat_state() -> dict:
    reply = pane("chat_state")
    value = reply.get("result") if isinstance(reply.get("result"), dict) else reply
    return value if isinstance(value, dict) else {}


def replied(after: int) -> dict | None:
    """The chat's assistant turn number `after`+1 or later says PONG and is done."""
    state = chat_state()
    turns = [t for t in state.get("transcript") or [] if isinstance(t, dict) and t.get("kind") == "assistant"]
    last = state.get("lastAssistant") or {}
    if len(turns) > after and REPLY in str(turns[-1].get("text", "")) and not last.get("streaming") and not state.get("isWorking"):
        return state
    return None


def assistant_count() -> int:
    return len([t for t in chat_state().get("transcript") or [] if isinstance(t, dict) and t.get("kind") == "assistant"])


def peer_connected() -> dict | None:
    """The acpmux peer as the app's daemon has it (`cmux acp host ls`): connected or not."""
    code, out, _ = cli("acp", "host", "ls", "--json", timeout=20)
    try:
        peers = json.loads(out).get("peers") or [] if code == 0 else []
    except (ValueError, AttributeError):
        peers = []
    row = next((p for p in peers if isinstance(p, dict) and p.get("name") == args.alias), None)
    return row if row and row.get("connected") else None


def machine_row() -> dict | None:
    listed = rpc("remote.machines")
    evidence["remote_machines_last"] = listed
    rows = listed.get("machines") if isinstance(listed.get("machines"), list) else listed.get("value")
    for row in rows or []:
        if isinstance(row, dict) and args.alias in json.dumps(row):
            return row
    return None


def watch_link(seconds: float, label: str) -> list:
    """remote.machines' link and the chat's connection every 0.5 s, for the record."""
    seen, last = [], None
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        row = machine_row() or {}
        state = chat_state()
        now = (row.get("status"), row.get("link"), state.get("connection"), state.get("unavailable"))
        if now != last:
            seen.append({"at_ms": now_ms(), "status": now[0], "link": now[1], "chat_connection": now[2], "chat_unavailable": now[3]})
            log(label, json.dumps(seen[-1]))
            last = now
        time.sleep(0.5)  # harness: sampling what the app shows
    return seen


# --- 1. add the host ----------------------------------------------------------------------------------------

APP_PID: list[int] = []


def app_pid() -> int | None:
    if not APP_PID:
        code, out, _ = cli("app", "identify", "--json", timeout=20)
        try:
            pid = json.loads(out).get("pid") if code == 0 else None
        except ValueError:
            pid = None
        if not isinstance(pid, int):
            # The app's own executable, by its full path in the bundle this proof launched (a read, never a signal).
            exe = APP / "Contents/MacOS"
            done = subprocess.run(["/usr/bin/pgrep", "-n", "-f", str(exe) + "/"], capture_output=True, text=True)
            pid = int(done.stdout.split()[0]) if done.stdout.strip() else None
            if pid is None:
                snag(f"no app pid: cmux app identify exit {code}: {out.strip()[:300]}")
        if isinstance(pid, int):
            APP_PID.append(pid)
    return APP_PID[0] if APP_PID else None


def ax(identifier: str, mode: str = "click") -> dict:
    """A native control by its accessibility identifier: find it, click it with a real mouse event, or AXPress it
    (remote-gui-proof-ax.js). The Add Device card is a native panel, out of debug.page's and debug.mouse's reach."""
    pid = app_pid()
    if not pid:
        return {"error": "no app pid (cmux app identify)"}
    try:
        done = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", str(HERE / "remote-gui-proof-ax.js"), str(pid), identifier, mode],
                              capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return {"error": f"osascript {mode} {identifier}: timed out after 90 s"}
    try:
        return json.loads(done.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": f"osascript exit {done.returncode}: {(done.stderr or done.stdout).strip()[:500]}"}


def native_click(identifier: str) -> bool:
    """A real click; when the mouse event did not land (no Accessibility for osascript, a covered window), AXPress."""
    reply = ax(identifier, "click")
    log("ax click", identifier, json.dumps(reply)[:300])
    if reply.get("clicked"):
        return True
    snag(f"native click on {identifier}: {reply.get('error') or reply}")
    reply = ax(identifier, "press")
    log("ax press", identifier, json.dumps(reply)[:300])
    return bool(reply.get("pressed"))


def watch_add(pressed_at: float) -> tuple[str | None, int]:
    """The Add Machine card's phase (best effort: its page) and the app's own machine row, until ready or failed."""
    phases = []

    def phase():
        rows = card("query", selector=".am-card").get("elements") or []
        ph = ((rows[0].get("data") or {}).get("phase")) if rows else None
        steps = card("query", selector="li.am-step").get("elements") or []
        row = machine_row() or {}
        now = (ph, tuple(((e.get("data") or {}).get("status"), (e.get("text") or "")[:80]) for e in steps), row.get("status"), row.get("link"))
        if not phases or phases[-1]["v"] != now:
            phases.append({"at_ms": round((time.monotonic() - pressed_at) * 1000), "v": now})
            log("add", ph, [s[0] for s in now[1]], row.get("status"), row.get("link"))
            if len(phases) == 2:
                card_shot("add-machine-running")
        if ph in ("ready", "failed"):
            return ph
        if row.get("link") == "connected" or row.get("status") == "connected":
            return "ready"
        return None

    outcome, ms = wait_until("add done", phase, 300, 0.3)
    title = card("query", selector="h1.am-title").get("elements") or [{}]
    evidence["add_machine_card"] = {"outcome": outcome, "ms_from_press": ms, "title": title[0].get("text"),
                                    "phases": [{"at_ms": p["at_ms"], "phase": p["v"][0], "steps": p["v"][1],
                                                "machine_status": p["v"][2], "link": p["v"][3]} for p in phases]}
    if outcome != "ready":
        snag(f"Add Machine: {outcome or 'no outcome in 300 s'}: {title[0].get('text')}",
             steps=[s for s in (phases[-1]["v"][1] if phases else ())])
    return outcome, ms


def add_host() -> bool:
    """Add Device (the sidebar's +), Advanced: add over SSH, the ~/.ssh/config row e2ehost, Add."""
    start = time.monotonic()
    reply = action("device.add")
    if reply.get("error"):
        snag(f"action device.add: {reply['error']}")
    time.sleep(1.5)
    shot("add-device")
    via = None
    if native_click("cmux.addDevice.advanced"):
        time.sleep(0.8)
        shot("add-device-advanced")
        row_id = f"cmux.addDevice.add.{args.alias}"
        found, ms = wait_until("ssh row", lambda: (lambda r: r if r.get("found") else None)(ax(row_id, "find")), 30, 1)
        shot("add-device-ssh-row" if found else "add-device-no-ssh-row")
        if found:
            evidence["times_ms"]["advanced_to_ssh_row"] = ms
            pressed_at = time.monotonic()
            if native_click(row_id):
                via = "Add Device > Advanced: add over SSH > e2ehost (ssh config) > Add"
        else:
            listing = ax("cmux.addDevice.network.list", "find")
            snag(f"Advanced shows no {args.alias} row in {ms} ms (the runner's ~/.ssh/config has Host {args.alias})", listing=listing)
            if native_click("cmux.addDevice.button.otherComputer"):
                waited = card("wait", selector="input.am-host", timeout_ms=30000)
                if waited.get("error"):
                    snag(f"Other Computer…: no host field: {waited['error']}")
                else:
                    card("type", selector="input.am-host", text=args.alias)
                    card_shot("add-machine-filled")
                    pressed_at = time.monotonic()
                    pressed = native_press('button[data-action="add"]')
                    if pressed.get("error"):
                        snag(f"pressing Add: {pressed['error']}")
                    else:
                        via = "Add Device > Advanced > Other Computer… > host field > Add"
    if not via:
        # The journey goes on from the CLI's add so the later steps still run; the GUI add stays a failure.
        snag("the GUI add did not start; falling back to `cmux setup machine e2ehost` for the later steps")
        code, out, err = cli("setup", "machine", args.alias, "--json", timeout=300)
        evidence["setup_machine_fallback"] = {"exit": code, "out": out[-2000:], "err": err[-2000:]}
        row, ms = wait_until("link connected", lambda: (lambda r: r if r and r.get("link") == "connected" else None)(machine_row()), 60, 0.5)
        evidence["remote_machine"] = machine_row()
        if not row:
            snag(f"`cmux setup machine {args.alias}` connected the peer, but the app's machines (remote.machines) do not list it after {ms} ms",
                 remote_machines=evidence.get("remote_machines_last"))
        shot("added-by-cli")
        step("add host (GUI)", False, error="GUI add did not start", cli_fallback_exit=code)
        return bool(row) or bool(peer_connected())
    outcome, ms = watch_add(pressed_at)
    card_shot(f"add-machine-{outcome or 'timeout'}")
    evidence["remote_machine"] = machine_row()
    total = round((time.monotonic() - start) * 1000)
    evidence["times_ms"]["add_host"] = total
    evidence["times_ms"]["add_press_to_ready"] = ms
    if outcome == "ready":
        native_press('button[data-action="done"]')
    step("add host (GUI)", outcome == "ready", ms=total, press_to_ready_ms=ms, via=via, machine=evidence["remote_machine"])
    return outcome == "ready" or bool(evidence["remote_machine"])


# --- 2. a chat on the host ----------------------------------------------------------------------------------

def menu(label: str) -> list:
    reply = pane("open_menu", label=label)
    rows = reply.get("result") if isinstance(reply.get("result"), (list, dict)) else reply
    return rows


def chat_on_host() -> bool:
    reply = action("palette.newAgentChat")
    if reply.get("error"):
        snag(f"action palette.newAgentChat: {reply['error']}")
    ok, ms = wait_until("composer", lambda: "error" not in pane("readiness"), 30, 0.5)
    time.sleep(1)
    shot("new-chat")
    where = menu("Computer")
    evidence["menu_computer"] = where
    shot("picker-where")
    remote = pane("click", text="Remote")
    if remote.get("error"):
        snag(f"the Where picker has no Remote row to click: {remote['error']}", rows=str(where)[:1500])
    time.sleep(0.5)
    machines = menu("Machine")
    evidence["menu_machine"] = machines
    shot("picker-machine")
    name = (evidence.get("remote_machine") or {}).get("name") or args.alias
    picked_at = time.monotonic()
    picked = pane("click", text=name)
    if picked.get("error"):
        snag(f"the Machine picker has no row {name!r}: {picked['error']}", rows=str(machines)[:1500])
        return step("chat on the host", False, error=picked.get("error"))
    time.sleep(0.3)
    shot("host-picked")
    sent = pane("compose_send", text=PROMPT)
    if sent.get("error"):
        snag(f"compose_send: {sent['error']}")
    first_seen = {}

    def first():
        state = chat_state()
        last = state.get("lastAssistant") or {}
        if last.get("text") and "first_text_ms" not in first_seen:
            first_seen["first_text_ms"] = round((time.monotonic() - picked_at) * 1000)
        if state.get("connection") and state.get("connection") not in ("connected", "ready") and "loading" not in first_seen:
            first_seen.setdefault("states", []).append(state.get("connection"))
        return replied(0)

    state, _ = wait_until("first reply", first, 180, 0.2)
    ms = round((time.monotonic() - picked_at) * 1000)
    shot("first-reply" if state else "no-reply")
    evidence["times_ms"]["pick_host_to_first_reply"] = ms if state else None
    if not state:
        st = chat_state()
        snag(f"no PONG {ms} ms after picking {name}", chat={k: st.get(k) for k in ("connection", "unavailable", "missingSession", "isWorking", "lastAssistant", "prompts", "harness")})
    return step("chat on the host: pick host -> first reply", bool(state), ms=ms, **first_seen,
                session=(state or {}).get("sessionId"), harness=(state or {}).get("harness"))


# --- 3. move a chat there and back --------------------------------------------------------------------------

def move_there_and_back() -> bool:
    """A chat started on this Mac moves to the host and back, through the started chat's Move to..."""
    reply = action("palette.newAgentChat")
    time.sleep(1.5)
    where = menu("Computer")
    pane("click", text="This Mac")
    sent = pane("compose_send", text=PROMPT)
    local, ms = wait_until("local reply", lambda: replied(0), 120, 0.3)
    shot("local-chat")
    if not local:
        st = chat_state()
        snag(f"a chat on this Mac gave no reply in {ms} ms", chat={k: st.get(k) for k in ("connection", "unavailable", "isWorking", "lastAssistant", "harness")})
    rows = menu("Computer")
    evidence["menu_move_from_local"] = rows
    shot("move-menu")
    opened = pane("click", text="Move to…")
    targets = menu("Computer") if opened.get("error") else pane("readiness")
    evidence["move_targets_from_local"] = {"click": opened, "after": targets}
    shot("move-targets")
    name = (evidence.get("remote_machine") or {}).get("name") or args.alias
    there_at = time.monotonic()
    there = pane("click", text=name)
    if there.get("error"):
        snag(f"Move to... offers no {name!r} (only Cloud machines and This Mac are move targets): {there['error']}",
             menu=str(rows)[:1500])
        pane("close_menus")
        return step("move a chat there and back", False, error="no SSH machine among the Move to... targets")
    moved, ms = wait_until("moved there", lambda: (lambda r: r if r and str(r.get("connection")) else None)(machine_row()), 120, 0.5)
    shot("moved-there")
    before = assistant_count()
    pane("send_prompt", text=PROMPT)
    ok_there, there_ms = wait_until("reply there", lambda: replied(before), 120, 0.3)
    evidence["times_ms"]["move_there"] = round((time.monotonic() - there_at) * 1000)
    menu("Computer")
    back_at = time.monotonic()
    pane("click", text="Move to…")
    back = pane("click", text="This Mac")
    before = assistant_count()
    pane("send_prompt", text=PROMPT)
    ok_back, _ = wait_until("reply back", lambda: replied(before), 120, 0.3)
    evidence["times_ms"]["move_back"] = round((time.monotonic() - back_at) * 1000)
    shot("moved-back")
    return step("move a chat there and back", bool(ok_there and ok_back), there=bool(ok_there), back=bool(ok_back))


# --- 4. drop and restore the network ------------------------------------------------------------------------

def drop_and_restore() -> bool:
    # Back to the chat on the host (step 2's): the newest chat on the machine.
    sid = next((s.get("session") for s in evidence["steps"] if s.get("step", "").startswith("chat on the host") and s.get("session")), None)
    if sid:
        pane("select_session", session=sid)
        time.sleep(1)
    drop_at = time.monotonic()
    host_sh("drop")
    seen = watch_link(min(args.drop_seconds, 600), "dropped")
    shot("network-dropped")
    st = chat_state()
    evidence["while_dropped"] = {"link": seen, "chat": {k: st.get(k) for k in ("connection", "unavailable", "missingSession")}}
    host_sh("restore")
    back_at = time.monotonic()
    before = assistant_count()
    sent = pane("send_prompt", text=PROMPT)
    if sent.get("error"):
        snag(f"send right after the network came back: {sent['error']}")
    link_seen = {}

    def working():
        row = machine_row() or {}
        if row.get("link") == "connected" and "link_ms" not in link_seen:
            link_seen["link_ms"] = round((time.monotonic() - back_at) * 1000)
        return replied(before)

    state, _ = wait_until("working again", working, 300, 0.2)
    ms = round((time.monotonic() - back_at) * 1000)
    shot("working-again" if state else "not-working")
    evidence["times_ms"]["restore_to_working"] = ms if state else None
    evidence["times_ms"]["drop_to_working"] = round((time.monotonic() - drop_at) * 1000) if state else None
    evidence["times_ms"]["restore_to_link_connected"] = link_seen.get("link_ms")
    if not state:
        st = chat_state()
        snag(f"the chat did not answer {ms} ms after the network came back",
             chat={k: st.get(k) for k in ("connection", "unavailable", "missingSession", "isWorking", "prompts", "lastAssistant")},
             machine=machine_row())
    return step("drop and restore the network: restore -> working", bool(state), ms=ms, drop_seconds=args.drop_seconds, **link_seen)


def main() -> int:
    save()
    try:
        if not launch():
            return 1
        if add_host():
            for fn in (chat_on_host, move_there_and_back, drop_and_restore):
                try:
                    fn()
                except Exception as error:  # a step's crash is a finding; the next step still runs
                    snag(f"{fn.__name__} raised {type(error).__name__}: {error}")
                    step(fn.__name__, False, error=str(error))
        # Recon for the later steps: the CLI's surface on this build.
        for words in (("--version",), ("acp", "host", "ls", "--json"), ("link", "agent", "--help"), ("cloud", "move", "--help")):
            code, out, err = cli(*words, timeout=30)
            (OUT / ("cli-" + "-".join(w.strip("-") for w in words) + ".txt")).write_text(f"exit {code}\n{out}\n{err}")
    finally:
        lines = ["## Remote GUI proof", "", "| step | ok | ms |", "| --- | --- | --- |"]
        lines += [f"| {s['step']} | {'yes' if s['ok'] else 'no'} | {s.get('ms', '')} |" for s in evidence["steps"]]
        lines += ["", "Times (ms): `" + json.dumps(evidence["times_ms"]) + "`", "", "### Snags", ""]
        lines += [f"- {s['at_ms'] / 1000:.1f}s: `{s['text'][:300]}`" for s in evidence["snags"]] or ["- none"]
        (OUT / "summary.md").write_text("\n".join(lines) + "\n")
        save()
        rpc("action.run", {"action": "quitEndEverything"}, timeout=20)
        try:
            host_sh("restore")
        except subprocess.CalledProcessError:
            pass
    return 0 if evidence["steps"] and all(s["ok"] for s in evidence["steps"]) else 1


if __name__ == "__main__":
    sys.exit(main())
