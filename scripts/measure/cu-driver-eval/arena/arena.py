#!/usr/bin/env python3
"""The computer-use arena (README.md): every engine x every harness model on one task suite.

  arena.py run --arms arms.json --harness claude:claude-opus-5-5 [--harness codex:gpt-6-astra]
               --app Arena.app --probe arena-probe --out DIR [--tasks a,b] [--reps 5] [--timeout 300]
  arena.py summary DIR [--md summary.md]

One trial is one task, one engine (an "arm": an MCP server the harness launches, plus the engine's
own skill text when it ships one) and one harness model. The runner resets the task, starts the
apps, gives the harness the same prompt for every arm and model, samples CPU and memory of every
process involved twice a second, then checks the outcome from the apps' own state, the files on
disk or the accessibility tree, never from the agent's word, except where the task asks for a value.

Each trial is one JSON line in DIR/trials.jsonl:
  config ("ARM|HARNESS:MODEL"), arm, harness, model, task, rep, passed, reason, wall_s,
  tool_calls, actions, observations, screenshots, tool_errors, model_calls, input_tokens,
  cached_input_tokens, cache_write_tokens, output_tokens, answer, shell_calls, timed_out, error,
  resources {GROUP: {cpu_avg_pct, cpu_peak_pct, rss_peak_mb, rss_avg_mb, procs}}.
Groups: harness (the agent CLI and its children other than the engine), engine (the MCP server
and any daemon or app the engine runs), apps (the task's apps) and windowserver.

No dollar figures: tokens and time only (HQ public-text rule). A count that could not be read is
null, never zero.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
OBSERVE = re.compile(r"screenshot|state|list_|get_|describe|find|read|zoom|status|tree|snapshot|windows|apps", re.I)


def expand(path: str) -> Path:
    return Path(os.path.expanduser(path))


# ---------------------------------------------------------------- resource sampling


def parse_cputime(text: str) -> float:
    """ps `time`: [[DD-]HH:]MM:SS[.ss] to seconds."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [float(p) for p in text.split(":")]
    seconds = 0.0
    for p in parts:
        seconds = seconds * 60 + p
    return days * 86400 + seconds


def ps_table() -> dict[int, dict]:
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss=,time=,comm="], capture_output=True, text=True, timeout=10).stdout
    table = {}
    for line in out.splitlines():
        bits = line.split(None, 4)
        if len(bits) < 5:
            continue
        try:
            table[int(bits[0])] = {"ppid": int(bits[1]), "rss_kb": int(bits[2]), "cpu_s": parse_cputime(bits[3]),
                                   "comm": bits[4].strip()}
        except ValueError:
            continue
    return table


class Sampler(threading.Thread):
    """Samples every process of the trial twice a second and groups it:
    engine        the MCP server the harness started (a process under the harness whose executable
                  is one of `mcp_names`) with everything under it, and any process anywhere whose
                  executable is one of the arm's daemons (`daemon_names`: a helper daemon, an engine
                  app LaunchServices started, a worker)
    harness       everything else under the harness CLI
    apps          the task's apps, by executable name
    windowserver  WindowServer, which draws every screenshot and every change"""

    def __init__(self, root_pid: int, mcp_names: list[str], daemon_names: list[str], app_names: list[str], interval: float = 0.5):
        super().__init__(daemon=True)
        self.root_pid, self.interval = root_pid, interval
        self.mcp_names, self.daemon_names, self.app_names = set(mcp_names), set(daemon_names), set(app_names)
        self.stop_event = threading.Event()
        self.samples: list[tuple[float, dict[str, dict[int, dict]]]] = []

    @staticmethod
    def base(comm: str) -> str:
        return os.path.basename(comm)

    def classify(self, table: dict[int, dict]) -> dict[str, dict[int, dict]]:
        groups: dict[str, dict[int, dict]] = {"harness": {}, "engine": {}, "apps": {}, "windowserver": {}}

        def chain(pid: int) -> list[int]:
            out = []
            while pid in table and len(out) < 64:
                out.append(pid)
                pid = table[pid]["ppid"]
            return out

        chains = {pid: chain(pid) for pid in table}
        in_harness = {pid for pid, c in chains.items() if self.root_pid in c}
        mcp_roots = {pid for pid in in_harness if pid != self.root_pid and self.base(table[pid]["comm"]) in self.mcp_names}
        for pid, row in table.items():
            name = self.base(row["comm"])
            if name == "WindowServer":
                groups["windowserver"][pid] = row
            elif name in self.daemon_names or mcp_roots & set(chains[pid]):
                groups["engine"][pid] = row
            elif pid in in_harness:
                groups["harness"][pid] = row
            elif name in self.app_names:
                groups["apps"][pid] = row
        return groups

    def run(self) -> None:
        while not self.stop_event.is_set():
            try:
                self.samples.append((time.monotonic(), self.classify(ps_table())))
            except Exception:  # a ps hiccup loses one sample, not the trial
                pass
            self.stop_event.wait(self.interval)

    def stop(self) -> dict:
        self.stop_event.set()
        if self.ident is not None:
            self.join(timeout=5)
        out = {}
        for group in ("harness", "engine", "apps", "windowserver"):
            rss, peaks, names = [], [], set()
            first_cpu: dict[int, float] = {}
            last_cpu: dict[int, float] = {}
            prev: tuple[float, dict[int, float]] | None = None
            for t, groups in self.samples:
                rows = groups[group]
                rss.append(sum(r["rss_kb"] for r in rows.values()) / 1024)
                now = {pid: r["cpu_s"] for pid, r in rows.items()}
                for pid, c in now.items():
                    first_cpu.setdefault(pid, c)
                    last_cpu[pid] = c
                    names.add(self.base(rows[pid]["comm"]))
                if prev is not None and t > prev[0]:
                    used = sum(max(0.0, c - prev[1].get(pid, c)) for pid, c in now.items())
                    peaks.append(100 * used / (t - prev[0]))
                prev = (t, now)
            span = (self.samples[-1][0] - self.samples[0][0]) if len(self.samples) > 1 else 0
            used = sum(last_cpu[p] - first_cpu[p] for p in last_cpu)
            out[group] = {
                "cpu_avg_pct": round(100 * used / span, 1) if span > 0 and names else None,
                "cpu_peak_pct": round(max(peaks), 1) if peaks and names else None,
                "rss_peak_mb": round(max(rss), 1) if rss and names else None,
                "rss_avg_mb": round(statistics.fmean(rss), 1) if rss and names else None,
                "procs": sorted(names),
            }
        return out


# ---------------------------------------------------------------- task setup and checks


class Task:
    def __init__(self, spec: dict, app: Path, probe: Path, work: Path, rep: int):
        self.spec, self.app, self.probe, self.work, self.rep = spec, app, probe, work, rep
        self.procs: list[subprocess.Popen] = []
        self.states: dict[str, Path] = {}
        self.app_names: list[str] = []

    def state(self, mode: str) -> dict:
        path = self.states.get(mode)
        try:
            return json.loads(path.read_text()) if path else {}
        except (OSError, ValueError):
            return {}

    def quit_system_app(self, name: str) -> None:
        # The VM is this run's throwaway clone: quitting TextEdit or Calculator there touches no person.
        subprocess.run(["osascript", "-e", f'tell application "{name}" to quit saving no'], capture_output=True, timeout=15)
        for _ in range(20):
            if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode != 0:
                return
            time.sleep(0.25)

    def setup(self) -> None:
        s = self.spec["setup"]
        for raw in s.get("remove", []):
            path = expand(raw)
            if path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)
        for raw, text in s.get("files", {}).items():
            path = expand(raw)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        if s.get("textedit"):
            self.quit_system_app("TextEdit")
            # A new untitled plain-text document at launch, not the open panel: the same start for every arm.
            for key, kind, value in (("NSShowAppCentricOpenPanelInsteadOfUntitledFile", "-bool", "false"),
                                     ("RichText", "-int", "0")):
                subprocess.run(["defaults", "write", "com.apple.TextEdit", key, kind, value], capture_output=True)
            self.app_names.append("TextEdit")
        if s.get("calculator"):
            self.quit_system_app("Calculator")
            subprocess.run(["open", "-g", "-a", "Calculator"], capture_output=True, timeout=15)
            self.app_names.append("Calculator")
        if "files" in s or "remove" in s:
            self.app_names.append("Finder")
        if s.get("arena"):
            self.app_names.append("Arena")
        binary = self.app / "Contents" / "MacOS" / "Arena"
        for i, mode in enumerate(s.get("arena", [])):
            state = self.work / f"state-{mode}.json"
            state.unlink(missing_ok=True)
            self.states[mode] = state
            seed = str(1000 * (self.rep + 1) + 17 * i + sum(map(ord, self.spec["id"])))
            self.procs.append(subprocess.Popen([str(binary), mode, str(state), seed], stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL))
            for _ in range(40):
                if state.exists():
                    break
                time.sleep(0.1)
        time.sleep(1.0)  # windows ordered in, the minimized one in the Dock

    def prompt(self) -> str:
        values = {"target": "", "code": ""}
        for mode in self.states:
            st = self.state(mode)
            for key in values:
                values[key] = values[key] or str(st.get(key, ""))
        return self.spec["prompt"].format(**values)

    def check(self, answer: str) -> tuple[bool, str]:
        c = self.spec["check"]
        reasons = []
        if "state" in c:
            st = self.state(c["state"])
            if not st:
                return False, f"no state from {c['state']}"
            for key, want in c.get("equals", {}).items():
                got = st.get(key)
                if (got.strip() if isinstance(got, str) else got) != want:
                    reasons.append(f"{key}={got!r}, want {want!r}")
            for key, ref in c.get("equals_state_key", {}).items():
                want = self.state(ref[0]).get(ref[1]) if len(ref) == 2 else st.get(ref[0])
                got = st.get(key)
                if key == "paid":
                    ok = got == [want]
                else:
                    ok = isinstance(got, str) and got.strip().upper() == str(want).upper()
                if not ok:
                    reasons.append(f"{key}={got!r}, want {want!r}")
        if "answer_state" in c:
            want = str(self.state(c["answer_state"]).get(c["key"], ""))
            tokens = re.findall(r"[A-Z0-9]{6}", answer.upper())
            if not want or want not in tokens:
                reasons.append(f"answer {answer[:60]!r}, want {want!r}")
        if "answer" in c:
            digits = re.sub(r"[,\s.]", "", answer)
            if c["answer"] not in digits:
                reasons.append(f"answer {answer[:60]!r}, want {c['answer']}")
        if "ax_value" in c:
            probe = subprocess.run([str(self.probe), "ax-text", c["ax_value"]["app"]], capture_output=True, text=True, timeout=20)
            text = re.sub(r"[,\s  ]", "", probe.stdout)
            if c["ax_value"]["contains"] not in text:
                reasons.append(f"{c['ax_value']['app']} shows {probe.stdout.strip()[:80]!r}")
        if "file_text" in c:
            found = [expand(p) for p in c["file_text"] if expand(p).is_file()]
            if not found:
                reasons.append("no saved file")
            else:
                text = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(found[0])], capture_output=True,
                                      text=True, timeout=20).stdout
                if c["contains"] not in text:
                    reasons.append(f"{found[0].name} holds {text.strip()[:60]!r}")
        for raw in c.get("exists", []):
            if not expand(raw).exists():
                reasons.append(f"{raw} missing")
        for raw in c.get("missing", []):
            if expand(raw).exists():
                reasons.append(f"{raw} still there")
        return (not reasons), "; ".join(reasons)

    def teardown(self) -> None:
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
        s = self.spec["setup"]
        if s.get("textedit"):
            self.quit_system_app("TextEdit")
        if s.get("calculator"):
            self.quit_system_app("Calculator")


# ---------------------------------------------------------------- harnesses


def claude_argv(model: str, prompt: str, mcp_config: Path, skill: str | None, max_turns: int) -> list[str]:
    argv = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", model,
            "--mcp-config", str(mcp_config), "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__computer",
            "--dangerously-skip-permissions", "--setting-sources", "project", "--no-session-persistence",
            "--max-turns", str(max_turns)]
    if model.startswith("claude-opus") or model.startswith("claude-sonnet"):
        argv += ["--effort", "medium"]
    if skill:
        argv += ["--append-system-prompt", skill]
    return argv


def toml_str(value: str) -> str:
    return json.dumps(value)  # a JSON string is a valid TOML basic string


def codex_argv(model: str, prompt: str, server: dict, skill: str | None, route: str) -> list[str]:
    env = "{" + ", ".join(f"{k} = {toml_str(v)}" for k, v in server.get("env", {}).items()) + "}"
    args = "[" + ", ".join(toml_str(a) for a in server.get("args", [])) + "]"
    full_prompt = (f"<engine-guide>\n{skill}\n</engine-guide>\n\n" if skill else "") + prompt
    argv = ["codex", "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "-m", model, "-s", "read-only",
            "-c", 'approval_policy="never"',
            "-c", 'model_provider="arena"',
            "-c", f"model_providers.arena.base_url={toml_str(route + '/v1')}",
            "-c", 'model_providers.arena.name="arena"',
            "-c", 'model_providers.arena.wire_api="responses"',
            "-c", 'model_providers.arena.experimental_bearer_token="subrouter"',
            "-c", 'model_providers.arena.stream_idle_timeout_ms=900000',
            "-c", 'model_providers.arena.http_headers={"X-Subrouter-Agent" = "codex", "X-Subrouter-Retry-Policy" = "autonomous"}',
            "-c", 'model_reasoning_effort="high"', "-c", 'service_tier="fast"',
            "-c", f"mcp_servers.computer.command={toml_str(server['command'])}",
            "-c", f"mcp_servers.computer.args={args}",
            "-c", f"mcp_servers.computer.env={env}",
            "-c", "mcp_servers.computer.startup_timeout_sec=60",
            "-c", "mcp_servers.computer.tool_timeout_sec=120"]
    # The engine's tools only: no shell, no Codex computer use, no browser or apps of its own.
    for feature in ("shell_tool", "unified_exec", "computer_use", "browser_use", "browser_use_external", "apps",
                    "image_generation", "goals"):
        argv += ["--disable", feature]
    return argv + [full_prompt]


def content_images(content) -> int:
    if isinstance(content, list):
        return sum(1 for c in content if isinstance(c, dict) and c.get("type") == "image")
    return 0


def parse_claude(lines: list[str]) -> dict:
    r = {"tool_calls": 0, "actions": 0, "observations": 0, "screenshots": 0, "tool_errors": 0, "model_calls": 0,
         "input_tokens": None, "cached_input_tokens": None, "cache_write_tokens": None, "output_tokens": None,
         "answer": "", "shell_calls": 0, "tools": {}}
    message_ids = set()
    for raw in lines:
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if ev.get("type") == "assistant":
            msg = ev.get("message", {})
            message_ids.add(msg.get("id"))
            for block in msg.get("content", []) or []:
                if block.get("type") == "tool_use":
                    name = block.get("name", "").removeprefix("mcp__computer__")
                    r["tool_calls"] += 1
                    r["tools"][name] = r["tools"].get(name, 0) + 1
                    r["observations" if OBSERVE.search(name) else "actions"] += 1
        elif ev.get("type") == "user":
            for block in (ev.get("message", {}).get("content") or []):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    r["screenshots"] += content_images(block.get("content"))
                    r["tool_errors"] += 1 if block.get("is_error") else 0
        elif ev.get("type") == "result":
            u = ev.get("usage") or {}
            r["input_tokens"] = u.get("input_tokens")
            r["cached_input_tokens"] = u.get("cache_read_input_tokens")
            r["cache_write_tokens"] = u.get("cache_creation_input_tokens")
            r["output_tokens"] = u.get("output_tokens")
            r["answer"] = ev.get("result") or ""
            r["num_turns"] = ev.get("num_turns")
            r["api_s"] = round((ev.get("duration_api_ms") or 0) / 1000, 2)
            r["is_error"] = bool(ev.get("is_error"))
    r["model_calls"] = len([m for m in message_ids if m])
    return r


def parse_codex(lines: list[str]) -> dict:
    r = {"tool_calls": 0, "actions": 0, "observations": 0, "screenshots": 0, "tool_errors": 0, "model_calls": None,
         "input_tokens": None, "cached_input_tokens": None, "cache_write_tokens": None, "output_tokens": None,
         "answer": "", "shell_calls": 0, "tools": {}, "model_calls_approx": True}
    reasoning, batches, last_kind = 0, 0, None
    for raw in lines:
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        kind = ev.get("type")
        item = ev.get("item") or {}
        if kind == "item.completed":
            itype = item.get("type") or item.get("item_type")
            if itype == "mcp_tool_call":
                name = item.get("tool", "")
                r["tool_calls"] += 1
                r["tools"][name] = r["tools"].get(name, 0) + 1
                r["observations" if OBSERVE.search(name) else "actions"] += 1
                result = item.get("result") or {}
                r["screenshots"] += content_images(result.get("content") if isinstance(result, dict) else None)
                if item.get("status") == "failed" or item.get("error"):
                    r["tool_errors"] += 1
                if last_kind != "tool":
                    batches += 1
                last_kind = "tool"
            elif itype == "command_execution":
                r["shell_calls"] += 1
                last_kind = "other"
            elif itype == "reasoning":
                reasoning += 1
                last_kind = "other"
            elif itype == "agent_message":
                r["answer"] = item.get("text") or r["answer"]
                last_kind = "other"
        elif kind == "turn.completed":
            u = ev.get("usage") or {}
            r["input_tokens"] = (r["input_tokens"] or 0) + (u.get("input_tokens") or 0)
            r["cached_input_tokens"] = (r["cached_input_tokens"] or 0) + (u.get("cached_input_tokens") or 0)
            r["output_tokens"] = (r["output_tokens"] or 0) + (u.get("output_tokens") or 0)
        elif kind in ("turn.failed", "error"):
            r["is_error"] = True
            r["error_text"] = json.dumps(ev)[:300]
    # Codex exec reports no per-request count: one request per tool batch, plus the closing answer.
    r["model_calls"] = batches + 1
    return r


# ---------------------------------------------------------------- the run


def start_daemon(arm: str, spec: dict, log_dir: Path) -> subprocess.Popen | None:
    daemon = spec.get("daemon")
    if not daemon:
        return None
    log = open(log_dir / f"daemon-{arm}.log", "ab")
    # A login session's basics and the arm's own variables, as cmux gives its helper: none of this runner's.
    base = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "SHELL") if k in os.environ}
    env = {**base, **daemon.get("env", {})}
    argv = list(daemon["argv"])
    # prepare.py wrote the argv and has exited: a helper that watches its owner watches this runner.
    if "--owner-pid" in argv:
        argv[argv.index("--owner-pid") + 1] = str(os.getpid())
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env, start_new_session=True)
    ready = daemon.get("ready_socket")
    deadline = time.monotonic() + 30
    while ready and not Path(ready).exists():
        if proc.poll() is not None:
            raise RuntimeError(f"{arm}: its daemon exited ({proc.returncode})")
        if time.monotonic() > deadline:
            stop_proc(proc)
            raise RuntimeError(f"{arm}: its daemon made no {ready} in 30 s")
        time.sleep(0.2)
    time.sleep(1.0)
    return proc


def stop_proc(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()


def trial(args, arm: str, spec: dict, harness: str, model: str, task_spec: dict, rep: int, preamble: str, out: Path) -> dict:
    work = Path(tempfile.mkdtemp(prefix=f"arena-{task_spec['id']}-"))
    task = Task(task_spec, args.app, args.probe, work, rep)
    row = {"config": f"{arm}|{harness}:{model}", "arm": arm, "harness": harness, "model": model, "task": task_spec["id"],
           "tags": task_spec.get("tags", []), "rep": rep, "passed": False, "reason": "", "error": None, "timed_out": False}
    trace = out / "traces" / f"{arm}--{harness}-{model}--{task_spec['id']}--{rep}.jsonl"
    trace.parent.mkdir(parents=True, exist_ok=True)
    try:
        task.setup()
        prompt = preamble + "\n\n" + task.prompt()
        skill = Path(spec["skill"]).read_text() if spec.get("skill") else None
        server = spec["mcp"]
        if harness == "claude":
            cfg = work / "mcp.json"
            cfg.write_text(json.dumps({"mcpServers": {"computer": {"type": "stdio", **server}}}))
            argv = claude_argv(model, prompt, cfg, skill, args.max_turns)
        else:
            argv = codex_argv(model, prompt, server, skill, args.route)
        started = time.monotonic()
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                cwd=work, start_new_session=True)
        mcp_names = [os.path.basename(server["command"])] + spec.get("mcp_procs", [])
        sampler = Sampler(proc.pid, mcp_names, spec.get("procs", []), task.app_names)
        sampler.start()
        try:
            stdout, stderr = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            row["timed_out"] = True
            stop_proc(proc)
            stdout, stderr = proc.communicate()
        row["wall_s"] = round(time.monotonic() - started, 2)
        row["resources"] = sampler.stop()
        lines = stdout.splitlines()
        trace.write_text(stdout)
        (trace.with_suffix(".stderr")).write_text(stderr[-20000:])
        parsed = parse_claude(lines) if harness == "claude" else parse_codex(lines)
        row.update(parsed)
        row["exit"] = proc.returncode
        time.sleep(0.5)  # the last write of the app's state
        passed, reason = task.check(row.get("answer", ""))
        if row["shell_calls"]:
            passed, reason = False, f"used a shell {row['shell_calls']} times; " + reason
        row["passed"], row["reason"] = passed, reason
    except Exception as error:  # one broken trial is a row, never the end of the run
        row["error"] = f"{type(error).__name__}: {error}"[:400]
    finally:
        task.teardown()
        shutil.rmtree(work, ignore_errors=True)
    return row


def cmd_run(args) -> int:
    arms = json.loads(Path(args.arms).read_text())
    suite = json.loads((HERE / "tasks.json").read_text())
    tasks = [t for t in suite["tasks"] if not args.tasks or t["id"] in args.tasks.split(",")]
    harnesses = [h.split(":", 1) for h in args.harness]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rows_path = out / "trials.jsonl"
    selected = [a for a in arms if not args.only_arms or a in args.only_arms.split(",")]
    stop_at = time.monotonic() + args.budget if args.budget > 0 else None
    skipped = 0
    print(f"ARENA arms={selected} harness={args.harness} tasks={len(tasks)} reps={args.reps}", flush=True)
    for arm in selected:
        spec = arms[arm]
        if spec.get("unavailable"):
            for harness, model in harnesses:
                with rows_path.open("a") as f:
                    f.write(json.dumps({"config": f"{arm}|{harness}:{model}", "arm": arm, "harness": harness, "model": model,
                                        "task": None, "unavailable": spec["unavailable"]}) + "\n")
            print(f"ARENA {arm}: unavailable: {spec['unavailable']}", flush=True)
            continue
        try:
            daemon = start_daemon(arm, spec, out)
        except Exception as error:
            # An engine that never came up is a row saying so, not a column of ordinary failures.
            print(f"ARENA {arm}: unavailable: {error}", flush=True)
            for harness, model in harnesses:
                with rows_path.open("a") as f:
                    f.write(json.dumps({"config": f"{arm}|{harness}:{model}", "arm": arm, "harness": harness, "model": model,
                                        "task": None, "unavailable": f"daemon: {error}"[:300]}) + "\n")
            continue
        try:
            # Reps outermost, so a slow minute of the VM spreads over every task rather than one.
            for rep in range(args.reps):
                for harness, model in harnesses:
                    for task_spec in tasks:
                        if stop_at is not None and time.monotonic() > stop_at:
                            skipped += 1
                            continue
                        row = trial(args, arm, spec, harness, model, task_spec, rep, suite["preamble"], out)
                        with rows_path.open("a") as f:
                            f.write(json.dumps(row, sort_keys=True) + "\n")
                        print(f"ARENA-TRIAL {row['config']} {row['task']} #{rep} passed={row['passed']} "
                              f"wall={row.get('wall_s')} tools={row.get('tool_calls')} shots={row.get('screenshots')} "
                              f"in={row.get('input_tokens')} out={row.get('output_tokens')} {row.get('reason') or row.get('error') or ''}",
                              flush=True)
        finally:
            stop_proc(daemon)
    if skipped:
        print(f"ARENA the budget ran out: {skipped} trials not started", flush=True)
        (out / "skipped.json").write_text(json.dumps({"skipped": skipped}) + "\n")
    write_summary(out, out / "summary.md")
    return 0


# ---------------------------------------------------------------- summary


def pct(values: list[float], q: float) -> float | None:
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def fmt(v, digits=1) -> str:
    if v is None:
        return "–"
    if isinstance(v, float):
        return f"{v:.{digits}f}"
    return str(v)


def tokens(row: dict) -> int | None:
    parts = [row.get("input_tokens"), row.get("cached_input_tokens"), row.get("cache_write_tokens")]
    if all(p is None for p in parts):
        return None
    return sum(p or 0 for p in parts)


def aggregate(rows: list[dict]) -> dict:
    n = len(rows)
    passed = sum(1 for r in rows if r.get("passed"))
    def col(key, f=lambda r, k: r.get(k)):
        return [f(r, key) for r in rows]
    res = lambda g, k: [((r.get("resources") or {}).get(g) or {}).get(k) for r in rows]
    return {
        "n": n, "passed": passed, "rate": passed / n if n else None,
        "wall_p50": pct(col("wall_s"), 0.5), "wall_p90": pct(col("wall_s"), 0.9),
        "wall_pass_p50": pct([r.get("wall_s") for r in rows if r.get("passed")], 0.5),
        "tools_p50": pct(col("tool_calls"), 0.5), "actions_p50": pct(col("actions"), 0.5),
        "model_calls_p50": pct(col("model_calls"), 0.5), "screenshots_p50": pct(col("screenshots"), 0.5),
        "in_tokens_p50": pct([tokens(r) for r in rows], 0.5), "out_tokens_p50": pct(col("output_tokens"), 0.5),
        "tool_errors": sum(r.get("tool_errors") or 0 for r in rows), "timeouts": sum(1 for r in rows if r.get("timed_out")),
        "errors": sum(1 for r in rows if r.get("error")),
        "engine_cpu_avg_p50": pct(res("engine", "cpu_avg_pct"), 0.5), "engine_cpu_peak_max": max([v for v in res("engine", "cpu_peak_pct") if v is not None], default=None),
        "engine_rss_peak_max": max([v for v in res("engine", "rss_peak_mb") if v is not None], default=None),
        "harness_cpu_avg_p50": pct(res("harness", "cpu_avg_pct"), 0.5), "harness_rss_peak_max": max([v for v in res("harness", "rss_peak_mb") if v is not None], default=None),
        "windowserver_cpu_avg_p50": pct(res("windowserver", "cpu_avg_pct"), 0.5),
    }


def load_rows(out: Path) -> list[dict]:
    rows = []
    for path in sorted(out.rglob("trials.jsonl")):
        for raw in path.read_text().splitlines():
            try:
                rows.append(json.loads(raw))
            except ValueError:
                pass
    return rows


def write_summary(out: Path, md: Path) -> dict:
    rows = load_rows(out)
    unavailable = {r["config"]: r["unavailable"] for r in rows if r.get("unavailable")}
    rows = [r for r in rows if not r.get("unavailable")]
    configs = sorted({r["config"] for r in rows})
    tasks = sorted({r["task"] for r in rows})
    by_config = {c: aggregate([r for r in rows if r["config"] == c]) for c in configs}
    by_cell = {f"{c}|{t}": aggregate([r for r in rows if r["config"] == c and r["task"] == t]) for c in configs for t in tasks}
    lines = ["## Computer-use arena", "",
             f"{len(rows)} trials, {len(configs)} configurations, {len(tasks)} tasks. Tokens are input (uncached + cached + cache writes) "
             "and output per trial; times are wall seconds per trial; CPU is percent of one core; memory is resident MB.", "",
             "### Per configuration", "",
             "| engine | harness:model | pass | wall p50 / p90 s | tool calls p50 | model calls p50 | screenshots p50 | input tokens p50 | output tokens p50 | engine CPU avg / peak % | engine RSS peak MB | harness CPU avg % | harness RSS peak MB | tool errors | timeouts |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in configs:
        a = by_config[c]
        arm, hm = c.split("|", 1)
        lines.append(f"| {arm} | {hm} | {a['passed']}/{a['n']} ({fmt(100 * a['rate'], 0)}%) | {fmt(a['wall_p50'])} / {fmt(a['wall_p90'])} | "
                     f"{fmt(a['tools_p50'], 0)} | {fmt(a['model_calls_p50'], 0)} | {fmt(a['screenshots_p50'], 0)} | {fmt(a['in_tokens_p50'], 0)} | "
                     f"{fmt(a['out_tokens_p50'], 0)} | {fmt(a['engine_cpu_avg_p50'])} / {fmt(a['engine_cpu_peak_max'])} | {fmt(a['engine_rss_peak_max'], 0)} | "
                     f"{fmt(a['harness_cpu_avg_p50'])} | {fmt(a['harness_rss_peak_max'], 0)} | {a['tool_errors']} | {a['timeouts']} |")
    for c, why in sorted(unavailable.items()):
        arm, hm = c.split("|", 1)
        lines.append(f"| {arm} | {hm} | not run: {why} |" + " |" * 13)
    lines += ["", "### Per task (passes / runs, wall p50 s)", "", "| task | " + " | ".join(configs) + " |",
              "|---|" + "---|" * len(configs)]
    for t in tasks:
        cells = []
        for c in configs:
            a = by_cell[f"{c}|{t}"]
            cells.append(f"{a['passed']}/{a['n']}, {fmt(a['wall_p50'], 0)} s" if a["n"] else "–")
        lines.append(f"| {t} | " + " | ".join(cells) + " |")
    fails = [r for r in rows if not r.get("passed")]
    if fails:
        lines += ["", "### Failures (first 40)", ""]
        for r in fails[:40]:
            lines.append(f"- {r['config']} {r['task']} #{r['rep']}: {r.get('error') or r.get('reason') or 'failed'}"
                         + (" (timed out)" if r.get("timed_out") else ""))
    md.write_text("\n".join(lines) + "\n")
    data = {"by_config": by_config, "by_cell": by_cell, "unavailable": unavailable}
    (md.parent / "summary.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    return data


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--arms", required=True)
    r.add_argument("--only-arms", default="")
    r.add_argument("--harness", action="append", required=True, help="claude:MODEL or codex:MODEL")
    r.add_argument("--app", type=Path, required=True, help="Arena.app")
    r.add_argument("--probe", type=Path, required=True, help="arena-probe")
    r.add_argument("--out", required=True)
    r.add_argument("--tasks", default="")
    r.add_argument("--reps", type=int, default=5)
    r.add_argument("--timeout", type=int, default=300)
    r.add_argument("--max-turns", type=int, default=60)
    r.add_argument("--budget", type=int, default=0, help="seconds after which no new trial starts (0: none)")
    r.add_argument("--route", default="http://127.0.0.1:4016", help="the Codex route (base URL without /v1)")
    s = sub.add_parser("summary")
    s.add_argument("dir", type=Path)
    s.add_argument("--md", type=Path)
    a = p.parse_args()
    if a.cmd == "run":
        return cmd_run(a)
    write_summary(a.dir, a.md or a.dir / "summary.md")
    print((a.md or a.dir / "summary.md").read_text())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
