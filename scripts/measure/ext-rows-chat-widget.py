#!/usr/bin/env python3
"""The drawing proof for the extension chat-widget NIGHTLY row.

This module stays separate from ``ext-rows-nightly.py`` so the existing routing row can
remain a cheap daemon check while the GUI row gets a real completed ACP transcript and a
pixel read-back.  The main driver should load this module and call
``row_chat_widget_drawn(ctx, ext_rows_module)`` from its ``chat_widget`` row.  The row
requires ``ctx.control``, ``ctx.app``, ``ctx.pid_file`` and ``ctx.mcp_config`` from the
isolated side instance.  The side copy must be launched after
``prepare_test_copy_config(ctx.mcp_config)`` so ``experiments.chatWidgets`` is enabled in
that copy only.

Evidence is intentionally conjunctive.  A ready ``apps.views`` mount proves that the
extension scene was produced, while a screenshot of the same side-instance window and
Vision OCR of a marker that exists only in the widget proves that the card was drawn.
The route response alone never passes this row.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CUSTOMIZE_APP = "local/customize"
HARNESS_ID = "rows-chat-widget-drawn"
WIDGET_INTERFACE = "cmux.chat.widget/1"


def prepare_test_copy_config(config: Path) -> dict:
    """Enable the user-only experiment in one side-instance config file.

    The shell integration calls this before launching the copy.  It edits no global
    defaults or personal settings.  A running-copy fallback exists in
    ``_enable_running_copy`` for callers that cannot prepare the file before launch.
    """
    config = Path(config)
    try:
        root = json.loads(config.read_text()) if config.is_file() and config.read_text().strip() else {}
    except (OSError, ValueError) as error:
        return {"ok": False, "path": str(config), "error": f"config: {error}"}
    if not isinstance(root, dict):
        return {"ok": False, "path": str(config), "error": "config is not a JSON object"}
    experiments = root.get("experiments")
    if not isinstance(experiments, dict):
        experiments = {}
        root["experiments"] = experiments
    before = experiments.get("chatWidgets")
    experiments["chatWidgets"] = True
    try:
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps(root, indent=2) + "\n")
    except OSError as error:
        return {"ok": False, "path": str(config), "before": before, "error": f"write: {error}"}
    return {"ok": True, "path": str(config), "before": before, "after": True}


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _enable_running_copy(ctx) -> dict:
    """Turn the experiment on through the copied NIGHTLY's own CLI."""
    setting = ctx.ext(["settings", "set", "experiments.chatWidgets", "true"], timeout=30)
    enabled = setting.get("exit") == 0 or setting.get("ok") is True
    if enabled:
        return {"ok": True, "via": "copy-cli", "reply": setting}
    if ctx.mcp_config:
        file_reply = prepare_test_copy_config(Path(ctx.mcp_config))
        if file_reply.get("ok") and ctx.control:
            rpc = ctx.rpc("settings.set", {"path": "experiments.chatWidgets", "value": True}, timeout=30)
            file_reply["rpc"] = rpc
            file_reply["ok"] = "error" not in rpc
        return {"ok": bool(file_reply.get("ok")), "via": "copy-config", "reply": file_reply,
                "cli": setting}
    return {"ok": False, "via": "copy-cli", "reply": setting,
            "error": "the integration did not pass ctx.mcp_config for the isolated copy"}


def _agent_script(ctx) -> Path:
    """Write a tiny ACP harness that emits one completed tool call without the marker."""
    script = ctx.work / "chat-widget-agent.py"
    fake_agent = ROOT / "cmux-tui/crates/acpmux/tests/fake_agent.py"
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text(
        f'''import importlib.util
import sys

FAKE = {str(fake_agent)!r}
spec = importlib.util.spec_from_file_location("fake_agent", FAKE)
fake = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(fake)


def handle_prompt(rid, params):
    sid = params["sessionId"]
    fake.update(sid, {{"sessionUpdate": "tool_call", "toolCallId": "widget-proof-tool",
                      "title": "mcp__rowsprobe__get_thing", "kind": "execute",
                      "status": "in_progress", "rawInput": {{"command": "get thing"}}}})
    fake.update(sid, {{"sessionUpdate": "tool_call_update", "toolCallId": "widget-proof-tool",
                      "status": "completed",
                      "content": [{{"type": "content", "content": {{"type": "text",
                      "text": "rows widget proof completed"}}}}]}})
    fake.update(sid, {{"sessionUpdate": "agent_message_chunk",
                      "content": {{"type": "text", "text": "The probe completed."}}}})
    fake.send({{"jsonrpc": "2.0", "id": rid, "result": {{"stopReason": "end_turn"}}}})


fake.handle_prompt = handle_prompt
if __name__ == "__main__":
    sys.argv[0] = FAKE
    fake.main()
'''
    )
    return script


def _acpmux_socket(ctx) -> str | None:
    """Find the socket belonging to this side-instance's bundled acpmux."""
    bench = _load("chat_widget_bench_memory", ROOT / "scripts/cmux-next/bench_memory.py")
    try:
        return bench.FakeChats.acpmux_socket(str(ctx.app))
    except (OSError, RuntimeError, SystemExit):
        return None


def _start_transcript(ctx) -> dict:
    if not ctx.app:
        return {"ok": False, "error": "chat-widget drawing needs the running NIGHTLY app copy"}
    cli = ctx.app / "Contents/Resources/bin/acpmux"
    if not cli.is_file() or not os.access(cli, os.X_OK):
        return {"ok": False, "error": f"missing bundled acpmux: {cli}"}
    script = _agent_script(ctx)
    harness = {"id": HARNESS_ID, "name": "Chat widget drawing proof", "command": sys.executable,
               "args": shlex.quote(str(script)), "protocol": "acp", "replace": True}
    added = None
    for _ in range(6):
        added = ctx.rpc("action.run", {"action": "agent.harness.add", "args": harness, "focus": False}, timeout=30)
        if "timeout" not in json.dumps(added).lower():
            break
        time.sleep(5)
    if not added or added.get("error"):
        return {"ok": False, "harness": added, "error": "agent.harness.add failed"}
    sock = _acpmux_socket(ctx)
    if not sock:
        return {"ok": False, "harness": added, "error": "the side copy's acpmux socket was not found"}
    env = os.environ | {"ACPMUX_SOCKET": sock, "HOME": str(ctx.work / "chat-widget-home")}
    made = subprocess.run([str(cli), "new", "--json", "-d", "--machine", "local",
                           "--cwd", str(ctx.work), "-m", HARNESS_ID, "chat widget proof"],
                          capture_output=True, text=True, timeout=180, env=env)
    if made.returncode:
        return {"ok": False, "harness": added, "socket": sock, "exit": made.returncode,
                "error": "acpmux session creation failed", "detail": (made.stdout + made.stderr)[-1000:]}
    try:
        session = json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        return {"ok": False, "harness": added, "socket": sock,
                "acp": (made.stdout + made.stderr)[-1000:], "error": "acpmux did not create a session"}
    completed = _read_completed_tool(ctx, cli, session, env)
    opened = ctx.rpc("action.run", {"action": "agent.openSessionWorkspace", "focus": False,
                                     "wait": False, "session": session}, timeout=60)
    created = [value for value in opened.get("created", []) if str(value).startswith("ws_")]
    workspace = created[0] if created else None
    if workspace:
        shown = ctx.rpc("action.run", {"action": "goToWorkspace", "focus": True,
                                        "workspace": workspace}, timeout=60)
    else:
        shown = {"error": "agent.openSessionWorkspace returned no workspace", "reply": opened}
    return {"ok": bool(session and workspace and "error" not in shown and completed["ok"]), "harness": added, "socket": sock,
            "session": session, "completed_tool": completed, "open": opened, "workspace": workspace, "shown": shown}


def _chat_views(ctx, base, marker: str) -> list[dict]:
    reply = ctx.rpc("apps.views", {"app": CUSTOMIZE_APP}, timeout=10)
    found = reply.get("views") if isinstance(reply, dict) else None
    matches = []
    for view in found or []:
        if not isinstance(view, dict) or view.get("preview") is not False:
            continue
        if view.get("surface") != "chatWidget" or view.get("interface") != WIDGET_INTERFACE:
            continue
        if view.get("status") != "ready" or not isinstance(view.get("revision"), (int, float)) or view["revision"] <= 0:
            continue
        if marker not in " ".join(str(text) for text in view.get("texts") or []):
            continue
        matches.append(view)
    return matches


def _completed_tool_events(text: str) -> bool:
    """Require the expected call and its final completed status in the daemon log."""
    seen = False
    status = None
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            return False
        if not isinstance(event, dict) or event.get("dir") != "in":
            continue
        msg = event.get("msg", {})
        if msg.get("method") != "session/update":
            continue
        update = msg.get("params", {}).get("update", {})
        if update.get("toolCallId") != "widget-proof-tool":
            continue
        if update.get("sessionUpdate") == "tool_call":
            seen = update.get("title") == "mcp__rowsprobe__get_thing"
        if update.get("sessionUpdate") in {"tool_call", "tool_call_update"}:
            status = update.get("status", status)
    return seen and status == "completed"


def _read_completed_tool(ctx, cli: Path, session: str, env: dict) -> dict:
    waited = subprocess.run([str(cli), "wait", session, "--timeout", "90"],
                            capture_output=True, text=True, timeout=100, env=env)
    if waited.returncode:
        return {"ok": False, "error": "the fixture turn did not finish",
                "wait_exit": waited.returncode, "detail": (waited.stdout + waited.stderr)[-2000:]}
    read = subprocess.run([str(cli), "session", "tail", session, "--last", "200"],
                          capture_output=True, text=True, timeout=30, env=env)
    path = ctx.work / "chat-widget-transcript.ndjson"
    path.write_text(read.stdout)
    return {"ok": read.returncode == 0 and _completed_tool_events(read.stdout),
            "path": str(path), "exit": read.returncode, "stderr": read.stderr[-2000:]}


def row_chat_widget_drawn(ctx, base) -> dict:
    """Run the real-transcript, same-window drawing proof for the main matrix row."""
    marker = f"CHATWIDGETDRAWN{ctx.token[-8:]}"
    install = base.install_customize(ctx, {
        "name": "Rows chat card", "description": "A card under a completed tool call.",
        "runtime": {"main": "main.js"},
        "implements": {WIDGET_INTERFACE: {"export": "renderCard", "title": "Rows card", "symbol": "square",
                                             "options": {"tools": ["mcp__rowsprobe__*"]}}}},
        {"main.js": ("function renderCard() {\n"
                      f"  return VStack([Text({json.dumps(marker)})])\n"
                      "}\n"
                      "globalThis.__cmuxAppExports = { renderCard }\n")})
    enabled = _enable_running_copy(ctx)
    transcript = _start_transcript(ctx)
    views = []
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        views = _chat_views(ctx, base, marker)
        if views:
            break
        time.sleep(0.5)
    capture = base.capture_marker(ctx, "chat-widget", marker) if views else {"drawn": False, "error": "no ready chat-widget view to capture"}
    checks = {
        "installed": install.get("installed") is True,
        "experiment_enabled_in_copy": enabled.get("ok") is True,
        "completed_transcript": transcript.get("ok") is True,
        "widget_view_ready": bool(views),
        "drawn_capture": capture.get("drawn") is True and bool(capture.get("captures")),
    }
    return {"checks": checks, "marker": marker, "install": install, "experiment": enabled,
            "transcript": transcript, "views": views[:8], "capture": capture,
            "evidence": "apps.views plus same-window PNG OCR; routing alone cannot pass"}


row_chat_widget_drawn.needs_app = True


INTEGRATION_REQUIREMENTS = (
    "Load this module beside ext-rows-nightly.py and call "
    "row_chat_widget_drawn(ctx, ext_rows_nightly) for the chat_widget row.",
    "Prepare the isolated side config with prepare_test_copy_config(config) before side launch, "
    "and pass that same config as --mcp-config.",
    "Run only in app/display mode with --rows=chat_widget. The CLI/headless mode must skip it.",
    "Keep the existing route-only checks if desired, but the row's pass must require every check returned here, "
    "including the same-window marker OCR.",
)


if __name__ == "__main__":
    print("\n".join(INTEGRATION_REQUIREMENTS))
