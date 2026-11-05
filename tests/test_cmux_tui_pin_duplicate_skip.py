#!/usr/bin/env python3
"""A cmux-tui-pin-* push of an already published tree builds nothing (cx-urd.26).

Pin pushes always built, even when their tree key was published: 222 pin runs
built on 2026-10-12, 25,215 job-minutes. Only a true
duplicate is skipped: the key's arm64 binaries and completion manifest are
published. A pin push also publishes its commit's binaries for cmux-tui.pin, so those
must be published too. A missing Windows daemon does not count: pushes never
build Windows, only a dispatch with include_windows does. A manual dispatch
still republishes.

This runs tree-preflight's own inspect step on this checkout with a fake curl
that serves files.cmux.com.
"""

import os
import stat
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
FAILURES = []

FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http")).split("?")[0]
if "/actions/" in url:
    print("{}")
    sys.exit(0)
out = args[args.index("-o") + 1] if "-o" in args else None
name = url.rsplit("/", 1)[1]
if name == "completion-windows.json" and os.environ.get("FAKE_WINDOWS") != "1":
    sys.exit(22)
if os.environ.get("FAKE_PUBLISHED") != "1":
    sys.exit(22)
if name == "daemon-tests.json" and os.environ.get("FAKE_MARKER") != "1":
    sys.exit(22)
if "/tree/" not in url:
    sys.exit(0 if os.environ.get("FAKE_COMMIT") != "0" else 22)
key = url.split("/tree/")[1].split("/")[0]
names = ["cmux-tui-aarch64-apple-darwin", "cmux-tui-app-host-aarch64-apple-darwin", "cmux-tui-cloud-server-aarch64-apple-darwin"]
if name == "completion.json":
    body = json.dumps({"key": key, "binaries": {n: "a" * 64 for n in names}})
elif name == "completion-windows.json":
    body = json.dumps({"key": key, "sourceCommit": "b" * 40})
elif name.endswith(".sha256"):
    body = "a" * 64 + "  x\n"
else:
    body = ""
if out and out != "/dev/null":
    open(out, "w").write(body)
elif not out:
    sys.stdout.write(body)
"""

FAKE_CLAIM = """#!/bin/sh
echo "owner=$GITHUB_RUN_ID granted=true"
"""


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def inspect_script():
    steps = yaml.safe_load(open(WORKFLOW, encoding="utf-8"))["jobs"]["tree-preflight"]["steps"]
    return next(s["run"] for s in steps if s.get("id") == "inspect")


def daemon_tests_run(outputs, takeover="true", unmarked="false", ref="refs/heads/cmux-tui-pin-0123456789ab"):
    """Evaluates cmux-next-daemon-tests' `if` for these tree-preflight outputs (daemon_tests true, as on a pin)."""
    import re
    expr = str(yaml.safe_load(open(WORKFLOW, encoding="utf-8"))["jobs"]["cmux-next-daemon-tests"]["if"]).strip()
    expr = expr.removeprefix("${{").removesuffix("}}")
    values = dict(outputs, daemon_tests="true")
    expr = re.sub(r"needs\.tree-preflight\.outputs\.(\w+)", lambda m: repr(values.get(m.group(1), "")), expr)
    expr = expr.replace("needs.tree-owner-wait.outputs.takeover", repr(takeover))
    expr = expr.replace("needs.tree-owner-wait.outputs.unmarked", repr(unmarked))
    expr = expr.replace("needs.tree-preflight.result", repr("success"))
    expr = expr.replace("needs.tree-owner-wait.result", repr("success"))
    expr = expr.replace("cancelled()", "False")
    expr = expr.replace("github.ref", repr(ref)).replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    return eval(" ".join(expr.split()), {"__builtins__": {}})


def preflight(ref, event="push", **fake):
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(bin_dir)
        curl = os.path.join(bin_dir, "curl")
        with open(curl, "w") as handle:
            handle.write(FAKE_CURL)
        os.chmod(curl, os.stat(curl).st_mode | stat.S_IXUSR)
        output = os.path.join(tmp, "out")
        open(output, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", EVENT_NAME=event, REF=ref, SHA=sha,
                   SOURCE_COMMIT=sha, HEAD_REPOSITORY="manaflow-ai/cmux", REPOSITORY="manaflow-ai/cmux",
                   SERVER_URL="https://github.invalid", API_URL="https://api.github.invalid", RUN_ID="5",
                   GITHUB_RUN_ID="5", GH_TOKEN="x", GITHUB_OUTPUT=output, RUNNER_TEMP=tmp)
        env.update(fake)
        result = subprocess.run(["bash", "-e", "-c", inspect_script()], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=120)
        outputs = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        return result, outputs


def main():
    pin = "refs/heads/cmux-tui-pin-0123456789ab"

    result, out = preflight(pin, FAKE_PUBLISHED="1", FAKE_WINDOWS="1")
    _check(result.returncode == 0 and out.get("run_macos") == "false",
           f"a pin push of a fully published tree builds nothing ({result.returncode}, {out.get('run_macos')}, {result.stderr.strip()[-300:]})")

    result, out = preflight(pin, FAKE_PUBLISHED="1", FAKE_WINDOWS="0")
    _check(result.returncode == 0 and out.get("run_macos") == "false",
           f"a pin push whose only gap is the Windows daemon builds nothing; pushes never build Windows ({out.get('run_macos')})")

    result, out = preflight(pin, FAKE_PUBLISHED="1", FAKE_WINDOWS="1", FAKE_COMMIT="0")
    _check(result.returncode == 0 and out.get("run_macos") == "true",
           f"a pin push of a new commit with a published tree still publishes that commit's binaries ({out.get('run_macos')})")

    result, out = preflight(pin, event="workflow_dispatch", FAKE_PUBLISHED="1", FAKE_WINDOWS="1")
    _check(result.returncode == 0 and out.get("run_macos") == "true",
           f"a dispatch on a pin ref still republishes ({out.get('run_macos')})")

    result, out = preflight("refs/heads/main", FAKE_PUBLISHED="1", FAKE_WINDOWS="1")
    _check(result.returncode == 0 and out.get("run_macos") == "true",
           f"main still builds a published tree for latest/ ({out.get('run_macos')})")

    # A pin push of a published tree that is not a full duplicate builds its commit's binaries (takeover),
    # but it does not test the tree again when tree/<key>/daemon-tests.json, which only a passing run of the
    # same key writes, already exists (2026-10-21).
    result, out = preflight(pin, FAKE_PUBLISHED="1", FAKE_WINDOWS="1", FAKE_COMMIT="0", FAKE_MARKER="1")
    _check(result.returncode == 0 and out.get("daemon_marker") == "true" and not daemon_tests_run(out),
           f"a pin build of a ready tree with its daemon-tests marker does not test it again ({out.get('daemon_marker')}, {result.stderr.strip()[-300:]})")
    result, out = preflight(pin, FAKE_PUBLISHED="1", FAKE_WINDOWS="1", FAKE_COMMIT="0")
    _check(result.returncode == 0 and out.get("daemon_marker") == "false" and daemon_tests_run(out),
           f"a pin build of a ready tree without the marker tests it ({out.get('daemon_marker')})")
    result, out = preflight(pin)
    _check(result.returncode == 0 and out.get("daemon_marker") == "false" and daemon_tests_run(out),
           f"a pin build of a new tree tests it ({out.get('daemon_marker')})")
    # Only a pin push: main and a dispatch still test a tree they build, marker or not.
    result, out = preflight("refs/heads/main", FAKE_PUBLISHED="1", FAKE_WINDOWS="1", FAKE_MARKER="1")
    _check(result.returncode == 0 and out.get("daemon_marker") == "false" and daemon_tests_run(out, ref="refs/heads/main"),
           f"a main build of a tested tree still tests it ({out.get('daemon_marker')})")
    result, out = preflight(pin, event="workflow_dispatch", FAKE_PUBLISHED="1", FAKE_WINDOWS="1", FAKE_MARKER="1")
    _check(result.returncode == 0 and out.get("daemon_marker") == "false" and daemon_tests_run(out),
           f"a dispatch on a pin ref of a tested tree still tests it ({out.get('daemon_marker')})")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: a pin push builds only a tree that is not fully published")
    return 0


if __name__ == "__main__":
    sys.exit(main())
