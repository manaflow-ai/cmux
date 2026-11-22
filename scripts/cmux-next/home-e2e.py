#!/usr/bin/env python3
"""Live check of Home on a running no-activate tagged build (plans/cmux-next/home.md).

Cmd-1 through `debug.key`, a message typed into the composer, the mux's reply
(which must use a cmux tool), and a child agent's report back. Reads state
only through `debug.home` and `debug.focus`; never sends system input.

Status: written for the phase A window overlay, which did not land. It runs again once
Home is the `kind: home` workspace with a conversation pane (home.md section 7): then
Cmd-1 selects that workspace and `debug.home` reports the pane.

Usage: home-e2e.py --tag <tag> [--timeout 600] [--prompt TEXT]
"""
import argparse, glob, json, os, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--timeout", type=float, default=600)
parser.add_argument("--prompt", default=(
    "Use the cmux CLI to list my workspaces and tell me how many there are. Then spawn one child agent "
    "named home-e2e-child with mux agents spawn whose task is to reply with the single word PONG, "
    "wait for its [mux-event], and tell me exactly what it said."))
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/*.app/Contents/Resources/bin/cmux")))), None)
if not CLI:
    sys.exit(f"no tagged CLI for {opts.tag}")
ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}


def rpc(method, params=None):
    out = subprocess.run([CLI, "--socket", SOCKET, "rpc", method, json.dumps(params or {})],
                         capture_output=True, text=True, timeout=30, env=ENV).stdout
    return json.loads(out) if out.strip() else None


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            print(f"ok {label}")
            return value
        time.sleep(1)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)\n{json.dumps(rpc('debug.home'), indent=1)}")


def focus_ok(stage):
    focus = rpc("debug.focus") or {}
    active, key = focus.get("app_active"), focus.get("key_window")
    print(f"{stage}: app_active={active} key_window={key}")
    if active or key:
        sys.exit(f"FAIL {stage}: the tagged app took the keyboard")


focus_ok("before")
rpc("debug.key", {"key": "1", "modifiers": ["command"]})
home = wait("Cmd-1 shows Home", lambda: (h := rpc("debug.home")) and any(w["shows_home"] and w["home_view_installed"]
                                                                            for w in h["windows"]) and h, 15)
if not home["available"]:
    sys.exit("FAIL the daemon does not serve local-conversations-v1")
conv = wait("the mux conversation exists", lambda: next((c for c in (rpc("debug.home") or {}).get("conversations", [])
                                                         if "agent_mux" in c["participants"]), None), 60)
start_seq = int(conv["last_seq"])
focus_ok("after Cmd-1")

rpc("debug.key", {"key": opts.prompt})
rpc("debug.key", {"key": "return"})


def tail():
    convs = (rpc("debug.home") or {}).get("conversations", [])
    return next((c.get("tail", []) for c in convs if c["id"] == conv["id"]), [])


wait("my message is confirmed", lambda: any(m["author"] == "user_local" and m["seq"] > start_seq and "PONG" in m["text"]
                                            for m in tail()), 30)
wait("the mux used cmux (it names a real workspace)", lambda: any(m["author"] == "agent_mux" and m["seq"] > start_seq
                                                                    and "workspace" in m["text"].lower() for m in tail()),
     opts.timeout)
# The report comes after the spawn message; the spawn message repeats the task ("reply with ... PONG").
reply = wait("the mux reports the child's PONG", lambda: next((m for m in tail() if m["author"] == "agent_mux"
                                                               and m["seq"] > start_seq and "PONG" in m["text"]
                                                               and "reply with" not in m["text"].lower()
                                                               and "finished" in m["text"].lower()), None),
             opts.timeout)
print("mux:", reply["text"][:400].replace("\n", " "))
focus_ok("after reply")
print(json.dumps(rpc("debug.home"), indent=1)[:3000])
