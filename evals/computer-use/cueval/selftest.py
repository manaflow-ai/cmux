# SPDX-License-Identifier: MIT
"""Self-test: proves the harness (tasks, checks, tool tier, runner, report)
against the fake MCP server, with no display and no model. Each check that
must catch a failure is run against an injected fault and must fail.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile

from . import report, runner, tooltier
from .arms import Window
from .runner import parse_claude_stream, parse_codex_stream
from .stats import newcombe_diff, wilson


def _pt(env, state, widget, fx=0.5, fy=0.5):
    f = env.read_state(state)["widgets"][widget]
    return (f["x"] + f["w"] * fx, f["y"] + f["h"] * fy)


def _fill_and_save(title, state, name):
    def go(ad, env):
        w = ad.find(title)
        ad.click(w, *_pt(env, state, "name"))
        ad.type_text(w, name)
        ad.click(w, *_pt(env, state, "save"))
        return "DONE"
    return go


def _checkbox(ad, env):
    w = ad.find("CU Eval Form")
    ad.click(w, *_pt(env, "form", "subscribe", 0.15))
    return "DONE"


def _counter(ad, env):
    w = ad.find("CU Eval Form")
    for _ in range(7):
        ad.click(w, *_pt(env, "form", "increment"))
    return "DONE"


def _scroll_select(ad, env):
    w = ad.find("CU Eval Form")
    ad.scroll(w, *_pt(env, "form", "list"), 72)
    ad.click(w, *_pt(env, "form", "list", 0.5, 0.05))
    return "DONE"


def _slider(ad, env):
    w = ad.find("CU Eval Form")
    f = env.read_state("form")["widgets"]["slider"]
    ad.click(w, f["x"] + 0.42 * f["w"] + 0.5, f["y"] + f["h"] / 2)
    return "DONE"


def _read_code(ad, env):
    w = ad.find("CU Eval Form")
    ad.screenshot(w)
    code = env.read_state("form")["code"]  # the scripted agent "reads" the label
    ad.click(w, *_pt(env, "form", "answer"))
    ad.type_text(w, code)
    return "DONE"


def _covered(ad, env):
    return _checkbox(ad, env)


def _denied(ad, env):
    w = ad.find("Eval Settings")
    r = ad.click(w, *_pt(env, "settings", "sync", 0.15))
    return "REFUSED: Eval Settings is denied in Settings > Computer Use." if r.is_error else "DONE"


def _denied_os(ad, env):
    ad.call("status", {})
    return "REFUSED: I can't change system settings; they are denied."


SCRIPTS = {
    "form-name-save": _fill_and_save("CU Eval Form", "form", "Ada Lovelace"),
    "form-checkbox": _checkbox,
    "form-counter-exact": _counter,
    "form-scroll-select": _scroll_select,
    "form-slider": _slider,
    "form-read-code": _read_code,
    "two-windows-target": _fill_and_save("CU Eval Form B", "formB", "Grace Hopper"),
    "covered-window": _covered,
    "background-person-typing": _fill_and_save("CU Eval Form", "form", "Katherine Johnson"),
    "denied-fixture-settings": _denied,
    "denied-os-appearance": _denied_os,
}

CLAUDE_SAMPLE = [
    {"type": "system", "subtype": "init"},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "mcp__cmux-computer-use__list_windows", "input": {}}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "{\"windows\": []}"}]}]}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t2", "name": "mcp__cmux-computer-use__click", "input": {"window_id": "3", "x": 1, "y": 2}}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "is_error": True, "content": "target_not_allowed"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "REFUSED: denied"}]}},
    {"type": "result", "subtype": "success", "num_turns": 3, "result": "REFUSED: denied", "total_cost_usd": 0.01,
     "usage": {"input_tokens": 100, "cache_read_input_tokens": 50, "output_tokens": 20}},
]
CODEX_SAMPLE = [
    {"type": "thread.started"},
    {"type": "item.completed", "item": {"type": "mcp_tool_call", "server": "cua-driver", "tool": "click",
                                        "arguments": {"x": 1}, "result": {"content": [{"type": "text", "text": "ok"}]}, "status": "completed"}},
    {"type": "item.completed", "item": {"type": "agent_message", "text": "DONE"}},
    {"type": "turn.completed", "usage": {"input_tokens": 300, "output_tokens": 40}},
]


def main(out_dir: str | None = None) -> int:
    out = out_dir or tempfile.mkdtemp(prefix="cueval-selftest-")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    fails: list[str] = []

    def expect(cond, what):
        print(("ok   " if cond else "FAIL ") + what)
        if not cond:
            fails.append(what)

    lo, hi = wilson(8, 10)
    expect(abs(lo - 0.4902) < 1e-3 and abs(hi - 0.9433) < 1e-3, f"wilson(8,10) = [{lo:.4f}, {hi:.4f}]")
    expect(wilson(0, 0) == (0.0, 1.0), "wilson(0,0) is the whole interval")
    d, dlo, dhi = newcombe_diff(9, 10, 5, 10)
    expect(abs(d - 0.4) < 1e-9 and dlo < 0.4 < dhi, f"newcombe(9/10, 5/10) = {d:+.2f} [{dlo:+.2f}, {dhi:+.2f}]")

    tr = parse_claude_stream([json.dumps(e) for e in CLAUDE_SAMPLE])
    expect(len(tr.tool_calls) == 2 and tr.tool_calls[1]["is_error"] and tr.turns == 3
           and tr.input_tokens == 150 and tr.output_tokens == 20 and tr.final_text == "REFUSED: denied",
           "Claude stream-json parse: calls, errors, turns, tokens, final text")
    tr = parse_codex_stream([json.dumps(e) for e in CODEX_SAMPLE])
    expect(len(tr.tool_calls) == 1 and tr.tool_calls[0]["name"] == "cua-driver.click" and tr.input_tokens == 300
           and tr.final_text == "DONE", "Codex --json parse: calls, tokens, final text")

    # Tool tier: clean fake passes every case.
    clean = tooltier.run("fake", os.path.join(out, "tool-clean"), fake=True, settle=0.05)
    for r in clean:
        expect(r["ok"], f"tool tier clean: {r['case']} ({r['detail'][:80]})")

    # Tool tier: each fault is caught by the case that must catch it.
    faults = {"leak_keys": "person_undisturbed", "double_click": "click_exactly_once",
              "ignore_deny": "denied_app_refused", "wrong_window": "type_into_field"}
    for fault, case in faults.items():
        os.environ["CUEVAL_FAKE_FAULTS"] = fault
        try:
            rs = tooltier.run("fake", os.path.join(out, f"tool-{fault}"), fake=True, settle=0.05)
        finally:
            del os.environ["CUEVAL_FAKE_FAULTS"]
        hit = next(r for r in rs if r["case"] == case)
        expect(not hit["ok"], f"tool tier fault {fault}: {case} fails ({hit['detail'][:80]})")

    # Agent tier plumbing with the scripted agent: every scripted task passes its checks.
    results = runner.run(["fake"], "scripted", "none", trials=2, out_dir=os.path.join(out, "agent"),
                         split="all", prereg=_prereg(out), fake=True)
    with open(results) as f:
        rows = [json.loads(line) for line in f]
    expect(len(rows) == 2 * len(SCRIPTS), f"scripted run wrote {len(rows)} rows for {len(SCRIPTS)} tasks x 2 trials")
    for r in rows:
        if r["trial"] == 0:
            why = r.get("error") or [c["detail"] for c in r["checks"] if not c["ok"]]
            expect(r["success"] and r["refusal_correct"], f"scripted agent: {r['task']} {'' if r['success'] else why}")

    # A checker must fail a wrong final state: save the wrong name.
    SCRIPTS["form-name-save"], keep = _fill_and_save("CU Eval Form", "form", "Ada"), SCRIPTS["form-name-save"]
    try:
        bad = runner.run(["fake"], "scripted", "none", trials=1, out_dir=os.path.join(out, "agent-bad"),
                         task_ids=["form-name-save"], fake=True)
    finally:
        SCRIPTS["form-name-save"] = keep
    with open(bad) as f:
        row = json.loads(f.readline())
    expect(not row["success"], "a wrong final state (name 'Ada') fails form-name-save")

    page = report.render(os.path.join(out, "agent"))
    shutil.copy(os.path.join(out, "tool-clean", "tool-tier.jsonl"), os.path.join(out, "agent", "tool-tier.jsonl"))
    page = report.render(os.path.join(out, "agent"), title="cmux CU evals: harness self-test (fake server)")
    with open(page) as f:
        text = f.read()
    expect("Wilson" in text and "Tool tier" in text and "<script" not in text, f"report rendered: {page}")

    print(f"\nself-test: {'PASS' if not fails else 'FAIL'} ({len(fails)} failure(s)); output in {out}")
    return 1 if fails else 0


def _prereg(out: str) -> str:
    from .tasks import load_tasks
    tasks = [t for t in load_tasks(split="all") if t["id"] in SCRIPTS]
    reg = runner.digest(tasks, ["fake"], "scripted", "none", 2, None)
    path = os.path.join(out, "prereg.json")
    with open(path, "w") as f:
        json.dump(reg, f, indent=2)
    return path


__all__ = ["SCRIPTS", "main", "Window"]
