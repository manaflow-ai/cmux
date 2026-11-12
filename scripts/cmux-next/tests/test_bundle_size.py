#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/bundle-size.py on small synthetic apps."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/bundle-size.py"
REAL_BUDGET = ROOT / "scripts/cmux-next/bundle-size-budget.json"
NIGHTLY_WORKFLOW = ROOT / ".github/workflows/nightly.yml"
CEF = "Contents/Frameworks/Chromium Embedded Framework.framework"


def write(app: Path, rel: str, size: int) -> None:
    p = app / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"x" * size)


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], capture_output=True, text=True)


def make_app(tmp: Path) -> Path:
    app = tmp / "cmux NEXT.app"
    write(app, "Contents/MacOS/cmux", 1000)
    write(app, f"{CEF}/Versions/A/Chromium Embedded Framework", 3000)
    write(app, f"{CEF}/Versions/A/Resources/v8_context_snapshot.arm64.bin", 100)
    # The framework's top-level links must not count twice.
    os.symlink("A", app / CEF / "Versions/Current")
    os.symlink("Versions/Current/Chromium Embedded Framework", app / CEF / "Chromium Embedded Framework")
    write(app, "Contents/Resources/bin/cmux", 500)
    return app


def budget(tmp: Path, **rules) -> Path:
    p = tmp / "budget.json"
    p.write_text(json.dumps({"schema": 1, "variants": {"arm64": rules}}))
    return p


def test_report_counts_files_once_per_component(tmp: Path) -> None:
    app = make_app(tmp)
    out = tmp / "r.json"
    r = run("report", str(app), "--json", str(out))
    assert r.returncode == 0, r.stderr
    data = json.loads(out.read_text())
    sizes = {c["component"]: c["bytes"] for c in data["components"]}
    assert sizes[CEF] == 3100, sizes
    assert sizes["Contents/MacOS/cmux"] == 1000
    assert sizes["Contents/Resources/bin"] == 500
    assert data["app_bytes"] == 4600


def test_fits_budget(tmp: Path) -> None:
    app = make_app(tmp)
    b = budget(tmp, app_max_bytes=5000, components={CEF: 3100}, forbidden=["**/*.map"])
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 0, r.stderr
    assert "fits" in r.stdout


def test_forbidden_file_fails_and_is_named(tmp: Path) -> None:
    app = make_app(tmp)
    snap = f"{CEF}/Versions/A/Resources/v8_context_snapshot.x86_64.bin"
    write(app, snap, 100)
    write(app, "Contents/Resources/markdown-viewer/app.js.map", 10)
    b = budget(tmp, forbidden=[snap, "**/*.map"])
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 1
    assert f"forbidden: {snap}" in r.stderr, r.stderr
    assert "forbidden: Contents/Resources/markdown-viewer/app.js.map" in r.stderr, r.stderr


def test_component_app_and_dmg_caps(tmp: Path) -> None:
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * 50)
    b = budget(tmp, app_max_bytes=4599, dmg_max_bytes=49, components={"Contents/MacOS/cmux": 999})
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 1
    assert "component over budget: Contents/MacOS/cmux is 1000 bytes" in r.stderr, r.stderr
    assert "app over budget: 4600 bytes" in r.stderr, r.stderr
    assert "DMG over budget: x.dmg is 50 bytes" in r.stderr, r.stderr


def test_dmg_cap_without_dmg_fails(tmp: Path) -> None:
    app = make_app(tmp)
    b = budget(tmp, dmg_max_bytes=10)
    r = run("check", str(app), "--budget", str(b), "--variant", "arm64")
    assert r.returncode == 1
    assert "no --dmg" in r.stderr


def test_nightly_bundle_budget_step_is_blocking(tmp: Path) -> None:
    del tmp
    text = NIGHTLY_WORKFLOW.read_text()
    match = re.search(
        r"(?ms)^      - name: Bundle size budget\n(?P<body>.*?)(?=^      - name: )",
        text,
    )
    assert match, "nightly.yml must keep the named bundle budget step"
    body = match.group("body")
    assert "continue-on-error:" not in body, "the bundle budget must block a nightly publish"
    assert "verify-final-dmg-bundle-size-budget.sh" in body


def test_unknown_variant_fails(tmp: Path) -> None:
    app = make_app(tmp)
    r = run("check", str(app), "--budget", str(budget(tmp)), "--variant", "x86_64")
    assert r.returncode == 1
    assert "no variant 'x86_64'" in r.stderr


def test_pr_resource_guard_fails_on_growth_missing_output_and_missing_cap(tmp: Path) -> None:
    pages = "Contents/Resources/CmuxNext_CmuxNextPages.bundle"
    pane = "Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle"
    root = tmp / "source"
    source = "Packages/macOS/CmuxNext/Sources"
    write(root, f"{source}/CmuxNextPages/Resources/pages/settings/index.html", 100)
    write(root, f"{source}/CmuxNextAgentPane/Resources/agent-pane/index.html", 100)
    b = budget(tmp, components={pages: 110, pane: 110}, app_max_bytes=1,
               dmg_max_bytes=1, forbidden=["**/*.map"])
    data = json.loads(b.read_text())
    data["web_resource_metadata_reserve_bytes"] = {pages: 10, pane: 10}
    b.write_text(json.dumps(data))

    def guard():
        return subprocess.run(["bash", str(ROOT / "scripts/cmux-next/check-web-bundle-size.sh"),
                               str(root), str(b)], capture_output=True, text=True)

    r = guard()
    assert r.returncode == 0, r.stderr  # Native/DMG caps do not apply to resources.
    write(root, f"{source}/CmuxNextPages/Resources/pages/shared/chunk.js", 1)
    r = guard()
    assert r.returncode == 1 and f"{pages} is 101 bytes" in r.stderr, r.stderr
    b.write_text(json.dumps({"variants": {"arm64": {"components": {pages: 102, pane: 100}}}}))
    write(root, f"{source}/CmuxNextAgentPane/Resources/agent-pane/index.html", 0)
    r = guard()
    assert r.returncode == 1 and "missing generated" in r.stderr, r.stderr
    write(root, f"{source}/CmuxNextAgentPane/Resources/agent-pane/index.html", 100)
    b.write_text(json.dumps({"variants": {"arm64": {"components": {pages: 102}}}}))
    r = guard()
    assert r.returncode != 0 and "missing or invalid Pages/AgentPane" in r.stderr, r.stderr


def test_pr_aggregate_rejects_bundle_failure_even_when_style_only_warns(tmp: Path) -> None:
    del tmp
    workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
    step = workflow.split("      - name: Fail on the gate checks\n", 1)[1]
    header, body = step.split("        run: |\n", 1)
    assert "BUNDLES: ${{ steps.bundles.outcome }}" in header
    assert "continue-on-error:" not in header
    lines = []
    for line in body.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line)
    command = textwrap.dedent("\n".join(lines))
    env = dict(os.environ)
    env.update({key: "success" for key in re.findall(r"^          ([A-Z_]+):", header, re.M)})
    env.update(CMUX_NEXT_STYLE_GUARDS="warn", STYLE_GATES="EAGER_JS_BUDGET REACT_COMPILER")
    passed = subprocess.run(["bash", "-e", "-c", command], env=env, capture_output=True, text=True)
    assert passed.returncode == 0, passed.stderr
    env["BUNDLES"] = "failure"
    failed = subprocess.run(["bash", "-e", "-c", command], env=env, capture_output=True, text=True)
    assert failed.returncode == 1, failed.stdout + failed.stderr
    assert "Gate failed; see the step 'Build the web bundles'" in failed.stdout


def test_real_budget_rejects_the_x86_64_snapshot(tmp: Path) -> None:
    # The checked-in arm64 budget, on an app that is small enough but still
    # carries the Intel V8 snapshot an older nightly-next (50af7da) shipped.
    app = make_app(tmp)
    write(app, f"{CEF}/Versions/A/Resources/v8_context_snapshot.x86_64.bin", 100)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d")
    r = run("check", str(app), "--budget", str(REAL_BUDGET), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 1
    assert "v8_context_snapshot.x86_64.bin" in r.stderr, r.stderr


def test_summary_names_the_overage_and_the_change_and_exits_0(tmp: Path) -> None:
    # Over budget is reported, not gated: the nightly shows it on every run.
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * (3 * 1024 * 1024))
    b = budget(tmp, app_max_bytes=5000, dmg_max_bytes=2 * 1024 * 1024)
    out = tmp / "s.json"
    r = run("summary", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg),
            "--previous-dmg-bytes", str(2 * 1024 * 1024 + 512 * 1024), "--json", str(out))
    assert r.returncode == 0, r.stderr
    head = r.stdout.splitlines()[0]
    assert head == ("**DMG 3.0 MiB**: 1.0 MiB over its 2.0 MiB cap (arm64); "
                    "+0.5 MiB since the previous nightly (2.5 MiB)."), head
    assert "- DMG over budget: x.dmg" in r.stdout, r.stdout
    data = json.loads(out.read_text())
    assert data["over_budget"] is True
    assert data["dmg_delta_bytes"] == 512 * 1024
    assert data["app_bytes"] == 4600 and data["app_max_bytes"] == 5000


def test_summary_under_budget_without_a_previous_nightly(tmp: Path) -> None:
    app = make_app(tmp)
    dmg = tmp / "x.dmg"
    dmg.write_bytes(b"d" * 10)
    b = budget(tmp, app_max_bytes=5000, dmg_max_bytes=1024 * 1024)
    r = run("summary", str(app), "--budget", str(b), "--variant", "arm64", "--dmg", str(dmg))
    assert r.returncode == 0, r.stderr
    assert "under its 1.0 MiB cap (arm64); no previous nightly to compare." in r.stdout, r.stdout
    assert "Over budget" not in r.stdout, r.stdout


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        with tempfile.TemporaryDirectory() as d:
            try:
                t(Path(d))
                print(f"ok {t.__name__}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {t.__name__}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
