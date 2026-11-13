# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Manaflow, Inc.
"""Overlay the cmux driver onto a checkout of the AgentEnv Cua Driver Bench port
(github.com/earakely-scale/agentenv-cua-driver-bench), in place, for a run.

    python3 overlay.py PORT --cmux cmux-tui.gz [--cmux-macos cmux-macos.tar.gz]

Writes, all under PORT and nothing here:
  envs/cmux/                      this driver, with the cmux binary staged as bin/cmux-tui.gz
  envs/desktop*-cmux/             each Linux computer of the bench (desktop, desktop-benchlab, desktop-s02..s04)
                                  with driver = "cmux"
  tasks/cmux-*.json               each Linux agent-desktop trial file, rewritten for the cmux computers (the trials'
                                  prompts, limits and grade are the port's, untouched)
  tasks/cmux-probe.json, tasks/cmux-app-s0N.json, tasks/cmux-sentinel-*.json
                                  the conformance probe, the app checks and the sentinel checks on cmux's computers
  tasks/cmux-benchlab-*.json      BenchLab's checks done through cmux's tools, with no model (check_benchlab_cmux)
  artifacts/check_benchlab_cmux/  that check
  evals/cmux-*.toml, evals/cmux-bench-v2-trials.txt

The trial files carry trycua's prompts (FSL-1.1), so they are generated into the port's checkout at run time and
never kept in the cmux repository. The bench names the driver by its folder, `cmux`, as a bundle env.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER_FILES = ("driver.py", "env.toml", "mcp.json", "requirements.txt", "requirements-macos.txt", "install.sh",
                "install-macos.sh")
COMPUTERS = ("desktop", "desktop-benchlab", "desktop-s02", "desktop-s03", "desktop-s04")



def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("port", type=Path)
    parser.add_argument("--cmux", type=Path, required=True, help="the Linux cmux-tui binary, gzipped")
    parser.add_argument("--cmux-macos", type=Path, help="a tarball of cmux and cmux Remote (dev).app (unverified)")
    args = parser.parse_args()
    port = args.port.resolve()
    if not (port / "bundle.toml").is_file() or not (port / "envs" / "desktop").is_dir():
        raise SystemExit(f"{port} is not a checkout of the bench port")

    driver = port / "envs" / "cmux"
    shutil.rmtree(driver, ignore_errors=True)
    (driver / "bin").mkdir(parents=True)
    for name in DRIVER_FILES:
        shutil.copy2(HERE / name, driver / name)
    shutil.copy2(args.cmux, driver / "bin" / "cmux-tui.gz")
    if args.cmux_macos:
        shutil.copy2(args.cmux_macos, driver / "bin" / "cmux-macos.tar.gz")

    for computer in COMPUTERS:
        text = (port / "envs" / computer / "env.toml").read_text()
        text, n = re.subn(r'^driver = "[^"]+"$', 'driver = "cmux"', text, flags=re.M)
        assert n == 1, computer
        (port / "envs" / f"{computer}-cmux").mkdir(exist_ok=True)
        (port / "envs" / f"{computer}-cmux" / "env.toml").write_text(text)

    def cmux_env(env_id: str) -> str:
        base = env_id.removesuffix("-agent-desktop")
        assert base in COMPUTERS, env_id
        return f"{base}-cmux"

    trials = []
    for source in sorted((port / "tasks").glob("agent-desktop-*.json")):
        steps = json.loads(source.read_text())
        for step in steps:
            for key in ("env_id",):
                if key in step:
                    step[key] = cmux_env(step[key])
            if "env_ids" in step:
                step["env_ids"] = [cmux_env(e) for e in step["env_ids"]]
        name = "cmux-" + source.name.removeprefix("agent-desktop-")
        _write(port / "tasks" / name, steps)
    for line in (port / "evals" / "agent-desktop-bench-v2-trials.txt").read_text().splitlines():
        trials.append(line.replace("agent-desktop-", "cmux-", 1) if line.strip() else line)
    (port / "evals" / "cmux-bench-v2-trials.txt").write_text("\n".join(trials) + "\n")

    def retarget(source: str, computer: str, target: str) -> None:
        steps = json.loads((port / "tasks" / source).read_text())
        for step in steps:
            if step.get("env_id") == computer:
                step["env_id"] = f"{computer}-cmux"
        _write(port / "tasks" / target, steps)

    retarget("probe.json", "desktop", "cmux-probe.json")
    for n in (2, 3, 4):
        retarget(f"app-s0{n}.json", f"desktop-s0{n}", f"cmux-app-s0{n}.json")
    for condition in ("background", "foreground"):
        retarget(f"sentinel-{condition}.json", "desktop-s02", f"cmux-sentinel-{condition}.json")

    check = port / "artifacts" / "check_benchlab_cmux"
    shutil.rmtree(check, ignore_errors=True)
    check.mkdir(parents=True)
    shutil.copy2(HERE / "check_benchlab_cmux.py", check / "run.py")
    benchlab = []
    for source in sorted((port / "tasks").glob("benchlab-*.json")):
        steps = json.loads(source.read_text())
        for step in steps:
            if step.get("env_id") == "desktop-benchlab":
                step["env_id"] = "desktop-benchlab-cmux"
            if step.get("script_artifact_id") == "check_benchlab":
                step["script_artifact_id"] = "check_benchlab_cmux"
        name = f"cmux-{source.stem}"
        _write(port / "tasks" / f"{name}.json", steps)
        benchlab.append(name)

    _toml(port / "evals" / "cmux-smoke.toml", ["cmux-probe", "taskpack"])
    _toml(port / "evals" / "cmux-apps.toml", [f"cmux-app-s0{n}" for n in (2, 3, 4)])
    _toml(port / "evals" / "cmux-sentinel.toml", ["cmux-sentinel-background", "cmux-sentinel-foreground"])
    _toml(port / "evals" / "cmux-benchlab.toml", benchlab)
    unique = list(dict.fromkeys(line for line in trials if line.strip()))
    _toml(port / "evals" / "cmux-bench-v2.toml", unique)
    _toml(port / "evals" / "cmux-foreground.toml", [t for t in unique if t.endswith("-foreground")])
    _toml(port / "evals" / "cmux-background.toml", [t for t in unique if t.endswith("-background")])
    print(f"overlaid cmux onto {port}: {len(trials)} trials, {len(unique)} trial files, {len(benchlab)} BenchLab checks")


def _write(path: Path, steps: list) -> None:
    path.write_text("[\n" + ",\n".join("  " + json.dumps(step, ensure_ascii=False) for step in steps) + "\n]\n")


def _toml(path: Path, tasks: list[str]) -> None:
    path.write_text("tasks = [\n" + "".join(f'  "{t}",\n' for t in tasks) + "]\n")


if __name__ == "__main__":
    main()
