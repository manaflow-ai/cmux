#!/usr/bin/env python3
"""feat-cmux-next pushes run ci-web's checks, routed by everything the push brought.

With no push run, a web red that a direct push brings (219ae289fc's unformatted files,
2026-10-19) is seen only when a pull request trips over it, and every web red on a pull
request looks like a base red with no base run to compare it with (#20633 merged with a new
lint red beside the eager JS budget red). The scope job costs one small Linux job, so a push
that touches no web path runs nothing else.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-web.yml"
CI_WEB = ROOT / ".github/workflows/ci-web.yml"
HELPER = ROOT / "scripts/ci/web_subareas.py"


def test_every_feat_cmux_next_push_runs_the_web_checks() -> None:
    doc = yaml.safe_load(WORKFLOW.read_text())
    on = doc.get("on", doc.get(True))
    push = on.get("push") if isinstance(on, dict) else None
    assert push is not None, "cmux-next-web.yml has no push trigger"
    assert push.get("branches") == ["feat-cmux-next"], push
    # No paths filter: the scope job routes, so a web path list here could only drift.
    assert "paths" not in push and "paths-ignore" not in push, push
    web = doc["jobs"]["web"]
    assert web["uses"] == "./.github/workflows/ci-web.yml"
    assert web["with"].get("push_base") == "${{ github.event_name == 'push' && github.event.before || '' }}"


def test_ci_web_routes_from_the_push_base() -> None:
    doc = yaml.safe_load(CI_WEB.read_text())
    on = doc.get("on", doc.get(True))
    assert on["workflow_call"]["inputs"]["push_base"]["required"] is False
    steps = doc["jobs"]["web-subarea-scope"]["steps"]
    scope = next(s for s in steps if s.get("id") == "scope")
    assert scope["env"].get("WEB_SUBAREAS_BASE") == "${{ inputs.push_base }}"


def test_feat_cmux_next_pushes_run_the_cmux_next_checks_job() -> None:
    doc = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
    cond = doc["jobs"]["checks"]["if"]
    assert "!(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next')" not in cond, cond


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def route(cwd: Path, base: str, *, ref: str = "") -> dict[str, str]:
    with tempfile.NamedTemporaryFile("r", delete=False) as out:
        path = out.name
    env = {
        **os.environ,
        "GITHUB_OUTPUT": path,
        "EVENT_NAME": "push",
        "GITHUB_REF": ref,
        "WEB_SUBAREAS_BASE": base,
    }
    subprocess.run([sys.executable, str(HELPER), "route"], cwd=cwd, env=env, check=True, capture_output=True)
    lines = Path(path).read_text().splitlines()
    os.unlink(path)
    return dict(line.split("=", 1) for line in lines)


def test_a_multi_commit_push_routes_every_commit_not_only_the_last() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        (repo / "README.md").write_text("a\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "base")
        before = git(repo, "rev-parse", "HEAD")
        (repo / "webviews/src").mkdir(parents=True)
        (repo / "webviews/src/a.ts").write_text("export const a = 1\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "web change")
        (repo / "README.md").write_text("b\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "docs change on top")
        # HEAD^1 alone sees only README.md; the push range sees the webviews file too.
        assert route(repo, "")["react_apps"] == "false"
        assert route(repo, before)["react_apps"] == "true"
        # A push base the clone cannot resolve (a force push, a shallow fetch) runs everything.
        assert route(repo, "0" * 40)["react_apps"] == "true"


def test_feat_cmux_next_pushes_always_run_react_apps_check() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        (repo / "README.md").write_text("a\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "base")
        before = git(repo, "rev-parse", "HEAD")
        (repo / "README.md").write_text("b\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "docs change")

        assert route(repo, before, ref="refs/heads/feat-cmux-next")["react_apps"] == "true"
        assert route(repo, before, ref="refs/heads/other")["react_apps"] == "false"


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as err:  # noqa: BLE001 - report every failure
                failed += 1
                print(f"FAIL {name}: {type(err).__name__} {err}")
    sys.exit(1 if failed else 0)
