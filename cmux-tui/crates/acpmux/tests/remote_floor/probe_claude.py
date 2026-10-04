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
# The built-in tools Claude Code 2.1.289 offers in -p mode (from the fake model's request log).
TOOLS_2_1_289 = ["Agent", "AskUserQuestion", "Bash", "CronCreate", "CronDelete", "CronList", "Edit", "EnterPlanMode",
                 "EnterWorktree", "ExitPlanMode", "ExitWorktree", "ListAgents", "NotebookEdit", "Read",
                 "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "TaskCreate", "TaskGet", "TaskList",
                 "TaskStop", "TaskUpdate", "WebFetch", "WebSearch", "Workflow", "Write"]
ASK_ALL = [t for t in TOOLS_2_1_289 if t != "Skill"]


SECRET_DENY = ["Read(./.env*)", "Read(**/.env*)", "Read(**/*.token)", "Read(**/.claude/**)", "Read(**/state/**)"]


REMOTE_DENY_TOOLS = ["Skill", "SlashCommand"]


def remote_settings(hook=None, hook_timeout=900, ask=ASK_ALL, deny=SECRET_DENY + REMOTE_DENY_TOOLS,
                    disable_bypass=True):
    settings = {"permissions": {"ask": list(ask), "deny": list(deny), "defaultMode": "default"}}
    if disable_bypass:
        settings["permissions"]["disableBypassPermissionsMode"] = "disable"
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
        ("flag-mode-bypass-without-disable", "INFO", "Bash", {"inject": remote_settings(disable_bypass=False),
                                                              "mode": "bypassPermissions"}),
        ("read-env-without-deny", "INFO", "Read", {"inject": remote_settings(deny=[]), "secret": ".env"}),
        ("read-env-with-deny", "FLOOR", "Read", {"inject": remote_settings(), "secret": ".env"}),
        ("read-token-with-deny", "FLOOR", "Read", {"inject": remote_settings(), "secret": "api.token"}),
        ("read-claude-dir-with-deny", "FLOOR", "Read", {"inject": remote_settings(), "secret": ".claude/notes.md"}),
        ("read-state-with-deny", "FLOOR", "Read", {"inject": remote_settings(), "secret": "state/session.json"}),
        ("at-path-expansion", "FLOOR", "Bash", {"inject": remote_settings(), "secret": "notes/private.txt",
                                                "prompt": "summarize @SECRETPATH"}),
        ("at-path-mid-text-blocks", "FLOOR", "Bash", {"inject": remote_settings(), "secret": "notes/private.txt",
                                                      "prompt": "Message from phone: see @SECRETPATH please", "blocks": True}),
        ("user-definitions-default-sources", "INFO", "Bash", {"inject": remote_settings(), "definitions": True}),
        ("user-definitions-empty-sources", "FLOOR", "Bash", {"inject": remote_settings(), "definitions": True,
                                                             "args": ["--setting-sources", ""]}),
        ("user-command-bang-empty-sources", "FLOOR", "Bash", {"inject": remote_settings(), "definitions": True,
                                                              "args": ["--setting-sources", ""], "prompt": "/probecmd"}),
        ("user-command-bang-default-sources", "INFO", "Bash", {"inject": remote_settings(), "definitions": True,
                                                               "prompt": "/probecmd"}),
        ("hook-allow-empty-sources-no-ask", "INFO", "Bash", {"inject": remote_settings(hook_script(root, "allow"), ask=[]),
                                                             "args": ["--setting-sources", ""]}),
        ("empty-sources-no-ask-rules", "FLOOR", "Bash", {"inject": remote_settings(ask=[]),
                                                         "args": ["--setting-sources", ""]}),
        ("empty-sources-write", "FLOOR", "Write", {"inject": remote_settings(ask=[]),
                                                   "args": ["--setting-sources", ""], "mode": "default"}),
        ("at-path-denied-file", "FLOOR", "Bash", {"inject": remote_settings(), "secret": ".env",
                                                  "prompt": "summarize @SECRETPATH"}),
        ("at-path-zero-width", "FLOOR", "Bash", {"inject": remote_settings(), "secret": "notes/private.txt",
                                                 "prompt": "summarize @\u200bSECRETPATH"}),
        ("at-path-fullwidth-at", "FLOOR", "Bash", {"inject": remote_settings(), "secret": "notes/private.txt",
                                                   "prompt": "summarize \uff20SECRETPATH"}),
        ("at-path-in-document-block", "FLOOR", "Bash", {"inject": remote_settings(), "secret": "notes/private.txt",
                                                        "prompt": "summarize @SECRETPATH", "document": True}),
        ("user-allow-without-floor", "INFO", "Bash", {"user": {"permissions": {"allow": ["Bash"]}}}),
        ("project-allow-bare-without-floor", "INFO", "Bash", {"project": {"permissions": {"allow": ["Bash"]}}}),
        ("read-in-cwd-with-ask", "FLOOR-ASK", "Read", {"inject": remote_settings(), "secret": "notes/plain.txt",
                                                   "args": ["--setting-sources", ""]}),
        ("read-in-cwd-ask-wildcard", "FLOOR-ASK", "Read", {"inject": remote_settings(ask=["*"]),
                                                            "secret": "notes/plain.txt", "args": ["--setting-sources", ""]}),
        ("read-in-cwd-no-ask", "INFO", "Read", {"inject": remote_settings(ask=[]), "secret": "notes/plain.txt",
                                                "args": ["--setting-sources", ""]}),
        ("tools-closed-list", "INFO", "Bash", {"inject": remote_settings(), "args": ["--setting-sources", "",
                                               "--tools", "Bash,Read,Write,Edit,Agent"]}),
        ("agent-ask", "FLOOR-ASK", "Agent", {"inject": remote_settings(), "args": ["--setting-sources", ""]}),
        ("subagent-inherits-ask", "FLOOR-ASK", "Agent", {"inject": remote_settings(), "args": ["--setting-sources", ""],
                                                         "allow_tools": ["Agent"], "sub": "Bash", "expect_ask": "Bash"}),
        ("subagent-inherits-deny", "FLOOR", "Agent", {"inject": remote_settings(), "args": ["--setting-sources", ""],
                                                      "allow_tools": ["Agent"], "sub": "Read", "secret": ".env"}),
        ("subagent-read-in-cwd-ask", "FLOOR-ASK", "Agent", {"inject": remote_settings(), "args": ["--setting-sources", ""],
                                                            "allow_tools": ["Agent"], "sub": "Read",
                                                            "secret": "notes/plain.txt", "expect_ask": "Read"}),
        ("memory-default-sources", "INFO", "Bash", {"inject": remote_settings(), "memory": True}),
        ("memory-empty-sources", "FLOOR", "Bash", {"inject": remote_settings(), "memory": True,
                                                   "args": ["--setting-sources", ""]}),
        ("slash-clear-prefixed", "INFO", "Bash", {"inject": remote_settings(), "prompt": "Message from phone: /clear"}),
        ("slash-clear-as-text", "INFO", "Bash", {"inject": remote_settings(), "prompt": "/clear"}),
        ("bang-as-text", "INFO", "Bash", {"inject": remote_settings(), "prompt": "!touch MARKER"}),
    ]


SENTINELS = {
    "user_memory": "probe-sentinel-user-claude-md",
    "user_import": "probe-sentinel-user-import",
    "project_memory": "probe-sentinel-project-claude-md",
    "skill": "probe-sentinel-user-skill",
    "command": "probe-sentinel-user-command",
    "agent": "probe-sentinel-user-agent",
    "project_skill": "probe-sentinel-project-skill",
}


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def plant_user_definitions(home, project, marker):
    write_text(os.path.join(home, ".claude", "skills", "probe", "SKILL.md"),
               f"---\nname: probe-skill\ndescription: {SENTINELS['skill']}\nallowed-tools: Bash\n---\n"
               f"Run touch {marker}\n")
    write_text(os.path.join(home, ".claude", "commands", "probecmd.md"),
               f"---\ndescription: {SENTINELS['command']}\nallowed-tools: Bash(touch:*)\n---\n"
               f"!`touch {marker}`\n")
    write_text(os.path.join(home, ".claude", "agents", "probe-agent.md"),
               f"---\nname: probe-agent\ndescription: {SENTINELS['agent']}\npermissionMode: bypassPermissions\n---\n"
               f"Run touch {marker}\n")
    write_text(os.path.join(project, ".claude", "skills", "projprobe", "SKILL.md"),
               f"---\nname: project-probe-skill\ndescription: {SENTINELS['project_skill']}\n---\nhello\n")


def plant_memory(home, project):
    write_text(os.path.join(home, ".claude", "notes.md"), SENTINELS["user_import"] + "\n")
    write_text(os.path.join(home, ".claude", "CLAUDE.md"),
               SENTINELS["user_memory"] + "\n@" + os.path.join(home, ".claude", "notes.md") + "\n")
    write_text(os.path.join(project, "CLAUDE.md"), SENTINELS["project_memory"] + "\n")


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(value, f)


SECRET = "probe-secret-7f3a9c"


def tool_input_for(tool, marker, secret_path, project):
    return {
        "Bash": {"command": f"touch {marker}"},
        "Read": {"file_path": secret_path},
        "Write": {"file_path": marker, "content": "x\n"},
        "Glob": {"pattern": "**/*", "path": project},
        "Grep": {"pattern": "probe", "path": project},
        "TodoWrite": {"todos": [{"content": "probe", "status": "pending", "activeForm": "probing"}]},
        "Agent": {"description": "probe", "prompt": "run the tool", "subagent_type": "general-purpose"},
    }[tool]


def start_fake(tool, marker, log, secret_path=None, project=None, sub=None):
    env = dict(os.environ, FAKE_TOOL_NAME=tool,
               FAKE_TOOL_INPUT=json.dumps(tool_input_for(tool, marker, secret_path, project)), FAKE_MODEL_LOG=log,
               FAKE_SECRET=SECRET, FAKE_SENTINELS=",".join(SENTINELS.values()))
    if sub:
        env.update(FAKE_SUB_TOOL_NAME=sub, FAKE_SUB_TOOL_INPUT=json.dumps(tool_input_for(sub, marker, secret_path, project)))
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
    # Inside the project: a path outside the working directory makes Claude ask
    # whatever the rules say, which would hide what the rules do.
    marker = os.path.join(project, "marker")
    # A real server checkout is trusted; without this Claude ignores project settings.
    write_json(os.path.join(home, ".claude.json"), {"projects": {project: {"hasTrustDialogAccepted": True}},
                                                    "hasCompletedOnboarding": True})
    if "user" in opts:
        write_json(os.path.join(home, ".claude", "settings.json"), opts["user"])
    if "project" in opts:
        write_json(os.path.join(project, ".claude", "settings.json"), opts["project"])
    args = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-prompt-tool", "stdio", "--model", "claude-sonnet-4-5"]
    if "inject" in opts:
        # Inline JSON, not a file a same-uid tool could rewrite (P2-L).
        args += ["--settings", json.dumps(opts["inject"]),
                 "--strict-mcp-config", "--mcp-config", json.dumps({"mcpServers": {}})]
    args += ["--permission-mode", opts.get("mode", "default")]
    args += opts.get("args", [])
    if opts.get("definitions"):
        plant_user_definitions(home, project, marker)
    secret_path = None
    if "secret" in opts:
        secret_path = os.path.join(project, opts["secret"])
        os.makedirs(os.path.dirname(secret_path), exist_ok=True)
        with open(secret_path, "w") as f:
            f.write(SECRET + "\n")
    if opts.get("memory"):
        plant_memory(home, project)
    fake, port = start_fake(tool, marker, os.path.join(case, "model.log"), secret_path, project, opts.get("sub"))
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
        prompt = prompt.replace("SECRETPATH", opts.get("secret", ""))
        if opts.get("document"):
            content = [{"type": "text", "text": "Message from phone, as a document:"},
                       {"type": "document", "source": {"type": "text", "media_type": "text/plain", "data": prompt}}]
        elif opts.get("blocks"):
            content = [{"type": "text", "text": prompt}]
        else:
            content = prompt
        send(proc, {"type": "user", "message": {"role": "user", "content": content}})
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
                asked_tool = msg["request"].get("tool_name")
                result.setdefault("asked_tools", []).append(asked_tool)
                if asked_tool in opts.get("allow_tools", []):
                    reply = {"behavior": "allow", "updatedInput": msg["request"].get("input", {})}
                else:
                    reply = {"behavior": "deny", "message": "remote floor probe denies"}
                send(proc, {"type": "control_response", "response": {
                    "subtype": "success", "request_id": msg["request_id"], "response": reply}})
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
    calls = [json.loads(line) for line in open(log)] if os.path.exists(log) else []
    result["model_calls"] = len(calls)
    result["secret_seen"] = any(c.get("secret_seen") for c in calls)
    result["sentinels"] = sorted({x for c in calls for x in c.get("sentinels", [])})
    result["offered"] = calls[0].get("tools", []) if calls else []
    result["holds"] = not result["ran"] and not result["secret_seen"] and not result["sentinels"]
    if kind == "FLOOR-ASK":
        expected = opts.get("expect_ask", tool)
        result["holds"] = result["holds"] and expected in result.get("asked_tools", [])
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
        effect = r["ran"] or r["secret_seen"] or bool(r["sentinels"])
        floor = kind.startswith("FLOOR")
        verdict = ("HOLDS" if r["holds"] else "BROKEN") if floor else ("effect" if effect else "no-effect")
        failed |= floor and not r["holds"]
        print(f"{kind:9} {name:36} {verdict:11} asked={r['asked']} secret_seen={r['secret_seen']} model_calls={r['model_calls']} result={r['result']} exit={r['exit']} tools={','.join(r.get('asked_tools', []))}"
              + (f" loaded={','.join(r['sentinels'])}" if r["sentinels"] else "")
              + (f" offered={','.join(r['offered'])}" if name == "tools-closed-list" else "")
              + (f" set_mode={r['set_mode_reply']}" if r["set_mode_reply"] else ""))
        if r["result"] is None and r["stderr"]:
            print("      stderr: " + r["stderr"].strip().replace("\n", " | ")[:400])
    if ns.json:
        with open(ns.json, "w") as f:
            json.dump({"claude": version, "results": results}, f, indent=2)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
