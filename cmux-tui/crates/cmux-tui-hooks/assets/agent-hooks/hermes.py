# cmux-tui-journal-plugin
import json
import os
import queue
import subprocess
import threading
import time
import uuid

_WAIT = 5.0
_pending = queue.Queue(maxsize=64)
_lock = threading.Lock()
_worker = None


class _Stream:
    """One pipe reader/writer. Its caller can bound a blocked pipe on Windows too."""

    def __init__(self, helper, env):
        self.child = subprocess.Popen(
            [helper, "--plugin-stream=hermes-agent"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=env,
        )
        self.frames = queue.Queue()
        self.replies = queue.Queue()
        threading.Thread(target=self._exchange, daemon=True).start()

    def _exchange(self):
        try:
            self.replies.put(self.child.stdout.readline(16))
            while True:
                frame = self.frames.get()
                if frame is None:
                    break
                self.child.stdin.write(frame)
                self.child.stdin.flush()
                self.replies.put(self.child.stdout.readline(16))
        except (ValueError, OSError):
            self.replies.put(b"")
        finally:
            try:
                self.child.stdin.close()
            except OSError:
                pass
            self.child.stdout.close()
            self.child.wait()

    def close(self):
        self.frames.put(None)

    def reply(self):
        try:
            return self.replies.get(timeout=_WAIT)
        except queue.Empty:
            self.child.kill()
            raise


def _deliver():
    stream = None
    route = None
    legacy = False
    while True:
        helper, socket, terminal, event, payload, key, finished = _pending.get()
        try:
            target = (helper, socket, terminal)
            env = dict(os.environ, CMUX_TUI_SOCKET=socket, CMUX_TUI_TERMINAL_ID=terminal)
            if target != route:
                if stream:
                    stream.close()
                route, stream, legacy = target, None, False
            if not legacy:
                try:
                    if stream is None:
                        stream = _Stream(helper, env)
                        if stream.reply() != b"ready\n":
                            legacy = True
                            raise OSError("plugin stream unavailable")
                    header = json.dumps([key, event])[:-1]
                    stream.frames.put((header + "," + payload + "]\n").encode("utf-8"))
                    if stream.reply() == b"ok\n":
                        continue
                except (OSError, queue.Empty):
                    pass
                if stream:
                    stream.close()
                stream = None
            subprocess.run(
                [helper, "hermes-agent", event], input=payload.encode("utf-8"),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=_WAIT,
                env=dict(env, CMUX_TUI_PLUGIN_EVENT=key), check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            pass
        finally:
            if finished:
                finished.set()


def _handler(native_event, durable_boundary=False):
    def handle(**native):
        global _worker
        helper = os.environ.get("CMUX_TUI_HOOK")
        socket = os.environ.get("CMUX_TUI_SOCKET")
        terminal = os.environ.get("CMUX_TUI_TERMINAL_ID")
        if not (helper and socket and terminal):
            return None
        try:
            payload = json.dumps(native, separators=(",", ":"), allow_nan=False)
        except (TypeError, ValueError, RecursionError):
            return None
        if len(payload) > 1048576:  # json.dumps uses ASCII escaping.
            return None
        finished = threading.Event() if durable_boundary else None
        key = "%d:%s" % (time.time_ns() // 1_000_000, uuid.uuid4().hex)
        with _lock:
            if _worker is None:
                _worker = threading.Thread(target=_deliver, daemon=True)
                _worker.start()
            _pending.put((helper, socket, terminal, native_event, payload, key, finished))
        if finished:
            finished.wait(_WAIT)
        return None

    return handle


def register(ctx):
    for event in (
        "on_session_start",
        "on_session_reset",
        "pre_approval_request",
        "post_approval_response",
        "pre_llm_call",
        "post_llm_call",
        "pre_tool_call",
        "post_tool_call",
        "subagent_stop",
    ):
        ctx.register_hook(event, _handler(event))
    ctx.register_hook("on_session_end", _handler("on_session_end", True))
    ctx.register_hook("on_session_finalize", _handler("on_session_finalize", True))
