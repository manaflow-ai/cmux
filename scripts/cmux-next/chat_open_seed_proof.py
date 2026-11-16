#!/usr/bin/env python3
"""What acpmux stores for the subagent chat that chat-open-bench.py seeds, on a host with an acpmux binary.

The bench seeds its subagent template through a daemon of its own (idle_cost_load.PeerDaemon) and its test agent
(chat_open_agent.py): a new chat with `turn: 0`, then `turn: 1`, then `subagents: K`. A seed whose event log has
no `subagent_spawned` line for each of the K subagents stops the bench (`subagent_template_fault`). This script
makes the same chat by the same calls and prints what the daemon stored, so that a red seed has a cause. It does
that 3 times, each on a new daemon:

  1. the subagent chat alone;
  2. the subagent chat after the bench's `small` chat (the bench's order when its seed cache is empty);
  3. the subagent chat with its 2 later turns after the daemon's first checkpoint of the chat. The bench's read
     waits only until the chat's session.json is there, so in this case it reads at once after the last send, with
     no checkpoint between them. When that read does not hold each subagent, the script then waits for the stored
     lines and prints the time that they took.

For each case it prints:

  - the acpmux binary's path, its `--version` line and the version of the Python that runs the script;
  - each `session/prompt` request in the event log: its blocks in their order (type, `_meta`, the start of the
    text), and the text that the agent's own rule reads from them;
  - the count of stored lines for each direction and kind, in the bench's own read (while the daemon runs) and
    again after the daemon's stop;
  - the count of subagents with a `subagent_spawned` line, against K;
  - the end of the daemon's log.

It needs no app and no display.

    python3 scripts/cmux-next/chat_open_seed_proof.py --acpmux PATH [--subagents 4] [--small-turns 30]

Exit 0: the K subagents are stored in each of the 3 chats, in the bench's read also. Exit 1: they are not.
Exit 2: a chat was not made.
"""

from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def process_table():
    """(pid, parent pid, command) of each process, by `ps`: what a PeerDaemon reads to end its own children."""
    out = subprocess.run(["ps", "-eo", "pid=,ppid=,comm="], capture_output=True, text=True, check=False).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


# idle_cost_load imports bench_memory, which loads libproc (macOS only) and measures an app. A PeerDaemon reads
# 2 names of it: the id that it gives the test agent (the bench's own value) and the process table. This script
# gives it those 2 on each host, so one path runs everywhere.
sys.modules["bench_memory"] = types.SimpleNamespace(FAKE_AGENT_ID="bench-memory-fake", process_table=process_table)
import idle_cost_load as icl  # noqa: E402


def files(home, session):
    """{file name: bytes} of the chat's event log segments, as idle_cost_load.read_chat gives them."""
    events = {}
    for path in sorted(glob.glob(os.path.join(home, "sessions", session, "events", "*.ndjson"))):
        with open(path, "rb") as handle:
            events[os.path.basename(path)] = handle.read()
    return events


def parsed(events):
    """The stored event lines of `events` (`files`) in the order of the files, and the count of lines that are
    no JSON object."""
    lines, bad = [], 0
    for name in sorted(events):
        for raw in events[name].splitlines():
            try:
                value = json.loads(raw)
            except ValueError:
                value = None
            if isinstance(value, dict):
                lines.append(value)
            else:
                bad += 1
    return lines, bad


def cut(value, limit=200):
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    return text if len(text) <= limit else f"{text[:limit]}... ({len(text)} characters)"


def message_of(line):
    message = line.get("msg")
    return message if isinstance(message, dict) else {}


def params_of(line):
    params = message_of(line).get("params")
    return params if isinstance(params, dict) else {}


def show_prompts(lines):
    """Prints each stored `session/prompt` request (the blocks as acpmux gave them to the agent); their count."""
    count = 0
    for line in lines:
        if "session/prompt" not in (line.get("kind"), message_of(line).get("method")):
            continue
        blocks = params_of(line).get("prompt")
        if not isinstance(blocks, list):
            continue  # the answer to a prompt has the same kind and no blocks
        count += 1
        print(f"PROMPT {count} (seq {line.get('seq')}, dir {line.get('dir')}, kind {line.get('kind')}): "
              f"{len(blocks)} block{'' if len(blocks) == 1 else 's'}")
        said = ""
        for index, block in enumerate(blocks):
            if not isinstance(block, dict):
                print(f"  block {index}: not an object: {cut(block)}")
                continue
            text = block.get("text")
            said += text if isinstance(text, str) else ""
            print(f"  block {index}: type={block.get('type')!r} _meta={cut(block.get('_meta'))} text={cut(text)!r}")
        print(f"  the agent's rule reads (each block's text, joined, with no space at its ends): {cut(said.strip(), 120)!r}")
    return count


def show_counts(title, lines, bad):
    counts = collections.Counter((str(line.get("dir")), str(line.get("kind"))) for line in lines)
    print(f"{title}: {len(lines)} lines" + (f", and {bad} that are no JSON object" if bad else ""))
    for (direction, kind), n in sorted(counts.items()):
        print(f"  {direction:<4} {kind:<44} {n}")
    return counts


def spawned(lines):
    """The subagent session ids with a `subagent_spawned` line: the first rule of the bench's check."""
    found = set()
    for line in lines:
        update = params_of(line).get("update")
        if isinstance(update, dict) and update.get("sessionUpdate") == "subagent_spawned":
            found.add(update.get("subagentSessionId"))
    return found


def show_log(path, last=30):
    try:
        with open(path, errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        print(f"daemon log: not read ({error})")
        return
    print(f"daemon log: {len(lines)} lines, the last {min(last, len(lines))}:")
    for line in lines[-last:]:
        print(f"  {cut(line, 300)}")


def send(peer, session, text):
    try:
        sent = peer.acpmux("send", session, text, timeout=120)
    except subprocess.TimeoutExpired:
        print(f"send {text!r}: no end in 120 s", flush=True)
        return False
    if sent.returncode != 0 or text.startswith("subagents:"):
        print(f"send {text!r}: exit {sent.returncode}, {len(sent.stdout)} characters of output, its end: "
              f"{sent.stdout.strip()[-160:]!r}" + (f", stderr: {sent.stderr.strip()[-400:]!r}" if sent.stderr.strip() else ""),
              flush=True)
    return sent.returncode == 0


def bench_read(peer, session):
    """The chat's event log by the bench's own read (it waits for the daemon's next checkpoint); the files as
    they are when that read fails."""
    try:
        return icl.read_chat(peer.home, session)["events"]
    except RuntimeError as error:
        print(f"the bench's read failed: {error}", flush=True)
        return files(peer.home, session)


def identity(binary):
    """Prints the acpmux binary's path, its `--version` line and the Python of this run."""
    try:
        ran = subprocess.run([binary, "--version"], capture_output=True, text=True, check=False, timeout=30)
        said = (ran.stdout.strip() or ran.stderr.strip() or "no output").splitlines()[0]
        version = said if ran.returncode == 0 else f"{said} (exit {ran.returncode})"
    except (OSError, subprocess.TimeoutExpired) as error:
        version = f"not run ({error})"
    print(f"acpmux binary: {binary}; its --version line: {cut(version)}; "
          f"python3: {platform.python_version()} ({sys.executable})", flush=True)


def stored_later(peer, session, subagents, limit=75.0):
    """After a read that did not hold each subagent: waits until the chat's files hold them, `limit` s at most,
    and prints the time."""
    began = time.monotonic()
    while True:
        found = len(spawned(parsed(files(peer.home, session))[0]))
        waited = time.monotonic() - began
        if found >= subagents or waited >= limit:
            break
        time.sleep(0.5)
    print(f"after the read: the chat's files hold {found} of {subagents} subagents {waited:.1f} s later"
          + ("" if found >= subagents else " (the limit of this wait; the daemon still runs)"), flush=True)


def seed(binary, agent, subagents, small_turns, after_checkpoint=False):
    """One daemon of its own: the bench's `small` chat first when `small_turns` is not 0, then the subagent chat.
    With `after_checkpoint` the chat's 2 later turns come after the daemon's first checkpoint of the chat, so the
    bench's read comes at once after the last send. Prints what the daemon stored for the subagent chat. 0 when
    each subagent is stored, 1 when not, 2 when a chat was not made."""
    began = time.monotonic()
    identity(binary)
    root = tempfile.mkdtemp(prefix="seed-proof-")
    try:
        # A PeerDaemon takes its acpmux out of an app bundle: a folder with the binary at a bundle's place.
        bundle = os.path.join(root, "bundle")
        os.makedirs(os.path.join(bundle, "Contents", "MacOS"))
        shutil.copy2(binary, os.path.join(bundle, "Contents", "MacOS", "acpmux"))
        peer = icl.PeerDaemon(bundle, root, agent)
        session, live = None, {}
        try:
            peer.start()
            if small_turns:
                small = peer.new_chat("turn: 0")
                if small:
                    ended = sum(1 for i in range(1, small_turns) if send(peer, small, f"turn: {i}"))
                    lines, _ = parsed(bench_read(peer, small))
                    print(f"the small chat: {ended + 1} of {small_turns} turns ended, {len(lines)} stored lines, "
                          f"{time.monotonic() - began:.1f} s", flush=True)
                else:
                    print("the small chat was NOT made", flush=True)
            session = peer.new_chat("turn: 0")
            print(f"the subagent chat with 'turn: 0': {'made' if session else 'NOT made'}", flush=True)
            if session:
                if after_checkpoint:
                    wait_began = time.monotonic()
                    bench_read(peer, session)  # returns when the chat's session.json is there
                    print(f"the chat's first checkpoint: {time.monotonic() - wait_began:.1f} s after its first turn; "
                          "the 2 later turns come now", flush=True)
                send(peer, session, "turn: 1")
                send(peer, session, f"subagents: {subagents}")
                read_began = time.monotonic()
                live = bench_read(peer, session)
                in_read = len(spawned(parsed(live)[0]))
                print(f"the bench's read: {time.monotonic() - read_began:.1f} s after the last send's end, "
                      f"{in_read} of {subagents} subagents in it", flush=True)
                if in_read < subagents:
                    stored_later(peer, session, subagents)
        finally:
            peer.stop()
        log = os.path.join(peer.home, "daemon.log")
        if not session:
            show_log(log)
            print("SEED-PROOF: the chat was not made")
            return 2
        (live_lines, live_bad), (after, after_bad) = parsed(live), parsed(files(peer.home, session))
        prompts = show_prompts(after)
        live_counts = show_counts("STORED in the bench's read, while the daemon runs", live_lines, live_bad)
        if show_counts("STORED after the daemon's stop", after, after_bad) == live_counts:
            print("  the 2 reads have the same counts")
        show_log(log)
        found, found_live = spawned(after), spawned(live_lines)
        print(f"SEED-PROOF: {len(found)} of {subagents} subagents have a `subagent_spawned` line after the stop, "
              f"{len(found_live)} in the bench's read; {prompts} prompt{'' if prompts == 1 else 's'} printed; "
              f"{time.monotonic() - began:.1f} s", flush=True)
        return 0 if len(found) == len(found_live) == subagents else 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--acpmux", required=True, help="the acpmux binary of the build")
    parser.add_argument("--subagents", type=int, default=4, help="K of the `subagents: K` prompt (default 4)")
    parser.add_argument("--small-turns", type=int, default=30,
                        help="the turns of the `small` chat before the second subagent chat (the bench's default, 30)")
    opts = parser.parse_args()
    binary = os.path.realpath(opts.acpmux)
    if not os.access(binary, os.X_OK):
        raise SystemExit(f"seed-proof: no acpmux binary at {binary}")
    agent = os.path.join(HERE, "chat_open_agent.py")
    print(f"seed-proof: {platform.platform()}, Python {platform.python_version()} ({sys.executable})", flush=True)
    print("=== SEED-PROOF 1 of 3: the subagent chat alone", flush=True)
    alone = seed(binary, agent, opts.subagents, 0)
    print(f"=== SEED-PROOF 2 of 3: the subagent chat after a small chat of {opts.small_turns} turns", flush=True)
    after_small = seed(binary, agent, opts.subagents, opts.small_turns)
    print("=== SEED-PROOF 3 of 3: the subagent chat with its 2 later turns after its first checkpoint", flush=True)
    checkpoint = seed(binary, agent, opts.subagents, 0, after_checkpoint=True)
    print(f"SEED-PROOF END: alone = exit {alone}, after the small chat = exit {after_small}, "
          f"after the checkpoint = exit {checkpoint}", flush=True)
    return max(alone, after_small, checkpoint)


if __name__ == "__main__":
    sys.exit(main())
