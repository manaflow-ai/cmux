#!/usr/bin/env python3
"""What acpmux stores for the subagent chat that chat-open-bench.py seeds, on a host with an acpmux binary.

The bench seeds its subagent template through a daemon of its own (idle_cost_load.PeerDaemon) and its test agent
(chat_open_agent.py): a new chat with `turn: 0`, then `turn: 1`, then `subagents: K`. A seed whose event log has
no `subagent_spawned` line for each of the K subagents stops the bench (`subagent_template_fault`). This script
makes the same chat by the same calls and prints what the daemon stored, so that a red seed has a cause:

  - each `session/prompt` request in the event log: its blocks in their order (type, `_meta`, the start of the
    text), and the text that the agent's own rule reads from them;
  - the count of stored lines for each direction and kind, read while the daemon runs (as the bench reads them)
    and again after its stop;
  - the count of subagents with a `subagent_spawned` line, against K;
  - the end of the daemon's log.

It needs no app and no display.

    python3 scripts/cmux-next/chat_open_seed_proof.py --acpmux PATH [--subagents 4]

Exit 0: the K subagents are stored. Exit 1: they are not. Exit 2: the chat was not made.
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


def stored(home, session):
    """The chat's stored event lines in the order of their files, and the count of lines that are no JSON object."""
    lines, bad = [], 0
    for path in sorted(glob.glob(os.path.join(home, "sessions", session, "events", "*.ndjson"))):
        with open(path, "rb") as handle:
            for raw in handle.read().splitlines():
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


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--acpmux", required=True, help="the acpmux binary of the build")
    parser.add_argument("--subagents", type=int, default=4, help="K of the `subagents: K` prompt (default 4)")
    opts = parser.parse_args()
    binary = os.path.realpath(opts.acpmux)
    if not os.access(binary, os.X_OK):
        raise SystemExit(f"seed-proof: no acpmux binary at {binary}")
    print(f"seed-proof: {platform.platform()}, Python {platform.python_version()} ({sys.executable})", flush=True)
    root = tempfile.mkdtemp(prefix="seed-proof-")
    try:
        # A PeerDaemon takes its acpmux out of an app bundle: a folder with the binary at a bundle's place.
        bundle = os.path.join(root, "bundle")
        os.makedirs(os.path.join(bundle, "Contents", "MacOS"))
        shutil.copy2(binary, os.path.join(bundle, "Contents", "MacOS", "acpmux"))
        peer = icl.PeerDaemon(bundle, root, os.path.join(HERE, "chat_open_agent.py"))
        session, live, live_bad = None, [], 0
        try:
            peer.start()
            session = peer.new_chat("turn: 0")
            print(f"new chat with 'turn: 0': {'made' if session else 'NOT made'}", flush=True)
            for text in ("turn: 1", f"subagents: {opts.subagents}") if session else ():
                try:
                    sent = peer.acpmux("send", session, text, timeout=120)
                except subprocess.TimeoutExpired:
                    print(f"send {text!r}: no end in 120 s", flush=True)
                    continue
                print(f"send {text!r}: exit {sent.returncode}, {len(sent.stdout)} characters of output, its end: "
                      f"{sent.stdout.strip()[-160:]!r}" + (f", stderr: {sent.stderr.strip()[-400:]!r}" if sent.stderr.strip() else ""),
                      flush=True)
            if session:
                live, live_bad = stored(peer.home, session)
        finally:
            peer.stop()
        log = os.path.join(peer.home, "daemon.log")
        if not session:
            show_log(log)
            print("SEED-PROOF: the chat was not made")
            return 2
        after, after_bad = stored(peer.home, session)
        prompts = show_prompts(after)
        live_counts = show_counts("STORED while the daemon runs (the bench's read)", live, live_bad)
        if show_counts("STORED after the daemon's stop", after, after_bad) == live_counts:
            print("  the 2 reads have the same counts")
        show_log(log)
        found, found_live = spawned(after), spawned(live)
        print(f"SEED-PROOF: {len(found)} of {opts.subagents} subagents have a `subagent_spawned` line after the stop, "
              f"{len(found_live)} in the read while the daemon runs; {prompts} prompt{'' if prompts == 1 else 's'} printed",
              flush=True)
        return 0 if len(found) == len(found_live) == opts.subagents else 1
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
