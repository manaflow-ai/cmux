#!/usr/bin/env python3
"""Preflight of the Chief memory inspector (cmux-lawrence-2 only;
plans/cmux-next/optchat-inspector.md). On a scratch Chief home:

  1. seed the memory with short notes (`optchat-chief import`, host stopped),
     so the view has cache marks without compactor calls;
  2. launch the tagged app (never activated) and wait for the brain host's
     optchat/inspector.json;
  3. send the Chief one message and wait for the turn to end in the trace;
  4. open the inspector from the command palette (Cmd-Shift-P, "Memory
     Inspector", Return) and find its browser tab;
  5. drive the page through the app's browser automation: the turn's prompt
     with cache marks, then three zoom hops down to one message;
  6. check the API directly (token, ticket, read-only methods).

Evidence (JSON, page snapshots, window snapshots) goes to --out. Only the app
this script started and the processes that run for its scratch Chief home
are stopped (by pid).

Usage: chief-inspector-preflight.py --app APP --tag TAG [--out DIR]
"""
import argparse, json, os, signal, socket, subprocess, tempfile, time, urllib.parse, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--app", required=True)
ap.add_argument("--tag", required=True)
ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "chief-inspector-preflight"))
ap.add_argument("--reply-wait", type=int, default=300)
opts = ap.parse_args()
os.makedirs(opts.out, exist_ok=True)
TAG, APP = opts.tag, opts.app
SOCK = f"/tmp/cmux-debug-{TAG}.sock"
CHIEF = os.path.join(opts.out, "chief-home-%d" % int(time.time()))
CHIEF_BIN = os.path.join(APP, "Contents/Resources/bin/optchat-chief")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SCRATCH = tempfile.mkdtemp(prefix="chinsp-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
report = {"tag": TAG, "chief_home": CHIEF, "steps": []}


def note(step, **fields):
    entry = {"step": step, **fields}
    report["steps"].append(entry)
    print(json.dumps(entry)[:600], flush=True)


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(SOCK)
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


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update({"CMUX_SOCKET_PATH": SOCK, "CMUX_TAG": TAG})
    run = subprocess.run([CLI, *args], env=env, capture_output=True, text=True, timeout=60)
    return run.stdout.strip() or run.stderr.strip()


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def snapshot(name):
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")})


def api(endpoint, path):
    req = urllib.request.Request(endpoint["url"].rstrip("/") + path, headers={"Authorization": "Bearer " + endpoint["token"]})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def seed():
    notes = os.path.join(SCRATCH, "notes.jsonl")
    with open(notes, "w") as f:
        for k in range(320):
            topic = ["build fleet", "inspector", "zoom path", "cache marks", "settle wait"][k % 5]
            text = f"preflight note {k}: Lawrence asked about the {topic}; the answer named a file, a decision and a next step. " + "detail " * 12
            f.write(json.dumps({"text": text[:200], "kind": "note"}) + "\n")
    run = subprocess.run([CHIEF_BIN, "import", "--mux-home", CHIEF, notes], capture_output=True, text=True, timeout=300)
    note("seed", out=run.stdout.strip(), err=run.stderr.strip()[-400:], code=run.returncode)


def launch():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,1000",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_HOME": CHIEF}
    binary = os.path.join(APP, "Contents/MacOS", "cmux DEV")
    log = open(os.path.join(opts.out, "app.log"), "a")
    proc = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    note("launch", pid=proc.pid)
    return proc


def chief_row(home):
    rows = [c for c in (home or {}).get("conversations", []) if "agent_mux" in c.get("participants", [])]
    return rows[0] if rows else None


def turn_ended():
    traces = os.path.join(CHIEF, "optchat", "traces")
    for name in sorted(os.listdir(traces)) if os.path.isdir(traces) else []:
        for line in open(os.path.join(traces, name)):
            if '"ev":"turn.end"' in line:
                return json.loads(line)
    return None


def browser_tab():
    try:
        tabs = json.loads(cli("--json", "tab", "list"))
    except ValueError:
        return None
    found = []

    def walk(v):
        if isinstance(v, dict):
            if v.get("content_kind") == "browser" and "127.0.0.1" in json.dumps(v):
                found.append(v)
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(tabs)
    return found[0] if found else None


def page(tab, name, *args):
    out = cli("browser", tab, *args)
    open(os.path.join(opts.out, f"{name}.txt"), "w").write(out)
    return out


def stop(proc):
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()


def stop_chief_processes():
    lock = os.path.join(CHIEF, "state", "host.lock")
    try:
        pid = int(open(lock).read().split()[0])
        os.kill(pid, signal.SIGTERM)
        note("stopped host", pid=pid)
    except (OSError, ValueError, IndexError):
        pass
    sock = os.path.join(CHIEF, "acpmux", "acpmux.sock")
    for pid in sorted(set(subprocess.run(["lsof", "-t", sock], capture_output=True, text=True).stdout.split())):
        try:
            os.kill(int(pid), signal.SIGTERM)
            note("stopped acpmux", pid=int(pid))
        except OSError:
            pass


proc = None
try:
    seed()
    proc = launch()
    info = os.path.join(CHIEF, "optchat", "inspector.json")
    endpoint = wait(lambda: os.path.exists(info) and json.load(open(info)), 180, 1)
    note("inspector.json", present=bool(endpoint), url=(endpoint or {}).get("url"))
    ready = wait(lambda: (chief_row(rpc("debug.home")) or {}).get("id"), 180, 1)
    note("home ready", ok=bool(ready))
    text = "inspector preflight: please answer in one short sentence."
    note("send", drive=[rpc("debug.home.drive", {"action": a, **({"text": text} if a == "type" else {})}) for a in ("focus", "type", "send")])
    ended = wait(turn_ended, opts.reply_wait, 2)
    note("turn", ended=bool(ended), status=(ended or {}).get("status"), harness=(ended or {}).get("harness"))
    snapshot("01-home")
    # The palette path: Cmd-Shift-P, the query, Return.
    keys = [rpc("debug.key", {"key": "p", "modifiers": ["command", "shift"]})]
    for ch in "memory inspector":
        keys.append(rpc("debug.key", {"key": ch, "target": "palette"}))
    snapshot("02-palette")
    keys.append(rpc("debug.key", {"key": "return", "target": "palette"}))
    tab = wait(browser_tab, 30, 1)
    if not tab:
        note("palette did not open the tab; running the action directly", keys=keys[:2])
        rpc("action.run", {"id": "chief.openMemoryInspector"})
        tab = wait(browser_tab, 30, 1)
    tab_id = (tab or {}).get("id")
    note("inspector tab", tab=tab_id, pane=(tab or {}).get("pane_id"))
    time.sleep(3)
    snapshot("03-inspector-column")
    if tab_id:
        state = page(tab_id, "page-state", "state")
        body = page(tab_id, "page-prompt", "text", "body")
        note("prompt tab", state=state[:200], has_marks="cache mark" in body or "end of the system prompt" in body,
             exact="Exact bytes" in body)
        # Pick the turn, then zoom three hops from its oldest merged line.
        api_turns = api(endpoint, "/api/turns")["turns"]
        if api_turns:
            key = api_turns[-1]["turn"]
            cli("browser", tab_id, "eval", f"(() => {{ const s = document.querySelector('select'); s.value = {json.dumps(key)}; s.dispatchEvent(new Event('change', {{bubbles: true}})); return s.value; }})()")
            time.sleep(2)
            body = page(tab_id, "page-turn", "text", "body")
            note("turn prompt", key=key, has_marks="cache mark" in body or "end of the system prompt" in body,
                 exact="Exact bytes" in body, marker="our cache marker" in body)
        hops = []
        first = cli("browser", tab_id, "eval", "(() => { const b = [...document.querySelectorAll('.lines .name')].find(x => /\\+(8|16|32|64|128|256)$/.test(x.textContent)) || document.querySelector('.lines .name'); b.click(); return b.textContent; })()")
        hops.append(first)
        for _ in range(3):
            time.sleep(1.5)
            hops.append(cli("browser", tab_id, "eval", "(() => { const b = [...document.querySelectorAll('.kids button')][0]; if (!b) return 'no child'; b.click(); return b.title; })()"))
        time.sleep(1.5)
        tree = page(tab_id, "page-tree", "text", "body")
        crumbs = cli("browser", tab_id, "eval", "[...document.querySelectorAll('.crumbs button, .crumbs b')].map(x => x.textContent).join(' > ')")
        note("zoom hops", hops=hops, crumbs=crumbs, agent_view="What the agent gets from zoom(" in tree)
        page(tab_id, "page-snapshot", "snapshot", "--interactive")
    if endpoint:
        status = api(endpoint, "/api/status")
        json.dump(status, open(os.path.join(opts.out, "api-status.json"), "w"), indent=2)
        turns = api(endpoint, "/api/turns")
        json.dump(turns, open(os.path.join(opts.out, "api-turns.json"), "w"), indent=2)
        if turns["turns"]:
            one = api(endpoint, "/api/turn?key=" + urllib.parse.quote(turns["turns"][-1]["turn"]))
            json.dump(one, open(os.path.join(opts.out, "api-turn.json"), "w"), indent=2)
            note("api turn", exact=one.get("exact"), layout=one.get("layout"), lines=len(one.get("lines") or []),
                 marks=(one.get("view") or {}).get("marks"))
        note("api status", messages=status["messages"], view_lines=status["view_lines"], settled=status["settled"])
finally:
    stop(proc)
    stop_chief_processes()
    json.dump(report, open(os.path.join(opts.out, "report.json"), "w"), indent=2)
    print("evidence:", opts.out, flush=True)
