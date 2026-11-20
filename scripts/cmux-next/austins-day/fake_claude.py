#!/usr/bin/env python3
"""A stand-in for the `claude` CLI for the Austin's-day load scenario.

It is installed as `claude` in a folder that comes on PATH right after the cmux `claude` shim
folder (ad-agent.sh puts it there). So a terminal that runs `claude` goes the real path: the
shim runs `cmux-tui agent claude-wrapper`, the wrapper finds this file as the real Claude,
writes its hook settings file and starts this file with `--settings FILE` and CMUX_TUI_HOOK.

It then does what Claude Code does with those hooks (cmux-tui-hooks claude_session_hook_settings):
for each event it runs every hook command of that event's matching groups with `sh -c`, all at
once, with Claude Code's hook payload on stdin and the group's timeout, and waits for them before
it goes on (a PreToolUse hook holds the tool call), except `async` ones, which run on. A turn is UserPromptSubmit, then
--tools-per-turn tool calls (PreToolUse, the tool, PostToolUse), then Stop. A tool call is real
work in the agent's folder (git status, git log, git diff, a file read, a grep) and, every
--cli-every tool calls, one `cmux` CLI call (the bundled CLI), as agents call it.

Between tool calls (the model's think time) it draws to its terminal as Claude Code's TUI does:
a spinner line rewritten 10 times a second and streamed text at --stream-cps characters a second,
and it keeps --cpu of one core busy (Claude Code is a node process that renders while it streams).
So the daemon parses 80 terminals' output and the app draws the visible ones, as on Austin's Mac.

Every hook run, tool run and CLI call is one JSON line in AD_AGENT_LOG:
  {"t": unix time, "kind": "hook"|"tool"|"cli"|"start"|"end", "event", "ms", "rc", "code"}
`code` is the cmux error code a CLI call printed (server.busy, session.busy, session.no_answer,
...), else null. The start line says whether the wrapper gave hooks (`hooked`): a run where no
agent got hooks does not load the daemon the way real hooks do.

Exit: at AD_AGENT_DEADLINE (unix time), or when stdin closes.
"""
import argparse
import json
import os
import random
import re
import select
import signal
import subprocess
import sys
import threading
import time
import uuid

SPINNER = "✻✽✶✳✢·"
WORDS = ("Reading", "the", "repository", "layout", "and", "checking", "the", "failing", "test", "before", "editing",
         "src/server.rs", "→", "the", "lock", "is", "held", "across", "the", "write;", "moving", "it", "out", "of", "the", "loop")

ERROR_CODE = re.compile(r'"code"\s*:\s*"([a-z_]+\.[a-z_.]+)"|\b((?:server|session)\.[a-z_]+)\b')
TOOLS = (
    ("Bash", ["git", "status", "--porcelain"]),
    ("Bash", ["git", "log", "--oneline", "-20"]),
    ("Bash", ["git", "diff", "--stat", "HEAD~3"]),
    ("Read", None),
    ("Grep", ["grep", "-rIl", "--include=*.txt", "needle", "."]),
    ("Bash", ["git", "rev-parse", "HEAD"]),
)


def log(record):
    path = os.environ.get("AD_AGENT_LOG")
    if not path:
        return
    record["t"] = round(time.time(), 3)
    with open(path, "a") as f:
        f.write(json.dumps(record) + "\n")


def load_settings(argv):
    """The hooks of the `--settings` file the wrapper passed (inline JSON or a path); {} if none."""
    for index, arg in enumerate(argv):
        value = None
        if arg == "--settings" and index + 1 < len(argv):
            value = argv[index + 1]
        elif arg.startswith("--settings="):
            value = arg.split("=", 1)[1]
        if value is None:
            continue
        try:
            text = value if value.lstrip().startswith("{") else open(value).read()
            return json.loads(text).get("hooks") or {}
        except (OSError, ValueError):
            return {}
    return {}


def matches(matcher, tool):
    if not matcher or matcher == "*" or tool is None:
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return matcher == tool


def run_hooks(hooks, event, payload, tool=None):
    """Runs every command of `event`'s groups that match `tool`, at once, as Claude Code does."""
    commands = []
    for group in hooks.get(event) or []:
        if not matches(group.get("matcher"), tool):
            continue
        for hook in group.get("hooks") or []:
            if hook.get("type", "command") == "command" and hook.get("command"):
                commands.append((hook["command"], float(hook.get("timeout") or 60), bool(hook.get("async"))))
    if not commands:
        return
    data = json.dumps({**payload, "hook_event_name": event}).encode()
    threads = []

    def one(command, timeout):
        """Runs one hook command; logs its wall time and its CPU time (user + system of the `sh -c` and the
        children it waited for, from wait4: a helper's detached child is not counted)."""
        start = time.monotonic()
        rc, cpu_ms = None, None
        try:
            child = subprocess.Popen(["sh", "-c", command], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        except OSError as error:
            log({"kind": "hook", "event": event, "ms": round((time.monotonic() - start) * 1000, 2), "rc": f"oserror:{error.errno}",
                 "cpu_ms": None})
            return
        try:
            try:
                child.stdin.write(data)
                child.stdin.close()
            except OSError:
                pass
            # Stopped at the hook's timeout, as Claude Code stops a hook that runs too long. The kill happens
            # only while our child is still unreaped (exited_within never reaps), so it cannot reach a pid
            # the kernel gave to another process.
            killed = not exited_within(child.pid, timeout)
            if killed:
                os.kill(child.pid, signal.SIGKILL)
            _, status, usage = os.wait4(child.pid, 0)
            child.returncode = os.waitstatus_to_exitcode(status)
            rc = "timeout" if killed else child.returncode
            cpu_ms = round((usage.ru_utime + usage.ru_stime) * 1000, 2)
        except ChildProcessError:
            rc = "lost"
        log({"kind": "hook", "event": event, "ms": round((time.monotonic() - start) * 1000, 2), "rc": rc, "cpu_ms": cpu_ms})

    def guarded(command, timeout):
        # A harness fault in a hook thread is logged, never silent (2026-10-30: os.waitid is missing on the
        # minis' Python 3.9, every hook thread died, and the runs logged no hooks).
        try:
            one(command, timeout)
        except Exception as error:  # noqa: BLE001 - recorded as the hook's result
            log({"kind": "hook", "event": event, "ms": None, "rc": f"harness-error:{type(error).__name__}: {error}", "cpu_ms": None})

    for command, timeout, detached in commands:
        thread = threading.Thread(target=guarded, args=(command, timeout), daemon=True)
        thread.start()
        if not detached:  # an `async` hook runs on while Claude Code goes on
            threads.append(thread)
    for thread in threads:
        thread.join()


def think(seconds, cps, cpu, turn):
    """The model's think time: a spinner at 10 Hz, streamed words at `cps`, `cpu` of a core busy."""
    end = time.monotonic() + seconds
    out = sys.stdout
    frame = 0
    budget = 0.0
    while True:
        now = time.monotonic()
        if now >= end:
            break
        tick_end = min(end, now + 0.1)
        # Busy for `cpu` of the tick (render work), then sleep the rest.
        busy_until = now + (tick_end - now) * max(0.0, min(1.0, cpu))
        x = 0
        while time.monotonic() < busy_until:
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        budget += cps * (tick_end - now)
        text = []
        while budget >= 1:
            word = random.choice(WORDS) + " "
            text.append(word)
            budget -= len(word)
        frame += 1
        # Rewrite the spinner line (as the TUI does), then stream the text above it.
        out.write("\r\x1b[2K" + "".join(text) + ("\n" if text and random.random() < 0.2 else "")
                  + f"\x1b[38;5;174m{SPINNER[frame % len(SPINNER)]} Thinking… ({frame // 10}s · ↓ {frame * 7} tokens · turn {turn})\x1b[0m")
        out.flush()
        sleep = tick_end - time.monotonic()
        if sleep > 0:
            time.sleep(sleep)
    out.write("\r\x1b[2K")


def exited_within(pid, timeout):
    """True when our child `pid` exits within `timeout` seconds; it stays unreaped either way. macOS: a
    kqueue process-exit event (Python 3.9 on the minis has no os.waitid); Linux: a pidfd; else waitid."""
    if hasattr(select, "kqueue"):
        queue = select.kqueue()
        try:
            event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                  fflags=select.KQ_NOTE_EXIT)
            try:
                return bool(queue.control([event], 1, timeout))
            except ProcessLookupError:
                return True  # it exited before the event was registered (a zombie now)
        finally:
            queue.close()
    if hasattr(os, "pidfd_open"):
        fd = os.pidfd_open(pid)
        try:
            return bool(select.select([fd], [], [], timeout)[0])
        finally:
            os.close(fd)
    os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)
    return True


def run_tool(name, argv, cwd):
    start = time.monotonic()
    rc = 0
    try:
        if name == "Read":
            # The fixture's files are in dir*/ folders of the worktree (the root has none).
            files = [os.path.join(d, f) for d in os.listdir(cwd) if os.path.isdir(os.path.join(cwd, d)) and not d.startswith(".")
                     for f in os.listdir(os.path.join(cwd, d)) if f.endswith(".txt")]
            if not files:
                rc = "no-files"
            else:
                with open(os.path.join(cwd, random.choice(files)), "rb") as f:
                    f.read()
        else:
            rc = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=120).returncode
    except subprocess.TimeoutExpired:
        rc = "timeout"
    except OSError as error:
        rc = f"oserror:{error.errno}"
    # `argv`: which command ran, so a tool that hangs can be traced (2026-10-30: 157 git calls hit the 120 s
    # time-out in the #28147 A/B's first run on cmux17, and the log did not say which).
    log({"kind": "tool", "event": name, "argv": " ".join(argv) if argv else None,
         "ms": round((time.monotonic() - start) * 1000, 2), "rc": rc})


def run_cli(cli):
    """One read through the bundled `cmux` CLI, as an agent's `cmux` call: its time and error code."""
    if not cli:
        return
    start = time.monotonic()
    code = None
    try:
        done = subprocess.run([cli, "--json", "workspace", "list"], capture_output=True, timeout=30)
        rc = done.returncode
        if rc != 0:
            text = (done.stdout + done.stderr).decode(errors="replace")
            found = ERROR_CODE.search(text)
            code = (found.group(1) or found.group(2)) if found else f"exit{rc}"
    except subprocess.TimeoutExpired:
        rc, code = "timeout", "timeout"
    except OSError as error:
        rc, code = f"oserror:{error.errno}", "oserror"
    log({"kind": "cli", "event": "workspace list", "ms": round((time.monotonic() - start) * 1000, 2), "rc": rc, "code": code})


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--tools-per-turn", type=int, default=int(os.environ.get("AD_TOOLS_PER_TURN", "6")))
    parser.add_argument("--tool-gap", type=float, default=float(os.environ.get("AD_TOOL_GAP", "3.0")),
                        help="mean seconds between tool calls (model think time)")
    parser.add_argument("--cli-every", type=int, default=int(os.environ.get("AD_CLI_EVERY", "3")))
    parser.add_argument("--stream-cps", type=float, default=float(os.environ.get("AD_STREAM_CPS", "300")))
    parser.add_argument("--cpu", type=float, default=float(os.environ.get("AD_CPU", "0.15")))
    known, _ = parser.parse_known_args(sys.argv[1:])
    hooks = load_settings(sys.argv[1:])
    deadline = float(os.environ.get("AD_AGENT_DEADLINE", "0") or 0) or time.time() + 3600
    cwd = os.getcwd()
    cli = os.environ.get("CMUX_BUNDLED_CLI_PATH") or None
    session = str(uuid.uuid4())
    payload = {"session_id": session, "transcript_path": os.path.join(cwd, f".ad-{session}.jsonl"), "cwd": cwd,
               "permission_mode": "bypassPermissions"}
    log({"kind": "start", "event": "start", "hooked": bool(hooks), "events": sorted(hooks), "pid": os.getpid(),
         "hook_helper": os.environ.get("CMUX_TUI_HOOK"), "cli": cli, "terminal": os.environ.get("CMUX_TUI_TERMINAL_ID")})
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    print(f"AD-AGENT session={session} hooked={bool(hooks)}", flush=True)
    run_hooks(hooks, "SessionStart", {**payload, "source": "startup"})
    random.seed(session)
    turn = 0
    calls = 0
    while time.time() < deadline:
        turn += 1
        run_hooks(hooks, "UserPromptSubmit", {**payload, "prompt": f"austins day turn {turn}"})
        for _ in range(known.tools_per_turn):
            if time.time() >= deadline:
                break
            # The model's think time between tool calls, as a stream of tokens to the screen.
            think(random.expovariate(1.0 / max(0.05, known.tool_gap)), known.stream_cps, known.cpu, turn)
            name, argv = random.choice(TOOLS)
            tool_input = {"command": " ".join(argv)} if argv else {"file_path": cwd}
            call = {**payload, "tool_name": name, "tool_input": tool_input, "tool_use_id": f"toolu_{uuid.uuid4().hex[:24]}"}
            run_hooks(hooks, "PreToolUse", call, tool=name)
            run_tool(name, argv, cwd)
            calls += 1
            if known.cli_every > 0 and calls % known.cli_every == 0:
                run_cli(cli)
            run_hooks(hooks, "PostToolUse", {**call, "tool_response": {"ok": True}}, tool=name)
            print(f"⏺ {name}({tool_input.get('command') or 'file'}) turn {turn} call {calls}", flush=True)
        run_hooks(hooks, "Stop", {**payload, "stop_hook_active": False})
        if turn % 5 == 0:
            run_hooks(hooks, "Notification", {**payload, "message": "Claude is waiting for your input"})
    run_hooks(hooks, "SessionEnd", {**payload, "reason": "other"})
    log({"kind": "end", "event": "end", "turns": turn, "calls": calls})


if __name__ == "__main__":
    main()
