#!/usr/bin/env python3
"""A stand-in for the `claude` and `codex` CLIs in a terminal tab, for the restore journey.

  rj_fake_cli_agent.py claude [--resume ID | -r ID] [flags...]
  rj_fake_cli_agent.py codex [resume ID] [flags...]

It behaves as far as restore needs as the real CLIs do:
- its account is the folder CLAUDE_CONFIG_DIR (claude) or CODEX_HOME (codex) names; it is
  signed in only when that folder holds `rj-login`. Otherwise it prints Claude Code's
  "Not logged in · Please run /login" and answers nothing else, as a resumed agent that lost
  its account does;
- its sessions live in that account folder (`rj-sessions/<id>`); a resume of an id the account
  does not have fails as Claude Code does ("No conversation found with session ID");
- at start it reports SessionStart through the cmux hook helper the terminal names
  (CMUX_TUI_HOOK), or else through the app's own cmux-tui (`RJ_CMUX_TUI __agent-hook`, which
  is what the `claude` shim's hooks run), with Claude Code's hook payload, so the terminal's
  relaunch record learns its session id as it does from the real hooks;
- its flags are the arguments other than the session's; run by a cmux shim, the arguments the
  shim was given (CMUX_TUI_AGENT_ARGS), not the hook arguments it adds;
- it prints one banner line `RJ-AGENT <provider> session=<id> ...`, replays a resumed
  session's transcript, then answers each input line with `echo: <line>` and appends both to
  the session.
Each start and answer is also one JSON line in RJ_AGENT_LOG (the journey reads that, not the
screen, whose lines wrap): {"event": "start"|"answer", "provider", "session", "resumed",
"flags", "signed_in", "hook", "pid", "text"}.
"""
import json
import os
import subprocess
import sys
import uuid

NOT_LOGGED_IN = "Not logged in · Please run /login"


def log(**event):
    path = os.environ.get("RJ_AGENT_LOG")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps(event) + "\n")


def report_session_start(provider, payload):
    """`yes` when a hook helper took the SessionStart, else why not."""
    hook = os.environ.get("CMUX_TUI_HOOK")
    commands = []
    if hook and os.path.exists(hook):
        commands.append([hook, provider, "SessionStart"])
    if os.environ.get("RJ_CMUX_TUI"):
        commands.append([os.environ["RJ_CMUX_TUI"], "__agent-hook", provider, "SessionStart"])
    if not commands:
        return f"no helper (CMUX_TUI_HOOK={hook!r})"
    why = ""
    for command in commands:
        try:
            done = subprocess.run(command, input=json.dumps(payload).encode(), capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            why += f"{command[0]}: {error}; "
            continue
        if done.returncode == 0:
            return "yes"
        why += f"{command[0]}: exit {done.returncode} {done.stderr.decode(errors='replace')[:200]}; "
    return why


def split_session(provider, args):
    """(session id to resume or None, the other arguments)."""
    session, flags, i = None, [], 0
    while i < len(args):
        if provider == "claude" and args[i] in ("--resume", "-r") and i + 1 < len(args):
            session, i = args[i + 1], i + 2
        elif provider == "codex" and args[i] == "resume" and i + 1 < len(args):
            session, i = args[i + 1], i + 2
        else:
            flags.append(args[i])
            i += 1
    return session, flags


def main():
    provider, args = sys.argv[1], sys.argv[2:]
    session, flags = split_session(provider, args)
    # Started through a cmux `claude` / `codex` shim (a new shell after a reboot puts the shims
    # first on PATH): the shim folds its hook arguments in and names the arguments it was given
    # in CMUX_TUI_AGENT_ARGS. Those are the flags a person typed; the folded hooks are cmux's own.
    try:
        given = json.loads(os.environ.get("CMUX_TUI_AGENT_ARGS") or "null")
    except ValueError:
        given = None
    if isinstance(given, list) and all(isinstance(arg, str) for arg in given):
        flags = split_session(provider, given)[1]
    resumed = session is not None
    account = os.environ.get("CLAUDE_CONFIG_DIR" if provider == "claude" else "CODEX_HOME")
    if not account or not os.path.exists(os.path.join(account, "rj-login")):
        log(event="start", provider=provider, session=session, resumed=resumed, flags=" ".join(flags),
            signed_in=False, account=account, pid=os.getpid())
        print(NOT_LOGGED_IN, flush=True)
        for _ in sys.stdin:
            print(NOT_LOGGED_IN, flush=True)
        return 1
    store = os.path.join(account, "rj-sessions")
    os.makedirs(store, exist_ok=True)
    if resumed and not os.path.exists(os.path.join(store, session)):
        log(event="start", provider=provider, session=session, resumed=resumed, flags=" ".join(flags),
            signed_in=True, missing=True, pid=os.getpid())
        print(f"No conversation found with session ID: {session}", flush=True)
        return 1
    session = session or str(uuid.uuid4())
    path = os.path.join(store, session)
    if not resumed:
        open(path, "a").close()
    payload = {"session_id": session, "hook_event_name": "SessionStart", "cwd": os.getcwd(),
               "source": "resume" if resumed else "startup", "transcript_path": path}
    hook = report_session_start(provider, payload)
    log(event="start", provider=provider, session=session, resumed=resumed, flags=" ".join(flags),
        signed_in=True, hook=hook, pid=os.getpid())
    if resumed:
        with open(path) as f:
            sys.stdout.write(f.read())
    print(f"RJ-AGENT {provider} session={session} resumed={int(resumed)} flags={' '.join(flags)} "
          f"pid={os.getpid()} hook={'yes' if hook == 'yes' else 'no'} RJ-END", flush=True)
    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue
        with open(path, "a") as f:
            f.write(f"> {text}\necho: {text}\n")
        print(f"echo: {text}", flush=True)
        log(event="answer", provider=provider, session=session, text=text, pid=os.getpid())
    return 0


if __name__ == "__main__":
    sys.exit(main())
