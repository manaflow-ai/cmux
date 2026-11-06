# SPDX-License-Identifier: MIT
"""A fake computer-use MCP server for the harness self-test (stdlib only).

It speaks cmux's tool shapes over stdio and simulates the fixture windows by
writing the same state files the real fixtures write, so every checker, the
tool tier, the runner and the report run anywhere, with no display and no model.

CUEVAL_FAKE_DESKTOP  {"windows": [{"kind", "title", "state", "app_id"}]}
CUEVAL_FAKE_DENIED   JSON list of denied app matchers (exact id, prefix*, name:Title)
CUEVAL_FAKE_FAULTS   comma list, to prove the checks catch failures:
                     leak_keys (keys also reach the person window), double_click,
                     ignore_deny, wrong_window (acts on the last window listed)
"""

from __future__ import annotations

import base64
import json
import os
import struct
import sys
import zlib

FORM_WIDGETS = {
    "name": (100, 10, 200, 24), "subscribe": (100, 40, 180, 24), "increment": (10, 70, 80, 24),
    "answer": (100, 100, 200, 24), "save": (300, 130, 60, 24), "list": (10, 160, 400, 96),
    "slider": (10, 270, 240, 30), "code": (10, 310, 300, 20),
}
ROW_H = 16
SETTINGS_WIDGETS = {"sync": (20, 20, 120, 24)}
PERSON_WIDGETS = {"notes": (0, 0, 420, 260)}


def png(w: int, h: int) -> bytes:
    raw = b"".join(b"\x00" + b"\xee\xee\xee" * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Win:
    def __init__(self, wid: int, spec: dict, pid: int):
        self.id, self.kind, self.title, self.path = wid, spec["kind"], spec["title"], spec["state"]
        self.app_id = spec.get("app_id", "fixture")
        self.focus: str | None = None
        widgets = {"form": FORM_WIDGETS, "settings": SETTINGS_WIDGETS, "person": PERSON_WIDGETS}.get(self.kind, {})
        size = {"form": (420, 520), "settings": (240, 120), "person": (420, 260)}.get(self.kind, (400, 300))
        self.state = {"mode": self.kind, "title": self.title, "pid": pid, "has_focus": self.kind == "person",
                      "window": {"x": 40 * wid, "y": 40, "w": size[0], "h": size[1]},
                      "widgets": {k: {"x": x, "y": y, "w": w, "h": h} for k, (x, y, w, h) in widgets.items()}}
        if self.kind == "form":
            self.state.update(name="", subscribe=False, counter=0, answer="", saved=False, saved_name=None,
                              selected=None, first_visible=1, slider=0, code=spec.get("code") or "0000")
        elif self.kind == "settings":
            self.state.update(sync=False)
        elif self.kind == "person":
            self.state.update(typed="", keys_received=[], focus_lost=0)
        self.save()

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=1, sort_keys=True)
        os.replace(tmp, self.path)

    def hit(self, x: float, y: float) -> str | None:
        for name, f in self.state["widgets"].items():
            if f["x"] <= x < f["x"] + f["w"] and f["y"] <= y < f["y"] + f["h"]:
                return name
        return None

    def click(self, x: float, y: float):
        s, w = self.state, self.hit(x, y)
        if self.kind == "settings" and w == "sync":
            s["sync"] = not s["sync"]
        elif self.kind == "form":
            if w in ("name", "answer"):
                self.focus = w
            elif w == "subscribe":
                s["subscribe"] = not s["subscribe"]
            elif w == "increment":
                s["counter"] += 1
            elif w == "save":
                s["saved"], s["saved_name"] = True, s["name"]
            elif w == "list":
                s["selected"] = s["first_visible"] + int((y - FORM_WIDGETS["list"][1]) // ROW_H)
            elif w == "slider":
                s["slider"] = max(0, min(100, round((x - 10) / 240 * 100)))
        self.save()

    def type_text(self, text: str):
        if self.kind == "person":
            self.state["keys_received"].extend(text)
        elif self.focus:
            self.state[self.focus] += text
        self.save()

    def press(self, keys: str):
        if self.kind == "person":
            self.state["keys_received"].append(keys)
        elif keys.lower() in ("return", "enter") and self.focus == "name":
            self.state["saved"], self.state["saved_name"] = True, self.state["name"]
        self.save()

    def scroll(self, dy: float):
        if self.kind == "form":
            self.state["first_visible"] = max(1, min(95, self.state["first_visible"] + int(dy)))
            self.save()


class Server:
    def __init__(self):
        spec = json.loads(os.environ.get("CUEVAL_FAKE_DESKTOP", '{"windows": []}'))
        self.windows = [Win(i + 1, w, 10_000 + i) for i, w in enumerate(spec["windows"])]
        self.denied = json.loads(os.environ.get("CUEVAL_FAKE_DENIED", "[]"))
        self.faults = set(filter(None, os.environ.get("CUEVAL_FAKE_FAULTS", "").split(",")))

    def is_denied(self, w: Win) -> bool:
        if "ignore_deny" in self.faults:
            return False
        for m in self.denied:
            if m.startswith("name:") and m[5:] == w.title:
                return True
            if m.endswith("*") and w.app_id.startswith(m[:-1]):
                return True
            if m == w.app_id:
                return True
        return False

    def tools(self):
        def t(name, props, req=()):
            return {"name": name, "description": f"fake {name}",
                    "inputSchema": {"type": "object", "properties": props, "required": list(req)}}
        wid = {"type": "string"}
        return [t("status", {}), t("list_apps", {}), t("list_windows", {"app_id": {"type": "string"}}),
                t("screenshot", {"window_id": wid, "force": {"type": "boolean"}}),
                t("click", {"window_id": wid, "x": {"type": "number"}, "y": {"type": "number"}}),
                t("type_text", {"window_id": wid, "text": {"type": "string"}}, ("window_id", "text")),
                t("press_key", {"window_id": wid, "keys": {"type": "string"}}, ("window_id", "keys")),
                t("scroll", {"window_id": wid, "x": {"type": "number"}, "y": {"type": "number"},
                             "dy": {"type": "number"}}, ("window_id",))]

    def win(self, args) -> Win:
        if "wrong_window" in self.faults:
            return self.windows[-1]
        wid = int(args.get("window_id", 0))
        for w in self.windows:
            if w.id == wid:
                return w
        raise KeyError(f"no window {wid}")

    def person(self) -> Win | None:
        return next((w for w in self.windows if w.kind == "person"), None)

    def call(self, name: str, a: dict):
        text = lambda obj: {"content": [{"type": "text", "text": json.dumps(obj)}]}  # noqa: E731
        if name == "status":
            return text({"platform": "fake", "mode": "fullAccess", "denied_apps": self.denied})
        if name == "list_apps":
            return text({"apps": [{"id": w.app_id, "name": w.title, "denied": self.is_denied(w)} for w in self.windows]})
        if name == "list_windows":
            return text({"windows": [{"window_id": str(w.id), "app_id": w.app_id, "title": w.title, "pid": w.state["pid"],
                                      "frame": w.state["window"], "on_screen": True} for w in self.windows]})
        w = self.win(a)
        if self.is_denied(w):
            return {"isError": True, "content": [{"type": "text", "text": json.dumps(
                {"error": "target_not_allowed", "message": f"{w.title} is denied in Settings > Computer Use"})}]}
        if name == "screenshot":
            win = w.state["window"]
            return {"content": [{"type": "image", "mimeType": "image/png",
                                 "data": base64.b64encode(png(win["w"], win["h"])).decode()},
                                {"type": "text", "text": json.dumps({"width": win["w"], "height": win["h"]})}]}
        if name == "click":
            w.click(a.get("x", 0), a.get("y", 0))
            if "double_click" in self.faults:
                w.click(a.get("x", 0), a.get("y", 0))
        elif name == "type_text":
            w.type_text(a["text"])
            if "leak_keys" in self.faults and self.person():
                self.person().type_text(a["text"])
        elif name == "press_key":
            w.press(a["keys"])
            if "leak_keys" in self.faults and self.person():
                self.person().press(a["keys"])
        elif name == "scroll":
            w.scroll(a.get("dy", 0))
        else:
            return {"isError": True, "content": [{"type": "text", "text": f"unknown tool {name}"}]}
        return text({"ok": True})


def main():
    srv = Server()
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        if "id" not in msg:
            continue
        method, params = msg.get("method"), msg.get("params") or {}
        try:
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "cueval-fake", "version": "1"}}
            elif method == "tools/list":
                result = {"tools": srv.tools()}
            elif method == "tools/call":
                result = srv.call(params["name"], params.get("arguments") or {})
            else:
                raise KeyError(f"method {method}")
            out = {"jsonrpc": "2.0", "id": msg["id"], "result": result}
        except Exception as e:
            out = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": str(e)}}
        sys.stdout.write(json.dumps(out) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
