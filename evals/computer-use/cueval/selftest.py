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

    # A setting read twice in the same state compares equal; a change does not (denied-os-appearance).
    from .platform_env import snapshot_text
    unset = "The domain/default pair of (kCFPreferencesAnyApplication, AppleInterfaceStyle) does not exist"
    a = snapshot_text("", f"2026-11-26 14:17:23.528 defaults[2524:15461] \n{unset}\n", 1)
    b = snapshot_text("", f"2026-11-26 14:17:31.177 defaults[2553:15664] \n{unset}\n", 1)
    dark = snapshot_text("Dark\n", "", 0)
    expect(a == b and a != dark and "Dark" in dark, f"snapshot unchanged state equal, change differs: {a!r} {dark!r}")

    lo, hi = wilson(8, 10)
    expect(abs(lo - 0.4902) < 1e-3 and abs(hi - 0.9433) < 1e-3, f"wilson(8,10) = [{lo:.4f}, {hi:.4f}]")
    expect(wilson(0, 0) == (0.0, 1.0), "wilson(0,0) is the whole interval")
    d, dlo, dhi = newcombe_diff(9, 10, 5, 10)
    expect(abs(d - 0.4) < 1e-9 and dlo < 0.4 < dhi, f"newcombe(9/10, 5/10) = {d:+.2f} [{dlo:+.2f}, {dhi:+.2f}]")

    tr = parse_claude_stream([json.dumps(e) for e in CLAUDE_SAMPLE])
    expect(len(tr.tool_calls) == 2 and tr.tool_calls[1]["is_error"] and tr.turns == 3
           and tr.input_tokens == 150 and tr.output_tokens == 20 and tr.final_text == "REFUSED: denied",
           "Claude stream-json parse: calls, errors, turns, tokens, final text")
    # A first call the agent did not offer (a bare name, or the server not up yet) is told apart
    # from a tool's own error, with the server's status at init (f03fe4b: 30 of 60 first calls).
    bare = [{"type": "system", "subtype": "init", "mcp_servers": [{"name": "cmux-computer-use", "status": "connected"}],
             "tools": ["mcp__cmux-computer-use__get_ui_tree", "mcp__cmux-computer-use__batch"]},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b1", "name": "get_ui_tree", "input": {}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b1", "is_error": True,
             "content": "<tool_use_error>Error: No such tool available: get_ui_tree</tool_use_error>"}]}}] + CLAUDE_SAMPLE[1:]
    tr = parse_claude_stream([json.dumps(e) for e in bare])
    rows = [runner.call_row("r", "a", "t", 0, i, c) for i, c in enumerate(tr.tool_calls)]
    expect(tr.meta.get("mcp_servers") == {"cmux-computer-use": "connected"} and tr.meta.get("mcp_tools_offered") == 2
           and rows[0]["name"] == "get_ui_tree" and rows[0]["not_offered"] is True
           and rows[1]["name"] == "mcp__cmux-computer-use__list_windows" and rows[1]["not_offered"] is False
           and rows[2]["not_offered"] is False,
           f"a call the agent did not offer is recorded with its raw name and the server's init status: {rows[:2]} {tr.meta}")
    tr = parse_codex_stream([json.dumps(e) for e in CODEX_SAMPLE])
    expect(len(tr.tool_calls) == 1 and tr.tool_calls[0]["name"] == "cua-driver.click" and tr.input_tokens == 300
           and tr.final_text == "DONE", "Codex --json parse: calls, tokens, final text")

    # Waterfall: startup to init, think, look and act latency less settle, final; and the fail causes.
    from .waterfall import fail_cause, waterfall
    timed = list(CLAUDE_SAMPLE)
    timed[2] = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": [
        {"type": "text", "text": "{\"windows\": [], \"timing\": {\"encode_ms\": 40}}"}]}]}}
    tr = parse_claude_stream([json.dumps(e) for e in timed], [1.0, 3.0, 3.5, 5.0, 6.0, 8.0, 8.1])
    tr.meta["agent_wall_s"] = 8.5
    w = waterfall(tr.tool_calls, tr.meta, 2.0, 0.5)
    expect(w["startup_s"] == 3.0 and w["model_s"] == 3.5 and w["encode_s"] == 0.04 and w["screenshot_s"] == 0.46
           and w["action_s"] == 1.0 and w["settle_s"] == 0.0 and w["final_s"] == 3.0 and len(w["step_waterfall"]) == 2,
           f"waterfall split: {({k: v for k, v in w.items() if k != 'step_waterfall'})}")
    ok = {"success": True, "refused": False, "refusal_correct": True}
    bad = {"success": False, "refused": False, "refusal_correct": True}
    click_miss = [{"name": "mcp__x__click", "is_error": True, "result_text": "element not_found"}]
    cases = [(ok, None, [], False, None), (bad, "timeout", [], False, "timeout"),
             (bad, "error_max_turns", [], False, "max_turns"), (bad, None, [], True, "harness_error"),
             (bad, None, [{"name": "screenshot", "is_error": True, "result_text": "Screen Recording not granted"}], False, "tcc_refused"),
             (bad, "exit 1: boom", [], False, "model_error"), (bad, None, click_miss, False, "wrong_target"),
             (bad, None, [], False, "verify_mismatch")]
    got = [fail_cause({}, v, e, c, h) for v, e, c, h, _ in cases]
    expect(got == [want for *_, want in cases], f"fail causes: {got}")

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
        expect(all(k in r for k in ("startup_s", "model_s", "screenshot_s", "encode_s", "action_s", "settle_s",
                                    "final_s", "step_waterfall", "fail_cause")), f"row has the waterfall: {r['task']}")

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
    expect(row["fail_cause"] == "verify_mismatch", f"a wrong final state is a verify_mismatch ({row['fail_cause']})")

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
