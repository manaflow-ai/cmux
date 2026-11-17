#!/usr/bin/env python3
"""Time from Connect to a linked row in Settings > Agents > Your other apps.

A Connect click runs `cmux agent hook install link-<app>` and the card then reads
`cmux agent hook status` (webviews/src/pages/settings/store.ts); the row reads Connected once
that status says `installed`. This harness does the same two calls in a scratch home where
Claude desktop and Codex look installed, and times each round until the row is linked, then
Disconnect. It never touches the real home.

  desktop-link-connect.py --bin PATH/TO/cmux [--runs 20] [--apps claude-desktop,codex]

Prints one line per sample and one summary line per (app, step):

  DESKTOP-LINK sample app=A step=connect|status|linked|disconnect ms=M
  DESKTOP-LINK row app=A step=S n=N p50_ms=X p95_ms=Y
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(bin_path: str, env: dict[str, str], *args: str) -> tuple[float, dict]:
    start = time.perf_counter()
    out = subprocess.run([bin_path, "--json", "agent", "hook", *args], env=env, text=True,
                         capture_output=True, timeout=60)
    ms = (time.perf_counter() - start) * 1000
    try:
        value = json.loads(out.stdout or "{}")
    except json.JSONDecodeError:
        value = {}
    if out.returncode != 0 and not value:
        sys.exit(f"cmux agent hook {' '.join(args)} failed ({out.returncode}): {out.stderr.strip()[-400:]}")
    return ms, value


def row_state(value: dict, app: str) -> str | None:
    # The CLI's --json answer, possibly under `result` or `details`.
    for holder in (value, value.get("result") or {}, value.get("details") or {}):
        for row in holder.get("providers") or []:
            if row.get("provider") == f"link-{app}" or row.get("id") == f"link-{app}":
                return row.get("state")
    return None


def scratch_home(root: Path) -> dict[str, str]:
    home = root / "home"
    (home / ".codex").mkdir(parents=True)
    # Claude desktop's folder: Application Support on macOS, the XDG config folder elsewhere.
    if sys.platform == "darwin":
        (home / "Library" / "Application Support" / "Claude").mkdir(parents=True)
    else:
        (home / ".config" / "Claude").mkdir(parents=True)
    env = {k: v for k, v in os.environ.items()
           if k not in ("XDG_CONFIG_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "ACPMUX_SESSION_ID")}
    env.update({"HOME": str(home), "ACPMUX_HOME": str(home / ".acpmux")})
    return env


def pct(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--apps", default="claude-desktop,codex")
    opts = parser.parse_args()
    samples: dict[tuple[str, str], list[float]] = {}
    with tempfile.TemporaryDirectory(prefix="desktop-link-bench-") as root:
        env = scratch_home(Path(root))
        _, value = run(opts.bin, env, "status")
        for app in opts.apps.split(","):
            if row_state(value, app) is None:
                sys.exit(f"link-{app}: no row in agent hook status in the scratch home: {json.dumps(value)[:400]}")
        for _ in range(opts.runs):
            for app in opts.apps.split(","):
                connect, _ = run(opts.bin, env, "install", f"link-{app}")
                status, value = run(opts.bin, env, "status")
                if row_state(value, app) != "installed":
                    sys.exit(f"link-{app}: not installed after Connect: {row_state(value, app)}")
                disconnect, _ = run(opts.bin, env, "uninstall", f"link-{app}")
                for step, ms in (("connect", connect), ("status", status), ("linked", connect + status),
                                 ("disconnect", disconnect)):
                    samples.setdefault((app, step), []).append(ms)
                    print(f"DESKTOP-LINK sample app={app} step={step} ms={ms:.1f}")
    for (app, step), values in samples.items():
        print(f"DESKTOP-LINK row app={app} step={step} n={len(values)} "
              f"p50_ms={statistics.median(values):.1f} p95_ms={pct(values, 0.95):.1f}")


if __name__ == "__main__":
    main()
