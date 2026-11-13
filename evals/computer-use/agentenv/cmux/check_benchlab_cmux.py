# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Manaflow, Inc.
"""BenchLab's checks, done through cmux Computer Use's tools with no model: the bench port's ``check_benchlab``
(github.com/earakely-scale/agentenv-cua-driver-bench, artifacts/check_benchlab) rewritten for cmux's tool surface
(list_windows, get_ui_tree, set_value, click, perform_action), which overlay.py stages as the
``check_benchlab_cmux`` artifact. Run inside BenchLab's computer as its session user, once the task pack is in
``~/bench``.

It checks BenchLab's window in its mode and seed; with ``solve`` it does the task element by element through cmux,
with the values trycua's files derive from the seed, for the grade to score; with ``background`` it brings up the
task's interruption and answers it through cmux's background delivery, and reports what the user's window went
through, from the sentinel's log. ``args``: ``mode``, ``seed``, ``solve``, ``background``."""
import base64
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path.home() / "bench" / "probes" / "_common"))
import benchlab_common as C  # noqa: E402

DATA = Path.home() / ".benchlab"
SENTINEL_LOG = Path.home() / ".bench-sentinel" / "sentinel.jsonl"
LOST = {"didResignKey", "didResignActive"}
DATA_OBJECTS = "urn:agentenv:data-objects/v1"
WAIT_S = 30.0
FRAME_AT = (60, 80)
#: Roles of elements that take text, as cmux names them on Linux (AT-SPI's) and elsewhere.
EDITABLE = ("text", "entry", "text field", "textfield", "spin button", "spinbutton", "combo box", "combobox",
            "password text", "editable")


def run(input):
    args, env = input["args"], input["env"]
    cmux = Cmux(env)
    title = f"BenchLab — {args['mode']}"
    lab = cmux.window(lambda w: w.get("title") == title)
    state = _wait(lambda: _json(DATA / "state.json"))
    events = _events()
    frame = lab.get("frame") or {}
    report = {"title_ok": lab.get("title") == title,
              "frame": frame,
              "placed": _placed(frame),
              "state_ok": (state["mode"], state["seed"]) == (args["mode"], args["seed"]),
              "started_ok": events[0]["type"] == "app_start" and events[0]["details"] == {
                  "mode": args["mode"], "seed": args["seed"]},
              "exported_ok": {".benchlab/state.json", ".benchlab/events.jsonl"} <= _exported(env),
              "window": lab}
    if args.get("dump", not (args.get("solve") or args.get("background"))):
        report["tree"] = cmux.tree(lab)
    if args.get("background"):
        mark = len(SENTINEL_LOG.read_text().splitlines())
        try:
            report["interrupted"] = INTERRUPTIONS[args["mode"]](cmux, lab, getattr(C, f"derive_{args['mode']}")(args["seed"]))
        except AssertionError as e:
            report["interrupted"] = False
            report["interrupt_error"] = str(e)[:2000]
        lines = [json.loads(line) for line in SENTINEL_LOG.read_text().splitlines()[mark:] if line.strip()]
        samples = [line for line in lines if line["ev"] == "s"]
        report["user_kept_focus"] = "yes" if samples and not any(line["ev"] in LOST for line in lines) and all(
            bool(s.get("key") and s.get("active")) for s in samples) else "no"
        report["user_window_on_top"] = "yes" if samples and not any(_raised(s, samples[0]) for s in samples) else "no"
        report["user_samples"] = {"samples": len(samples), "not_key": sum(not s.get("key") for s in samples),
                                  "not_active": sum(not s.get("active") for s in samples),
                                  "under_another": sum(bool(_raised(s, samples[0])) for s in samples),
                                  "lost": sorted({line["ev"] for line in lines if line["ev"] in LOST}),
                                  "first_not_key_at": next((i for i, s in enumerate(samples) if not s.get("key")), None),
                                  "raised_over_user": sorted({json.dumps(w, sort_keys=True) for s in samples
                                                              for w in _raised_list(s, samples[0])})}
    if args.get("solve"):
        report["solved"] = SOLVERS[args["mode"]](cmux, lab, getattr(C, f"derive_{args['mode']}")(args["seed"]))
        report["events"] = [event["type"] for event in _events()]
    if args.get("solve") or args.get("background"):
        report["screenshot_png_b64"] = cmux.display_png()
    report["calls"] = cmux.log
    failed = sorted(key for key, value in report.items() if value is False)
    if failed:
        report.pop("screenshot_png_b64", None)
        raise AssertionError(f"{', '.join(failed)} failed: {json.dumps(report)[:20000]}")
    return report


def _placed(frame):
    """Whether the window is where the bench places BenchLab, its outer frame's top left at 60,80, within the
    decoration the window manager adds; recorded, not failed, since cmux reports the frame its own way."""
    try:
        return 0 <= frame["x"] - FRAME_AT[0] <= 12 and 0 <= frame["y"] - FRAME_AT[1] <= 48
    except (KeyError, TypeError):
        return None


def _irmodal(cmux, lab, values):
    """IR-01: the form's first step, the permission prompt denied, the second step, Submit once."""
    cmux.act("set_value", lab, "Name", value=values["name"])
    cmux.act("set_value", lab, "Email", value=values["email"])
    cmux.act("click", lab, "Next")
    prompt = cmux.window(lambda w: (w.get("title") or "").startswith("Allow BenchLab"))
    cmux.act("click", prompt, "Don’t Allow")
    _choose(cmux, lab, "Team", values["team"])
    cmux.act("set_value", lab, "Seats", value=str(values["seats"]))
    cmux.act("click", lab, "Submit")
    return values


def _choose(cmux, window, name, item):
    """A pop-up's item chosen as an agent would through cmux: set_value with the item's title; when cmux refuses that
    (on Linux a GTK combo box has no Value), a click with ``menu_item``; when that is refused too, a click that opens
    the menu, then a click on the item, found in the click's result or in the tree of the window the menu opened."""
    try:
        return cmux.act("set_value", window, name, value=item)
    except AssertionError as e:
        if "unsupported" not in str(e):
            raise
    element = _wait(lambda: cmux.element(window, name, editable=True))
    try:
        return cmux.call("click", window_id=str(window["window_id"]), element_id=element, menu_item=item,
                         observe=False)
    except AssertionError as e:
        if "unsupported" not in str(e):
            raise
    opened = cmux.call("click", window_id=str(window["window_id"]), element_id=element)

    def item_in(tree, window_id):
        found = next((n for n in _walk(tree) if (n.get("name") or "") == item), None)
        return (window_id, found["id"]) if found else None

    def find():
        if hit := item_in(opened, str(window["window_id"])):
            return hit
        for w in cmux.call("list_windows").get("windows", []):
            if w.get("app_id") == window.get("app_id"):
                if hit := item_in(cmux.call("get_ui_tree", window_id=str(w["window_id"])), str(w["window_id"])):
                    return hit
        return None

    window_id, item_id = _wait(find)
    return cmux.call("click", window_id=window_id, element_id=item_id, observe=False)


def _tooltip(cmux, lab, values):
    """MB-11: the pointer rested on the target's icon (xdotool, as the port does) until BenchLab is asked for its
    tooltip, then its code set and Submit once."""
    cell = (760 - 2 * 24 - 3 * 24) // 4
    _rest(lab, 24 + values["target_index"] * (cell + 24) + cell // 2, 60,
          lambda: any(e["type"] == "tooltip_query" and e["details"].get("icon") == values["target"] for e in _events()))
    cmux.act("set_value", lab, "Code", value=values["target_code"])
    cmux.act("click", lab, "Submit")
    return values


def _hover(cmux, lab, values):
    """MB-10: the pointer into the Actions zone (xdotool) until the buttons show, then the target clicked once."""
    _rest(lab, 380, 40, lambda: any(e["type"] == "overlay_shown" for e in _events()))
    cmux.act("click", lab, values["target"])
    return values


SOLVERS = {"irmodal": _irmodal, "tooltip": _tooltip, "hover": _hover}


def _permission_prompt(cmux, lab, values):
    cmux.act("set_value", lab, "Name", value=values["name"])
    cmux.act("click", lab, "Next")
    return _answered(cmux, "Allow BenchLab", "Don’t Allow")


def _unsaved_prompt(cmux, lab, values):
    cmux.act("set_value", lab, "Title", value=values["titles"][0] + " (edited)")
    cmux.act("click", lab, values["titles"][1])
    return _answered(cmux, "Save changes", "Cancel")


def _consent_prompt(cmux, lab, values):
    cmux.act("set_value", lab, "Email", value="user@example.com")
    return _answered(cmux, "Cookie preferences", "Reject optional")


def _answered(cmux, title, answer):
    dialog = cmux.window(lambda w: (w.get("title") or "").startswith(title))
    time.sleep(1.0)
    cmux.act("click", dialog, answer)
    time.sleep(1.0)
    return dialog.get("title")


INTERRUPTIONS = {"irmodal": _permission_prompt, "irunsaved": _unsaved_prompt, "irconsent": _consent_prompt}


def _raised_list(sample, first):
    above = sample.get("above") or []
    return [w for w in above if w not in (first.get("above") or [])]


def _raised(sample, first):
    return set(sample.get("above") or []) - set(first.get("above") or [])


def _rest(window, x, y, done):
    frame = window["frame"]
    point = (frame["x"] + x, frame["y"] + y)
    subprocess.run(["xdotool", "mousemove", *map(str, point)], check=True)
    subprocess.run(["xdotool", "mousemove_relative", "--", "2", "1"], check=True)
    _wait(lambda: done() or None)


class Cmux:
    """The computer's driver over its MCP endpoint, called as an agent calls it: cmux's tools."""

    def __init__(self, env):
        self.url, self.headers, self.session, self.ids, self.log = env["mcp_url"], env["headers"], None, 0, []
        self._rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                 "clientInfo": {"name": "check_benchlab_cmux", "version": "1"}})
        self._rpc("notifications/initialized", None)

    def call(self, name, **args):
        result = self._rpc("tools/call", {"name": name, "arguments": args})
        text = " ".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        self.log.append({"tool": name, "args": args, "error": bool(result.get("isError")), "text": text[:400]})
        if result.get("isError"):
            raise AssertionError(f"{name}({json.dumps(args)}): {text[:1000]}")
        if isinstance(result.get("structuredContent"), dict):
            return result["structuredContent"]
        try:
            return json.loads(text)
        except ValueError:
            return {"text": text}

    def display_png(self):
        """The main display as cmux's screenshot tool captures it, base64 PNG, for the report; None if it has none."""
        try:
            result = self._rpc("tools/call", {"name": "screenshot", "arguments": {"force": True}})
        except AssertionError:
            return None
        return next((c["data"] for c in result.get("content", []) if c.get("type") == "image"), None)

    def window(self, match):
        return _wait(lambda: next((w for w in self.call("list_windows").get("windows", []) if match(w)), None))

    def tree(self, window):
        return self.call("get_ui_tree", window_id=str(window["window_id"]))

    def element(self, window, name, editable=False):
        """The element named ``name`` in the window's tree, by its name or (not a field) its value; for ``editable``,
        a field of that name, else the first field after a label of that name, in reading order."""
        nodes = list(_walk(self.tree(window)))
        named = [n for n in nodes if (n.get("name") or "").rstrip(":") == name]
        if editable:
            if field := next((n for n in named if _editable(n)), None):
                return field["id"]
            for i, node in enumerate(nodes):
                if node in named:
                    if field := next((after for after in nodes[i + 1:] if _editable(after)), None):
                        return field["id"]
            return None
        if named:
            return named[0]["id"]
        return next((n["id"] for n in nodes if n.get("value") == name and not _editable(n)), None)

    def act(self, tool, window, name, **args):
        element = _wait(lambda: self.element(window, name, editable=tool in ("set_value", "type_text")))
        return self.call(tool, window_id=str(window["window_id"]), element_id=element, observe=False, **args)

    def _rpc(self, method, params):
        notify = params is None
        self.ids += 1
        body = {"jsonrpc": "2.0", "method": method, **({} if notify else {"id": self.ids, "params": params})}
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   **self.headers, **({"mcp-session-id": self.session} if self.session else {})}
        request = urllib.request.Request(self.url, data=json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(request, timeout=120) as response:
            self.session = self.session or response.headers.get("mcp-session-id")
            text = response.read().decode()
        if notify:
            return None
        if "data:" in text:
            text = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")][-1]
        reply = json.loads(text)
        if "error" in reply:
            raise AssertionError(f"{method}: {reply['error']}")
        return reply["result"]


def _walk(node):
    """Every element of a cmux tree, in reading order, from any of the shapes it comes in."""
    if isinstance(node, dict):
        if "id" in node and "role" in node:
            yield node
        for key in ("root", "tree", "children", "elements"):
            child = node.get(key)
            if isinstance(child, (dict, list)):
                yield from _walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from _walk(child)


def _editable(node):
    role = (node.get("role") or "").lower().replace("_", " ")
    return any(word in role for word in EDITABLE)


def _exported(env):
    request = urllib.request.Request(f"{env['url']}/svc/benchlab/agentenv", data=json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "data/get", "params": {}}).encode(),
        headers={"Content-Type": "application/json", **env["headers"]})
    with urllib.request.urlopen(request, timeout=120) as response:
        parts = json.load(response)["result"]["parts"]
    return {part["metadata"][DATA_OBJECTS]["path"] for part in parts if base64.b64decode(part["file"]["bytes"])}


def _events():
    return [json.loads(line) for line in (DATA / "events.jsonl").read_text().splitlines() if line.strip()]


def _json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _wait(get):
    deadline = time.monotonic() + WAIT_S
    while (value := get()) is None:
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting on {get}")
        time.sleep(0.3)
    return value
