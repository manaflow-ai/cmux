#!/usr/bin/env python3
"""Generate the standalone agent worktree import clip; never launch a capture.

The fixture runs only inside a capture-owned terminal. Its first invocation checks
both app and daemon ownership before installing itself in the isolated HOME.
Later invocations verify the installed source digest, then repeat those checks.
Use --check to validate the checked-in spec without changing it.
"""

import argparse
import ast
import base64
import hashlib
import json
from pathlib import Path
import shlex
import zlib


DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[2]
FIXTURE = DIRECTORY / "fixtures/agent-worktree-import.py"
OUTPUT = ROOT / "release-notes/next/clips/agent-worktree-import.json"


def terminal(source, mode, title, wait=0, clip=False):
    if mode == "setup":
        payload = base64.b64encode(zlib.compress(source, 9)).decode("ascii")
        bootstrap = (
            "import base64,zlib;_fixture_source=zlib.decompress(base64.b64decode("
            + repr(payload)
            + "));exec(compile(_fixture_source,'<capture-fixture>','exec'))"
        )
    else:
        digest = hashlib.sha256(source).hexdigest()
        bootstrap = "\n".join([
            "import hashlib,os,pathlib",
            "home=pathlib.Path(os.environ['HOME'])",
            "if not home.is_absolute() or home.is_symlink(): raise RuntimeError('Invalid capture HOME')",
            "if str(home)!=os.environ.get('CMUX_CAPTURE_SHELL_HOME'): raise RuntimeError('Wrong capture HOME')",
            "helper=home/'import-any-tool-fixture/capture.py'",
            "if helper.is_symlink() or not helper.resolve().is_relative_to(home.resolve()): raise RuntimeError('Helper escapes capture HOME')",
            "_fixture_source=helper.read_bytes()",
            "if hashlib.sha256(_fixture_source).hexdigest()!=" + repr(digest)
            + ": raise RuntimeError('Fixture source changed')",
            "exec(compile(_fixture_source,str(helper),'exec'))",
        ])
    command = shlex.join(["python3", "-c", bootstrap, mode])
    step = {
        "title": title,
        "daemon": True,
        "timeout": 150,
        "cmux": ["terminal", "${saved:fixture_terminal}", "run", "--timeout", "120s", "--text", command],
    }
    if wait:
        step["wait"] = wait
    if clip:
        step["clip"] = True
    return step


def rpc(method, params=None, title=None):
    return {
        "title": title or method,
        "rpc": {"method": method, "params": params or {}},
        "record": "file",
    }


def page(action, **params):
    return rpc("debug.page", {"page": "cmux.settings", "action": action, **params},
               "Settings import " + action)


def spec(source):
    ast.parse(source)
    card = '[data-import-card="agents.conductor"]'
    return {
        "caption": "Review the worktree import plan in Settings, then open the workspaces in their existing folders.",
        "frameInterval": 1.0,
        "steps": [
            {"title": "Open the fixture terminal", "cmux": ["workspace", "new", "--name", "Import fixture"]},
            {"title": "Focus the fixture terminal", "cmux": ["workspace", "name:Import fixture", "focus"]},
            {"title": "Resolve the fixture terminal", "daemon": True,
             "cmux": ["--json", "terminal", "list", "--workspace", "name:Import fixture"],
             "save": {"fixture_terminal": "0.id"}},
            terminal(source, "setup", "Create isolated linked worktree and agent rollout"),
            {"title": "Refresh project metadata", "reopen": "quit", "recordLaunch": 6, "wait": 2},
            {"title": "Open Import settings", "cmux": ["import", "open"]},
            page("wait", selector=card + ' [data-action="start"]', timeout_ms=30000),
            page("state"),
            {**page("click", selector=card + ' [data-action="start"]'), "wait": 1},
            rpc("debug.dialog", title="Real import consent"),
            terminal(source, "consent", "Assert and confirm native consent", wait=2),
            rpc("debug.dialog", title="Real generic worktree preview"),
            terminal(source, "preview", "Import the worktree from its preview", wait=1.2, clip=True),
            {**page("wait", selector=card + '[data-state="done"]', timeout_ms=60000),
             "wait": 0.8, "clip": True},
            page("state"),
            terminal(source, "verify", "Assert open workspace and completed idempotent ledger"),
            rpc("snapshot.get", title="Read back imported app workspace"),
            {"title": "Completed Import settings", "cmux": ["import", "open"]},
            page("state"),
        ],
        "crop": [0.2, 0.08, 0.75, 0.75],
        "lead": 0.6,
        "hold": 1.2,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = json.dumps(spec(FIXTURE.read_bytes()), ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != generated:
            parser.exit(1, "agent-worktree-import.json is stale; run this generator\n")
        print("Agent worktree import clip matches its fixture source.")
    else:
        OUTPUT.write_text(generated)
        print(OUTPUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
