#!/usr/bin/env python3
"""Remote-floor probes for Claude Code against the scripted fake model.

Each scenario starts `claude -p` the way acpmux does (stream-json,
--permission-prompt-tool stdio) in an isolated HOME and project. The fake
model asks for one tool call whose only effect is creating a marker file.
This runner plays acpmux: it answers every can_use_tool with deny. The floor
holds when the tool did not run. A scenario records whether Claude asked
(can_use_tool reached the runner) and whether the marker exists.

Usage: probe_claude.py [--claude PATH] [--only NAME,...] [--json OUT]
Exit 0 when every FLOOR scenario holds; INFO scenarios only report.
"""
import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ASK_ALL = ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "Task"]


def remote_settings(hook=None, hook_timeout=900, ask=ASK_ALL):
    settings = {"permissions": {"ask": list(ask), "disableBypassPermissionsMode": "disable",
                                "defaultMode": "default"}}
    if hook is not None:
        settings["hooks"] = {"PreToolUse": [{"matcher": "*", "hooks": [
            {"type": "command", "command": hook, "timeout": hook_timeout}]}]}
    return settings


def hook_script(root, behavior):
    path = os.path.join(root, f"hook-{behavior}.sh")
    body = {
        "allow": 'cat >/dev/null; echo \'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\'',
        "ask": 'cat >/dev/null; echo \'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\'',
        "crash": "cat >/dev/null; echo hook crashed >&2; exit 1",
        "sleep": "cat >/dev/null; sleep 30",
    }[behavior]
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)
    return path


# name, kind, tool, options. kind FLOOR must not run the tool; INFO reports.
def scenarios(root):
    allow_project = {"permissions": {"allow": ["Bash(touch:*)", "Write"]}}
    return [
        ("baseline-no-rules", "FLOOR", "Bash", {}),
        ("project-allow-without-floor", "INFO", "Bash", {"project": allow_project}),
        ("project-allow-with-floor", "FLOOR", "Bash", {"project": allow_project, "inject": remote_settings()}),
        ("user-allow-with-floor", "FLOOR", "Bash", {"user": allow_project, "inject": remote_settings()}),
        ("hook-allow-fast-path", "INFO", "Bash", {"inject": remote_settings(hook_script(root, "allow"))}),
        ("hook-ask", "FLOOR", "Bash", {"inject": remote_settings(hook_script(root, "ask"))}),
        ("hook-crash", "FLOOR", "Bash", {"project": allow_project, "inject": remote_settings(hook_script(root, "crash"))}),
        ("hook-missing", "FLOOR", "Bash", {"project": allow_project, "inject": remote_settings(os.path.join(root, "no-such-hook"))}),
        ("hook-timeout", "FLOOR", "Bash", {"project": allow_project, "inject": remote_settings(hook_script(root, "sleep"), hook_timeout=2)}),
        ("user-disable-all-hooks", "FLOOR", "Bash", {"user": {**allow_project, "disableAllHooks": True},
                                                     "inject": remote_settings(hook_script(root, "allow"))}),
        ("flag-dangerously-skip", "FLOOR", "Bash", {"inject": remote_settings(), "args": ["--dangerously-skip-permissions"]}),
        ("flag-mode-bypass", "FLOOR", "Bash", {"inject": remote_settings(), "mode": "bypassPermissions"}),
        ("user-default-mode-bypass", "FLOOR", "Bash", {"user": {"permissions": {"defaultMode": "bypassPermissions"}},
                                                       "inject": remote_settings()}),
        ("mode-accept-edits-write", "FLOOR", "Write", {"inject": remote_settings(), "mode": "acceptEdits"}),
        ("control-set-mode-bypass", "FLOOR", "Bash", {"inject": remote_settings(), "set_mode": "bypassPermissions"}),
        ("setting-sources-empty-project-allow", "FLOOR", "Bash", {"project": allow_project, "user": allow_project,
                                                                "inject": remote_settings(ask=[]),
                                                                "args": ["--setting-sources", ""]}),
        ("setting-sources-empty-repo-hook", "FLOOR", "Bash", {
            "project": {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
                {"type": "command", "command": hook_script(root, "allow")}]}]}},
            "inject": remote_settings(ask=[]), "args": ["--setting-sources", ""]}),
        ("slash-clear-as-text", "INFO", "Bash", {"inject": remote_settings(), "prompt": "/clear"}),
        ("bang-as-text", "INFO", "Bash", {"inject": remote_settings(), "prompt": "!touch MARKER"}),
    ]


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(value, f)


def start_fake(tool, marker, log):
    tool_input = {"command": f"touch {marker}"} if tool == "Bash" else {"file_path": marker, "content": "x\n"}
    env = dict(os.environ, FAKE_TOOL_NAME=tool, FAKE_TOOL_INPUT=json.dumps(tool_input), FAKE_MODEL_LOG=log)
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_model.py")], env=env,
                            stdout=subprocess.PIPE, text=True)
    line = proc.stdout.readline().split()
    return proc, int(line[1])


def send(proc, value):
    proc.stdin.write(json.dumps(value) + "\n")
    proc.stdin.flush()


def run(claude, root, name, kind, tool, opts, deadline_s=90):
    case = os.path.join(root, name)
    home, project = os.path.join(case, "home"), os.path.join(case, "project")
    os.makedirs(home)
    os.makedirs(project)
    marker = os.path.join(case, "marker")
    if "user" in opts:
        write_json(os.path.join(home, ".claude", "settings.json"), opts["user"])
    if "project" in opts:
        write_json(os.path.join(project, ".claude", "settings.json"), opts["project"])
    args = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-prompt-tool", "stdio", "--model", "claude-sonnet-4-5"]
    if "inject" in opts:
        injected = os.path.join(case, "remote-settings.json")
        write_json(injected, opts["inject"])
        args += ["--settings", injected]
    args += ["--permission-mode", opts.get("mode", "default")]
    args += opts.get("args", [])
    fake, port = start_fake(tool, marker, os.path.join(case, "model.log"))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_"))}
    env.update(HOME=home, ANTHROPIC_BASE_URL=f"http://127.0.0.1:{port}", ANTHROPIC_API_KEY="sk-ant-probe-fake",
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_AUTOUPDATER="1")
    result = {"name": name, "kind": kind, "tool": tool, "asked": 0, "ran": False, "exit": None,
              "set_mode_reply": None, "stderr": "", "result": None}
    proc = subprocess.Popen(args, cwd=project, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        send(proc, {"type": "control_request", "request_id": "ctl-init",
                    "request": {"subtype": "initialize", "hooks": {}}})
        if "set_mode" in opts:
            send(proc, {"type": "control_request", "request_id": "ctl-mode",
                        "request": {"subtype": "set_permission_mode", "mode": opts["set_mode"]}})
        prompt = opts.get("prompt", "probe: run the tool").replace("MARKER", marker)
        send(proc, {"type": "user", "message": {"role": "user", "content": prompt}})
        end = time.time() + deadline_s
        while time.time() < end:
            ready, _, _ = select.select([proc.stdout], [], [], 1)
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("type") == "control_request" and msg["request"].get("subtype") == "can_use_tool":
                result["asked"] += 1
                send(proc, {"type": "control_response", "response": {
                    "subtype": "success", "request_id": msg["request_id"],
                    "response": {"behavior": "deny", "message": "remote floor probe denies"}}})
            elif msg.get("type") == "control_response" and msg["response"].get("request_id") == "ctl-mode":
                result["set_mode_reply"] = msg["response"].get("subtype") + ":" + str(msg["response"].get("error", ""))[:200]
            elif msg.get("type") == "result":
                result["result"] = msg.get("subtype")
                break
    finally:
        try:
            proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        fake.kill()
        fake.wait()
    result["exit"] = proc.returncode
    result["stderr"] = proc.stderr.read()[-600:]
    result["ran"] = os.path.exists(marker)
    log = os.path.join(case, "model.log")
    result["model_calls"] = sum(1 for _ in open(log)) if os.path.exists(log) else 0
    result["holds"] = not result["ran"]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--claude", default=shutil.which("claude") or "claude")
    parser.add_argument("--only")
    parser.add_argument("--json")
    ns = parser.parse_args()
    root = tempfile.mkdtemp(prefix="remote-floor-")
    version = subprocess.run([ns.claude, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"claude {version}; work dir {root}")
    results, failed = [], False
    for name, kind, tool, opts in scenarios(root):
        if ns.only and name not in ns.only.split(","):
            continue
        r = run(ns.claude, root, name, kind, tool, opts)
        results.append(r)
        verdict = ("HOLDS" if r["holds"] else "BROKEN") if kind == "FLOOR" else ("ran" if r["ran"] else "did-not-run")
        failed |= kind == "FLOOR" and not r["holds"]
        print(f"{kind:5} {name:30} {verdict:11} asked={r['asked']} model_calls={r['model_calls']} result={r['result']} exit={r['exit']}"
              + (f" set_mode={r['set_mode_reply']}" if r["set_mode_reply"] else ""))
        if r["result"] is None and r["stderr"]:
            print("      stderr: " + r["stderr"].strip().replace("\n", " | ")[:400])
    if ns.json:
        with open(ns.json, "w") as f:
            json.dump({"claude": version, "results": results}, f, indent=2)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
