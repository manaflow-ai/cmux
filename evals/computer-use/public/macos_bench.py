# SPDX-License-Identifier: MIT
"""Public macOS benchmarks, Codex Computer Use vs cmux Computer Use.

Runs on a Mac host with Tart. Each attempt (task x arm x trial) gets a fresh
APFS clone of a provisioned golden VM, so every arm starts from the same
state and nothing leaks between attempts. The benchmark's own setup steps and
checkers run unmodified over SSH; the agent (codex exec, same model and
prompt for every arm) runs in the guest's GUI session through
guest/run-agent.sh.

Suites:
  macagentbench  JetAstra/MacAgentBench (MIT), a checkout given by --mab.
                 Tasks whose related apps all exist on a stock macOS VM.
  macosworld     showlab/macosworld (CC BY-NC 4.0), a checkout given by
                 --mow; used unmodified for internal measurement only.

  python3 macos_bench.py run --suite macagentbench --mab ~/cu-bench/MacAgentBench \
      --arms codex-cu,cmux-cu --golden cu-golden --jobs 2 --out runs/iter1
  python3 macos_bench.py report --out runs/iter1
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import glob
import json
import os
import random
import shlex
import subprocess
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TART = os.environ.get("TART", os.path.expanduser("~/cu-bench/bin/tart"))
GUEST_USER = os.environ.get("CUBENCH_GUEST_USER", "admin")
GUEST_PASS = os.environ.get("CUBENCH_GUEST_PASS", "admin")

# Apps a stock macOS guest has, or that the golden image installs (VS Code,
# Obsidian). iWork apps need an App Store sign-in, so their tasks are out.
MAB_APPS = {"calendar", "clock", "clock_no_kill", "finder", "mac_system_settings",
            "mac_system_settings_no_kill", "notes", "reminders", "reminder", "safari",
            "terminal", "vscode", "obsidian", "textedit"}
# Folders of OpenClaw command-line skills (gifgrep, himalaya, ...): no GUI, so
# they say nothing about computer use.
MAB_CLI_FOLDERS = {"new_blogwatcher", "new_clawhub", "new_gifgrep", "new_github", "new_himalaya",
                   "new_peekaboo", "new_sherpa_onnx_tts", "new_songsee", "new_tmux",
                   "new_video_frames", "new_weather", "new_whisper"}

SYSTEM = (
    "You are operating this Mac only through the computer-use tools you were given; no shell, "
    "file or web tools are available. Do exactly what the task says. When you are finished, "
    "reply with one final line: DONE if you completed the task, or FAILED: <reason> if you could not."
)


def sh(cmd: list[str], timeout: float = 600, check: bool = True) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: exit {p.returncode}: {p.stderr[-400:]}")
    return p.stdout


# ------------------------------------------------------------------ tasks

def mab_tasks(root: str) -> list[dict]:
    out = []
    for path in sorted(glob.glob(os.path.join(root, "tasks", "*", "*.json"))):
        folder = os.path.basename(os.path.dirname(path))
        if folder in MAB_CLI_FOLDERS:
            continue
        t = json.load(open(path))
        apps = t.get("related_apps") or []
        if not apps or not all(a in MAB_APPS for a in apps):
            continue
        out.append({"suite": "macagentbench", "id": f"{folder}/{t['id']}", "path": path,
                    "instruction": t["instruction"], "apps": apps})
    return out


# macOSWorld's own guest is an EC2 AMI with seeded files in
# ~/Benchmark_Backup and App Store apps; tasks that need either cannot run
# faithfully in a stock VM and are left out. The rest run with the AMI's user
# path rewritten to the guest's.
MOW_APP_STORE = ("Pages", "Keynote", "Numbers", "iMovie", "GarageBand", "Xcode", "Final Cut", "Logic")


def mow_tasks(root: str) -> list[dict]:
    out = []
    for path in sorted(glob.glob(os.path.join(root, "tasks", "*", "*.json"))):
        t = json.load(open(path))
        blob = json.dumps(t)
        if "Benchmark_Backup" in blob or t.get("force_ec2") or any(a in blob for a in MOW_APP_STORE):
            continue
        task = t.get("task") or {}
        instr = task.get("en") if isinstance(task, dict) else task
        if not instr:
            continue
        t = json.loads(blob.replace("/Users/ec2-user", f"/Users/{GUEST_USER}"))
        out.append({"suite": "macosworld", "id": f"{os.path.basename(os.path.dirname(path))}/{os.path.basename(path)[:-5]}",
                    "path": path, "instruction": instr, "raw": t})
    return out


def mow_setup(task: dict, vm: "VM"):
    t = task["raw"]
    pre = t.get("pre_command")
    if isinstance(pre, dict):
        pre = pre.get("en")
    if pre:
        r = vm.ssh(pre, timeout=300)
        if r.returncode != 0 and t.get("force_error_free_prep"):
            raise RuntimeError(f"pre_command failed: {r.stderr[-300:]}")
    # The benchmark's own settle time, capped: it was sized for EC2 cold starts.
    time.sleep(min(int(t.get("before_action_delay_seconds", 0) or 0), 10))


def mow_check(task: dict, vm: "VM") -> tuple[float, dict]:
    """macOSWorld's evaluator: the first full-score grading command whose
    output contains "true" scores; a command that fails to run is an error."""
    t = task["raw"]
    time.sleep(min(int(t.get("before_grading_delay_seconds", 0) or 0), 10))
    for command, value in [c for c in t["grading_command"] if c[1] == 100]:
        r = vm.ssh(command, timeout=120)
        if r.returncode == 255:
            # The check never ran (ssh): an infrastructure failure, retried on resume.
            raise RuntimeError(f"grading ssh failed: {r.stderr[-200:]}")
        if "true" in r.stdout.lower():
            return value / 100.0, {"matched": command[:200]}
    return 0.0, {}


# ------------------------------------------------------------------ VM

class VM:
    def __init__(self, golden: str, name: str):
        self.golden, self.name, self.proc, self.ip = golden, name, None, None

    def __enter__(self):
        sh([TART, "clone", self.golden, self.name], timeout=300)
        log = open(f"/tmp/{self.name}.tart.log", "w")
        self.proc = subprocess.Popen([TART, "run", "--no-graphics", self.name], stdout=log, stderr=log)
        self.ip = sh([TART, "ip", "--wait", "180", self.name], timeout=200).strip()
        self.ssh_wait()
        return self

    def __exit__(self, *exc):
        subprocess.run([TART, "stop", "--timeout", "10", self.name], capture_output=True)
        if self.proc:
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        subprocess.run([TART, "delete", self.name], capture_output=True)

    def ssh_args(self) -> list[str]:
        return ["sshpass", "-p", GUEST_PASS, "ssh", "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password",
                "-o", "ConnectTimeout=5", f"{GUEST_USER}@{self.ip}"]

    def ssh(self, command: str, timeout: float = 600, check: bool = False) -> subprocess.CompletedProcess:
        # The guest's sshd now and then refuses a password login right after
        # another session (rc 255, "Permission denied"): retry those only.
        for attempt in range(4):
            p = subprocess.run(self.ssh_args() + [command], capture_output=True, text=True, timeout=timeout)
            if p.returncode != 255 or "Permission denied" not in p.stderr and "authentication failures" not in p.stderr:
                break
            time.sleep(1 + attempt)  # bounded retry backoff for a refused login, not a synchronization
        if check and p.returncode != 0:
            raise RuntimeError(f"guest `{command[:80]}`: exit {p.returncode}: {p.stderr[-300:]}")
        return p

    def ssh_wait(self, limit: float = 180):
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                if self.ssh("true", timeout=10).returncode == 0:
                    # The GUI session (auto-login) is up once Finder runs.
                    if self.ssh("pgrep -x Finder", timeout=10).returncode == 0:
                        return
            except subprocess.TimeoutExpired:
                pass
            time.sleep(2)  # bounded boot wait; the guest offers no readiness signal
        raise TimeoutError(f"{self.name}: no SSH/GUI session after {limit}s")

    def put(self, local: str, remote: str):
        self._scp(local, f"{GUEST_USER}@{self.ip}:{remote}")

    def get(self, remote: str, local: str):
        self._scp(f"{GUEST_USER}@{self.ip}:{remote}", local, check=False)

    def _scp(self, src: str, dst: str, check: bool = True):
        for attempt in range(4):
            p = subprocess.run(["sshpass", "-p", GUEST_PASS, "scp", "-q", "-o", "StrictHostKeyChecking=no",
                                "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                                "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password",
                                "-r", src, dst], capture_output=True, text=True, timeout=300)
            if p.returncode == 0 or "No such file" in p.stderr:
                break
            time.sleep(1 + attempt)  # bounded retry backoff for a refused login, not a synchronization
        if check and p.returncode != 0:
            raise RuntimeError(f"scp {src} -> {dst}: {p.stderr[-300:]}")

# ------------------------------------------------------------------ suites' setup and checks

def mab_env(root: str, ip: str):
    if root not in sys.path:
        sys.path.insert(0, root)
    from controllers.env import MacOSEnv  # noqa: E402  (the benchmark's own code)

    class TartEnv(MacOSEnv):
        def __init__(self):  # no YAML: the VM is ours
            self.config, self.mode, self.platform = {}, "tart", "macos"
            self.docker_name, self.host_ip, self.port = None, ip, 22
            self.username, self.password, self.action_space = GUEST_USER, GUEST_PASS, "pyautogui"
            self.ssh_client = self.eval_ssh_client = self.sftp_client = self.task = None
            self.use_eval_ssh = False

        def _reset_env(self):  # every attempt already has a fresh clone
            self.close_connection()

    return TartEnv()


_mab_lock = threading.Lock()  # MAB's modules keep some module-level state


def mab_setup(task: dict, vm: VM, root: str):
    cwd = os.getcwd()
    with _mab_lock:
        os.chdir(root)
        try:
            env = mab_env(root, vm.ip)
            env.connect_ssh()
            env.init_task(task["path"])
        finally:
            os.chdir(cwd)
    return env


def mab_check(env, root: str) -> tuple[float, dict]:
    cwd = os.getcwd()
    with _mab_lock:
        os.chdir(root)
        try:
            r = env.evaluate_task()
        finally:
            os.chdir(cwd)
    if hasattr(r, "score"):
        return float(r.score), {"components": getattr(r, "components", None).__repr__()}
    return (1.0 if r else 0.0), {}


# ------------------------------------------------------------------ attempt

def run_attempt(task: dict, arm: str, trial: int, args, out_dir: str) -> dict:
    aid = f"{task['id'].replace('/', '_')}__{arm}__{trial}"
    adir = os.path.join(out_dir, "attempts", aid)
    os.makedirs(adir, exist_ok=True)
    row = {"suite": task["suite"], "task": task["id"], "arm": arm, "trial": trial,
           "model": args.model, "effort": args.effort, "started": time.time()}
    name = f"cub-{uuid.uuid4().hex[:10]}"
    try:
        with VM(args.golden, name) as vm:
            env = mab_setup(task, vm, args.mab) if task["suite"] == "macagentbench" else None
            if task["suite"] == "macosworld":
                mow_setup(task, vm)
            prompt = f"{SYSTEM}\n\nTask: {task['instruction']}\n"
            pf = os.path.join(adir, "prompt.txt")
            open(pf, "w").write(prompt)
            vm.ssh("mkdir -p ~/cub", check=True)
            vm.put(pf, "~/cub/prompt.txt")
            vm.put(os.path.join(HERE, "guest", "run-agent.sh"), "~/cub/run-agent.sh")
            t0 = time.monotonic()
            r = vm.ssh(f"bash ~/cub/run-agent.sh {arm} {shlex.quote(args.model)} {args.effort} "
                       f"{args.timeout} ~/cub/prompt.txt ~/cub/out", timeout=args.timeout + 120)
            row["agent_seconds"] = round(time.monotonic() - t0, 1)
            row["agent_rc"] = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else f"ssh {r.returncode}"
            if row["agent_rc"] == "setup":
                raise RuntimeError("the arm's computer-use service did not start in the guest")
            vm.get("~/cub/out/events.jsonl", adir)
            vm.get("~/cub/out/stderr.txt", adir)
            if args.screenshot:
                vm.ssh("screencapture -x ~/cub/out/final.png")
                vm.get("~/cub/out/final.png", adir)
            if env is not None:
                score, detail = mab_check(env, args.mab)
                env.close_connection()
                row.update(score=score, success=score >= 1.0, check=detail)
            else:
                score, detail = mow_check(task, vm)
                row.update(score=score, success=score >= 1.0, check=detail)
    except Exception as e:  # infrastructure failure: recorded, never counted as a task failure
        row.update(infra_error=f"{type(e).__name__}: {e}"[:500], score=None, success=None)
    row.update(summarize_events(os.path.join(adir, "events.jsonl")))
    row["finished"] = time.time()
    with open(os.path.join(adir, "row.json"), "w") as f:
        json.dump(row, f, indent=1)
    return row


def summarize_events(path: str) -> dict:
    s = {"tool_calls": 0, "tool_errors": 0, "input_tokens": 0, "output_tokens": 0, "final": "", "tools": {}}
    if not os.path.exists(path):
        return s
    for line in open(path, errors="replace"):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        item = ev.get("item") or {}
        if ev.get("type") == "item.completed" and item.get("type") == "mcp_tool_call":
            s["tool_calls"] += 1
            name = f"{item.get('server', '')}.{item.get('tool', '')}"
            s["tools"][name] = s["tools"].get(name, 0) + 1
            if item.get("error") or item.get("status") == "failed" or (item.get("result") or {}).get("isError"):
                s["tool_errors"] += 1
        elif ev.get("type") == "item.completed" and item.get("type") == "agent_message":
            s["final"] = (item.get("text") or "")[-300:]
        elif ev.get("type") == "turn.completed":
            u = ev.get("usage") or {}
            s["input_tokens"] += u.get("input_tokens", 0) or 0
            s["output_tokens"] += u.get("output_tokens", 0) or 0
    return s


# ------------------------------------------------------------------ commands

def cmd_run(args):
    tasks = mab_tasks(args.mab) if args.suite == "macagentbench" else mow_tasks(args.mow)
    if args.filter:
        tasks = [t for t in tasks if any(f in t["id"] for f in args.filter.split(","))]
    if args.limit:
        tasks = tasks[: args.limit]
    arms = args.arms.split(",")
    os.makedirs(args.out, exist_ok=True)
    rows_path = os.path.join(args.out, "rows.jsonl")
    done = set()
    if os.path.exists(rows_path):  # resume: skip attempts that already have a row
        for line in open(rows_path):
            r = json.loads(line)
            if not r.get("infra_error"):
                done.add((r["task"], r["arm"], r["trial"]))
    jobs = [(t, a, k) for t in tasks for k in range(args.trials) for a in arms]
    if args.shard:
        # Hosts split the attempt list by task, so both arms of a task run on
        # the same host (same hardware for the pair) and shards never overlap.
        index, count = (int(x) for x in args.shard.split("/"))
        jobs = [j for j in jobs if tasks.index(j[0]) % count == index]
    jobs = [j for j in jobs if (j[0]["id"], j[1], j[2]) not in done]
    random.Random(args.seed).shuffle(jobs)  # interleave arms so drift hits both alike
    json.dump({"suite": args.suite, "arms": arms, "model": args.model, "effort": args.effort,
               "trials": args.trials, "tasks": [t["id"] for t in tasks], "golden": args.golden,
               "started": time.time()}, open(os.path.join(args.out, "meta.json"), "w"), indent=1)
    print(f"{len(tasks)} tasks x {len(arms)} arms x {args.trials} trials: {len(jobs)} attempts to run", flush=True)
    lock = threading.Lock()
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        futs = {ex.submit(run_attempt, t, a, k, args, args.out): (t, a, k) for t, a, k in jobs}
        for n, f in enumerate(cf.as_completed(futs), 1):
            row = f.result()
            with lock, open(rows_path, "a") as fh:
                fh.write(json.dumps(row) + "\n")
            print(f"[{n}/{len(jobs)}] {row['arm']:9} {row['task']:40} score={row.get('score')} "
                  f"{row.get('agent_seconds', '-')}s calls={row['tool_calls']} {row.get('infra_error', '')[:80]}", flush=True)


def cmd_report(args):
    rows = []
    for out in args.out.split(","):
        for path in glob.glob(os.path.join(out, "**", "rows.jsonl"), recursive=True):
            rows += [json.loads(l) for l in open(path)]
    by = {}
    for r in rows:
        by.setdefault(r["arm"], []).append(r)
    print(f"{'arm':10} {'scored':>6} {'success':>8} {'mean':>6} {'infra':>6} {'p50 s':>6} {'calls':>6}")
    for arm, rs in sorted(by.items()):
        scored = [r for r in rs if r.get("score") is not None]
        succ = sum(1 for r in scored if r.get("success"))
        secs = sorted(r["agent_seconds"] for r in scored if r.get("agent_seconds"))
        calls = sorted(r["tool_calls"] for r in scored)
        print(f"{arm:10} {len(scored):6} {succ:8} {sum(r['score'] for r in scored)/max(1,len(scored)):6.3f} "
              f"{len(rs)-len(scored):6} {secs[len(secs)//2] if secs else 0:6} {calls[len(calls)//2] if calls else 0:6}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--suite", choices=["macagentbench", "macosworld"], default="macagentbench")
    r.add_argument("--mab", default=os.path.expanduser("~/cu-bench/MacAgentBench"))
    r.add_argument("--mow", default=os.path.expanduser("~/cu-bench/macosworld"))
    r.add_argument("--arms", default="codex-cu,cmux-cu")
    r.add_argument("--golden", default="cu-golden")
    r.add_argument("--model", default=os.environ.get("CUBENCH_MODEL", "gpt-6.1-sol"))
    r.add_argument("--effort", default="medium")
    r.add_argument("--trials", type=int, default=1)
    r.add_argument("--jobs", type=int, default=2)  # Apple's license allows 2 macOS VMs per host
    r.add_argument("--timeout", type=int, default=900)
    r.add_argument("--filter")
    r.add_argument("--limit", type=int)
    r.add_argument("--seed", type=int, default=7)
    r.add_argument("--screenshot", action="store_true")
    r.add_argument("--shard", help="I/N: run only this host's share of the tasks (fanout.sh sets it)")
    r.add_argument("--out", required=True)
    r.set_defaults(fn=cmd_run)
    p = sub.add_parser("report")
    p.add_argument("--out", required=True)
    p.set_defaults(fn=cmd_report)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
