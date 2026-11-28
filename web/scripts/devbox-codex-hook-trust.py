#!/usr/bin/env python3
"""Ask codex whether every hook a cmux-tui pane launch gives it is trusted.

A daemon pane starts codex through `cmux-tui agent codex-wrapper`, which adds
per-terminal hooks and their trust as `-c` overrides. Codex draws its composer
before it shows "Hooks need review", so a screen probe cannot see a wrapper
whose trust codex ignores. This records the exact argv the wrapper passes,
then asks codex itself: `codex <argv> app-server`, `hooks/list` for the work
home. Every hook the wrapper injected must be listed (its key names codex's
session-flags layer), and every listed hook must report trustStatus
"trusted".
"""

import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

SESSION_FLAGS_KEY = "/<session-flags>/"

FAKE_CODEX = """#!/bin/sh
for arg in "$@"; do printf '%s\\0' "$arg"; done > "$CMUX_HOOK_TRUST_ARGV"
"""


def wrapper_argv(wrapper, socket, terminal):
    """The arguments the wrapper hands the codex it finds first on PATH."""
    # Under HOME, not /tmp: the wrapper skips a codex it cannot execute, and
    # /tmp may be mounted noexec.
    scratch = tempfile.mkdtemp(prefix=".cmux-hook-trust-", dir=os.environ.get("HOME") or None)
    try:
        fake = os.path.join(scratch, "codex")
        with open(fake, "w") as handle:
            handle.write(FAKE_CODEX)
        os.chmod(fake, 0o755)
        argv_file = os.path.join(scratch, "argv")
        env = dict(os.environ)
        env.update(
            PATH=scratch + os.pathsep + env.get("PATH", ""),
            CMUX_TUI_SOCKET=socket,
            CMUX_TUI_TERMINAL_ID=terminal,
            CMUX_HOOK_TRUST_ARGV=argv_file,
        )
        for name in ("CMUX_TUI_CODEX_WRAPPER_ACTIVE", "CMUX_TUI_CODEX_HOOKS_DISABLED", "CMUX_CODEX_HOOKS_DISABLED"):
            env.pop(name, None)
        subprocess.run([wrapper, "agent", "codex-wrapper"], env=env, check=True, timeout=60)
        with open(argv_file, "rb") as handle:
            return [arg.decode() for arg in handle.read().split(b"\0")[:-1]]
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def list_hooks(codex, argv, cwd, timeout):
    """hooks/list over one `codex app-server` JSON-RPC session."""
    process = subprocess.Popen(
        [codex, *argv, "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    deadline = time.monotonic() + timeout

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    # readline blocks, so a reader thread feeds a queue and the deadline is
    # enforced on the queue.
    lines = queue.Queue()

    def pump():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()

    def reply(request_id):
        while True:
            try:
                line = lines.get(timeout=max(deadline - time.monotonic(), 0.001))
            except queue.Empty:
                raise RuntimeError("codex app-server did not answer within %ss" % timeout) from None
            if line is None:
                raise RuntimeError("codex app-server exited before answering")
            try:
                message = json.loads(line)
            except ValueError:
                continue
            # A server request or notification carries a method; only a
            # response answers ours.
            if "method" in message or message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError("codex app-server: %s" % message["error"])
            return message.get("result")

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "cmux-verify", "version": "0"}}})
        reply(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "hooks/list", "params": {"cwds": [cwd]}})
        return list(hooks_in(reply(2)))
    finally:
        process.kill()
        process.wait()


def hooks_in(value):
    """Every hook record (an object carrying trustStatus), wherever the result nests it."""
    if isinstance(value, dict):
        if "trustStatus" in value:
            yield value
        for child in value.values():
            yield from hooks_in(child)
    elif isinstance(value, list):
        for child in value:
            yield from hooks_in(child)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wrapper", required=True, help="the cmux-tui binary a pane's codex shim execs")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--terminal", default="term_verify")
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--cwd", default=os.environ.get("HOME", "/"))
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--label", default="codex-hooks-trusted")
    args = parser.parse_args()

    argv = wrapper_argv(args.wrapper, args.socket, args.terminal)
    if argv[:2] != ["--enable", "hooks"]:
        print("%s: the wrapper injected no hooks: %r" % (args.label, argv[:4]), file=sys.stderr)
        return 1
    injected = sum(1 for arg in argv if arg.startswith("hooks.") and not arg.startswith("hooks.state"))
    try:
        hooks = list_hooks(args.codex, argv, args.cwd, args.timeout)
    except RuntimeError as error:
        print("%s: %s" % (args.label, error), file=sys.stderr)
        return 1
    listed = sum(1 for hook in hooks if SESSION_FLAGS_KEY in str(hook.get("key", "")))
    if injected == 0 or listed < injected:
        # Trust is moot for hooks codex never loaded: the wrapper's hooks
        # did not reach codex, so a pane's codex runs without them.
        print("%s: the wrapper injected %d hooks, codex lists %d" % (args.label, injected, listed), file=sys.stderr)
        return 1
    untrusted = [hook for hook in hooks if hook.get("trustStatus") != "trusted"]
    if not hooks or untrusted:
        print("%s: %d of %d hooks need review" % (args.label, len(untrusted), len(hooks)), file=sys.stderr)
        for hook in untrusted:
            print("  %s %s" % (hook.get("trustStatus"), hook.get("key")), file=sys.stderr)
        return 1
    print("%s-ok %d" % (args.label, len(hooks)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
