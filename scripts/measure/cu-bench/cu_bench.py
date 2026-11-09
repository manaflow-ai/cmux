#!/usr/bin/env python3
"""Per-call latency of every computer-use engine on one harness (README.md).

  cu_bench.py run --out DIR (--arms arms.json [--engine NAME]... | --server NAME=COMMAND...)
                  [--rounds 15] [--samples 2] [--app /System/Applications/Calculator.app]
  cu_bench.py summary DIR

Each engine is an MCP server over stdio. The bench launches it, reads its tool catalog, and maps
one op set onto it: list_apps, ax_tree, screenshot, click, type_text, press_key. Three catalog
shapes exist today, picked by the tools an engine lists (PROFILES): `app` (calls take the app's
name), `window` (calls take a pid and a window id) and `tree` (calls take a window id; the
accessibility tree is JSON). Engines take turns per round, in alternating order, so a slow
minute on the host lands on every engine alike. The target app is relaunched at the start of each
engine's turn and before each end-to-end sample, and cleared (Escape, untimed) before each sample.

The end-to-end loop is what an agent does for "12 x 7" in Calculator: read the window, click
clear, read it again (All Clear renumbers elements) unless the click returned the new state, click
1, 2, multiply, 7, equals, read the window again, and check that the display reads 84.
Its time is the wall time of all of that, through the engine's own tools.

Writes DIR/cu-bench.json (schema below), DIR/summary.md, DIR/samples.jsonl (one line per call)
and DIR/first/ENGINE-OP.txt (the first answer of each op, cut to 6000 characters, so a mapping
that went wrong can be read back).

cu-bench.json (cmux.cu-bench/1): run {at, host, macos, cpu, app, rounds, samples}, and per
engine: profile, tools, startup_ms, ops {OP: {n, ok, errors, median_ms, p95_ms, min_ms,
max_ms, bytes_median, first_error}}, e2e {n, ok, reads_84, median_ms, p95_ms, modes,
first_error}, unavailable. A count nobody could measure is null, never zero.

Python 3.9 standard library only (the bench VM's Command Line Tools Python).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import select
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "cmux.cu-bench/1"
OPS = ["list_apps", "ax_tree", "screenshot", "click", "type_text", "press_key"]
DEFAULT_APP = "/System/Applications/Calculator.app"

# Tool catalog shapes, keyed by the tool that reads a window's state.
PROFILES = [("app", "get_app_state"), ("tree", "get_ui_tree"), ("window", "get_window_state")]

# What a Calculator button is called, in titles, descriptions and identifiers across macOS releases.
BUTTONS = {
    "clear": ["all clear", "allclear", "clear", "ac", "c"],
    "1": ["1", "one"], "2": ["2", "two"], "5": ["5", "five"], "7": ["7", "seven"],
    "multiply": ["multiply", "times", "×", "*", "x"],
    "equals": ["equals", "equal", "="],
}
# The key each button falls back to when an engine shows no such element (xdotool names).
BUTTON_KEYS = {"clear": "Escape", "1": "1", "2": "2", "5": "5", "7": "7", "multiply": "asterisk", "equals": "Return"}
E2E_STEPS = ["clear", "1", "2", "multiply", "7", "equals"]


# ---------------------------------------------------------------- stats

def percentile(values: list[float], q: float) -> float | None:
    """Linear interpolation between closest ranks (numpy's default), None when empty."""
    data = sorted(v for v in values if v is not None)
    if not data:
        return None
    if len(data) == 1:
        return data[0]
    k = (len(data) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return data[lo]
    return data[lo] + (data[hi] - data[lo]) * (k - lo)


def summarize(samples: list[dict]) -> dict:
    """samples: [{ms, ok, bytes?, error?}] -> the per-op row of cu-bench.json."""
    good = [s["ms"] for s in samples if s.get("ok")]
    sizes = [s["bytes"] for s in samples if s.get("ok") and s.get("bytes") is not None]
    errors = [s for s in samples if not s.get("ok")]
    r = lambda v: None if v is None else round(v, 1)
    return {
        "n": len(samples), "ok": len(good), "errors": len(errors),
        "median_ms": r(percentile(good, 0.5)), "p95_ms": r(percentile(good, 0.95)),
        "min_ms": r(min(good)) if good else None, "max_ms": r(max(good)) if good else None,
        "bytes_median": None if not sizes else int(percentile(sizes, 0.5)),
        "first_error": errors[0].get("error") if errors else None,
    }


# ---------------------------------------------------------------- reading answers

def result_texts(result: dict) -> list[str]:
    texts = [part.get("text", "") for part in result.get("content", []) or [] if isinstance(part, dict) and part.get("type") == "text"]
    return [t for t in texts if t]


def result_json(result: dict) -> list:
    """structuredContent and every text part that is JSON."""
    found = []
    if isinstance(result.get("structuredContent"), (dict, list)):
        found.append(result["structuredContent"])
    for text in result_texts(result):
        stripped = text.strip()
        if stripped[:1] in "[{":
            try:
                found.append(json.loads(stripped))
            except ValueError:
                pass
    return found


def walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def norm(text) -> str:
    """Lowercase, invisible marks and surrounding punctuation dropped: "‎84" -> "84"."""
    text = re.sub(r"[‎‏‪-‮⁦-⁩﻿]", "", str(text)).strip().lower()
    return text.strip(" \t\"'.,:;()[]")


JSON_ID_KEYS = ("element_index", "element_id", "index", "id")
JSON_LABEL_KEYS = ("title", "label", "description", "identifier", "ax_identifier", "name", "help", "value", "text")
LINE_INDEX = re.compile(r"\[(\d+)\]|^\s*(?:-\s*)?(\d+)\s")
LINE_PAIR = re.compile(r"([A-Za-z][A-Za-z _]*?)\s*[:=]\s*(\"[^\"]*\"|[^,()\]]+)")
LINE_QUOTED = re.compile(r"\"([^\"]*)\"")


def line_labels(line: str) -> tuple[str | None, list[str], str]:
    """One line of an indexed text tree -> (index, its labels, its role text).

    Shapes seen: `12 button Description: 1, ID: One` (index, role, pairs), `- [12] AXButton "1"
    (id=One)` (bracketed index, quoted title)."""
    m = LINE_INDEX.search(line)
    if not m:
        return None, [], ""
    index = m.group(1) or m.group(2)
    rest = line[m.end():].strip()
    labels = [norm(v) for _, v in LINE_PAIR.findall(rest)]
    labels += [norm(v) for v in LINE_QUOTED.findall(rest)]
    head = re.split(r"[,(]", rest, maxsplit=1)[0]
    words = head.split()
    role = words[0].lower() if words else ""
    if len(words) > 1 and ":" not in head:
        # `12 button 7`: the title follows the role. Two-word roles ("static text") read as role.
        title = " ".join(words[1:])
        if words[0].lower() in ("static", "text") and len(words) > 2:
            role, title = " ".join(words[:2]).lower(), " ".join(words[2:])
        labels.append(norm(title))
    return index, [l for l in labels if l], role


def find_element(result: dict, button: str) -> str | None:
    """The id or index of Calculator's `button` (a BUTTONS key) in a state answer, or None."""
    aliases = set(BUTTONS[button])
    for doc in result_json(result):
        for node in walk(doc):
            role = norm(node.get("role") or node.get("role_description") or node.get("type") or "")
            if role and "button" not in role:
                continue
            ident = next((node[k] for k in JSON_ID_KEYS if isinstance(node.get(k), (str, int)) and not isinstance(node.get(k), bool)), None)
            if ident is None:
                continue
            labels = {norm(node[k]) for k in JSON_LABEL_KEYS if isinstance(node.get(k), (str, int)) and k != "id"}
            if labels & aliases:
                return str(ident)
    for text in result_texts(result):
        for line in text.splitlines():
            index, labels, role = line_labels(line)
            if index is None or "button" not in role:
                continue
            if set(labels) & aliases:
                return index
    return None


def display_values(result: dict) -> list[str]:
    """Every value a state answer shows for a text element, normalized."""
    values = []
    for doc in result_json(result):
        for node in walk(doc):
            role = norm(node.get("role") or node.get("role_description") or "")
            if "button" in role:
                continue
            for key in ("value", "title", "label", "text"):
                if isinstance(node.get(key), (str, int)) and not isinstance(node.get(key), bool):
                    values.append(norm(node[key]))
    for text in result_texts(result):
        for line in text.splitlines():
            index, labels, role = line_labels(line)
            if "button" in role:
                continue
            values += [norm(v) for v in re.findall(r"Value:\s*([^,]+)", line)]
            if index is not None and "text" in role:
                values += labels
    return [v.replace(",", "").replace(" ", "") for v in values if v]


def reads(result: dict, want: str) -> bool:
    return want in display_values(result)


def find_window(doc, pid: int | None, app: str, bundle: str) -> dict | None:
    """The best window record in a list_windows / launch_app answer: the app's (by pid, then name
    or bundle id), on screen first."""
    best, best_score = None, -1
    for node in walk(doc):
        wid = node.get("window_id", node.get("windowId"))
        if wid is None or isinstance(wid, bool):
            continue
        names = {norm(node.get(k, "")) for k in ("app_name", "app", "owner", "owner_name", "name", "bundle_id", "app_id", "title")}
        wanted = {norm(app), norm(bundle)} - {""}
        score = 0
        if pid is not None and node.get("pid") == pid:
            score += 4
        if wanted & names:
            score += 2
        if node.get("on_screen", node.get("is_on_screen", True)) and not node.get("minimized"):
            score += 1
        if score > best_score:
            best, best_score = node, score
    if best is None or best_score < 2:
        return None
    return {"window_id": best.get("window_id", best.get("windowId")), "pid": best.get("pid")}


# ---------------------------------------------------------------- MCP client

class Mcp:
    """One engine's MCP server over stdio (newline-delimited JSON-RPC)."""

    def __init__(self, name: str, command: str, args: list[str], env: dict, stderr_path: Path, timeout: float = 30):
        self.name, self.next_id, self.buffer, self.timeout = name, 1, b"", timeout
        self.stderr = open(stderr_path, "ab")
        base = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "SHELL") if k in os.environ}
        self.proc = subprocess.Popen([command, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                     env={**base, **env}, start_new_session=True)
        try:
            self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "cu-bench", "version": "1"}})
            self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except Exception:
            self.close()
            raise

    def _send(self, message: dict) -> None:
        assert self.proc.stdin
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def _line(self, deadline: float) -> bytes | None:
        assert self.proc.stdout
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if self.proc.poll() is not None and not select.select([fd], [], [], 0)[0]:
                raise RuntimeError(f"{self.name} exited {self.proc.returncode}")
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.2))
            if ready:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    raise RuntimeError(f"{self.name} closed its stdout")
                self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line

    def request(self, method: str, params: dict) -> dict:
        result, _ = self.request_sized(method, params)
        return result

    def request_sized(self, method: str, params: dict) -> tuple[dict, int]:
        ident = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            raw = self._line(deadline)
            if raw is None:
                raise RuntimeError(f"{method} timed out after {self.timeout:.0f} s")
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if message.get("id") != ident:
                continue  # a notification, or a late answer to a call that timed out
            if "error" in message:
                raise RuntimeError(json.dumps(message["error"])[:600])
            return message.get("result") or {}, len(raw)

    def tools(self) -> dict:
        listed = self.request("tools/list", {})
        return {t["name"]: t.get("inputSchema") or {} for t in listed.get("tools", []) if isinstance(t, dict) and "name" in t}

    def call(self, tool: str, args: dict) -> tuple[dict, int]:
        result, size = self.request_sized("tools/call", {"name": tool, "arguments": args})
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {' '.join(result_texts(result)).strip()[:600]}")
        return result, size

    def close(self) -> None:
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        for stream in (self.proc.stdin, self.proc.stdout, self.stderr):
            try:
                if stream:
                    stream.close()
            except OSError:
                pass


# ---------------------------------------------------------------- engine adapter

def props(schema: dict) -> dict:
    return (schema or {}).get("properties") or {}


def typed(schema: dict, key: str, value):
    """An element id as the tool's schema types it (int or string)."""
    kind = (props(schema).get(key) or {}).get("type")
    if kind == "integer":
        return int(value)
    if kind == "string" or (isinstance(kind, list) and "string" in kind):
        return str(value)
    return int(value) if str(value).isdigit() else value


class Adapter:
    """Maps the bench's ops onto one engine's tools."""

    def __init__(self, mcp: Mcp, tools: dict, app_name: str, bundle_id: str):
        self.mcp, self.tools, self.app_name, self.bundle_id = mcp, tools, app_name, bundle_id
        self.profile = next((p for p, tool in PROFILES if tool in tools), None)
        if self.profile is None:
            raise RuntimeError("no tool that reads a window's state (" + ", ".join(t for _, t in PROFILES) + ")")
        self.target: dict | None = None
        self.pid: int | None = None
        self.state: dict | None = None  # the latest state answer, for element ids

    # The arguments that name the target, per profile.
    def resolve(self, pid: int | None) -> None:
        self.pid, self.target, self.state = pid, None, None
        if self.profile == "app":
            p = props(self.tools["get_app_state"])
            key = next((k for k in ("app", "app_name", "name", "bundle_id") if k in p), "app")
            self.target = {key: self.bundle_id if key == "bundle_id" and self.bundle_id else self.app_name}
            return
        doc = None
        if "list_windows" in self.tools:
            schema = self.tools["list_windows"]
            args = {}
            if "pid" in props(schema) and pid is not None:
                args["pid"] = pid
            result, _ = self.mcp.call("list_windows", args)
            doc = result_json(result)
        if (doc is None or find_window(doc, pid, self.app_name, self.bundle_id) is None) and "launch_app" in self.tools:
            p = props(self.tools["launch_app"])
            args = {"bundle_id": self.bundle_id} if "bundle_id" in p else {"app": self.app_name} if "app" in p else {"name": self.app_name}
            result, _ = self.mcp.call("launch_app", args)
            doc = result_json(result)
        window = find_window(doc or [], pid, self.app_name, self.bundle_id)
        if window is None:
            raise RuntimeError(f"{self.mcp.name}: no window of {self.app_name} in list_windows/launch_app")
        self.target = {"window_id": window["window_id"]}
        if self.profile == "window":
            self.target["pid"] = window.get("pid") or pid
            if self.target["pid"] is None:
                raise RuntimeError(f"{self.mcp.name}: no pid for {self.app_name}'s window")

    def state_call(self, screenshot: bool) -> tuple[str, dict]:
        tool = dict(PROFILES)[self.profile]
        args = dict(self.target or {})
        p = props(self.tools[tool])
        if "screenshot" in p:
            args["screenshot"] = screenshot
        elif "include_screenshot" in p:
            args["include_screenshot"] = screenshot
        return tool, args

    def state_has_no_flag(self) -> bool:
        p = props(self.tools[dict(PROFILES)[self.profile]])
        return self.profile != "tree" and "screenshot" not in p and "include_screenshot" not in p

    def op(self, op: str) -> tuple[str, dict]:
        """(tool, arguments) for one sample of `op`."""
        t = self.target or {}
        if op == "list_apps":
            return ("list_apps", {}) if "list_apps" in self.tools else ("list_windows", {})
        if op == "ax_tree":
            return self.state_call(screenshot=False)
        if op == "screenshot":
            if "screenshot" in self.tools and self.profile != "app":
                p = props(self.tools["screenshot"])
                return "screenshot", {k: v for k, v in t.items() if k in p or not p}
            return self.state_call(screenshot=True)
        if op == "click":
            return self.click_args("1")
        if op == "type_text":
            return "type_text", {**t, "text": "5"}
        if op == "press_key":
            return self.key_args("Escape")
        raise ValueError(op)

    def key_args(self, key: str) -> tuple[str, dict]:
        p = props(self.tools.get("press_key", {}))
        name = "keys" if "keys" in p and "key" not in p else "key"
        return "press_key", {**(self.target or {}), name: key}

    def element_key(self) -> str:
        p = props(self.tools.get("click", {}))
        for key in ("element_index", "element_id", "element_token", "index"):
            if key in p:
                return key
        return "element_id" if self.profile == "tree" else "element_index"

    def click_args(self, button: str) -> tuple[str, dict] | None:
        ident = find_element(self.state, button) if self.state else None
        if ident is None:
            return None
        key = self.element_key()
        return "click", {**(self.target or {}), key: typed(self.tools.get("click", {}), key, ident)}

    def call(self, tool: str, args: dict) -> tuple[dict, int]:
        result, size = self.mcp.call(tool, args)
        if tool == dict(PROFILES)[self.profile] or (find_element(result, "1") is not None):
            self.state = result  # an action that returns the new state keeps ids current
        return result, size

    def refresh(self) -> dict:
        tool, args = self.state_call(screenshot=False)
        result, _ = self.call(tool, args)
        return result


# ---------------------------------------------------------------- the target app

class TargetApp:
    """The app under test, started as this bench's own child so the bench stops exactly it."""

    def __init__(self, path: str, settle_s: float):
        self.path, self.settle_s, self.proc = path, settle_s, None
        self.name = Path(path).stem if path else "Calculator"
        self.bundle_id = ""
        plist = Path(path) / "Contents" / "Info.plist" if path else None
        if plist and plist.exists():
            import plistlib
            with open(plist, "rb") as f:
                info = plistlib.load(f)
            self.bundle_id = info.get("CFBundleIdentifier", "")
            self.name = info.get("CFBundleName", self.name)
            self.executable = Path(path) / "Contents" / "MacOS" / info.get("CFBundleExecutable", self.name)
        else:
            self.executable = None

    def relaunch(self) -> int | None:
        self.stop()
        if not self.executable:
            return None
        self.proc = subprocess.Popen([str(self.executable)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        time.sleep(self.settle_s)
        subprocess.run(["/usr/bin/open", "-a", self.path], capture_output=True, timeout=10)  # bring it forward
        time.sleep(0.3)
        return self.proc.pid

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        self.proc = None


# ---------------------------------------------------------------- engines

def load_engines(args) -> dict:
    """name -> {mcp: {command, args, env}, daemon?: ...} or {unavailable}."""
    engines = {}
    if args.arms:
        arms = json.loads(Path(args.arms).read_text())
        wanted = args.engine or list(arms)
        for name in wanted:
            engines[name] = arms.get(name) or {"unavailable": f"no arm {name} in {args.arms}"}
    for spec in args.server or []:
        name, _, command = spec.partition("=")
        argv = shlex.split(command)
        if not name or not argv:
            raise SystemExit(f"--server NAME=COMMAND, got {spec!r}")
        engines[name] = {"mcp": {"command": argv[0], "args": argv[1:], "env": {}}}
    if not engines:
        raise SystemExit("cu_bench.py run: give --arms or --server")
    return engines


def start_daemon(name: str, spec: dict, out: Path):
    if not spec.get("daemon"):
        return None
    sys.path.insert(0, str(HERE.parent / "cu-driver-eval" / "arena"))
    import arena  # the arena's own daemon start, so both runs start an engine the same way
    return arena.start_daemon(name, spec, out)


def stop_daemon(proc) -> None:
    if proc is not None:
        import arena
        arena.stop_proc(proc)


class Engine:
    def __init__(self, name: str, spec: dict, out: Path, app: TargetApp, timeout: float):
        self.name, self.spec, self.out, self.app = name, spec, out, app
        self.samples: dict[str, list[dict]] = {op: [] for op in OPS}
        self.e2e: list[dict] = []
        self.errors: list[str] = []
        self.unavailable = spec.get("unavailable")
        self.daemon = self.mcp = self.adapter = None
        self.startup_ms = None
        self.first_written: set[str] = set()
        if self.unavailable:
            return
        try:
            started = time.monotonic()
            self.daemon = start_daemon(name, spec, out)
            m = spec["mcp"]
            self.mcp = Mcp(name, m["command"], list(m.get("args", [])), dict(m.get("env", {})), out / f"stderr-{name}.log", timeout)
            tools = self.mcp.tools()
            self.startup_ms = round((time.monotonic() - started) * 1000, 1)
            self.adapter = Adapter(self.mcp, tools, app.name, app.bundle_id)
        except Exception as error:
            self.unavailable = f"start: {error}"[:600]
            self.close()

    def keep_first(self, op: str, result: dict | None, error: str | None) -> None:
        if op in self.first_written:
            return
        self.first_written.add(op)
        (self.out / "first").mkdir(exist_ok=True)
        if result is not None:
            redacted = {**result, "content": [p if p.get("type") != "image" else {"type": "image", "bytes": len(p.get("data", ""))}
                                              for p in result.get("content", []) or [] if isinstance(p, dict)]}
            body = json.dumps(redacted, indent=1, ensure_ascii=False)[:6000]
        else:
            body = f"error: {error}"
        (self.out / "first" / f"{self.name}-{op}.txt").write_text(body + "\n")

    def close(self) -> None:
        if self.mcp:
            self.mcp.close()
            self.mcp = None
        stop_daemon(self.daemon)
        self.daemon = None


def timed(engine: Engine, op: str, tool: str, args: dict, log) -> dict:
    started = time.monotonic()
    try:
        result, size = engine.adapter.call(tool, args)
        sample = {"ok": True, "ms": (time.monotonic() - started) * 1000, "bytes": size}
        engine.keep_first(op, result, None)
    except Exception as error:
        sample = {"ok": False, "ms": (time.monotonic() - started) * 1000, "error": str(error)[:300]}
        engine.keep_first(op, None, str(error))
    log.write(json.dumps({"engine": engine.name, "op": op, "tool": tool, **sample}) + "\n")
    return sample


def soft_reset(engine: Engine) -> None:
    try:
        engine.adapter.call(*engine.adapter.key_args("Escape"))
    except Exception:
        pass


def turn(engine: Engine, app: TargetApp, samples: int, e2e_samples: int, log) -> None:
    """One engine's turn in a round: every op `samples` times, then the end-to-end loop."""
    a = engine.adapter
    try:
        a.resolve(app.relaunch())
        a.refresh()  # untimed: the ids the click samples use
    except Exception as error:
        engine.errors.append(f"setup: {error}"[:300])
        return
    for op in OPS:
        for _ in range(samples):
            if op in ("click", "type_text", "press_key"):
                soft_reset(engine)
            if op == "click":
                try:  # untimed: clearing can renumber Calculator's elements
                    a.refresh()
                except Exception:
                    pass
            call = a.op(op)
            if call is None:
                sample = {"ok": False, "ms": 0.0, "error": f"no {op} target in the state (button '1' not found)"}
                engine.keep_first(op, None, sample["error"])
                log.write(json.dumps({"engine": engine.name, "op": op, **sample}) + "\n")
            else:
                sample = timed(engine, op, call[0], call[1], log)
            engine.samples[op].append(sample)
    for _ in range(e2e_samples):
        engine.e2e.append(end_to_end(engine, app, log))


def end_to_end(engine: Engine, app: TargetApp, log) -> dict:
    a = engine.adapter
    try:
        a.resolve(app.relaunch())
    except Exception as error:
        row = {"ok": False, "ms": 0.0, "error": f"setup: {error}"[:300]}
        log.write(json.dumps({"engine": engine.name, "op": "e2e", **row}) + "\n")
        return row
    modes, started = set(), time.monotonic()
    try:
        a.refresh()
        for step in E2E_STEPS:
            call = a.click_args(step)
            if call is None:
                call, mode = a.key_args(BUTTON_KEYS[step]), "keys"
            else:
                mode = "clicks"
            modes.add(mode)
            result, _ = a.call(*call)
            if step == "clear" and find_element(result, "1") is None:
                a.refresh()  # All Clear removes display nodes, so ids from before it may be stale
        final, ok = None, False
        for _ in range(4):  # an agent reads until the display settles
            final = a.refresh()
            if reads(final, "84"):
                ok = True
                break
            time.sleep(0.15)
        engine.keep_first("e2e", final, None)
        row = {"ok": ok, "reads_84": ok, "ms": (time.monotonic() - started) * 1000,
               "mode": "+".join(sorted(modes)), "display": display_values(final)[:12] if final else None}
        if not ok:
            row["error"] = "display did not read 84"
    except Exception as error:
        row = {"ok": False, "reads_84": False, "ms": (time.monotonic() - started) * 1000, "mode": "+".join(sorted(modes)),
               "error": str(error)[:300]}
    log.write(json.dumps({"engine": engine.name, "op": "e2e", **row}) + "\n")
    return row


def host_facts(app: TargetApp, args) -> dict:
    def sh(*argv):
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip() or None
        except Exception:
            return None
    return {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "host": platform.node(),
            "macos": sh("sw_vers", "-productVersion"), "build": sh("sw_vers", "-buildVersion"),
            "cpu": sh("sysctl", "-n", "machdep.cpu.brand_string"), "app": app.name, "app_path": app.path,
            "rounds": args.rounds, "samples": args.samples, "e2e_samples": args.e2e_samples}


def report(engines: dict[str, Engine], run: dict) -> dict:
    out = {"schema": SCHEMA, "run": run, "engines": {}}
    for name, e in engines.items():
        e2e_ok = [r["ms"] for r in e.e2e if r.get("ok")]
        r = lambda v: None if v is None else round(v, 1)
        out["engines"][name] = {
            "profile": e.adapter.profile if e.adapter else None,
            "tools": sorted(e.adapter.tools) if e.adapter else None,
            "startup_ms": e.startup_ms, "unavailable": e.unavailable, "errors": e.errors[:20],
            # True when the state tool has no way to skip its screenshot: its ax_tree row then
            # includes that capture and is not a tree-only number.
            "ax_tree_has_screenshot": e.adapter.state_has_no_flag() if e.adapter else None,
            "ops": {op: summarize(s) for op, s in e.samples.items()},
            "e2e": {"n": len(e.e2e), "ok": len(e2e_ok) if e.e2e else None,
                    "reads_84": sum(1 for x in e.e2e if x.get("reads_84")) if e.e2e else None,
                    "median_ms": r(percentile(e2e_ok, 0.5)), "p95_ms": r(percentile(e2e_ok, 0.95)),
                    "modes": sorted({x.get("mode") for x in e.e2e if x.get("mode")}),
                    "first_error": next((x.get("error") for x in e.e2e if x.get("error")), None)},
        }
    return out


def fmt_cell(row: dict | None) -> str:
    if not row or row.get("median_ms") is None:
        return "n/a" if not row or not row.get("n") else f"failed ({row.get('errors')}/{row.get('n')})"
    return f"{row['median_ms']:.1f} / {row['p95_ms']:.1f}"


def markdown(data: dict) -> str:
    run = data["run"]
    names = list(data["engines"])
    lines = [f"Computer-use engine latency, {run.get('app')} on {run.get('host')} (macOS {run.get('macos')}, "
             f"{run.get('cpu')}), {run.get('rounds')} rounds x {run.get('samples')} samples per op, at {run.get('at')}.",
             "", "Median / p95 ms per call (n = successful calls).", "",
             "| op | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for op in OPS:
        cells = []
        for n in names:
            row = data["engines"][n]["ops"].get(op)
            cell = fmt_cell(row)
            if row and row.get("median_ms") is not None:
                cell += f" (n={row['ok']})"
            cells.append(cell)
        lines.append(f"| {op} | " + " | ".join(cells) + " |")
    cells = []
    for n in names:
        e = data["engines"][n]["e2e"]
        if e.get("median_ms") is None:
            cells.append(f"failed (0/{e.get('n')})" if e.get("n") else "n/a")
        else:
            cells.append(f"{e['median_ms']:.0f} / {e['p95_ms']:.0f} ({e['reads_84']}/{e['n']} read 84, {','.join(e['modes'])})")
    lines.append("| e2e 12x7= | " + " | ".join(cells) + " |")
    lines.append("| startup | " + " | ".join(
        f"{data['engines'][n]['startup_ms']:.0f}" if data["engines"][n].get("startup_ms") is not None else "n/a" for n in names) + " |")
    lines.append("| profile | " + " | ".join(str(data["engines"][n].get("profile")) for n in names) + " |")
    notes = []
    for n in names:
        e = data["engines"][n]
        if e.get("unavailable"):
            notes.append(f"- {n}: unavailable: {e['unavailable']}")
        if e.get("ax_tree_has_screenshot"):
            notes.append(f"- {n}: its state tool cannot skip the screenshot, so ax_tree includes one")
        for op, row in e["ops"].items():
            if row.get("first_error"):
                notes.append(f"- {n} {op}: {row['errors']} errors, first: {row['first_error']}")
        if e["e2e"].get("first_error"):
            notes.append(f"- {n} e2e: {e['e2e']['first_error']}")
        for err in e.get("errors") or []:
            notes.append(f"- {n}: {err}")
    if notes:
        lines += ["", "Notes and errors:", ""] + notes
    return "\n".join(lines) + "\n"


def cmd_run(args) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    app = TargetApp(args.app, args.settle)
    specs = load_engines(args)
    engines = {name: Engine(name, spec, out, app, args.timeout) for name, spec in specs.items()}
    live = [e for e in engines.values() if not e.unavailable]
    deadline = time.monotonic() + args.budget if args.budget else None
    try:
        with open(out / "samples.jsonl", "a") as log:
            for rnd in range(args.rounds):
                if deadline and time.monotonic() > deadline:
                    print(f"CU-BENCH budget reached after {rnd} rounds", flush=True)
                    break
                order = live if rnd % 2 == 0 else list(reversed(live))
                for engine in order:
                    turn(engine, app, args.samples, args.e2e_samples, log)
                log.flush()
                print(f"CU-BENCH round {rnd + 1}/{args.rounds} done", flush=True)
    finally:
        for e in engines.values():
            e.close()
        app.stop()
    data = report(engines, host_facts(app, args))
    (out / "cu-bench.json").write_text(json.dumps(data, indent=2) + "\n")
    (out / "summary.md").write_text(markdown(data))
    print(markdown(data), flush=True)
    measured = any(s.get("ok") for e in engines.values() for rows in e.samples.values() for s in rows)
    # 4: no engine started, or none answered a single call (the artifacts above still say why).
    return 0 if measured else 4


def cmd_summary(args) -> int:
    data = json.loads((Path(args.dir) / "cu-bench.json").read_text())
    print(markdown(data), end="")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("--arms", help="the arena's arms.json (arena/prepare.py)")
    r.add_argument("--engine", action="append", help="an arm of --arms to measure (default: all)")
    r.add_argument("--server", action="append", help="NAME=COMMAND: an MCP server to launch")
    r.add_argument("--app", default=DEFAULT_APP, help="the target app bundle; '' launches nothing")
    r.add_argument("--rounds", type=int, default=15)
    r.add_argument("--samples", type=int, default=2, help="samples of each op per engine per round")
    r.add_argument("--e2e-samples", type=int, default=1, help="end-to-end loops per engine per round")
    r.add_argument("--settle", type=float, default=1.5, help="seconds the app gets after a launch")
    r.add_argument("--timeout", type=float, default=30, help="seconds one call may take")
    r.add_argument("--budget", type=float, default=0, help="stop starting rounds after this many seconds")
    s = sub.add_parser("summary")
    s.add_argument("dir")
    args = p.parse_args(argv)
    return cmd_run(args) if args.cmd == "run" else cmd_summary(args)


if __name__ == "__main__":
    sys.exit(main())
