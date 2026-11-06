# SPDX-License-Identifier: MIT
"""End-to-end agent task evals: one agent (Claude Code or Codex, headless),
one model, one prompt, the same limits, and a computer-use MCP server per arm.
Each attempt is reset, run and checked; one JSONL row per attempt.
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

from . import arms as armsmod
from . import platform_env as penv
from .mcp import McpClient
from .tasks import ROOT, TaskEnv, Transcript, load_tasks, task_set_digest

PROMPT_PATH = os.path.join(ROOT, "prompts", "system.md")


def prompt_text() -> str:
    with open(PROMPT_PATH) as f:
        return f.read()


def digest(tasks: list[dict], arm_ids: list[str], agent: str, model: str, trials: int, max_turns_cap: int | None) -> dict:
    arm_blobs = {a: json.dumps(armsmod.load_arm(a), sort_keys=True) for a in arm_ids}
    parts = {
        "tasks": task_set_digest(tasks),
        "arms": hashlib.sha256(json.dumps(arm_blobs, sort_keys=True).encode()).hexdigest(),
        "prompt": hashlib.sha256(prompt_text().encode()).hexdigest(),
        "agent": agent, "model": model, "trials": trials, "max_turns_cap": max_turns_cap,
    }
    parts["digest"] = hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()
    return parts


# ---------------------------------------------------------------- Claude Code

def parse_claude_stream(lines: list[str]) -> Transcript:
    tr = Transcript()
    pending: dict[str, dict] = {}
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        kind = ev.get("type")
        if kind == "assistant":
            tr.turns += 1
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    call = {"name": block.get("name", ""), "args": block.get("input", {}), "result_text": "", "is_error": False}
                    pending[block.get("id", "")] = call
                    tr.tool_calls.append(call)
                elif block.get("type") == "text":
                    tr.final_text = block.get("text", "")
        elif kind == "user":
            content = ev.get("message", {}).get("content", [])
            for block in content if isinstance(content, list) else []:
                if block.get("type") == "tool_result" and block.get("tool_use_id") in pending:
                    call = pending[block["tool_use_id"]]
                    body = block.get("content")
                    if isinstance(body, list):
                        body = "\n".join(b.get("text", "") for b in body if b.get("type") == "text")
                    call["result_text"] = (body or "")[:4000]
                    call["is_error"] = bool(block.get("is_error"))
        elif kind == "result":
            tr.turns = ev.get("num_turns", tr.turns)
            usage = ev.get("usage") or {}
            tr.input_tokens = sum(usage.get(k, 0) or 0 for k in
                                  ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            tr.output_tokens = usage.get("output_tokens")
            tr.cost_usd = ev.get("total_cost_usd")
            if ev.get("result"):
                tr.final_text = ev["result"]
            if ev.get("is_error") and ev.get("subtype") not in (None, "success"):
                tr.error = ev.get("subtype")
    return tr


def run_claude(arm: dict, env_vars: dict, instruction: str, model: str, max_turns: int, timeout: float, log: str) -> Transcript:
    server = arm["mcp"]["server_name"]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(armsmod.mcp_config(arm, env_vars), f)
        cfg = f.name
    cmd = [os.environ.get("CUEVAL_CLAUDE", "claude"), "-p", instruction,
           "--mcp-config", cfg, "--strict-mcp-config",
           "--tools", "",  # no built-in tools: the computer-use server is the only way to act
           "--allowedTools", f"mcp__{server}",
           "--append-system-prompt", prompt_text(),
           "--output-format", "stream-json", "--verbose",
           "--max-turns", str(max_turns), "--model", model]
    return _run_and_parse(cmd, timeout, log, parse_claude_stream)


# ---------------------------------------------------------------- Codex

def parse_codex_stream(lines: list[str]) -> Transcript:
    tr = Transcript()
    tr.input_tokens = tr.output_tokens = 0
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        kind = ev.get("type")
        item = ev.get("item") or {}
        if kind == "item.completed" and item.get("type") == "mcp_tool_call":
            result = item.get("result") or {}
            text = "\n".join(c.get("text", "") for c in (result.get("content") or []) if c.get("type") == "text")
            tr.tool_calls.append({"name": f"{item.get('server', '')}.{item.get('tool', '')}",
                                  "args": item.get("arguments") or {},
                                  "result_text": (text or json.dumps(item.get("error") or ""))[:4000],
                                  "is_error": bool(item.get("error")) or item.get("status") == "failed" or bool(result.get("isError"))})
        elif kind == "item.completed" and item.get("type") == "agent_message":
            tr.final_text = item.get("text", "")
            tr.turns += 1
        elif kind == "turn.completed":
            usage = ev.get("usage") or {}
            tr.input_tokens += usage.get("input_tokens", 0) or 0
            tr.output_tokens += usage.get("output_tokens", 0) or 0
        elif kind in ("turn.failed", "error"):
            tr.error = json.dumps(ev.get("error") or ev)[:400]
    tr.turns = max(tr.turns, len(tr.tool_calls))
    return tr


def run_codex(arm: dict, env_vars: dict, instruction: str, model: str, max_turns: int, timeout: float, log: str) -> Transcript:
    cfg = armsmod.mcp_config(arm, env_vars)["mcpServers"][arm["mcp"]["server_name"]]
    name = arm["mcp"]["server_name"].replace("-", "_")
    toml = lambda v: json.dumps(v)  # noqa: E731  JSON strings and arrays are valid TOML values
    cmd = [os.environ.get("CUEVAL_CODEX", "codex"), "exec", "--json", "--skip-git-repo-check",
           "--sandbox", "read-only", "-m", model,
           "-c", f"mcp_servers.{name}.command={toml(cfg['command'])}",
           "-c", f"mcp_servers.{name}.args={toml(cfg['args'])}"]
    for k, v in cfg["env"].items():
        cmd += ["-c", f"mcp_servers.{name}.env.{k}={toml(v)}"]
    cmd += [prompt_text() + "\n\nTask: " + instruction]
    tr = _run_and_parse(cmd, timeout, log, parse_codex_stream)
    if len(tr.tool_calls) > max_turns and tr.error is None:
        tr.error = f"over the {max_turns}-step limit"  # codex exec has no turn cap flag; enforce it here
    return tr


def _run_and_parse(cmd: list[str], timeout: float, log: str, parse) -> Transcript:
    with open(log + ".cmd", "w") as f:
        f.write(" ".join(shlex.quote(c) for c in cmd) + "\n")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out, err, code = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        err, code = "timeout", None
    with open(log, "w") as f:
        f.write(out)
    with open(log + ".stderr", "w") as f:
        f.write(err or "")
    tr = parse(out.splitlines())
    if code is None:
        tr.error = "timeout"
    elif code != 0 and tr.error is None and not tr.final_text:
        tr.error = f"exit {code}: {(err or '')[-300:]}"
    return tr


# ---------------------------------------------------------------- scripted (self-test)

def run_scripted(arm: dict, env_vars: dict, env: TaskEnv, log: str) -> Transcript:
    """A fixed solution per task over the fake server; proves runner, checks and report."""
    from .selftest import SCRIPTS
    client = McpClient(armsmod.server_command(arm), env=env_vars, stderr_path=log + ".stderr")
    try:
        client.initialize()
        client.list_tools()
        env._wait_for_states()
        ad = armsmod.adapter_for(arm, client)
        final = SCRIPTS[env.task["id"]](ad, env)
        return Transcript(tool_calls=ad.calls, final_text=final, turns=len(ad.calls) + 1)
    finally:
        client.close()


def fake_desktop(task: dict, env: TaskEnv) -> dict:
    wins = []
    for s in task["setup"]:
        s = env.render(s)
        if s.get("fixture") in ("form", "settings", "person"):
            wins.append({"kind": s["fixture"], "state": env.states[s["name"]], "code": s.get("code"),
                         "title": s.get("title") or {"form": "CU Eval Form", "settings": "Eval Settings", "person": "Person"}[s["fixture"]],
                         "app_id": s.get("wm_class") or "CuEvalFixture"})
    return {"windows": wins}


# ---------------------------------------------------------------- the run loop

def run(arm_ids: list[str], agent: str, model: str, trials: int, out_dir: str, task_ids=None, split="dev",
        seed: int = 1, prereg: str | None = None, max_turns_cap: int | None = None, fake: bool = False) -> str:
    plat = penv.platform_name() if not fake else None
    tasks = load_tasks(task_ids, split, plat)
    if fake:
        from .selftest import SCRIPTS
        tasks = [t for t in tasks if t["id"] in SCRIPTS]
    if split in ("heldout", "all") and not prereg:
        raise SystemExit("held-out tasks run only under a pre-registration (--prereg FILE from `cueval prereg`)")
    reg = digest(load_tasks(task_ids, split, plat) if not fake else tasks, arm_ids, agent, model, trials, max_turns_cap)
    if prereg:
        with open(prereg) as f:
            want = json.load(f)
        if want.get("digest") != reg["digest"]:
            raise SystemExit(f"this run does not match the pre-registration {prereg}: "
                             f"{ {k: (want.get(k), reg[k]) for k in reg if want.get(k) != reg[k]} }")
    os.makedirs(out_dir, exist_ok=True)
    run_id = time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:6]
    results = os.path.join(out_dir, "results.jsonl")
    logs = os.path.join(out_dir, "logs", run_id)
    os.makedirs(logs, exist_ok=True)
    rng = random.Random(seed)
    arms = {a: armsmod.load_arm(a) for a in arm_ids}
    schedule = []
    for trial in range(trials):
        for task in tasks:
            order = list(arm_ids)
            rng.shuffle(order)  # interleave arms so drift in the machine or the model hits both
            schedule += [(trial, task, a) for a in order]
    for trial, task, arm_id in schedule:
        arm = arms[arm_id]
        env = TaskEnv(task, os.path.join(out_dir, "work"), trial, seed, fake=fake)
        log = os.path.join(logs, f"{task['id']}-{arm_id}-t{trial}.jsonl")
        t0 = time.monotonic()
        try:
            env.reset(start_processes=not fake)
            srv_env = armsmod.apply_policy(arm, task, fake=False)
            if fake:
                srv_env["CUEVAL_FAKE_DESKTOP"] = json.dumps(fake_desktop(task, env))
                tr = run_scripted(arm, srv_env, env, log)
            else:
                limit = min(task["max_turns"], max_turns_cap or task["max_turns"])
                driver = {"claude": run_claude, "codex": run_codex}[agent]
                tr = driver(arm, srv_env, env.instruction, model, limit, task["timeout_s"], log)
            wall = time.monotonic() - t0
            verdict = env.check(tr)
        except Exception as e:
            wall = time.monotonic() - t0
            tr = Transcript(error=f"{type(e).__name__}: {e}")
            verdict = {"success": False, "checks": [], "refused": False,
                       "refusal_correct": not task.get("expect_refusal"), "background_safe": None, "background": None}
        finally:
            env.teardown()
        row = {
            "run_id": run_id, "tier": "agent", "arm": arm_id, "agent": "scripted" if fake else agent, "model": model,
            "task": task["id"], "split": task["split"], "platform": plat or "fake", "trial": trial,
            "expect_refusal": bool(task.get("expect_refusal")), "person_present": bool(task.get("person_present")),
            **verdict, "steps": len(tr.tool_calls), "turns": tr.turns, "input_tokens": tr.input_tokens,
            "output_tokens": tr.output_tokens, "cost_usd": tr.cost_usd, "wall_s": round(wall, 2),
            "error": tr.error, "final_text": (tr.final_text or "")[-500:], "prereg": reg["digest"],
        }
        with open(results, "a") as f:
            f.write(json.dumps(row) + "\n")
        mark = "PASS" if row["success"] else "FAIL"
        print(f"{mark} {arm_id:20} {task['id']:28} t{trial} steps={row['steps']} {row['wall_s']}s", flush=True)
    return results


if __name__ == "__main__":
    sys.exit("use: python3 -m cueval run ...")
