#!/usr/bin/env python3
"""Relaunch restore (cmuxterm-hq#7149 row L5): quit cmux NEXT, open it again, and everything is back.

Leo, 2026-11-05: "It's like a binary. Like, did you hit it? Did you not fucking hit it?" The row passes when,
after Quit and Keep Sessions and a relaunch, every workspace, terminal and chat is back: the terminal's own
process is the same pid and still alive (the cmux-tui daemon kept it), its scrollback hashes the same
(sha256), the chat is bound to its tab again with the same messages, and the app is usable less than
--budget-ms (3000) after the quit was asked for.

Two halves, one file:

  The probe set, shared with scripts/measure/try-pr-apply.sh (#35887) so rows L2 to L5 read the same state.
  Both read the instance from CMUX_TRY_SOCKET (its control socket) and CMUX_TRY_APP (its bundle):
    relaunch_restore_check.py seed    two workspaces `l5-a` and `l5-b`; in l5-a a terminal running one
                                      long-lived process (its pid in a file) under SCROLLBACK_LINES numbered
                                      lines; in l5-b an agent chat on the acpmux test agent (harness `l5fake`,
                                      a profile in the instance's HOME, CMUX_TRY_HOME), one turn answered.
                                      What it made goes to <socket>.l5-seed.json.
    relaunch_restore_check.py state   one JSON line: {"workspaces": N, "terminal_pid": PID,
                                      "scrollback_sha256": HEX, "chat": "<id>:<messages>:<tab|no-tab>"}; a
                                      field it cannot read is left out, so the compare says "not proven"
  The instance's HOME is CMUX_TRY_HOME, else the HOME of the app process CMUX_TRY_PID (`ps eww`); never the
  caller's own HOME, which would put the harness profile in the account's real home.

  The check, on a fresh home (fresh_home_launch_smoke.py launches it, as the nightly gate does):
    relaunch_restore_check.py (--app APP | --dmg DMG) [--rounds 3] [--fronts terminal,chat] [--budget-ms 3000]
        [--out DIR] [--fake-agent PATH]
  seeds, reads the state, then each round: puts the round's front in the front window (--fronts, cycled over
  the rounds: `terminal` l5-a's terminal tab, `chat` l5-b's chat tab, `home` Home on its home-dock tab,
  `first-run` the fresh home's first-run Home with no tab selected, round 1 only), Quit and Keep Sessions
  (`action.run quitKeepSessions`), waits for the process to end, starts the same app with the same
  environment, and polls every POLL_S until it is usable: the control socket answers snapshot.get with the
  topology loaded, both l5 workspaces and the chat's tab back, the front window showing what it showed at
  the quit (workspace and selected tabs), the state probe equal to before, and the launch settled (the app's
  `reveal.pane` launch mark: its control socket also opens at a 4 s backstop when the launch never settles,
  cmux#36274). A `chat` round also needs the shown chat page drawn (`agent_pane.painted`), and after it is
  usable a new turn sent to the chat must be answered (live_ms), so the chat is reattached to its agent, not
  only bound to its tab; where the build serves `debug.agent_pane` (a DEV build; a NIGHTLY's release router
  drops `debug.*`), the shown page must also report a live event (`liveEvent`, as bench_relaunch_reconnect.py
  reads it). `first-run` (the #36274 case) stays out of the default until cmux#36306 (its fix) lands. Each round prints
  `L5-ROUND {json}` (quit_ms: quit asked to process gone; quit_to_usable_ms: quit asked to the end of the
  poll that found it usable, the budgeted number; ready_ms: to the start of that poll, a lower bound), and the
  run prints `L5 {json}` with the verdict. Exit 0 only when every round restored everything within budget.

A NIGHTLY is a Release build: only release control methods (snapshot.get, action.run, system.ping) and the
bundled CLI are used, so the same check runs on a NIGHTLY DMG and a DEV app.
"""
from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

SCROLLBACK_LINES = 2000
POLL_S = 0.05
HARNESS = "l5fake"
KEYS = ("workspaces", "terminal_pid", "scrollback_sha256", "chat")
PROMPT = "l5 hello"
DEFAULT_FAKE_AGENT = HERE.parent.parent / "cmux-tui" / "crates" / "acpmux" / "tests" / "fake_agent.py"


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# ---- transport ------------------------------------------------------------------------------

def call(sock: str, method: str, params: dict | None = None, timeout: float = 10.0) -> dict:
    """One request on the release control socket: the result, or {"error": ...}."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buffer = b""
            while b"\n" not in buffer:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buffer += chunk
        reply = json.loads(buffer.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if reply.get("ok") is False or reply.get("error"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"value": result}


class Instance:
    """One running app: its control socket, bundle and HOME (the CLI runs in it, so it reaches this app's session)."""

    def __init__(self, sock: str, app: str, home: str):
        self.sock, self.app, self.home = sock, app, home
        self.cli = os.path.join(app, "Contents", "Resources", "bin", "cmux")
        self.record = sock + ".l5-seed.json"
        self.last_rows: list[str] = []

    def cmux(self, *argv: str, timeout: float = 30.0):
        """The bundled CLI with --json: the parsed answer, or {"error": ...}."""
        env = {"HOME": self.home, "CFFIXED_USER_HOME": self.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "CMUX_NEXT_SOCKET_PATH": self.sock, "CMUX_QUIET": "1"}
        try:
            # --app-socket: app actions (chat new's tab) ignore CMUX_NEXT_SOCKET_PATH and look for the build's default
            # socket under HOME ("app.unreachable", nightly 4191131679101).
            done = subprocess.run([self.cli, "--json", "--app-socket", self.sock, *argv], env=env, cwd=self.home or "/",
                                  capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.SubprocessError) as error:
            return {"error": str(error)}
        lines = [line for line in done.stdout.splitlines() if line.strip()]
        try:
            answer = json.loads(lines[-1]) if lines else None
        except ValueError:
            answer = None
        if done.returncode != 0 or answer is None:
            return {"error": (done.stdout + done.stderr).strip()[-400:] or f"exit {done.returncode}"}
        return answer

    def topology(self) -> dict | None:
        snap = call(self.sock, "snapshot.get", timeout=5)
        topo = snap.get("topology") if isinstance(snap, dict) else None
        return topo if isinstance(topo, dict) else None


def process_home(pid: str) -> str | None:
    """HOME from a running process's environment (`ps eww`, same user), None when it cannot be read."""
    try:
        line = subprocess.run(["ps", "eww", "-o", "command=", "-p", pid], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for word in line.split():
        if word.startswith("HOME=") and len(word) > 5:
            return word[5:]
    return None


def unwrap(answer):
    """A CLI answer's payload: its `value` (daemon verbs) or `result` (agents verbs, e.g. chat.new) when it has one."""
    if not isinstance(answer, dict):
        return answer
    for key in ("value", "result"):
        if isinstance(answer.get(key), dict):
            return answer[key]
    return answer


def workspace_named(topo: dict | None, name: str) -> dict | None:
    return next((w for w in (topo or {}).get("workspaces") or [] if isinstance(w, dict) and w.get("name") == name), None)


def tabs_of(workspace: dict | None) -> list[dict]:
    return [t for s in (workspace or {}).get("screens") or [] for p in (s or {}).get("panes") or []
            for t in (p or {}).get("tabs") or [] if isinstance(t, dict)]


def wait(probe, seconds: float, every: float = 0.25):
    end = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() >= end:
            return value
        time.sleep(every)


# ---- seed -----------------------------------------------------------------------------------

def write_harness(home: str, fake_agent: str) -> None:
    """The acpmux test agent as harness `l5fake`, a profile in the instance's own HOME (cmux reads it live)."""
    folder = Path(home) / ".config" / "cmux" / "harnesses"
    folder.mkdir(parents=True, exist_ok=True)
    profile = folder / f"{HARNESS}.toml"
    profile.write_text(f'schema = 1\nid = "{HARNESS}"\nname = "L5 test agent"\nprotocol = "acp"\n'
                       f'command = "/usr/bin/python3"\nargs = [{json.dumps(str(fake_agent))}]\n')
    profile.chmod(0o600)


def seed(inst: Instance, fake_agent: str, work: str, front_terminal: bool = True) -> dict:
    """Makes the probed state and records it; raises RuntimeError naming the step that failed."""
    os.makedirs(work, exist_ok=True)
    pidfile = os.path.join(work, "l5-terminal.pid")
    if os.path.exists(pidfile):
        os.remove(pidfile)
    made = {"pidfile": pidfile, "work": work}

    a = unwrap(inst.cmux("workspace", "create", "--name", "l5-a"))
    term = a.get("terminal_id") if isinstance(a, dict) else None
    if not term:
        raise RuntimeError(f"workspace l5-a made no terminal: {a}")
    made["terminal"] = term
    # One process for the whole run: the shell execs into it after printing the numbered lines, so its pid
    # (written first) is the terminal's foreground program, and nothing prints after, so the scrollback is fixed.
    # The typed line says l5-scrollback-"done", so only the output matches the wait's pattern.
    command = (f"sh -c 'echo $$ > {pidfile}; i=0; while [ $i -lt {SCROLLBACK_LINES} ]; do i=$((i+1)); "
               f"echo l5-line-$i; done; echo l5-scrollback-\"done\"; exec sleep 86400'\n")
    wrote = inst.cmux("terminal", term, "write", "--text", command)
    if isinstance(wrote, dict) and wrote.get("error"):
        raise RuntimeError(f"terminal write failed: {wrote['error']}")
    done = inst.cmux("terminal", term, "screen", "wait", "--pattern", "l5-scrollback-done", "--timeout-ms", "30000", timeout=45)
    if isinstance(done, dict) and done.get("error"):
        raise RuntimeError(f"the numbered lines never finished: {done['error']}")
    if not wait(lambda: os.path.exists(pidfile) and open(pidfile).read().strip(), 10):
        raise RuntimeError("the terminal's process never wrote its pid")
    made["terminal_pid"] = int(open(pidfile).read().strip())

    b = unwrap(inst.cmux("workspace", "create", "--name", "l5-b"))
    ws_b = b.get("workspace_id") if isinstance(b, dict) else None
    if not ws_b:
        raise RuntimeError(f"workspace l5-b was not made: {b}")
    write_harness(inst.home, fake_agent)
    inst.cmux("harness", "reload")
    inst.cmux("setup", "trust", work)
    chat = unwrap(inst.cmux("agents", "chat", "new", "--workspace", ws_b, "--harness", HARNESS, "--cwd", work,
                            "--name", "l5-chat", "--", PROMPT, timeout=90))
    chat_id = None
    if isinstance(chat, dict):
        chat_id = chat.get("chat")  # chat.new's result names the chat, its acpmux session id
    if not chat_id:
        raise RuntimeError(f"agents chat new made no chat: {json.dumps(chat)[:400]}")
    made["chat"] = str(chat_id)
    inst.cmux("agents", "wait", "--until", "idle", "--target", str(chat_id), "--timeout", "60", timeout=75)
    # The fake agent echoes the prompt: the turn is in when the reply is.
    if not wait(lambda: chat_messages(inst, made["chat"]) >= 2, 30, 0.5):
        raise RuntimeError(f"the chat's first turn was never answered: {json.dumps(inst.cmux('agents', 'chat', 'read', made['chat']))[:400]}")
    if not wait(lambda: chat_tab(inst.topology(), made["chat"]), 15, 0.25):
        raise RuntimeError(f"no tab is bound to chat {made['chat']} 15 s after it was made: {json.dumps(chat_tabs(inst.topology()))[:600]}; "
                           f"chat new answered {json.dumps(chat)[:600]}")
    # The front window shows l5-a, as a person leaves the workspace they worked in. Left alone it shows the fresh
    # home's first-run Home, whose pane has no selected tab; that relaunch never settles its launch (no pane
    # content), so the control socket opens only at its 4 s backstop (nightly 4191131679101: 5.3-5.6 s).
    made["front_workspace"] = a.get("workspace_id")
    made.update(workspace_a=a.get("workspace_id"), terminal_tab=a.get("tab_id"), workspace_b=ws_b,
                chat_tab=chat_tab_id(inst.topology(), made["chat"]))
    # The check sets each round's front itself (put_front), so a `first-run` round can find the first-run Home.
    if front_terminal:
        focused = inst.cmux("workspace", a["workspace_id"], "focus")
        if isinstance(focused, dict) and focused.get("error"):
            raise RuntimeError(f"focusing l5-a failed: {focused['error']}")
    with open(inst.record, "w") as handle:
        json.dump(made, handle)
    return made


# ---- state ----------------------------------------------------------------------------------

def scrollback_sha256(inst: Instance, term: str) -> str | None:
    """sha256 of the terminal's whole text: every scrollback row (oldest first, paged back from the newest), then
    the screen's rows, as one list. Independent of the terminal's size: a terminal first given a view after the
    relaunch resizes, which moves rows between scrollback and screen, pads rows to the new width and rewraps long
    lines at it, so the digest is of the text with every space and row break taken out (nightly 4198271655001
    reported every round "changed" for the same text wrapped at another width). The rows are kept on the instance
    (`last_rows`) for a failure's evidence."""
    rows, before = [], None
    for _ in range(100):
        page = unwrap(inst.cmux("terminal", term, "history", "read", "--limit", "1000",
                                *(["--before", str(before)] if before is not None else [])))
        if not isinstance(page, dict) or "rows" not in page:
            return None
        chunk = ["".join(r.get("text", "") for r in row.get("runs", [])).rstrip() for row in page["rows"]]
        rows = chunk + rows
        start = int(page.get("start") or 0)
        if not chunk or start <= 0:
            break
        before = start
    screen = unwrap(inst.cmux("terminal", term, "screen", "read"))
    text = screen.get("text") if isinstance(screen, dict) else None
    if text is None:
        return None
    rows = rows + [line.rstrip() for line in text.split("\n")]
    while rows and not rows[-1]:
        rows.pop()
    inst.last_rows = rows
    return hashlib.sha256("".join("".join(rows).split()).encode()).hexdigest()


def chat_messages(inst: Instance, chat: str) -> int:
    read = unwrap(inst.cmux("agents", "chat", "read", chat, "--limit", "200"))
    items = read.get("items") if isinstance(read, dict) else read if isinstance(read, list) else None
    if not isinstance(items, list):
        return -1
    # chat read's items carry a role: user, assistant or tool (cli/agents/chat.rs); the messages are the first two.
    return sum(1 for item in items if isinstance(item, dict) and item.get("role") in ("user", "assistant"))


def chat_tab(topo: dict | None, chat: str) -> str | None:
    """Where the chat is reattached: the name of the workspace whose tab is bound to its session (`agent_session`,
    ControlTopology+JSON), or None. The name is part of the probe, so a chat back in another workspace is a change."""
    for workspace in (topo or {}).get("workspaces") or []:
        if isinstance(workspace, dict) and any(str(t.get("agent_session") or "") == chat for t in tabs_of(workspace)):
            return str(workspace.get("name") or workspace.get("id"))
    return None


def chat_tab_id(topo: dict | None, chat: str) -> str | None:
    """The id of the tab bound to the chat's session, or None."""
    for workspace in (topo or {}).get("workspaces") or []:
        for tab in tabs_of(workspace if isinstance(workspace, dict) else None):
            if str(tab.get("agent_session") or "") == chat:
                return tab.get("id")
    return None


def chat_tabs(topo: dict | None) -> list[dict]:
    """Every conversation-like tab with its workspace, for a failure's evidence."""
    return [{"workspace": w.get("name"), **{k: t.get(k) for k in ("kind", "page", "agent_session")}}
            for w in (topo or {}).get("workspaces") or [] if isinstance(w, dict) for t in tabs_of(w)
            if t.get("agent_session") or t.get("kind") not in ("terminal", "browser")]


def state(inst: Instance, topo: dict | None = None) -> dict:
    """The probe set's JSON. A field that cannot be read is left out: a null on both sides would compare equal."""
    try:
        with open(inst.record) as handle:
            made = json.load(handle)
    except (OSError, ValueError):
        made = {}
    topo = topo if topo is not None else inst.topology()
    workspaces = len([w for w in (topo or {}).get("workspaces") or [] if isinstance(w, dict)]) if topo else None
    term, chat = made.get("terminal"), made.get("chat")
    pid = None
    if made.get("pidfile") and os.path.exists(made["pidfile"]):
        try:
            pid = int(open(made["pidfile"]).read().strip())
            os.kill(pid, 0)
        except (OSError, ValueError):
            pid = None
    messages = chat_messages(inst, chat) if chat else -1
    found = {
        "workspaces": workspaces,
        "terminal_pid": pid,
        "scrollback_sha256": scrollback_sha256(inst, term) if term else None,
        "chat": f"{chat}:{messages}:{chat_tab(topo, chat) or 'no-tab'}" if chat and messages >= 0 else None,
    }
    return {k: v for k, v in found.items() if v is not None}


# ---- the check ------------------------------------------------------------------------------

def launch(app: Path, env: dict, out_log: Path) -> tuple[subprocess.Popen, int, int]:
    """The app with the run's environment and a fresh launch-marks pipe, as fresh_home_launch_smoke.run starts it."""
    import fresh_home_launch_smoke as smoke
    marks_read, marks_write = os.pipe()
    env = {**env, "CMUX_NEXT_LAUNCH_MARKS_FD": str(marks_write)}
    _, executable = smoke.bundle_info(app)
    with open(out_log, "ab") as handle:
        process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable), "-ApplePersistenceIgnoreState", "YES"],
                                   env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=handle,
                                   stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
    os.close(marks_write)
    os.set_blocking(marks_read, False)
    return process, marks_read, marks_write


def usable(inst: Instance, before: dict, chat: str, shown_before: list[dict], which: str,
           marks: dict) -> tuple[bool, dict | None, str]:
    """(usable, state, why not): topology loaded, both l5 workspaces and the chat tab back, the front window showing
    what it showed at the quit, the state equal, and the launch settled (and the shown chat drawn, for `chat`)."""
    topo = inst.topology()
    if not topo:
        return False, None, "no snapshot"
    if topo.get("loaded") is False:
        return False, None, "topology not loaded"
    if not (workspace_named(topo, "l5-a") and workspace_named(topo, "l5-b")):
        return False, None, "l5 workspaces not back"
    if not chat_tab(topo, chat):
        return False, None, f"chat tab not bound (tabs {json.dumps(chat_tabs(topo))[:400]})"
    shown = front(topo)
    if shown != shown_before:
        return False, None, f"front window differs ({json.dumps(shown)[:300]})"
    now = state(inst, topo)
    changed = [k for k in KEYS if before.get(k) != now.get(k)]
    if changed:
        return False, now, "changed: " + ", ".join(changed)
    if "reveal.pane" not in marks:
        return False, now, "launch not settled (no reveal.pane mark)"
    if which == "chat" and "agent_pane.painted" not in marks:
        return False, now, "shown chat not drawn (no agent_pane.painted mark)"
    return True, now, ""


def live_turn(inst: Instance, chat: str, n: int, seconds: float = 30.0) -> tuple[int | None, str]:
    """(ms from send to answer, why not): a new turn through the reattached chat, answered by the test agent."""
    had = chat_messages(inst, chat)
    started = time.monotonic()
    sent = inst.cmux("agents", "chat", "send", chat, "--", f"{PROMPT} live {n}", timeout=30)
    if isinstance(sent, dict) and sent.get("error"):
        return None, f"chat send failed: {sent['error']}"
    if not wait(lambda: chat_messages(inst, chat) >= had + 2, seconds, 0.1):
        return None, f"the live turn was not answered within {seconds:.0f} s ({chat_messages(inst, chat)} messages, had {had})"
    return round((time.monotonic() - started) * 1000), ""


def page_live_event(inst: Instance, seconds: float = 20.0) -> tuple[bool | None, str]:
    """(the shown chat page reported a live event, detail); None when the build does not serve debug.agent_pane."""
    first = call(inst.sock, "debug.agent_pane", {"action": "perf_stats"}, timeout=10)
    if first.get("error"):
        return None, f"not served by this build ({str(first['error'])[:120]})"
    def live():
        stats = call(inst.sock, "debug.agent_pane", {"action": "perf_stats"}, timeout=10)
        launch = stats.get("launch") if isinstance(stats, dict) else None
        return isinstance(launch, dict) and "liveEvent_epoch_ms" in launch
    return bool(wait(live, seconds, 0.25)), ""


def front(topo: dict | None) -> list[dict]:
    """What each visible window shows: its workspace (name, kind) and every pane's selected tab (kind, page, session).
    Ids are left out: a relaunch keeps them, but the compare is about what a person sees."""
    shown = []
    for window in (topo or {}).get("windows") or []:
        if not (isinstance(window, dict) and window.get("visible")):
            continue
        ws = next((w for w in topo.get("workspaces") or [] if isinstance(w, dict) and w.get("id") == window.get("workspace")), {})
        tabs = [{k: t.get(k) for k in ("kind", "page", "agent_session")} for s_ in ws.get("screens") or []
                for p in (s_ or {}).get("panes") or []
                for t in (p or {}).get("tabs") or [] if isinstance(t, dict) and t.get("id") == p.get("selected_tab")]
        shown.append({"workspace": ws.get("name"), "kind": ws.get("kind"), "selected": tabs})
    return shown


FRONTS = ("terminal", "chat", "home", "first-run")


def fronted(shown: list[dict], which: str, made: dict) -> bool:
    """`shown` (front()) has the round's front in a visible window: l5-a on its terminal, l5-b on the chat, or Home."""
    for window in shown:
        selected = window.get("selected") or []
        if which == "terminal" and window.get("workspace") == "l5-a" and any(t.get("kind") == "terminal" for t in selected):
            return True
        if which == "chat" and window.get("workspace") == "l5-b" and any(t.get("agent_session") == made["chat"] for t in selected):
            return True
        # Home's workspace has no kind in the topology (null on nightly 4191131679101): its name and page say it.
        home = window.get("kind") == "home" or window.get("workspace") == "Home"
        if which == "home" and home and any(t.get("page") == "home-dock" for t in selected):
            return True
        # The fresh home's first-run Home: its cover leaves the pane with no selected tab (cmux#36274).
        if which == "first-run" and home and not selected:
            return True
    return False


def put_front(inst: Instance, which: str, made: dict) -> str | None:
    """Puts the round's front in the front window before the quit, as a person leaves it; None, or why it failed."""
    if which == "first-run":
        steps = []  # nothing to do: it holds only while nothing has changed the front since the first launch
    elif which == "home":
        steps = [lambda: call(inst.sock, "action.run", {"action": "home.show", "focus": True}, timeout=15)]
    else:
        ws, tab = (made["workspace_a"], made["terminal_tab"]) if which == "terminal" else (made["workspace_b"], made["chat_tab"])
        if not (ws and tab):
            return f"no {which} tab recorded at seed"
        steps = [lambda: inst.cmux("workspace", ws, "focus"), lambda: inst.cmux("tab", tab, "focus")]
    for step in steps:
        answer = step()
        if isinstance(answer, dict) and answer.get("error"):
            return f"putting {which} in front failed: {answer['error']}"
    if not wait(lambda: fronted(front(inst.topology()), which, made), 0 if which == "first-run" else 10, 0.1):
        return f"{which} never showed in the front window: {json.dumps(front(inst.topology()))[:300]}"
    return None


def round_once(n: int, process, inst: Instance, app: Path, env: dict, before: dict, made: dict, args, out: Path):
    """One quit and relaunch; returns (row, the new process). `before` takes the chat's state after a live turn."""
    which = args.fronts[(n - 1) % len(args.fronts)]
    row: dict = {"round": n, "front": which, "pid_before": process.pid}
    failed = put_front(inst, which, made)
    row["front_before"] = front(inst.topology())
    if failed:
        row["failures"] = [failed]
        print("L5-ROUND " + json.dumps(row, default=str), flush=True)
        return row, process
    asked = time.monotonic()
    reply = call(inst.sock, "action.run", {"action": "quitKeepSessions"}, timeout=10)
    row["quit_reply"] = reply.get("error") or "ok"
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        row["quit_ms"] = None
        row["failures"] = ["the app did not end within 20 s of Quit and Keep Sessions"]
        process.kill()
        process.wait(timeout=10)
    gone = time.monotonic()
    row.setdefault("quit_ms", round((gone - asked) * 1000))
    # The daemon must have kept the terminal's process through the quit.
    try:
        os.kill(made["terminal_pid"], 0)
        row["terminal_alive_while_quit"] = True
    except OSError:
        row["terminal_alive_while_quit"] = False
    if os.path.exists(inst.sock):
        try:
            os.remove(inst.sock)  # the old app's socket file: only the relaunched app's counts
        except OSError:
            pass
    process, marks_read, _ = launch(app, env, out / "app-relaunched.log")
    row["pid_after"] = process.pid
    launched = time.monotonic()
    row["relaunch_ms"] = round((launched - asked) * 1000)
    deadline = launched + args.settle
    ok, now, why = False, None, "never polled"
    done = launched
    marks_text = b""
    # The app's own launch marks (ms since its process started, LaunchMarkSink), first of each, read as they come:
    # usable needs the launch settled (reveal.pane), and they say which wait the control socket sat behind.
    marks: dict[str, float] = {}

    def drain():
        nonlocal marks_text
        try:
            while chunk := os.read(marks_read, 1 << 16):
                marks_text += chunk
        except (BlockingIOError, OSError):
            pass
        whole, _, marks_text = marks_text.rpartition(b"\n")
        for line in whole.decode(errors="replace").splitlines():
            name, _, ms = line.rpartition(" ")
            try:
                marks.setdefault(name, round(float(ms)))
            except ValueError:
                pass
    timeline = row.setdefault("timeline", [])  # [ms since the quit, what still stops it], one entry per change
    while time.monotonic() < deadline and process.poll() is None:
        # Usable counts to the end of the poll that found it so: a field may only have matched during the poll's
        # own reads, so its start would undercount. ready_ms keeps the start as the lower bound.
        drain()
        polled = time.monotonic()
        ok, now, why = usable(inst, before, made["chat"], row["front_before"], which, marks)
        reason = why.split(" (")[0] if not ok else "usable"
        if not timeline or timeline[-1][1] != reason:
            timeline.append([round((polled - asked) * 1000), reason])
        if ok:
            done = time.monotonic()
            row["ready_ms"] = round((polled - asked) * 1000)
            break
        time.sleep(POLL_S)
    drain()
    os.close(marks_read)
    row["marks"] = marks
    row["front_after"] = front(inst.topology())
    row["usable"] = ok
    row["quit_to_usable_ms"] = round((done - asked) * 1000) if ok else None
    row["launch_to_usable_ms"] = round((done - launched) * 1000) if ok else None
    row["state_after"] = now if now is not None else state(inst)
    failures = row.setdefault("failures", [])
    if process.poll() is not None:
        failures.append(f"the relaunched app exited (status {process.poll()})")
    if not ok:
        failures.append(f"not usable within {args.settle:.0f} s of the relaunch: {why}")
    elif row["quit_to_usable_ms"] > args.budget_ms:
        failures.append(f"usable {row['quit_to_usable_ms']} ms after the quit, over the {args.budget_ms} ms budget")
    if not row["terminal_alive_while_quit"]:
        failures.append(f"the terminal's process {made['terminal_pid']} ended with the app")
    if ok and which == "chat":
        # After the budgeted time: the chat answers through the relaunched app's reattached session.
        row["live_ms"], why_not = live_turn(inst, made["chat"], n)
        if row["live_ms"] is None:
            failures.append(why_not)
        row["page_live_event"], detail = page_live_event(inst)
        if row["page_live_event"] is False:
            failures.append("the shown chat page reported no live event within 20 s (debug.agent_pane perf_stats)")
        elif detail:
            row["page_live_event_detail"] = detail
        # The next rounds compare against the chat with its new turn.
        after = state(inst)
        if "chat" in after:
            before["chat"] = after["chat"]
    print("L5-ROUND " + json.dumps(row, default=str), flush=True)
    return row, process


def check(args) -> int:
    import fresh_home_launch_smoke as smoke
    import stable_next_ui_journey as ui
    result: dict = {"rounds": [], "budget_ms": args.budget_ms}

    def journey(process, socket_path, env, app, out, report):
        out = Path(out) if out else Path(env["HOME"]).parent
        inst = Instance(str(socket_path), str(app), env["HOME"])
        try:
            made = seed(inst, args.fake_agent, os.path.join(env["HOME"], "l5-work"), front_terminal=False)
        except RuntimeError as error:
            result["seed_error"] = str(error)
            return [f"seed: {error}"]
        before = state(inst)
        result["before"] = before
        rows_before = list(inst.last_rows)
        missing = [k for k in KEYS if k not in before or (k == "workspaces" and before[k] < 2)
                   or (k == "chat" and before[k].endswith(":no-tab"))]
        if missing:
            return [f"seed: the state probe cannot read {', '.join(missing)} before the quit: {before}"]
        failures = []
        for n in range(1, args.rounds + 1):
            row, process = round_once(n, process, inst, Path(app), env, before, made, args, out)
            if any("scrollback_sha256" in f for f in row["failures"]) and args.out:
                # Both texts, so the change can be read (a size-dependent digest looks the same as a lost line).
                for name, rows in (("before", rows_before), (f"round{n}-after", inst.last_rows)):
                    Path(args.out, f"scrollback-{name}.txt").write_text("\n".join(rows) + "\n")
            result["rounds"].append(row)
            failures += [f"round {n}: {f}" for f in row["failures"]]
            if process.poll() is not None:
                break
        # The relaunched process is not the one the smoke started: end it here, through its own quit.
        call(inst.sock, "action.run", {"action": "quitEndEverything"}, timeout=10)
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        # The seeded process, by the pid it wrote: its command line does not name the run's root, so the smoke's
        # cleanup would not find it if the quit above left it.
        try:
            os.kill(made["terminal_pid"], 15)
        except OSError:
            pass
        return failures

    smoke.AFTER_RENDER = journey
    def prepare(env):
        ui.login_keychain(env)
        # Before the launch: the app's acpmux reads the harness folder when it starts, and on a NIGHTLY
        # `cmux harness reload` after the launch did not reach it ("unknown harness l5fake", nightly 4191131679101).
        write_harness(env["HOME"], args.fake_agent)

    smoke.PREPARE_HOME = prepare
    argv = ["--seconds", "1", *(["--dmg", args.dmg] if args.dmg else ["--app", args.app]), *(["--out", args.out] if args.out else [])]
    status = smoke.main(argv)
    times = [r["quit_to_usable_ms"] for r in result["rounds"] if isinstance(r.get("quit_to_usable_ms"), int)]
    result["quit_to_usable_ms_max"] = max(times) if times else None
    result["quit_to_usable_ms_p50"] = sorted(times)[len(times) // 2] if times else None
    passed = status == 0 and len(result["rounds"]) == args.rounds and all(not r["failures"] for r in result["rounds"])
    result["verdict"] = "pass" if passed else "fail"
    if args.out:
        with open(Path(args.out) / "l5.json", "w") as handle:
            json.dump(result, handle, indent=2, default=str)
    print("L5 " + json.dumps({k: result.get(k) for k in ("verdict", "quit_to_usable_ms_p50", "quit_to_usable_ms_max",
                                                          "budget_ms", "seed_error")}), flush=True)
    return 0 if passed else (status if status not in (0, None) else 1)


def main(argv: list[str] | None = None) -> int:
    import argparse
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] in (["seed"], ["state"]):
        sock, app = os.environ.get("CMUX_TRY_SOCKET"), os.environ.get("CMUX_TRY_APP")
        if not sock or not app:
            log("seed and state read the instance from CMUX_TRY_SOCKET and CMUX_TRY_APP")
            return 2
        home = os.environ.get("CMUX_TRY_HOME") or (process_home(os.environ["CMUX_TRY_PID"]) if os.environ.get("CMUX_TRY_PID") else None)
        if not home:
            log("cannot tell the instance's HOME: set CMUX_TRY_HOME or CMUX_TRY_PID")
            return 2
        inst = Instance(sock, app, home)
        if argv[0] == "state":
            print(json.dumps(state(inst)))
            return 0
        fake = os.environ.get("CMUX_TRY_FAKE_AGENT") or str(DEFAULT_FAKE_AGENT)
        try:
            seed(inst, fake, os.path.join(os.path.dirname(inst.record) or "/tmp", "l5-work"))
        except RuntimeError as error:
            log(f"seed: {error}")
            return 1
        return 0
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app")
    source.add_argument("--dmg")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--fronts", default="terminal,chat",
                        help="what each round leaves in front at the quit, cycled over the rounds: " + ", ".join(FRONTS))
    parser.add_argument("--budget-ms", type=int, default=3000)
    parser.add_argument("--settle", type=float, default=30.0, help="seconds a relaunch may take to become usable")
    parser.add_argument("--fake-agent", default=str(DEFAULT_FAKE_AGENT))
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    if args.rounds < 1:
        parser.error("--rounds must be at least 1")
    args.fronts = [f.strip() for f in args.fronts.split(",") if f.strip()]
    if not args.fronts or any(f not in FRONTS for f in args.fronts):
        parser.error(f"--fronts takes {', '.join(FRONTS)}")
    return check(args)


if __name__ == "__main__":
    sys.exit(main())
