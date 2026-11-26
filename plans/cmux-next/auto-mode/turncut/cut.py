#!/usr/bin/env python3
"""Start a headless agent turn, SIGKILL its process group at a chosen moment.

usage: cut.py OUT_PREFIX MODE -- CMD...
MODE:
  text:N      kill once the streamed text contains "line N"
  tool:SECS   kill SECS seconds after the first tool_use event (tool is running)
Writes OUT_PREFIX.stream (raw stdout) and prints what triggered the kill.
"""
import json, os, signal, subprocess, sys, time

out, mode = sys.argv[1], sys.argv[2]
cmd = sys.argv[sys.argv.index("--") + 1:]
kind, arg = mode.split(":", 1)

p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     start_new_session=True, text=True, bufsize=1)
text = ""
start = time.monotonic()
with open(out + ".stream", "w") as f:
    for line in p.stdout:
        f.write(line); f.flush()
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if kind == "text":
            # Claude stream_event deltas
            d = ev.get("event", {}).get("delta", {}) if ev.get("type") == "stream_event" else {}
            text += d.get("text", "")
            # Codex json events carry text in item.text / msg
            if f"line {arg}\n" in text:
                os.killpg(p.pid, signal.SIGKILL)
                print(f"KILLED during text at {time.monotonic()-start:.1f}s; streamed chars={len(text)}")
                break
        elif kind == "after" and ev.get("type") == "turn.started":
            try:
                p.wait(timeout=float(arg))
            except subprocess.TimeoutExpired:
                pass
            os.killpg(p.pid, signal.SIGKILL)
            print(f"KILLED {arg}s after turn.started")
            break
        elif kind == "tool":
            s = json.dumps(ev)
            if '"tool_use"' in s or '"command_execution"' in s or '"exec_command' in s:
                try:
                    p.wait(timeout=float(arg))  # bounded: let the tool run, then cut
                except subprocess.TimeoutExpired:
                    pass
                os.killpg(p.pid, signal.SIGKILL)
                print(f"KILLED {arg}s after tool start, at {time.monotonic()-start:.1f}s")
                break
    else:
        print("turn finished before the cut point; rc=", p.wait())
p.wait()
