#!/usr/bin/env python3
"""The perf corpus's ACP replay agent (p12-perf-process.md 3.8, task 114).

A corpus story's agent track (`agents[]` of schemas/perf/corpus-story-v1.schema.json, `agent: "acp-replay"`) is a
transcript blob. This file is the agent that plays it: an ACP v1 agent on stdio that acpmux starts through the
harness profile harnesses/replay.toml, and that answers the prompt `replay <sha256>` by streaming that transcript's
session updates at their recorded times (update time = send time, as the input track's event time is its send time).
Chromium replays recorded traffic the same way: Web Page Replay serves recorded responses, the story stays fixed and
only the browser varies (third_party/catapult/web_page_replay_go/README.md). Here the agent is fixed and the app's
agent pane, acpmux and their hosts vary.

    python3 -I scripts/perf-lab/corpus/agent_replay.py serve                    # the agent (acpmux starts it)
    python3 -I scripts/perf-lab/corpus/agent_replay.py validate FILE...         # transcript rules
    python3 -I scripts/perf-lab/corpus/agent_replay.py digest FILE              # the frames digest it streams
    python3 -I scripts/perf-lab/corpus/agent_replay.py install --root ROOT --bundle-id ID --config-home DIR \
        --transcripts DIR

Transcript (cmux-perf-acp-transcript/v1), NDJSON: a header `{"schema": "cmux-perf-acp-transcript/v1"}`, then one
record per update, `t_ms` non-decreasing, ending with one `end`. A transcript holds no text (rule R10, fail closed):
every record names sizes and shapes, and the agent writes fixed synthetic text of that size, as the input track's
typing keys type a fixed synthetic text. Records (no other field is allowed):
  {"t_ms", "kind": "message", "bytes", "shape": prose|code|list|table}   agent_message_chunk
  {"t_ms", "kind": "thought", "bytes"}                                    agent_thought_chunk
  {"t_ms", "kind": "tool_call", "tool", "tool_kind", "status"}           tool_call (pending|in_progress)
  {"t_ms", "kind": "tool_update", "tool", "status", "bytes"}             tool_call_update of an announced tool
  {"t_ms", "kind": "plan", "entries", "done"}                             plan (the first `done` completed)
  {"t_ms", "kind": "end", "stop": end_turn|max_tokens|refusal}           the prompt's stopReason

Determinism: the frames of a transcript depend only on its records, so two replays stream the same ACP frames in the
same order. `frames_digest` is sha256 over each update object (canonical JSON) and the stop reason; it leaves out the
session id and the JSON-RPC ids, which acpmux and the pool assign. With CMUX_PERF_REPLAY_LOG set, each turn appends
`{"transcript", "frames", "digest", "stop"}` to that file before it answers the prompt, so a lab replay that reads the
file once the stopReason arrives compares two runs' digests.

The bench app: its acpmux home is its own under CMUX_NEXT_ACPMUX_ROOT (read by bench builds since task 221,
AcpmuxEnvironment.testRoot), `<root>/builds/<key>`, never the person's. acpmux reads profile files from
`$XDG_CONFIG_HOME/cmux/harnesses` (config/profiles.rs `ProfileSources::current`; its per-build `<home>/harnesses`
applies only to a home under `~/.acpmux`), so the bench gets a scratch XDG_CONFIG_HOME too. `install` writes the
profile there and `defaultHarness: "replay"` into the home's config.json, so a chat or a pool prewarm that names no
harness starts the replay agent. `launch_env` is what the bench launch adds: the root, the scratch config home, model
probes for `replay` only (ACPMUX_PROBE_HARNESSES), the agent-pane mock taken off, and bench_env's
`ACPMUX_AGENT_LAUNCH=deny` narrowed to `only:replay`. That allowlist is what keeps real agents out: acpmux still
discovers the host's harnesses, and a session/new or prewarm that names one gets the launch-disabled error
(launch_policy.rs; test: acpmux tests/agent_launch_deny.rs). The app passes ACPMUX_AGENT_LAUNCH to every acpmux it
starts (AcpmuxEnvironment `agentLaunchKeys`).

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_agent_replay.py
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "harnesses" / "replay.toml"
TRANSCRIPT_SCHEMA = "cmux-perf-acp-transcript/v1"
# The manifest's agents[].agent for a track this agent plays, and the acpmux harness id that plays it.
AGENT_KIND = "acp-replay"
HARNESS_ID = "replay"
PROMPT = re.compile(r"replay ([0-9a-f]{64})")
TRANSCRIPTS_ENV = "CMUX_PERF_REPLAY_TRANSCRIPTS"
LOG_ENV = "CMUX_PERF_REPLAY_LOG"
SPEED_ENV = "CMUX_PERF_REPLAY_SPEED"

MAX_BYTES = 64 * 1024
MAX_RECORDS = 100_000
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
SHAPES = ("prose", "code", "list", "table")
TOOL_KINDS = ("read", "edit", "delete", "move", "search", "execute", "think", "fetch", "other")
STOPS = ("end_turn", "max_tokens", "refusal")
TOKEN = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")


def _size(value: Any) -> bool:
    return type(value) is int and 0 < value <= MAX_BYTES


def _size_or_zero(value: Any) -> bool:
    return type(value) is int and 0 <= value <= MAX_BYTES


# kind: {field: check}; t_ms and kind are common to every record.
RECORDS: dict[str, dict[str, Any]] = {
    "message": {"bytes": _size, "shape": lambda v: v in SHAPES},
    "thought": {"bytes": _size},
    "tool_call": {"tool": lambda v: isinstance(v, str) and TOKEN.fullmatch(v) is not None,
                  "tool_kind": lambda v: v in TOOL_KINDS, "status": lambda v: v in ("pending", "in_progress")},
    "tool_update": {"tool": lambda v: isinstance(v, str) and TOKEN.fullmatch(v) is not None,
                    "status": lambda v: v in ("in_progress", "completed", "failed"), "bytes": _size_or_zero},
    "plan": {"entries": lambda v: type(v) is int and 1 <= v <= 50, "done": lambda v: type(v) is int and v >= 0},
    "end": {"stop": lambda v: v in STOPS},
}


class TranscriptError(ValueError):
    pass


# ---------------------------------------------------------------- transcripts

def parse_transcript(data: bytes) -> list[dict[str, Any]]:
    """The records of a transcript (the header left out); raises TranscriptError naming every broken rule."""
    if len(data) > MAX_TRANSCRIPT_BYTES:
        raise TranscriptError(f"transcript is {len(data)} bytes; the limit is {MAX_TRANSCRIPT_BYTES}")
    lines = [line for line in data.decode("utf-8").split("\n") if line.strip()]
    if not lines:
        raise TranscriptError("transcript is empty")
    try:
        rows = [json.loads(line) for line in lines]
    except ValueError as error:
        raise TranscriptError(f"not NDJSON: {error}") from error
    errors = transcript_errors(rows)
    if errors:
        raise TranscriptError("; ".join(errors))
    return rows[1:]


def transcript_errors(rows: list[Any]) -> list[str]:
    """Every rule a transcript (header row included) breaks."""
    if not rows or rows[0] != {"schema": TRANSCRIPT_SCHEMA}:
        return [f"line 1: the header must be exactly {{\"schema\": \"{TRANSCRIPT_SCHEMA}\"}}"]
    records = rows[1:]
    if len(records) > MAX_RECORDS:
        return [f"{len(records)} records; the limit is {MAX_RECORDS}"]
    errors: list[str] = []
    last_t = 0
    tools: set[str] = set()
    for line, record in enumerate(records, start=2):
        where = f"line {line}"
        if not isinstance(record, dict):
            errors.append(f"{where}: a record is an object")
            continue
        kind = record.get("kind")
        fields = RECORDS.get(kind) if isinstance(kind, str) else None
        if fields is None:
            errors.append(f"{where}: unknown kind {kind!r}")
            continue
        extra = sorted(set(record) - {"t_ms", "kind", *fields})
        if extra:
            errors.append(f"{where}: {kind} has no field {', '.join(extra)} (a transcript holds no text)")
        t_ms = record.get("t_ms")
        if type(t_ms) is not int or t_ms < 0:
            errors.append(f"{where}: t_ms is a non-negative integer")
        elif t_ms < last_t:
            errors.append(f"{where}: t_ms {t_ms} is before the previous record's {last_t}")
        else:
            last_t = t_ms
        for field, ok in fields.items():
            if field not in record or not ok(record[field]):
                errors.append(f"{where}: {kind}.{field} is missing or out of range")
        if kind == "plan" and type(record.get("done")) is int and type(record.get("entries")) is int \
                and record["done"] > record["entries"]:
            errors.append(f"{where}: plan.done is more than plan.entries")
        if kind == "tool_call":
            if record.get("tool") in tools:
                errors.append(f"{where}: tool {record.get('tool')} is announced twice")
            tools.add(record.get("tool"))
        if kind == "tool_update" and record.get("tool") not in tools:
            errors.append(f"{where}: tool_update of tool {record.get('tool')} before its tool_call")
        if kind == "end" and line != len(records) + 1:
            errors.append(f"{where}: end is the last record")
    if not records or not isinstance(records[-1], dict) or records[-1].get("kind") != "end":
        errors.append("the last record is an end")
    return errors


WORDS = ("frame", "layout", "commit", "budget", "pane", "sidebar", "socket", "replay", "render", "input",
         "scroll", "daemon", "session", "workspace", "terminal", "surface", "metric", "window", "turn", "token")


def synthetic_text(size: int, shape: str, index: int) -> str:
    """Exactly `size` ASCII bytes of fixed text in `shape`; `index` (the record's place) varies the words, so
    neighbouring chunks differ while every replay writes the same bytes."""
    if size <= 0:
        return ""
    pieces: list[str] = []
    length = 0
    n = index
    while length < size:
        word = WORDS[n % len(WORDS)]
        if shape == "code":
            piece = f"let {word}_{n % 97} = {n % 1000};\n"
        elif shape == "list":
            piece = f"- {word} {n % 1000}\n"
        elif shape == "table":
            piece = f"| {word} | {n % 1000} |\n"
        else:
            piece = word + (".\n\n" if n % 23 == 22 else " ")
        pieces.append(piece)
        length += len(piece)
        n += 1
    text = "".join(pieces)[:size]
    if shape == "code" and size >= 8:
        text = "```\n" + text[: size - 8] + "```\n"
    return text


def transcript_frames(records: Iterable[Mapping[str, Any]]) -> tuple[list[tuple[int, dict[str, Any]]], str]:
    """[(t_ms, ACP session update)] and the stop reason of a parsed transcript: what the agent streams."""
    frames: list[tuple[int, dict[str, Any]]] = []
    stop = "end_turn"
    for index, record in enumerate(records):
        kind, t_ms = record["kind"], record["t_ms"]
        if kind == "message":
            update = {"sessionUpdate": "agent_message_chunk",
                      "content": {"type": "text", "text": synthetic_text(record["bytes"], record["shape"], index)}}
        elif kind == "thought":
            update = {"sessionUpdate": "agent_thought_chunk",
                      "content": {"type": "text", "text": synthetic_text(record["bytes"], "prose", index)}}
        elif kind == "tool_call":
            update = {"sessionUpdate": "tool_call", "toolCallId": f"replay-{record['tool']}",
                      "title": f"{record['tool_kind'].capitalize()} {record['tool']}", "kind": record["tool_kind"],
                      "status": record["status"]}
        elif kind == "tool_update":
            update = {"sessionUpdate": "tool_call_update", "toolCallId": f"replay-{record['tool']}",
                      "status": record["status"]}
            if record["bytes"]:
                text = synthetic_text(record["bytes"], "code", index)
                update["content"] = [{"type": "content", "content": {"type": "text", "text": text}}]
        elif kind == "plan":
            update = {"sessionUpdate": "plan", "entries": [
                {"content": f"Step {i + 1}", "priority": "medium",
                 "status": "completed" if i < record["done"] else ("in_progress" if i == record["done"] else "pending")}
                for i in range(record["entries"])]}
        else:
            stop = record["stop"]
            continue
        frames.append((t_ms, update))
    return frames, stop


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def frames_digest(updates: Iterable[Mapping[str, Any]], stop: str) -> str:
    """sha256 over the updates in order and the stop reason; no session or request id."""
    digest = hashlib.sha256()
    for update in updates:
        digest.update(canonical(update) + b"\n")
    digest.update(canonical({"stopReason": stop}) + b"\n")
    return digest.hexdigest()


def read_transcript(directory: Path, hex_digest: str) -> bytes:
    """The transcript blob `<directory>/<hex>`, checked against its digest (as BlobCache reads blobs)."""
    data = (directory / hex_digest).read_bytes()
    if hashlib.sha256(data).hexdigest() != hex_digest:
        raise TranscriptError(f"transcript {hex_digest}: the bytes do not match the digest")
    return data


# ---------------------------------------------------------------- the agent

class ReplayAgent:
    """ACP v1 over line-delimited JSON-RPC: initialize, session/new, session/prompt (`replay <sha256>`),
    session/cancel. Each prompt streams on its own thread; a cancel ends it at the next update."""

    def __init__(self, out, env: Mapping[str, str], clock=time.monotonic):
        self.out = out
        self.transcripts = Path(env.get(TRANSCRIPTS_ENV) or ".")
        self.log = env.get(LOG_ENV) or None
        speed = float(env.get(SPEED_ENV) or "1")
        if not speed > 0:
            raise SystemExit(f"agent_replay: {SPEED_ENV} must be above 0")
        self.speed = speed
        self.clock = clock
        self.write_lock = threading.Lock()
        self.sessions = 0
        self.cancels: dict[str, threading.Event] = {}
        self.turns: list[threading.Thread] = []

    def send(self, message: Mapping[str, Any]) -> None:
        with self.write_lock:
            self.out.write(json.dumps(message, separators=(",", ":")) + "\n")
            self.out.flush()

    def answer(self, rid: Any, result: Any) -> None:
        self.send({"jsonrpc": "2.0", "id": rid, "result": result})

    def fail(self, rid: Any, code: int, message: str) -> None:
        self.send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    def handle(self, message: Mapping[str, Any]) -> None:
        method, rid, params = message.get("method"), message.get("id"), message.get("params") or {}
        if method is None:
            return  # a response: this agent asks the client nothing
        if method == "initialize":
            self.answer(rid, {"protocolVersion": 1, "agentInfo": {"name": "cmux-perf-replay", "version": "1"},
                              "agentCapabilities": {"loadSession": False}, "authMethods": []})
        elif method == "session/new":
            self.sessions += 1
            session = f"replay-{self.sessions}"
            self.cancels[session] = threading.Event()
            self.answer(rid, {"sessionId": session})
        elif method == "session/prompt":
            session = params.get("sessionId")
            if session not in self.cancels:
                self.fail(rid, -32002, "Session not found")
                return
            self.cancels[session].clear()
            turn = threading.Thread(target=self.play, args=(rid, session, params.get("prompt") or []), daemon=True)
            self.turns.append(turn)
            turn.start()
        elif method == "session/cancel":
            event = self.cancels.get(params.get("sessionId"))
            if event is not None:
                event.set()
        elif method in ("session/set_mode", "session/set_config_option", "session/set_model"):
            self.answer(rid, {})
        elif rid is not None:
            self.fail(rid, -32601, f"{method} is not supported by the replay agent")

    def play(self, rid: Any, session: str, prompt: list[Any]) -> None:
        start = self.clock()
        text = "".join(block.get("text", "") for block in prompt if isinstance(block, dict)).strip()
        match = PROMPT.fullmatch(text)
        if match is None:
            self.fail(rid, -32602, "the replay agent answers only `replay <sha256 of a transcript>`")
            return
        try:
            frames, stop = transcript_frames(parse_transcript(read_transcript(self.transcripts, match.group(1))))
        except (OSError, TranscriptError, UnicodeDecodeError) as error:
            self.fail(rid, -32602, f"transcript {match.group(1)}: {error}")
            return
        cancel = self.cancels[session]
        sent: list[dict[str, Any]] = []
        for t_ms, update in frames:
            # Recorded timing: each update leaves at its t_ms after the prompt arrived. The wait ends early on a cancel.
            if cancel.wait(max(0.0, start + t_ms / 1000 / self.speed - self.clock())):
                stop = "cancelled"
                break
            self.send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": update}})
            sent.append(update)
        # The turn's record is written before its stopReason goes out, so a reader that sees the answer finds it.
        if self.log:
            line = json.dumps({"transcript": match.group(1), "frames": len(sent), "digest": frames_digest(sent, stop),
                               "stop": stop}) + "\n"
            with open(self.log, "a", encoding="utf-8") as handle:
                handle.write(line)
        self.answer(rid, {"stopReason": stop})

    def serve(self, lines: Iterable[str]) -> None:
        for line in lines:
            if not line.strip():
                continue
            try:
                message = json.loads(line)
            except ValueError:
                self.send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
                continue
            if isinstance(message, dict):
                self.handle(message)
        for turn in self.turns:
            turn.join()


# ---------------------------------------------------------------- bench install

def bench_acpmux_home(root: Path, bundle_id: str) -> Path:
    """The acpmux home a bench app with `bundle_id` uses under CMUX_NEXT_ACPMUX_ROOT `root`: `<root>/builds/<id>`
    (cmux-agent-pane-policy build_identity.rs `acpmux_home`). Only for an id that is already its own key (a path
    component of [A-Za-z0-9._-] with no leading or trailing '-' or '.'), as every bench and tagged build id is; any
    other id gets a hashed key there, so this refuses it rather than guess."""
    if bundle_id == "com.cmuxterm.app.nightly":
        return root
    if not re.fullmatch(r"[A-Za-z0-9_](?:[A-Za-z0-9._-]*[A-Za-z0-9_])?", bundle_id) or "--" in bundle_id:
        raise ValueError(f"bundle id {bundle_id!r} is not its own acpmux key; pass the home itself")
    return root / "builds" / bundle_id


def render_profile(transcripts: Path, *, python: str, log: Path | None = None, speed: float = 1.0) -> str:
    """harnesses/replay.toml with its placeholders filled. Values are TOML basic strings (JSON escapes are valid)."""
    text = TEMPLATE.read_text(encoding="utf-8")
    values = {"@PYTHON@": python, "@AGENT_REPLAY@": str(Path(__file__).resolve()),
              "@TRANSCRIPTS@": str(transcripts), "@LOG@": "" if log is None else str(log), "@SPEED@": repr(speed)}
    for placeholder, value in values.items():
        quoted = f'"{placeholder}"'
        if text.count(quoted) != 1:
            raise ValueError(f"{TEMPLATE}: {quoted} appears {text.count(quoted)} times, not once")
        text = text.replace(quoted, json.dumps(value))
    return text


def install(acpmux_home: Path, config_home: Path, transcripts: Path, *, python: str = sys.executable,
            log: Path | None = None, speed: float = 1.0) -> Path:
    """Writes the replay profile to `<config_home>/cmux/harnesses/replay.toml` (config_home: the daemon's
    XDG_CONFIG_HOME) and makes `replay` the default harness in `<acpmux_home>/config.json`, keeping the file's other
    keys. Returns the profile's path."""
    folder = config_home / "cmux" / "harnesses"
    # acpmux refuses a home another user may write; the profile folder is private the same way.
    acpmux_home.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    profile = folder / f"{HARNESS_ID}.toml"
    _write_private(profile, render_profile(transcripts, python=python, log=log, speed=speed))
    config_path = acpmux_home / "config.json"
    config = json.loads(config_path.read_text(encoding="utf-8")) if config_path.exists() else {}
    config["defaultHarness"] = HARNESS_ID
    _write_private(config_path, json.dumps(config, indent=2) + "\n")
    return profile


def _write_private(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temporary, path)


def launch_env(root: Path, config_home: Path) -> dict[str, str | None]:
    """What a bench launch that plays agent tracks adds to bench_env's fixed env (None: unset the variable).
    ACPMUX_AGENT_LAUNCH goes from `deny` to `only:replay`: acpmux (launch_policy.rs) starts the replay harness and
    refuses any other launch, probe or credential read as under `deny`."""
    return {"CMUX_NEXT_ACPMUX_ROOT": str(root), "XDG_CONFIG_HOME": str(config_home),
            "ACPMUX_PROBE_HARNESSES": HARNESS_ID,
            "ACPMUX_AGENT_LAUNCH": f"only:{HARNESS_ID}", "CMUX_NEXT_AGENT_PANE_MOCK": None}


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("serve", help="run the ACP agent on stdio")
    validate = commands.add_parser("validate", help="check transcripts")
    validate.add_argument("files", nargs="+", type=Path)
    digest = commands.add_parser("digest", help="print the frames digest a transcript streams")
    digest.add_argument("file", type=Path)
    setup = commands.add_parser("install", help="write the replay harness into a bench app's acpmux home")
    where = setup.add_mutually_exclusive_group(required=True)
    where.add_argument("--home", type=Path, help="the acpmux home itself")
    where.add_argument("--root", type=Path, help="CMUX_NEXT_ACPMUX_ROOT (with --bundle-id)")
    setup.add_argument("--bundle-id")
    setup.add_argument("--config-home", type=Path, required=True, help="the bench's scratch XDG_CONFIG_HOME")
    setup.add_argument("--transcripts", type=Path, required=True, help="folder of transcript blobs named by sha256")
    setup.add_argument("--log", type=Path)
    args = parser.parse_args(argv)
    if args.command == "serve":
        ReplayAgent(sys.stdout, os.environ).serve(sys.stdin)
        return 0
    if args.command == "validate":
        bad = 0
        for path in args.files:
            try:
                parse_transcript(path.read_bytes())
            except (OSError, TranscriptError, UnicodeDecodeError) as error:
                print(f"{path}: {error}", file=sys.stderr)
                bad += 1
        return 1 if bad else 0
    if args.command == "digest":
        frames, stop = transcript_frames(parse_transcript(args.file.read_bytes()))
        print(frames_digest((update for _, update in frames), stop))
        return 0
    if args.root is not None and not args.bundle_id:
        parser.error("--root needs --bundle-id")
    home = args.home or bench_acpmux_home(args.root, args.bundle_id)
    print(install(home, args.config_home, args.transcripts.resolve(), log=args.log))
    return 0


if __name__ == "__main__":
    sys.exit(main())
