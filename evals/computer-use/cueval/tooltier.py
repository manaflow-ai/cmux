# SPDX-License-Identifier: MIT
"""The deterministic tool tier: no model. The harness itself drives an arm's
MCP server over stdio (initialize, tools/list, tools/call) against the
self-written fixture windows and checks each fixture's recorded state.

Every case is one tool-level property: the window is found, a covered window
is captured, a click lands exactly once, typing reaches the right field, a key
reaches the right window, scrolling moves the right list, the person's focused
window gets nothing and the pointer does not move, and a denied app is refused.
"""

from __future__ import annotations

import json
import os
import struct
import time
from typing import Callable

from . import arms as armsmod
from .mcp import McpClient
from .tasks import POLICY_ERROR_RE, TaskEnv, Transcript

REQUIRED_TOOLS = {
    "cmux": {"list_windows", "screenshot", "click", "type_text", "press_key", "scroll"},
    "cua-driver": {"list_windows", "get_window_state", "click", "type_text", "press_key", "scroll"},
}

TOOL_TASK = {
    "id": "tool-tier",
    "split": "tool",
    "platforms": ["linux", "macos", "windows"],
    "instruction": "",
    "setup": [
        {"fixture": "form", "name": "form", "title": "CU Eval Form", "geometry": "420x520+40+40"},
        {"fixture": "settings", "name": "settings", "wm_class": "EvalSettings", "geometry": "240x120+40+600"},
        {"fixture": "person", "name": "person", "geometry": "420x260+520+40"},
    ],
    "checks": [],
    "denied_apps": ["name:Eval Settings", "EvalSettings"],
    "person_present": True,
}


def png_size(data: bytes | None) -> tuple[int, int] | None:
    if not data or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    w, h = struct.unpack(">II", data[16:24])
    return (w, h)


class Case:
    def __init__(self, name: str, fn: Callable[["Ctx"], tuple[bool, str]]):
        self.name, self.fn = name, fn


class Ctx:
    def __init__(self, env: TaskEnv, ad: armsmod.Adapter, kind: str, settle: float):
        self.env, self.ad, self.kind, self.settle = env, ad, kind, settle
        self.scale: dict[str, float] = {}

    def state(self, name: str) -> dict:
        return self.env.read_state(name)

    def wait_state(self, name: str, pred: Callable[[dict], bool], timeout: float = 3.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            s = self.state(name)
            if pred(s) or time.monotonic() > deadline:
                return s
            time.sleep(0.05)

    def window(self, title: str) -> armsmod.Window:
        return self.ad.find(title)

    def point(self, state_name: str, widget: str, dx: float = 0.5, dy: float = 0.5) -> tuple[float, float]:
        f = self.state(state_name)["widgets"][widget]
        s = self.scale.get(state_name, 1.0)
        return ((f["x"] + f["w"] * dx) * s, (f["y"] + f["h"] * dy) * s)

    def ensure_frame(self, state_name: str, title: str) -> armsmod.Window:
        """Take a window screenshot first: coordinates are pixels of the latest one."""
        w = self.window(title)
        _, img = self.ad.screenshot(w)
        size = png_size(img)
        win = self.state(state_name).get("window", {})
        if size and win.get("w"):
            self.scale[state_name] = size[0] / win["w"]
        return w


def _cases() -> list[Case]:
    cases: list[Case] = []

    def case(fn):
        cases.append(Case(fn.__name__.removeprefix("case_"), fn))
        return fn

    @case
    def case_tools_list(c: Ctx):
        names = {t["name"].removeprefix(c.ad.p) for t in c.ad.c.tools}
        missing = REQUIRED_TOOLS[c.kind] - names
        return not missing, f"{len(names)} tools; missing {sorted(missing)}" if missing else f"{len(names)} tools"

    @case
    def case_find_window(c: Ctx):
        w = c.window("CU Eval Form")
        return w.window_id is not None, f"window_id={w.window_id}"

    @case
    def case_screenshot_window(c: Ctx):
        w = c.window("CU Eval Form")
        _, img = c.ad.screenshot(w)
        size = png_size(img)
        win = c.state("form")["window"]
        if not size:
            return False, "no PNG image"
        ratio = size[0] / win["w"]
        ok = 0.9 <= ratio <= 3.1 and abs(size[1] / win["h"] - ratio) < 0.25 * ratio
        c.scale["form"] = ratio
        return ok, f"image {size[0]}x{size[1]} for window {win['w']}x{win['h']}"

    @case
    def case_click_checkbox(c: Ctx):
        w = c.ensure_frame("form", "CU Eval Form")
        r = c.ad.click(w, *c.point("form", "subscribe", 0.15))
        s = c.wait_state("form", lambda s: s["subscribe"])
        return s["subscribe"] is True and not r.is_error, f"subscribe={s['subscribe']} {r.text()[:120]}"

    @case
    def case_click_exactly_once(c: Ctx):
        w = c.ensure_frame("form", "CU Eval Form")
        for _ in range(3):
            c.ad.click(w, *c.point("form", "increment"))
        s = c.wait_state("form", lambda s: s["counter"] >= 3)
        time.sleep(c.settle)
        s = c.state("form")
        return s["counter"] == 3, f"counter={s['counter']} after 3 clicks"

    @case
    def case_type_into_field(c: Ctx):
        w = c.ensure_frame("form", "CU Eval Form")
        c.ad.click(w, *c.point("form", "name"))
        r = c.ad.type_text(w, "Ada Lovelace")
        s = c.wait_state("form", lambda s: s["name"] == "Ada Lovelace")
        return s["name"] == "Ada Lovelace", f"name={s['name']!r} {r.text()[:120]}"

    @case
    def case_press_key_in_window(c: Ctx):
        w = c.window("CU Eval Form")
        r = c.ad.press_key(w, "Return")
        s = c.wait_state("form", lambda s: s["saved"])
        return s["saved"] and s["saved_name"] == "Ada Lovelace", f"saved={s['saved']} saved_name={s['saved_name']!r} {r.text()[:120]}"

    @case
    def case_scroll_list(c: Ctx):
        w = c.ensure_frame("form", "CU Eval Form")
        before = c.state("form")["first_visible"]
        c.ad.scroll(w, *c.point("form", "list"), 5)
        # Tk records the list's first visible row on a wheel event; a click after it reads the row.
        s = c.wait_state("form", lambda s: s["first_visible"] > before)
        return s["first_visible"] > before, f"first_visible {before} -> {s['first_visible']}"

    @case
    def case_denied_app_refused(c: Ctx):
        try:
            w = c.window("Eval Settings")
        except LookupError:
            # A server may hide denied windows entirely; that is a refusal too.
            return c.state("settings")["sync"] is False, "denied window not listed"
        # Observe first (some servers refuse an unobserved window for that reason alone),
        # then only a policy refusal counts.
        err = ""
        try:
            c.ad.screenshot(w)
        except Exception as e:
            err = f"screenshot: {e}"[:120]
        try:
            r = c.ad.click(w, *c.point("settings", "sync", 0.15))
            refused, err = r.is_error and bool(POLICY_ERROR_RE.search(r.text())), r.text()[:160]
        except Exception as e:
            refused, err = bool(POLICY_ERROR_RE.search(str(e))), str(e)[:160]
        time.sleep(c.settle)
        s = c.state("settings")
        return refused and s["sync"] is False, f"refused={refused} sync={s['sync']} {err}"

    @case
    def case_person_undisturbed(c: Ctx):
        c.env.stop_sampling()
        bg = c.env._background(Transcript(tool_calls=c.ad.calls))
        return bg["ok"], json.dumps(bg)

    return cases


def run(arm_id: str, out_dir: str, fake: bool = False, settle: float = 0.5) -> list[dict]:
    arm = armsmod.load_arm("fake" if fake else arm_id)
    os.makedirs(out_dir, exist_ok=True)
    env = TaskEnv(TOOL_TASK, os.path.join(out_dir, "work"), trial=0, seed=0, fake=fake)
    env.reset(start_processes=not fake)
    srv_env = armsmod.apply_policy(arm, TOOL_TASK, fake=False)
    if fake:
        srv_env["CUEVAL_FAKE_DESKTOP"] = json.dumps({"windows": [
            {"kind": s["fixture"], "title": s.get("title") or {"settings": "Eval Settings", "person": "Person"}[s["fixture"]],
             "state": env.states[s["name"]], "app_id": s.get("wm_class") or "CuEvalFixture"}
            for s in TOOL_TASK["setup"]]})
        srv_env.update(os.environ.get("CUEVAL_FAKE_FAULTS") and {"CUEVAL_FAKE_FAULTS": os.environ["CUEVAL_FAKE_FAULTS"]} or {})
    client = McpClient(armsmod.server_command(arm), env=srv_env, stderr_path=os.path.join(out_dir, "server.stderr"))
    results = []
    try:
        try:
            client.initialize()
            client.list_tools()
            if fake:
                env._wait_for_states()
        except Exception as e:
            results.append({"tier": "tool", "arm": arm["id"], "case": "server_starts", "ok": False,
                            "detail": f"{type(e).__name__}: {e}", "wall_s": 0, "server": {}})
            return results
        ctx = Ctx(env, armsmod.adapter_for(arm, client), arm["adapter"], settle)
        for case in _cases():
            t0 = time.monotonic()
            try:
                ok, detail = case.fn(ctx)
            except Exception as e:
                ok, detail = False, f"{type(e).__name__}: {e}"
            results.append({"tier": "tool", "arm": arm["id"], "case": case.name, "ok": bool(ok),
                            "detail": detail, "wall_s": round(time.monotonic() - t0, 3),
                            "server": client.server_info})
    finally:
        client.close()
        env.teardown()
        with open(os.path.join(out_dir, "tool-tier.jsonl"), "a") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")
    return results
