#!/usr/bin/env python3
"""Main-thread time of a structural sidebar rebuild in the sidebar-document mode (bead cx-x5jpp).

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-mirror-rebuild-perf.py --label before --out "$NX_ARTIFACTS"
  scripts/cmux-next/sidebar-mirror-rebuild-perf.py --tag <tag> [--count 1000] [--rebuilds 20]   (a running tagged app)

Inside an nx-remote GUI job (NX_APP set) it launches $NX_APP with an empty config and quits it with
$NX_APP_STOP at the end; with --tag it attaches to a running tagged app and quits nothing. Never on
the laptop. It makes `--count` empty workspaces (`perf-NNNN`, the names
sidebar-rows-perf-live.py uses, so either script reuses the other's), then `--rebuilds` times
creates one workspace and closes it again. Each create and each close changes the live workspace
set, so the sidebar asks the Rust mirror for its rows again (one `view` FFI call) and lays out the
list again. Measured from `debug.sidebar_perf` (reset before the phase):

  mirror_ns   main-thread time in SidebarMirror.rows / .acceptance (request encode, Rust call, reply read)
  main_ns     main-thread time of the list layout paths
  rebuilds, list_reloads, and the mirror `view` calls (`debug.sidebar_rows` doc.ffi_calls)

It reports the time per `view` call and per rebuild. It fails when the build has no `mirror_ns`
counter, when the sidebar document mode is not active, or when no `view` call happened.
"""

import argparse, atexit, json, os, socket, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--rebuilds", type=int, default=20)
parser.add_argument("--label", default="run")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
if not opts.tag:
    sys.exit("--tag is required outside an nx-remote --app-from-fleet job")
APP, STOP = os.environ.get("NX_APP"), os.environ.get("NX_APP_STOP")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{opts.tag}.sock"
HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.environ.get("NX_APP_CLI") or os.path.join(HERE, "..", "cmux-debug-cli.sh")


def rpc(method, params=None, timeout=60):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli(*args, timeout=60):
    env = dict(os.environ, CMUX_TAG=opts.tag, CMUX_QUIET="1")
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout)


def rows():
    return rpc("debug.sidebar_rows", timeout=120) or {}


def titles():
    return {str(r.get("title")) for w in (rows().get("windows") or []) for r in (w.get("rows") or [])}


def view_calls():
    return int(((rows().get("doc") or {}).get("ffi_calls") or {}).get("view", 0))


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the sidebar to follow a CLI change
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    return predicate()


def launch():
    scratch = tempfile.mkdtemp(prefix="mirror-rebuild-")
    config, ghostty = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
    open(config, "w").write("{}")
    open(ghostty, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={config}", f"CMUX_NEXT_GHOSTTY_CONFIG={ghostty}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,720"]
    subprocess.run(["open", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    atexit.register(lambda: STOP and subprocess.run([STOP]))
    if not wait(lambda: os.path.exists(SOCKET) and (rows().get("doc") or {}).get("active"), 120):
        sys.exit(f"FAIL the tagged app did not come up with the sidebar document active ({rows().get('doc')})")


def main():
    if APP:
        launch()
    doc = rows().get("doc") or {}
    if "error" in rows() or not doc.get("active"):
        sys.exit(f"no tagged app with the sidebar document active on {SOCKET} ({doc})")
    have = titles()
    missing = [f"perf-{i:04d}" for i in range(opts.count) if f"perf-{i:04d}" not in have]
    with ThreadPoolExecutor(max_workers=8) as pool:
        bad = [r for r in pool.map(lambda n: cli("workspace", "create", "--empty", "--name", n), missing) if r.returncode]
    if bad:
        sys.exit(f"workspace create failed: {bad[0].stderr[-300:]}")
    listed = wait(lambda: sum(t.startswith("perf-") for t in titles()) >= opts.count, 300)
    if not listed:
        sys.exit("the sidebar does not list the perf workspaces")
    rpc("debug.sidebar_perf", {"reset": True})
    views_before = view_calls()
    close_errors = []
    for index in range(opts.rebuilds):
        name = f"rebuild-{index:03d}"
        made = cli("workspace", "create", "--empty", "--name", name, "--json")
        if made.returncode:
            sys.exit(f"create failed: {made.stderr[-300:]}")
        reply = json.loads(made.stdout or "{}")
        value = reply.get("value") or {}
        ws_id = value.get("workspace_id") or reply.get("workspace_id") or reply.get("id")
        wait(lambda: name in titles(), 15)
        if not ws_id:
            sys.exit(f"no workspace id in the create reply: {made.stdout[:300]}")
        # The close is a second rebuild when it lands; a refused close only leaves one more row.
        closed = cli("workspace", ws_id, "close")
        if closed.returncode == 0:
            wait(lambda: name not in titles(), 15)
        else:
            close_errors.append((closed.stdout + closed.stderr).strip()[-200:])
    counters = rpc("debug.sidebar_perf") or {}
    if "mirror_ns" not in counters:
        sys.exit(f"this build has no mirror_ns counter: {counters}")
    views = view_calls() - views_before
    summary = {
        "label": opts.label, "tag": opts.tag, "count": opts.count, "rebuild_cycles": opts.rebuilds,
        "view_calls": views, "rebuilds": counters.get("rebuilds"), "list_reloads": counters.get("list_reloads"),
        "mirror_ms_per_view": round(counters["mirror_ns"] / 1e6 / max(views, 1), 3),
        "main_ms_per_rebuild": round(counters.get("main_ns", 0) / 1e6 / max(counters.get("rebuilds") or 1, 1), 3),
        "close_errors": close_errors[:3],
        "mirror_ms_total": round(counters["mirror_ns"] / 1e6, 2), "main_ms_total": round(counters.get("main_ns", 0) / 1e6, 2),
    }
    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, f"mirror-rebuild-{opts.label}.json"), "w") as out:
        json.dump(summary, out, indent=2)
    print(json.dumps(summary), flush=True)
    if views == 0:
        sys.exit("FAIL no mirror view call during the rebuilds")
    print("ok", flush=True)


main()
