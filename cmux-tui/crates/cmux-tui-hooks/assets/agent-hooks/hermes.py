# cmux-tui-journal-plugin
import json
import os
import subprocess
import threading

HELPER = os.environ.get("CMUX_TUI_HOOK")


def _append(native_event, payload):
    try:
        subprocess.run(
            [HELPER, "hermes-agent", native_event],
            input=payload,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5.0,
            check=False,
        )
    except Exception:
        pass


def _handler(native_event, durable_boundary=False):
    def handle(**native):
        if not HELPER or not os.environ.get("CMUX_TUI_SOCKET") or not os.environ.get(
            "CMUX_TUI_TERMINAL_ID"
        ):
            return None
        try:
            payload = json.dumps(native)
        except Exception:
            return None
        if durable_boundary:
            _append(native_event, payload)
        else:
            threading.Thread(
                target=_append,
                args=(native_event, payload),
                daemon=True,
            ).start()
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
