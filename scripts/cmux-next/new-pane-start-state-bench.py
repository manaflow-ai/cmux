#!/usr/bin/env python3
"""A new agent pane's start state: first frame to the frame where it stays (new-pane-start-state), and when its
composer takes a key (click_to_composer_ready_ms).

What a fresh New Tab page or new chat shows of its start (the folder chip's project, the hero's
project and its Do not work in a project check) should be final on its first frame: the app already
knows the folders. The page records the first start it drew and when it last changed
(webviews perf.ts `noteStartState`); `debug.agent_pane perf_stats` reads it as
`agent.start_state_final_ms` (0: the first frame was final) and `agent.start_state_changes`.

Launches the tagged app (no activation, scratch config) and sets up the case a person hits: a workspace
whose project root is a git repository (a terminal tab there) and a focused terminal at the home folder,
so the New Tab page has no folder of its own and its chat starts in the workspace's project. Then per arm
it times `--runs` openings from that home-folder terminal:
  fresh      Cmd-T with no prewarmed spare (`debug.new_tab capacity 0`): the page loads and handshakes
  spare      Cmd-T adopting a loaded spare (capacity 1, a ready spare waited for)
  busy       Cmd-T with no spare while the Mac is loaded: every core busy with `yes` and `--storm` loops
             of the tag's CLI against its daemon.
With `busy` among the arms, `--busy-chats` agent tabs stay open in another workspace for every arm (each
a page with its own acpmux connection). Fleet Macs have no agent login, so those chats are idle
connections, not running turns.
Each opening waits for its page's handshake, then `--settle` seconds, and reads the page's marks:
`start_state_final_ms` (the page's first frame to its final start), and `click_to_final_ms` (the key press
to the frame whose start stayed, both on this Mac's wall clock), with the start it shows
(`start_state_shown`). The tab closes before the next.

`--command new_chat` opens New Agent Chat (`palette.newAgentChat`, the action the sidebar's New Agent Chat, the File
menu and the dock menu run) instead of Cmd-T's New Tab page, and times its composer as a person reaches it, from the
press on this Mac's wall clock (Leo, 2026-11-22: "i hope we're still pursuing startup times for the app itself aka
percieved time and percieved interactive time as well as general cloud startup time for any and every path we have"):
  composer_field_ms           the chat's composer field (`.acpmux-composer [contenteditable="true"]`) exists;
  composer_focused_ms         it has the page's caret;
  click_to_composer_ready_ms  a key typed then (`debug.key` with no target: where a person's key goes) echoed in it,
                              read back from the field's text. A key that did not echo within `--echo-wait` is deleted
                              if it landed late and typed again (`composer_key_attempts`), so the mark is the first
                              read of an echo, never a key typed before the field could take it.
The marks are polled over the control socket (a read is a few ms), so each is an upper bound by about one read. The
typed key is deleted before the tab closes, so no draft is left. `--runs` is per arm (10 by default); the JSON report
keeps every round (`runs`) and, per arm, each field's rounds in `summary[arm].rounds` with p50, p95 and max.

Usage: new-pane-start-state-bench.py --tag TAG --app PATH [--runs 10] [--arms fresh,spare,busy] [--command new_tab|new_chat]
       [--json FILE]
Fleet: cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/instant-new-surfaces.sh
       --ref SHA --arg=--bench=new-pane-start-state --artifact artifacts/instant-new-surfaces.json [--arg=--runs=8]
       (instant-new-surfaces-bench.py hands `--bench=new-pane-start-state` to this script)
"""
import argparse, glob, json, os, shutil, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402
from state_wait import wait_stable, wait_until  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=10)
parser.add_argument("--arms", default="fresh,spare,busy")
parser.add_argument("--busy-chats", type=int, default=6)
parser.add_argument("--storm", type=int, default=6)
parser.add_argument("--settle", type=float, default=1.5, help="seconds after the handshake before the marks are read")
parser.add_argument("--command", choices=("new_tab", "new_chat"), default="new_tab",
                    help="new_tab: Cmd-T's New Tab page; new_chat: New Agent Chat, with its composer timed to a typed key's echo")
parser.add_argument("--echo-wait", type=float, default=1.0, help="seconds a typed probe key may take to echo before it is typed again")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix=f"startstate-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
LAUNCHED, LOAD = [], []
app = None
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_QUIET": "1", "CMUX_TAG": TAG, "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
# The workspace's project: a git repository below the home folder (canonical, so the store names it as is).
PROJECT = os.path.join(os.environ["HOME"], f"cmux-start-state-bench-{TAG}", "app")


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def panes():
    return [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]


def focused():
    return next((p for p in panes() if p.get("focused")), None)


def window_key():
    return ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")


def tab_cwds():
    """Every tab's folder in the app's published topology (snapshot.get)."""
    topology = (rpc("snapshot.get") or {}).get("topology") or {}
    return {os.path.realpath(tab["cwd"]) for ws in topology.get("workspaces") or [] for screen in ws.get("screens") or []
            for pane in screen.get("panes") or [] for tab in pane.get("tabs") or [] if tab.get("cwd")}


def wait_cwd(folder):
    """Until a terminal's shell is in `folder` (its tab reports it), best effort as the old fixed wait was."""
    if not wait_until(lambda: os.path.realpath(folder) in tab_cwds(), f"a tab in {folder}", timeout=15, raise_on_timeout=False):
        print(f"setup: no tab reported {folder} after 15 s; going on", flush=True)


def settle_panes(what):
    """Until the panes the next step reads stop changing."""
    wait_stable(lambda: json.dumps(panes(), sort_keys=True), what, timeout=10, interval=0.1, raise_on_timeout=False)


def make_project():
    os.makedirs(PROJECT, exist_ok=True)
    subprocess.run(["git", "init", "-q", PROJECT], capture_output=True, timeout=30)
    open(os.path.join(PROJECT, "README.md"), "w").write("start-state bench\n")


def setup_workspace():
    """A workspace with a terminal in PROJECT and, focused beside it, a terminal at the home folder."""
    rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "start-state-bench", "cwd": PROJECT}, "wait": True})
    wait(lambda: (focused() or {}).get("kind") == "terminal", 30, step=0.25)
    wait_cwd(PROJECT)
    rpc("action.run", {"action": "splitRight", "args": {"cwd": os.environ["HOME"]}, "wait": True})
    ok = wait(lambda: len(panes()) >= 2 and (focused() or {}).get("kind") == "terminal", 30, step=0.25)
    wait_cwd(os.environ["HOME"])
    print(f"setup: panes={json.dumps(panes())[:600]}", flush=True)
    return ok


def ensure_terminal():
    return (focused() or {}).get("kind") == "terminal" or wait(lambda: (focused() or {}).get("kind") == "terminal", 10)


def open_busy_chats():
    """`--busy-chats` agent tabs in a workspace of their own, each a page with its own acpmux connection;
    made first, so the bench workspace made after it is the shown one."""
    rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "busy-chats", "cwd": PROJECT}, "wait": True})
    wait(lambda: (focused() or {}).get("kind") == "terminal", 30, step=0.25)
    rpc("debug.new_tab", {"action": "capacity", "count": 0})
    for _ in range(opts.busy_chats):
        rpc("debug.new_tab", {"action": "bench_create", "command": "new_tab"}, timeout=20)
        # The page loaded and connected to acpmux: its handshake mark is in (the load it adds is best effort).
        wait_until(lambda: "handshakeReady_ms" in agent_marks(), "a busy chat's handshake", timeout=20, interval=0.1, raise_on_timeout=False)


def start_load():
    """Every core busy and a CLI storm against the daemon (the busy arm)."""
    for _ in range(os.cpu_count() or 8):
        LOAD.append(subprocess.Popen(["yes"], stdout=subprocess.DEVNULL))
    loop = f'while :; do "{CLI}" workspace list >/dev/null 2>&1; "{CLI}" tree >/dev/null 2>&1; done'
    for _ in range(opts.storm):
        LOAD.append(subprocess.Popen(["/bin/sh", "-c", loop], env=CLI_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    # The load is on: every `yes` alive and every storm loop running a CLI call.
    def loaded():
        if any(proc.poll() is not None for proc in LOAD):
            return False
        loops = LOAD[-opts.storm:] if opts.storm else []
        return all(subprocess.run(["pgrep", "-P", str(proc.pid)], capture_output=True).returncode == 0 for proc in loops)
    if not wait_until(loaded, "the busy load (yes and the CLI storm) running", timeout=15, interval=0.1, raise_on_timeout=False):
        print("busy: the load did not all come up in 15 s; going on", flush=True)


def stop_load():
    for proc in LOAD:
        try:
            proc.terminate()
        except OSError:
            pass
    LOAD.clear()


def agent_marks():
    stats = rpc("debug.agent_pane", {"action": "perf_stats"}, timeout=20) or {}
    if not isinstance(stats.get("agent"), dict):
        return {"error": stats.get("error")}
    return {**stats["agent"], "start_state_shown": stats.get("start_state_shown")}


# The chat's composer field (ProseMirror's editable root inside the composer), and the key typed into it.
COMPOSER_FIELD = '.acpmux-composer [contenteditable="true"]'
PROBE_KEY = "q"


def composer_text():
    """The focused chat's composer text, or None while the pane shows no composer field."""
    reply = rpc("debug.agent_pane", {"action": "query", "selector": COMPOSER_FIELD}, timeout=10) or {}
    elements = reply.get("elements")
    if not isinstance(elements, list) or not elements:
        return None
    return "".join(str(e.get("text", "")) for e in elements if isinstance(e, dict))


def since(pressed):
    return round(time.time() * 1000 - pressed, 1)


def clear_probe_keys(base):
    """Deletes the probe keys this run typed (the field back to `base` of them), so no draft is left."""
    for _ in range(8):
        text = composer_text()
        if text is None or text.count(PROBE_KEY) <= base:
            return
        rpc("debug.key", {"key": "delete", "modifiers": []})
        wait(lambda: (composer_text() or "").count(PROBE_KEY) < text.count(PROBE_KEY), 1, 0.02)


def composer_ready(pressed, seconds=20):
    """From the press: the composer field exists, has the caret, and a typed key echoes in it (module docstring)."""
    out, base = {"composer_key_attempts": 0}, None
    deadline = time.time() + seconds
    while time.time() < deadline:
        text = composer_text()
        if text is None:
            time.sleep(0.005)  # test harness polling a live app
            continue
        out.setdefault("composer_field_ms", since(pressed))
        base = text.count(PROBE_KEY) if base is None else base
        if "composer_focused_ms" not in out and (rpc("debug.agent_pane", {"action": "composer_focused"}, timeout=10) or {}).get("focused"):
            out["composer_focused_ms"] = since(pressed)
        out["composer_key_attempts"] += 1
        typed = rpc("debug.key", {"key": PROBE_KEY, "modifiers": []}) or {}
        if typed.get("error"):
            out["composer_key_error"] = str(typed["error"])[:200]
        echo_by = min(time.time() + opts.echo_wait, deadline)
        while time.time() < echo_by:
            now = composer_text()
            if now is not None and now.count(PROBE_KEY) > base:
                out["click_to_composer_ready_ms"] = since(pressed)
                clear_probe_keys(base)
                return out
            time.sleep(0.005)  # test harness polling a live app
        clear_probe_keys(base)  # a key that landed after its wait: gone before the next
    out["composer_error"] = ("no composer field" if base is None else "no typed key echoed") + f" within {seconds} s"
    if base is not None:
        clear_probe_keys(base)
    return out


def one(arm, index, window):
    if not ensure_terminal():
        return {"arm": arm, "run": index, "error": "no focused terminal"}
    before = len(panes())
    if arm == "spare":
        rpc("debug.new_tab", {"action": "capacity", "count": 1})
        wait(lambda: [s for s in (rpc("debug.new_tab", {"action": "state"}) or {}).get("spares", []) if s.get("ready")], 20, 0.25)
    else:
        rpc("debug.new_tab", {"action": "capacity", "count": 0})
    command = "new_workspace" if arm == "workspace" else "new_tab"
    pressed = time.time() * 1000
    composer = {}
    if opts.command == "new_chat":
        # New Agent Chat as the sidebar item and the menu run it; the control socket may not name the user as origin.
        created = rpc("action.run", {"action": "palette.newAgentChat", "focus": True}, timeout=20) or {}
        created = {"error": created.get("error")} if isinstance(created, dict) and created.get("error") else {}
        composer = composer_ready(pressed)
    else:
        created = rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=20) or {}
    marks = wait(lambda: (lambda m: m if "handshakeReady_ms" in m and "start_state_final_ms" in m else None)(agent_marks()), 20, 0.1)
    # sleep-ok: --settle is the observation window for a start that changes late (after the handshake, when the
    # daemon's lists arrive); "nothing more will change" has no signal, the bench measures whether one comes.
    time.sleep(opts.settle)
    marks = agent_marks() if marks else {"error": "no handshake or start mark"}
    row = {"arm": arm, "run": index, "command": opts.command, "visible_ms": created.get("visible_ms"), **marks, **composer}
    if isinstance(row.get("start_state_final_epoch_ms"), (int, float)):
        row["click_to_final_ms"] = round(row["start_state_final_epoch_ms"] - pressed, 1)
    shown = (row.get("start_state_shown") or "").replace(os.environ["HOME"], "~")
    row["start_state_shown"] = shown
    print(f"{arm} #{index}: start_state_final_ms={row.get('start_state_final_ms')} click_to_final_ms={row.get('click_to_final_ms')} "
          f"shown={shown!r} changes={row.get('start_state_changes')} "
          f"handshakeReady_ms={row.get('handshakeReady_ms')} click_to_composer_ready_ms={row.get('click_to_composer_ready_ms')} "
          f"keys={row.get('composer_key_attempts')} err={row.get('error') or created.get('error') or row.get('composer_error')}", flush=True)
    if arm == "workspace":
        rpc("action.run", {"action": "closeWorkspace"})
    else:
        rpc("debug.key", {"key": "w", "modifiers": ["command"], "window": window})
        wait(lambda: len(panes()) <= before, 10)
    wait(lambda: (focused() or {}).get("kind") == "terminal", 10)
    settle_panes("the panes after the tab closed")
    return row


# Every round of these fields is kept per arm (summary[arm].rounds), with its p50, p95 and max.
ROUND_FIELDS = ("click_to_composer_ready_ms", "click_to_final_ms", "composer_field_ms", "composer_focused_ms",
                "start_state_final_ms", "handshakeReady_ms")


def percentile(values, q):
    """Nearest-rank percentile (q in 0..100) of a non-empty list."""
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, -(-q * len(ordered) // 100) - 1))]


def rounds(rows, arm):
    """Each ROUND_FIELDS field's value in every round of `arm` (in run order, a missed round left out)."""
    out = {}
    for field in ROUND_FIELDS:
        values = [r[field] for r in rows if r["arm"] == arm and isinstance(r.get(field), (int, float)) and not isinstance(r.get(field), bool)]
        if values:
            out[field] = {"values": values, "p50": round(statistics.median(values), 1), "p95": round(percentile(values, 95), 1),
                          "max": round(max(values), 1)}
    return out


def summary(rows):
    out = {}
    for arm in sorted({r["arm"] for r in rows}):
        values = [r["start_state_final_ms"] for r in rows if r["arm"] == arm and isinstance(r.get("start_state_final_ms"), (int, float))]
        changed = [r.get("start_state_changes") or 0 for r in rows if r["arm"] == arm and "start_state_final_ms" in r]
        clicks = [r["click_to_final_ms"] for r in rows if r["arm"] == arm and isinstance(r.get("click_to_final_ms"), (int, float))]
        handshake = [r["handshakeReady_ms"] for r in rows if r["arm"] == arm and isinstance(r.get("handshakeReady_ms"), (int, float))]
        out[arm] = {
            "runs": len(values),
            "missed": sum(1 for r in rows if r["arm"] == arm) - len(values),
            "start_state_final_ms_p50": round(statistics.median(values), 1) if values else None,
            "start_state_final_ms_max": round(max(values), 1) if values else None,
            "runs_changed_after_first_frame": sum(1 for c in changed if c),
            "click_to_final_ms_p50": round(statistics.median(clicks), 1) if clicks else None,
            "click_to_final_ms_max": round(max(clicks), 1) if clicks else None,
            "shown": sorted({r.get("start_state_shown") or "" for r in rows if r["arm"] == arm}),
            "handshake_ready_ms_p50": round(statistics.median(handshake), 1) if handshake else None,
            "composer_missed": sum(1 for r in rows if r["arm"] == arm and r.get("command") == "new_chat" and "click_to_composer_ready_ms" not in r),
            "rounds": rounds(rows, arm),
        }
    return out


def cleanup():
    stop_load()
    # Only the folder this bench made.
    shutil.rmtree(os.path.dirname(PROJECT), ignore_errors=True)
    if not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    CLI_ENV["CMUX_SOCKET_PATH"] = SOCKET
    window = wait_until(window_key, "the app's first window", timeout=30)
    settle_panes("the first window's panes")
    make_project()
    arms = [a for a in opts.arms.split(",") if a]
    if "busy" in arms:
        open_busy_chats()
    if not setup_workspace():
        sys.exit("no project workspace: " + json.dumps(panes())[:800])
    rows = []
    for arm in arms:
        if arm == "busy":
            start_load()
        for index in range(opts.runs):
            rows.append(one(arm, index, window))
    result = {"tag": TAG, "host": os.uname().nodename, "command": opts.command, "summary": summary(rows), "runs": rows}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    for arm, value in result["summary"].items():
        print(f"HEADLINE new-pane-start-state/{arm} start_state_final_ms p50={value['start_state_final_ms_p50']} "
              f"max={value['start_state_final_ms_max']} changed={value['runs_changed_after_first_frame']}/{value['runs']} "
              f"click_to_final_ms p50={value['click_to_final_ms_p50']} max={value['click_to_final_ms_max']} "
              f"shown={value['shown']}", flush=True)
        ready = value["rounds"].get("click_to_composer_ready_ms")
        if opts.command == "new_chat":
            print(f"HEADLINE new-chat/{arm} click_to_composer_ready_ms p50={ready and ready['p50']} p95={ready and ready['p95']} "
                  f"max={ready and ready['max']} missed={value['composer_missed']}/{opts.runs}", flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
