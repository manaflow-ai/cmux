"""Synthetic native steps through legacy CUA MCP and its authenticated activity reads.

The helper owns recording, redaction and expiry. Explicit run bundles export its existing
redacted thumbnail bytes and exact linked activity records, never raw tool replies,
AX text or credentials. The upstream v2 driver has no activity store and is unsupported.

``native_config`` names a private JSON file with ``driver: legacy``, ``mcp`` (the
command/args/env entry supplied by the tagged app), ``activity`` (socket, token_env),
``targets`` (fixture ID -> pid/window_id), and ``source_sha``/``artifact`` matching
the context. Run as the app-launched agent so the helper's normal ancestry admission
still applies. No host credential is needed: activity reads use the launch credential.
"""
from __future__ import annotations

import hashlib
import base64
import json
import os
from pathlib import Path
import plistlib
import select
import socket
import stat
import subprocess
import time

MAX_REPLY = 16 * 1024 * 1024
READ_METHODS = {"activity_sessions_list", "activity_timeline", "activity_frame"}
ACTIONS = {"native.observe": None, "native.click": "click"}


class Unavailable(Exception):
    """A fixed, non-sensitive reason; never attach a transport reply."""


def unavailable(reason):
    return {"status": "unavailable", "reason": reason, "state": {}, "assertions": [],
            "evidence": {}, "metrics": {}, "event_refs": []}


def private_config(path):
    with open(path) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Unavailable("native_config must be private to its owner")
        return json.load(stream)


def verify_build(config, context):
    """Bind the live fixture PID to the downloaded app and its fleet artifact metadata."""
    app = Path(config["app"]).resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = (app / "Contents/MacOS" / info["CFBundleExecutable"]).resolve()
    if not executable.is_relative_to(app):
        raise Unavailable("native app executable escapes its bundle")
    with open(config["artifact_metadata"]) as stream:
        metadata = json.load(stream)
    if any(metadata.get(key) != context.get(key) for key in ("source_sha", "artifact")):
        raise Unavailable("native artifact metadata does not match this build")
    if info.get("CMUXCommit", context["source_sha"]) != context["source_sha"]:
        raise Unavailable("native bundle source differs from artifact metadata")
    hasher = hashlib.sha256()
    with executable.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    if metadata.get("executable_sha256") != hasher.hexdigest():
        raise Unavailable("native executable differs from the fleet artifact")
    for window in config["targets"].values():
        result = subprocess.run(["ps", "-p", str(window["pid"]), "-o", "comm="],
                                capture_output=True, text=True, timeout=5)
        if result.returncode or result.stdout.strip() != str(executable):
            raise Unavailable("native fixture PID does not run the pinned executable")


def payload(reply):
    if "error" in reply or (reply.get("result") or {}).get("isError"):
        # A refusal may be consent. No retry, diagnostic or evidence request follows it.
        raise Unavailable("CUA refused the request; resolve consent or admission in the app")
    result = reply.get("result") or {}
    def accepted(value):
        if value.get("ok") is False or value.get("error") or value.get("consentRequired") is True:
            raise Unavailable("CUA refused the request; resolve consent or admission in the app")
        return value
    if isinstance(result.get("structuredContent"), dict):
        return accepted(result["structuredContent"])
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                value = json.loads(item.get("text", ""))
                if isinstance(value, dict):
                    return accepted(value)
            except ValueError:
                pass
    return {}


class MCP:
    """The stdio protocol used by cua_v2_probe_agent.py, without its raw reply log."""

    def __init__(self, entry):
        env = dict(os.environ)
        for item in entry.get("env", []):
            env[item["name"]] = item["value"]
        self.proc = subprocess.Popen([entry["command"], *entry.get("args", [])],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env)
        self.buffer = b""
        self.counter = 0

    def request(self, method, params):
        self.counter += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.counter,
                                          "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                reply = json.loads(line)
                if "method" in reply and "id" in reply:
                    # Elicitation/approval belongs to the user; do not answer or continue.
                    raise Unavailable("CUA requests user approval; continue in the app")
                if reply.get("id") == self.counter:
                    return reply
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                break
            self.buffer += chunk
            if len(self.buffer) > MAX_REPLY:
                raise Unavailable("CUA reply exceeds the bounded reader")
        raise Unavailable("CUA request timed out or bridge exited; mutation outcome unknown")

    def initialize(self):
        reply = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "cmux-workflow", "version": "1"}})
        payload(reply)
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.proc.stdin.flush()
        listed = self.request("tools/list", {})
        payload(listed)
        return {row["name"] for row in listed.get("result", {}).get("tools", [])}

    def call(self, name, args):
        return payload(self.request("tools/call", {"name": name, "arguments": args}))

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdout.close()


class Activity:
    """Only the documented authenticated read methods (computer-use.md section 6a)."""

    def __init__(self, config):
        self.path = config["socket"]
        self.token = os.environ.get(config["token_env"])
        if not self.token:
            raise Unavailable("activity launch credential is unavailable")

    def read(self, method, args):
        if method not in READ_METHODS:
            raise Unavailable("activity client permits reads only")
        request = {"auth_token": self.token, "request": {"method": method, "args": args}}
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(self.path)
            client.sendall((json.dumps(request) + "\n").encode())
            data = b""
            while b"\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    raise Unavailable("activity connection closed")
                data += chunk
                if len(data) > MAX_REPLY:
                    raise Unavailable("activity reply exceeds the bounded reader")
        reply = json.loads(data.split(b"\n", 1)[0])
        if reply.get("ok") is not True:
            raise Unavailable("authenticated activity read unavailable")
        return reply.get("result") or {}


def elements(value):
    if isinstance(value, dict):
        if isinstance(value.get("role"), str):
            yield value
        for child in value.values():
            yield from elements(child)
    elif isinstance(value, list):
        for child in value:
            yield from elements(child)


def selected(snapshot, target):
    return [row for row in elements(snapshot) if row.get("role") == target["role"]
            and any(row.get(key) == target["name"] for key in ("label", "name", "title", "description"))]


def semantic(snapshot, target):
    matches = selected(snapshot, target)
    if len(matches) > 1:
        raise Unavailable("native target is ambiguous")
    row = matches[0] if matches else {}
    state = {"visible": bool(matches)}
    for key in ("enabled", "focused"):
        if type(row.get(key)) is bool:
            state[key] = row[key]
    if row.get("role") in ("AXCheckBox", "AXRadioButton") and row.get("value") in (True, False, 0, 1, "0", "1"):
        state["checked"] = row["value"] in (True, 1, "1")
    # Hash structure only: neither raw AX strings nor guessable hashes of those strings.
    roles = [row["role"] for row in elements(snapshot)]
    digest = hashlib.sha256(json.dumps(roles, separators=(",", ":")).encode()).hexdigest()
    return state, {"sha256": digest, "elements": len(roles), "scope": "roles-only"}


def correlated(page, session, after_seq, tool, target):
    # Pinned cmux-cua e8a8dbfd: activity/model.rs AgentIdentity.actor/proxy_pid,
    # SessionRecord.agent and Event.session/seq/tool/actor/target are serialized verbatim.
    rows = [row for row in page.get("events", [])
            if row.get("session") == session["id"] and type(row.get("seq")) is int
            and row["seq"] > after_seq and row.get("tool") == tool
            and row.get("actor") == session["agent"]["actor"]
            and (row.get("target") or {}).get("pid") == target["pid"]
            and (row.get("target") or {}).get("window_id") == target["window_id"]]
    if len(rows) != 1:
        raise Unavailable("no unique fresh CUA event for this action and target")
    return rows[0]


def export_file(out, name, data):
    """A requested private export, never an overwrite of a previous run's evidence."""
    with os.fdopen(os.open(Path(out) / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)
    return {"path": name, "sha256": hashlib.sha256(data).hexdigest()}


def export_events(out, name, rows):
    # These are ActivityHost's already-redacted Event records, not MCP results. Refuse
    # unexpected raw payload fields instead of exporting a forward-incompatible schema.
    event_keys = {"session", "seq", "ts_ms", "tx", "kind", "tool", "actor", "origin", "target",
                  "args_redacted", "result", "reject", "duration_ms", "click_point", "before_frame",
                  "after_frame", "ax_digest"}
    target_keys = {"app_bundle_id", "app_name", "pid", "pid_start", "window_id", "title_redacted"}
    result_keys = {"ok", "effect", "verified", "error_code"}
    for row in rows:
        if set(row) - event_keys or set(row.get("target") or {}) - target_keys or set(row.get("result") or {}) - result_keys:
            raise Unavailable("CUA event export contains unsupported fields")
    data = (json.dumps(rows, sort_keys=True, indent=2, allow_nan=False) + "\n").encode()
    return {**export_file(out, name, data), "schema": "cmux-cua-core::activity::model::Event[]",
            "retention": "explicit-export; not automatically deleted by the helper"}


def event_refs(session, rows, path=None):
    return [{"format": "cua_event", "session": session["id"], "seq": row["seq"], "tx": row["tx"],
             **({"path": path, "index": index} if path else {})} for index, row in enumerate(rows)]


def frame_ref(activity, page, session, observation, out=None, phase=None):
    if (observation.get("result") or {}).get("ok") is not True or observation.get("reject"):
        raise Unavailable("CUA observation did not succeed")
    blob = observation.get("after_frame")
    info = page.get("frames", {}).get(blob, {})
    if not blob or info.get("expired") is not False:
        raise Unavailable("CUA screenshot is absent or expired")
    frame = activity.read("activity_frame", {"blob": blob, "size": "thumb", "id": session["id"]})
    data = base64.b64decode(frame.get("data_base64", ""), validate=True)
    if not ((frame.get("mime") == "image/png" and data.startswith(b"\x89PNG\r\n\x1a\n"))
            or (frame.get("mime") == "image/jpeg" and data.startswith(b"\xff\xd8\xff"))):
        raise Unavailable("CUA screenshot is unavailable under the helper retention policy")
    exported = {}
    if out is not None:
        extension = "png" if frame["mime"] == "image/png" else "jpg"
        exported = export_file(out, f"{phase}.{extension}", data)
    return {"format": "cua_frame", "session": session["id"], "blob": blob,
            "size": "thumb", "expired": False, **exported}


def perform(step, config, mcp, activity, out=None, progress=None):
    target = step["target"]
    if set(target) != {"fixture", "role", "name"}:
        raise Unavailable("native target requires fixture, role and name")
    window = config["targets"][target["fixture"]]
    if set(window) != {"pid", "window_id"} or any(type(v) is not int or v <= 0 for v in window.values()):
        raise Unavailable("native fixture must identify one live app window")
    expected = step["expect"]
    if not expected or set(expected) - {"visible", "enabled", "checked", "focused"} or any(type(v) is not bool for v in expected.values()):
        raise Unavailable("native expectations require semantic boolean assertions")
    action = ACTIONS[step["action"]]
    tools = mcp.initialize()
    required = {"check_permissions", "get_window_state"} | ({action} if action else set())
    if not required <= tools:
        raise Unavailable("legacy CUA tools are unavailable")
    grants = mcp.call("check_permissions", {"prompt": False})
    if grants.get("accessibility") is not True or grants.get("screen_recording") is not True:
        raise Unavailable("CUA consent is required; finish setup in the app")
    # Probe the existing activity service before any mutation. This never starts a recorder.
    activity.read("activity_sessions_list", {"status": "live", "limit": 500})
    before = mcp.call("get_window_state", {**window, "include_screenshot": True})
    sessions = activity.read("activity_sessions_list", {"status": "live", "limit": 500}).get("sessions", [])
    owned = [row for row in sessions if (row.get("agent") or {}).get("proxy_pid") == mcp.proc.pid]
    if len(owned) != 1:
        raise Unavailable("CUA activity does not identify this MCP proxy uniquely")
    session = owned[0]
    page = activity.read("activity_timeline", {"id": session["id"], "limit": 5000})
    if len(page.get("events", [])) >= 5000:
        raise Unavailable("CUA activity timeline exceeds the bounded step reader")
    after_seq = max((row["seq"] for row in page.get("events", [])), default=0)
    before_event = correlated(page, session, 0, "get_window_state", window)
    before_frame = frame_ref(activity, page, session, before_event, out, "before")
    before_state, before_ax = semantic(before, target)
    before_evidence = {"screenshot": before_frame, "ax_digest": before_ax, "state": before_state}
    if out is not None:
        before_evidence["events"] = export_events(out, "before-events.json", [before_event])
    if progress is not None:
        progress.update(evidence={"before": before_evidence},
                        event_refs=event_refs(session, [before_event], "before-events.json" if out is not None else None))
    if action:
        args = dict(step["args"])
        if set(args) & {"pid", "window_id", "element_index", "element_token", "session_id"}:
            raise Unavailable("native action cannot override its fixture target")
        args.update(window)
        if action == "click":
            if step["args"]:
                raise Unavailable("native.click accepts no arguments")
            matches = selected(before, target)
            if len(matches) != 1 or not ("element_token" in matches[0] or "element_index" in matches[0]):
                raise Unavailable("native click target is absent or ambiguous")
            key = "element_token" if "element_token" in matches[0] else "element_index"
            args[key] = matches[0][key]
        mcp.call(action, args)
    elif step["args"]:
        raise Unavailable("native.observe accepts no arguments")
    after = mcp.call("get_window_state", {**window, "include_screenshot": True})
    state, ax = semantic(after, target)
    page = activity.read("activity_timeline", {"id": session["id"], "after_seq": after_seq, "limit": 100})
    observation = correlated(page, session, after_seq, "get_window_state", window)
    event = correlated(page, session, after_seq, action, window) if action else observation
    after_frame = frame_ref(activity, page, session, observation, out, "after")
    assertions = [{"name": key, "ok": state.get(key) is value} for key, value in expected.items()]
    assertions.append({"name": "CUA action recorded", "ok": (event.get("result") or {}).get("ok") is True})
    rows = [before_event, event, observation] if action else [before_event, observation]
    evidence = {"before": before_evidence, "after": {"screenshot": after_frame, "ax_digest": ax, "state": state}}
    if out is not None:
        evidence["events"] = export_events(out, "cua-events.json", rows)
    refs = event_refs(session, rows, "cua-events.json" if out is not None else None)
    return {"status": "passed" if all(a["ok"] for a in assertions) else "failed",
            "state": state, "assertions": assertions, "event_refs": refs,
            "evidence": evidence,
            "metrics": {"action_ms": event.get("duration_ms")}}


def run_step(step: dict, context: dict, out: Path) -> dict:
    mcp = None
    progress = {}
    try:
        config = private_config(context["native_config"])
        if config.get("driver") != "legacy":
            raise Unavailable("native receipts require the legacy helper activity store")
        if any(config.get(key) != context.get(key) for key in ("source_sha", "artifact")):
            raise Unavailable("native launch metadata does not match the pinned build")
        verify_build(config, context)
        if step.get("action") not in ACTIONS:
            raise Unavailable("unsupported native action")
        activity = Activity(config["activity"])
        mcp = MCP(config["mcp"])
        return perform(step, config, mcp, activity, out=out, progress=progress)
    except Unavailable as error:
        return {**unavailable(str(error)), **progress}
    except (OSError, ValueError, KeyError, TypeError):
        return {**unavailable("native transport or configuration is unavailable"), **progress}
    finally:
        if mcp is not None:
            try:
                mcp.close()
            except (OSError, ValueError, subprocess.SubprocessError):
                # Closing our bridge must not replace a consent/unavailable result.
                pass
