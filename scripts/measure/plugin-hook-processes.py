#!/usr/bin/env python3
"""Count helper launches and check handoffs through the installed plugin callbacks.

python3 scripts/measure/plugin-hook-processes.py --base REF --events 256
The journal peer records every launch, event and retry identity. A second run
forces an older helper, and a third loses an acknowledgement after accepting
the first event. No installed plugin, user config or running daemon is touched.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ASSETS = Path("cmux-tui/crates/cmux-tui-hooks/assets/agent-hooks")
PEER = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
out = Path(os.environ["RESULTS"])
def log(name, data):
    with (out / name).open("a") as f:
        f.write(json.dumps(data) + "\\n")
log("processes", sys.argv[1:])
mode = os.environ["PEER_MODE"]
if sys.argv[1].startswith("--plugin-stream="):
    if mode == "old":
        sys.exit(2)
    print("ready", flush=True)
    for line in sys.stdin:
        key, event, native = json.loads(line)
        log("events", [key, native])
        if mode == "lose-ack" and not (out / "crashed").exists():
            (out / "crashed").touch()
            sys.exit(1)
        print("ok", flush=True)
else:
    log("events", [os.environ.get("CMUX_TUI_PLUGIN_EVENT"), json.load(sys.stdin)])
'''
NODE = '''
import plugin from "./plugin.mjs";
const hooks = await plugin({directory: "/tmp"});
for (let n = 0; n < Number(process.env.EVENT_COUNT); ++n) {
  await hooks.event({ event: { type: "tool.execute.after", properties: { n } } });
}
'''
HERMES = '''
import os
from plugin import register
class Provider:
    def __init__(self): self.hooks = {}
    def register_hook(self, name, fn): self.hooks[name] = fn
p = Provider()
register(p)
for n in range(int(os.environ["EVENT_COUNT"])-1):
    p.hooks["post_tool_call"](n=n)
p.hooks["on_session_finalize"](n=n+1)
'''


def source(path, ref):
    if ref:
        if os.environ.get("BASE_OPENCODE_B64") and path == "opencode.js":
            return base64.b64decode(os.environ["BASE_OPENCODE_B64"], validate=True).decode()
        return subprocess.check_output(["git", "show", f"{ref}:{ASSETS / path}"], text=True)
    return (ASSETS / path).read_text()


def measure(provider, mode, count, ref=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        helper = root / "helper"
        helper.write_text(PEER)
        helper.chmod(0o700)
        env = dict(os.environ, RESULTS=directory, PEER_MODE=mode, EVENT_COUNT=str(count),
                   CMUX_TUI_HOOK=str(helper), CMUX_TUI_SOCKET=str(root / "session.sock"),
                   CMUX_TUI_TERMINAL_ID="term_00000000000000000000000000000001")
        if provider == "opencode":
            plugin = source("opencode.js", ref)
            if "journalPlugin(" in plugin:
                plugin = source("plugin-stream.js", ref) + "\n" + plugin
            (root / "plugin.mjs").write_text(plugin)
            (root / "driver.mjs").write_text(NODE)
            cmd = ["node", "driver.mjs"]
        else:
            (root / "plugin.py").write_text(source("hermes.py", ref))
            (root / "driver.py").write_text(HERMES)
            cmd = [sys.executable, "driver.py"]
        started = time.monotonic()
        subprocess.run(cmd, cwd=root, env=env, check=True, timeout=120)
        elapsed = time.monotonic() - started
        launches = (root / "processes").read_text().splitlines()
        rows = [json.loads(line) for line in (root / "events").read_text().splitlines()]
        ids = [r[1]["event"]["properties"]["n"] if provider == "opencode" else r[1]["n"]
               for r in rows]
        print(f"{provider} {ref or 'worktree'} {mode}: events={len(set(ids))}/{count} "
              f"helper_starts={len(launches)} seconds={elapsed:.3f}", flush=True)
        if ref:
            # The old Hermes implementation uses daemon threads: exiting may
            # race outstanding children. Its single synchronous boundary is the
            # supported baseline; the OpenCode fixture measures whole bursts.
            assert sorted(ids) == list(range(count))
            assert len(launches) == count
            return
        ordered = list(dict.fromkeys(ids))
        assert ordered == list(range(count)), ordered
        if mode == "lose-ack":
            assert ids == [0] + list(range(count)) and rows[0][0] == rows[1][0]
            assert len(launches) == 3
        else:
            assert len(rows) == count
            assert len(launches) == (1 if mode == "normal" else count + 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--events", type=int, default=128)
    args = parser.parse_args()
    if not shutil.which("node") or args.events < 2:
        parser.error("requires Node.js and at least two events")
    if args.base:
        measure("opencode", "normal", args.events, args.base)
    for provider in ("opencode", "hermes"):
        measure(provider, "normal", args.events)
        measure(provider, "old", 4)
        measure(provider, "lose-ack", 4)


if __name__ == "__main__":
    main()
