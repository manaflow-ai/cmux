"""One agent turn: Claude Code headless (`claude -p --output-format stream-json`), or the
scripted stand-in with the same output for tests. A turn is a process in its own group, so the
holder can stop, continue or kill its whole tree."""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

DROP_ENV = ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_SESSION_ID",
            "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_CHILD_NOTES_DIR",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_EFFORT")


def new_session_id():
    return str(uuid.uuid4())


def agent_command():
    """The agent's argv prefix: $AUTO_AGENT_CMD, the scripted agent for `fake`, or claude."""
    custom = os.environ.get("AUTO_AGENT_CMD")
    if custom == "fake":
        return [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake_agent.py")]
    if custom:
        return custom.split()
    exe = os.environ.get("CLAUDE_CODE_EXECPATH")
    if exe and os.path.exists(exe):
        return [exe]
    found = shutil.which("claude")
    if not found:
        raise RuntimeError("no `claude` on PATH; set AUTO_AGENT_CMD")
    return [found]


def tree(pid):
    """`pid` and every process under it (a tool's shell may be in a group of its own)."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return [pid]
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, todo = [], [pid]
    while todo:
        p = todo.pop()
        found.append(p)
        todo.extend(children.get(p, []))
    return found


def signal_tree(pid, sig):
    for p in tree(pid):
        try:
            os.kill(p, sig)
        except (ProcessLookupError, PermissionError):
            pass


def summary(name, tool_input):
    if not isinstance(tool_input, dict):
        return name
    for key in ("command", "file_path", "path", "pattern", "url", "description", "prompt"):
        if tool_input.get(key):
            return "%s: %s" % (name, str(tool_input[key]).strip().splitlines()[0][:160])
    return name


def result_text(content):
    if isinstance(content, list):
        content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
    text = str(content or "").strip()
    first = text.splitlines()[0] if text else ""
    more = text.count("\n")
    return first[:160] + (" (+%d lines)" % more if more else "")


class Turn:
    """One running turn."""

    def __init__(self, cwd, sid, resume, prompt, model=None):
        argv = agent_command() + ["-p", "--output-format", "stream-json", "--verbose",
                                  "--include-partial-messages", "--dangerously-skip-permissions"]
        if model:
            argv += ["--model", model]
        argv += ["--resume" if resume else "--session-id", sid, prompt]
        env = {k: v for k, v in os.environ.items() if k not in DROP_ENV}
        if os.environ.get("AUTO_CLAUDE_CONFIG_DIR"):
            env["CLAUDE_CONFIG_DIR"] = os.environ["AUTO_CLAUDE_CONFIG_DIR"]
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            env["IS_SANDBOX"] = "1"
        self.stopped = False
        self.killed = False
        self.errors = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=self.errors,
                                     start_new_session=True)

    def stop(self):
        if not self.stopped:
            self.stopped = True
            signal_tree(self.proc.pid, signal.SIGSTOP)

    def cont(self):
        if self.stopped:
            self.stopped = False
            signal_tree(self.proc.pid, signal.SIGCONT)

    def kill(self):
        self.killed = True
        pids = tree(self.proc.pid)
        for p in pids:
            try:
                os.kill(p, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

    def _lines(self):
        """The agent's output lines, then None when its process has exited and its output has
        ended, or has said nothing more for a while (something a tool left running may hold
        the pipe open for ever)."""
        import queue
        import threading
        lines = queue.Queue()

        def read():
            for raw in self.proc.stdout:
                lines.put(raw)
            lines.put(None)

        threading.Thread(target=read, daemon=True).start()
        quiet = 0.0
        while True:
            try:
                raw = lines.get(timeout=0.5)
            except queue.Empty:
                if self.proc.poll() is not None:
                    quiet += 0.5
                    if quiet >= 3.0:
                        return
                continue
            if raw is None:
                return
            quiet = 0.0
            yield raw

    def events(self):
        """Yields ("delta", text), ("text", text, was_streamed), ("tool", id, label),
        ("tool_result", id, ok, label) and at last ("end", ok, text).

        Claude Code may print a result and go on: a command it runs in the background keeps
        the process alive, and it speaks again when that ends. The turn is over when the
        process is."""
        streamed = False
        result = None
        log = None
        if os.environ.get("AUTO_AGENT_LOG"):
            os.makedirs(os.environ["AUTO_AGENT_LOG"], exist_ok=True)
            log = open(os.path.join(os.environ["AUTO_AGENT_LOG"], "%d-%d.jsonl" % (os.getpid(), self.proc.pid)), "wb")
        for raw in self._lines():
            if log:
                log.write(raw)
                log.flush()
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            kind = ev.get("type")
            if kind == "stream_event":
                delta = (ev.get("event") or {}).get("delta") or {}
                if delta.get("type") == "text_delta" and delta.get("text"):
                    streamed = True
                    yield ("delta", delta["text"])
            elif kind == "assistant":
                for block in (ev.get("message") or {}).get("content") or []:
                    if block.get("type") == "text" and block.get("text", "").strip():
                        yield ("text", block["text"], streamed)
                        streamed = False
                    elif block.get("type") == "tool_use":
                        yield ("tool", block.get("id"), summary(block.get("name", "tool"), block.get("input")))
            elif kind == "user":
                content = (ev.get("message") or {}).get("content")
                for block in content if isinstance(content, list) else []:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        yield ("tool_result", block.get("tool_use_id"), not block.get("is_error"),
                               result_text(block.get("content")))
            elif kind == "result":
                result = (not ev.get("is_error"), str(ev.get("result") or ""))
        try:
            code = self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            code = None
        if self.killed:
            return
        if result is not None:
            yield ("end", result[0], result[1])
        else:
            self.errors.seek(0)
            err = self.errors.read().decode("utf-8", "replace").strip()
            yield ("end", False, "the agent exited %s: %s" % (code, err[-400:]))
