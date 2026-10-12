#!/usr/bin/env python3
"""Live check: every way of opening the agent pane's model picker ends with the keyboard in its
search field (Lawrence 2026-10-09: "after cmd ctrl m we need to be focused in the 'type to search
models' area"). GUI host only (cmux-lawrence-2), under nx-remote; never on a laptop.

It downloads the fleet build of `--job`, starts it with its own tag and ACPMUX_HOME, opens an agent
chat, and for each opener (Cmd-Ctrl-M through debug.key, the palette action agentPane.switchModel, automation open_menu "Model") reads the
page's focused element (chat_state.focus) after the menu opens. On exit the tag's daemons stop
(tag_teardown.py); only this job's own app copy is stopped, by exact PID.

Usage: model-picker-focus-live.py --job <cmux-ci job id> --tag <the build's tag>"""
import argparse, glob, json, os, plistlib, re, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
opts = parser.parse_args()
OUT = os.environ.get("NX_ARTIFACTS") or "/tmp/model-picker-focus"
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                   env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None) or sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

TAG = opts.tag
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
HOME_ACP = os.path.join(OUT, "acpmux-home")
ACP_SOCKET = f"/tmp/mpf-acp-{os.getpid()}.sock"


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def pane(action, **params):
    result = rpc("debug.agent_pane", dict({k: v for k, v in params.items() if v is not None}, action=action), timeout=40)
    if isinstance(result, dict) and isinstance(result.get("result"), str):
        try:
            result["result"] = json.loads(result["result"])
        except ValueError:
            pass
    return result


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def chat_state():
    state = pane("chat_state")
    if isinstance(state, dict) and isinstance(state.get("result"), dict):
        state = state["result"]
    return state if isinstance(state, dict) and "focus" in state else None


def focus():
    state = chat_state()
    return state["focus"] if state else None


state_dir = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")
if os.path.isdir(state_dir) and not os.path.islink(state_dir):
    os.rename(state_dir, state_dir + ".old-" + str(int(time.time())))
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
os.makedirs(HOME_ACP, exist_ok=True)
config = os.path.join(OUT, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = dict(os.environ, CMUX_NEXT_NO_ACTIVATE="1", CMUX_NEXT_SOCKET_MODE="automation", CMUX_NEXT_TEST_WINDOW_SCREEN="last",
           CMUX_NEXT_CONFIG_FILE=config, CMUX_NEXT_TEST_WINDOW_FRAME="40,40,1200,800", ACPMUX_HOME=HOME_ACP, ACPMUX_SOCKET=ACP_SOCKET)
teardown = TagTeardown(APP, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
teardown.install()
app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT,
                       stdin=subprocess.DEVNULL)
say("app pid", app.pid)
report = {}
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("the app did not come up")
    def panes_now():
        return {p for p in re.findall(r"pane_[A-Za-z0-9_-]+", json.dumps(rpc("snapshot.get"))) if p != "pane_chrome"}

    before = panes_now()
    say("new workspace", json.dumps(rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}))[:200])
    fresh = wait(lambda: sorted(panes_now() - before) or None, 30, 0.5) or sorted(panes_now())
    say("panes", fresh)
    opened = rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
    if isinstance(opened, dict) and "error" in opened:
        # The focused pane's controller key (snapshot ids are not always the controller's key).
        time.sleep(1.5)
        focused = rpc("debug.focus")
        say("debug.focus", json.dumps(focused)[:400])
        keys = re.findall(r'"pane": "([^"]+)"', json.dumps(focused))
        if keys:
            opened = rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{keys[0]}", "focus": True})
    say("new agent chat", json.dumps(opened)[:300])
    if not wait(chat_state, 60, 0.5):
        sys.exit("no agent pane: " + json.dumps(pane("chat_state"))[:300])
    wait(lambda: focus() == "composer", 15)
    say("focus before any opener:", focus())

    def closed():
        rpc("debug.key", {"key": "Escape", "modifiers": []})
        rpc("debug.key", {"key": "Escape", "modifiers": []})
        time.sleep(0.4)

    # 1. Cmd-Ctrl-M with the prompt focused, through the app's real key path.
    key = rpc("debug.key", {"key": "m", "modifiers": ["cmd", "control"]})
    say("debug.key cmd+ctrl+m:", json.dumps(key)[:400])
    time.sleep(0.8)
    report["cmd_ctrl_m"] = {"key": key, "focus": focus()}
    say("after Cmd-Ctrl-M focus:", report["cmd_ctrl_m"]["focus"])
    closed()
    # 2. The palette's Switch Model… (agentPane.switchModel; absent on builds without it).
    ran = rpc("action.run", {"action": "agentPane.switchModel", "focus": True})
    time.sleep(0.8)
    report["palette_switch_model"] = {"result": ran, "focus": focus()}
    say("after action.run agentPane.switchModel:", json.dumps(ran)[:160], "focus:", report["palette_switch_model"]["focus"])
    closed()
    # 2. Automation opens the menu by its label, as a click does.
    menu = pane("open_menu", label="Model")
    time.sleep(0.8)
    report["open_menu"] = {"result": menu, "focus": focus()}
    say("after open_menu Model focus:", report["open_menu"]["focus"])
    closed()
    say("focus after closing:", focus())
finally:
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)
    teardown.end()
    try:
        app.terminate()
        app.wait(timeout=20)
    except Exception:  # noqa: BLE001 - the teardown also stops it by PID
        pass
