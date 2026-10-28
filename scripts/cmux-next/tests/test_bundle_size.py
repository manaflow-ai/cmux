#!/usr/bin/env python3
"""Behavior tests of scripts/cmux-next/bundle-size.py on small synthetic apps."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "scripts/cmux-next/bundle-size.py"
REAL_BUDGET = ROOT / "scripts/cmux-next/bundle-size-budget.json"
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


def test_unknown_variant_fails(tmp: Path) -> None:
    app = make_app(tmp)
    r = run("check", str(app), "--budget", str(budget(tmp)), "--variant", "x86_64")
    assert r.returncode == 1
    assert "no variant 'x86_64'" in r.stderr


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


def load_tool():
    import importlib.util
    spec = importlib.util.spec_from_file_location("bundle_size_under_test", TOOL)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def story_values(tool):
    writer = tool._load("perf_result", ROOT / "scripts/perf-lab/perf_result.py")
    build = writer.Build(sha="c" * 40, config="bench", measure_version=tool.STORY_MEASURE_VERSION)
    host = writer.Host(fingerprint="d" * 64, host_class="apple-m6/16gb/0hz", chip="Apple M6", macos="26.1",
                       macos_build="25B78", display_hz=None)
    return writer, build, host


def test_story_writes_result_v1_of_the_app_and_its_cef_framework(tmp: Path) -> None:
    tool = load_tool()
    writer, build, host = story_values(tool)
    app = make_app(tmp)
    out = tmp / "out"
    path = tool.write_story(app, out, build, host)
    stored = {r.metric: r for r in writer.read_file(path)}
    assert sorted(stored) == ["bundle.app_bytes", "bundle.cef_framework_bytes"], sorted(stored)
    assert stored["bundle.app_bytes"].samples == [4600], stored["bundle.app_bytes"].samples
    assert stored["bundle.cef_framework_bytes"].samples == [3100], stored["bundle.cef_framework_bytes"].samples
    assert {(r.story, r.unit, r.better, r.engine) for r in stored.values()} == {("bundle-size", "bytes", "lower", "none")}
    import hashlib
    digest = "sha256:" + hashlib.sha256((out / tool.REPORT_FILE).read_bytes()).hexdigest()
    assert {a.digest for r in stored.values() for a in r.attachments} == {digest}


def test_story_metrics_are_the_ones_its_story_claims(tmp: Path) -> None:
    import re
    tool = load_tool()
    story = json.loads((ROOT / "scripts/perf-lab/stories.d/bundle-size.json").read_text())
    assert story["command"][:2] == ["scripts/cmux-next/bundle-size.py", "story"], story["command"]
    _, series = tool.story_series(make_app(tmp))
    for metric, _size in series:
        assert any(re.fullmatch(m["name"], metric) and m["unit"] == "bytes" for m in story["metrics"]), metric


def test_story_refuses_an_app_without_cef_and_writes_nothing(tmp: Path) -> None:
    tool = load_tool()
    _, build, host = story_values(tool)
    app = tmp / "cmux DEV x.app"
    write(app, "Contents/MacOS/cmux DEV", 10)
    try:
        tool.write_story(app, tmp / "out", build, host)
    except tool.StoryError as error:
        assert "Chromium Embedded Framework" in str(error), error
    else:
        raise AssertionError("an app without CEF was measured")
    assert not (tmp / "out").exists()


def test_story_cli_refuses_a_bundle_with_no_build_sha(tmp: Path) -> None:
    app = make_app(tmp)
    out = tmp / "out"
    env = {k: v for k, v in os.environ.items() if k not in ("CMUX_CI_SHA", "PERF_LAB_CONFIG")}
    r = subprocess.run([sys.executable, "-I", str(TOOL), "story", "--app", str(app), "--out", str(out)],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 2, (r.returncode, r.stderr)
    assert "story refused" in r.stderr and "no build sha" in r.stderr, r.stderr
    assert not out.exists() or not list(out.glob("*.ndjson"))


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
