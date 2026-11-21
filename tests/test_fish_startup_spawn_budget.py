#!/usr/bin/env python3
"""Regression: fish shell integration keeps startup and first-prompt spawns bounded.

Two hot paths slowed down every new cmux fish terminal before the first prompt:

1. `_cmux_private_dirs` spawned `/usr/bin/find` two or three times for every
   ancestor of each checked directory (and again for the resolved realpath
   chain), plus `realpath` per directory. On macOS, one `/usr/bin/stat` per
   directory (with fish's builtin `path resolve` when available) now covers the
   directory and all of its ancestors with a fixed spawn count independent of
   path depth. Non-Darwin hosts keep the `find` fallback, and both paths must
   agree on every security case.
2. `_cmux_tmux_publish_cmux_environment` spawned one `tmux set-environment`
   process per `CMUX_*` variable (~20+ sequential spawns) on the first prompt
   whenever a default tmux server socket existed. It now batches all
   `set-environment -g` / `-gu` commands into a single `tmux` invocation.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FISH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "fish" / "config.fish"
SPAWNED = (
    "/usr/bin/find",
    "/usr/bin/stat",
    "/usr/bin/realpath",
    "/bin/realpath",
    "/usr/bin/readlink",
)
SURFACE_ID = "11111111-1111-1111-1111-111111111111"


def find_fish() -> str:
    fish = shutil.which("fish")
    if fish is not None and os.access(fish, os.X_OK):
        return fish
    if os.environ.get("GITHUB_ACTIONS") == "true":
        raise RuntimeError("fish is required for the fish startup spawn budget regression")
    print("SKIP: fish is not installed")
    raise SystemExit(0)


def base_env(home: Path, tmpdir: Path, integration_dir: Path) -> dict[str, str]:
    return {
        "CMUX_FISH_USER_CONFIG_ALREADY_LOADED": "1",
        "CMUX_NO_GIT_WATCH": "1",
        "CMUX_NO_PR_WATCH": "1",
        "CMUX_SHELL_INTEGRATION": "1",
        "CMUX_SHELL_INTEGRATION_DIR": str(integration_dir),
        "CMUX_SURFACE_ID": SURFACE_ID,
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
        "TMPDIR": str(tmpdir),
    }


def make_fake_bundle(root: Path) -> Path:
    integration_dir = root / "bundle" / "shell-integration"
    integration_dir.mkdir(parents=True)
    wrapper = root / "bundle" / "bin" / "cmux-claude-wrapper"
    wrapper.parent.mkdir()
    wrapper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    wrapper.chmod(0o755)
    return integration_dir


def run_fish(fish: str, script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [fish, "--no-config", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def spawns_while_sourcing(fish: str, depth: int, root: Path) -> tuple[int, str]:
    case = root / f"depth-{depth}"
    home = case.joinpath(*[f"d{index}" for index in range(depth)], "home")
    home.mkdir(parents=True)
    tmpdir = case / "tmp"
    tmpdir.mkdir()
    tmpdir.chmod(0o1777)
    env = base_env(home, tmpdir, make_fake_bundle(case))
    script = (
        "set -g fish_trace 1\n"
        f'source "{FISH_INTEGRATION}"\n'
        "set -e fish_trace\n"
        'printf "ROOT=%s\\n" "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"\n'
    )
    result = run_fish(fish, script, env)
    if result.returncode != 0:
        raise AssertionError(f"fish exited {result.returncode}: {result.stderr[-2000:]}")
    expected_root = f"{home}/.cmuxterm/cmux-cli-shims/{SURFACE_ID}"
    if f"ROOT={expected_root}" not in result.stdout:
        raise AssertionError(
            f"fish did not accept shim root under depth-{depth} HOME:\n{result.stdout}"
        )
    hits: list[str] = []
    for line in result.stderr.splitlines():
        stripped = line.lstrip("-")
        if not stripped.startswith("> "):
            continue
        body = stripped[2:].lstrip()
        command = body.split(" ", 1)[0]
        if command in SPAWNED:
            hits.append(body[:160])
    return len(hits), "\n  ".join(hits[:12])


def check_private_dir_spawn_budget(fish: str, root: Path) -> list[str]:
    root.mkdir()
    if not sys.platform.startswith("darwin"):
        return []
    shallow, _ = spawns_while_sourcing(fish, 1, root)
    deep, sample = spawns_while_sourcing(fish, 12, root)
    failures: list[str] = []
    if shallow == 0:
        failures.append("fish: trace captured 0 path checks (fish_trace parser did not match)")
    if deep != shallow:
        failures.append(
            f"fish: sourcing started {shallow} path checks under a 1-level HOME and {deep} "
            f"under a 12-level one; the count must not grow with depth:\n  {sample}"
        )
    # Three shim dirs (~/.cmuxterm, cmux-cli-shims, <surface>), at most one stat each
    # (and one realpath fallback on fish <3.5).
    if deep > 6:
        failures.append(
            f"fish: sourcing started {deep} path checks (budget 6):\n  {sample}"
        )
    return failures


RULE_CASES_SCRIPT = r"""
function check --argument-names label
    set -e argv[1]
    if _cmux_private_dirs $argv
        printf '%s accept\n' "$label"
    else
        printf '%s reject\n' "$label"
    end
end
check private 0 "$R/private"
check private-canonical 0 "$R_REAL/private"
check group-writable 0 "$R/group"
check other-writable 0 "$R/other"
check group-writable-low-bits 0 "$R/group-low"
check other-writable-low-bits 0 "$R/other-low"
check sticky-self 0 "$R/sticky-self"
check symlink 0 "$R/link"
check under-open-parent 0 "$R/open/child"
check under-sticky-parent 0 "$R/sticky/child"
check under-symlinked-parent 0 "$R/via/child"
check symlink-into-open-parent 0 "$R/via-open/child"
check missing 0 "$R/missing"
check created 1 "$R/created"
check relative 0 "relative/dir"
check file 0 "$R/file"
check unsearchable 0 "$R/unsearchable"
check newline-component 0 "$R/nl"\n"/child"
"""

EXPECTED_RULES = {
    "private": "accept",
    "private-canonical": "accept",
    "group-writable": "reject",
    "other-writable": "reject",
    "group-writable-low-bits": "reject",
    "other-writable-low-bits": "reject",
    "sticky-self": "reject",
    "symlink": "reject",
    "under-open-parent": "reject",
    "under-sticky-parent": "accept",
    "under-symlinked-parent": "accept",
    "symlink-into-open-parent": "reject",
    "missing": "reject",
    "created": "accept",
    "relative": "reject",
    "file": "reject",
    "unsearchable": "reject",
    "newline-component": "reject",
}


def check_private_dir_rules(fish: str, root: Path) -> list[str]:
    failures: list[str] = []
    for variant, ostype in (("native", ""), ("find-fallback", "linux-gnu")):
        case_dir = root / variant
        case_dir.mkdir(parents=True)
        # Ensure the case root itself is private so ancestor checks pass for valid leaves.
        case_dir.chmod(0o700)
        home = case_dir / "home"
        home.mkdir(mode=0o700)
        tmpdir = case_dir / "tmp"
        tmpdir.mkdir()
        tmpdir.chmod(0o1777)

        r = case_dir / "cases"
        r.mkdir(mode=0o700)
        (r / "private").mkdir(mode=0o700)
        (r / "group").mkdir()
        (r / "group").chmod(0o770)
        (r / "other").mkdir()
        (r / "other").chmod(0o707)
        (r / "group-low").mkdir()
        (r / "group-low").chmod(0o020)
        (r / "other-low").mkdir()
        (r / "other-low").chmod(0o002)
        (r / "sticky-self").mkdir()
        (r / "sticky-self").chmod(0o1777)
        os.symlink(r / "private", r / "link")

        open_parent = r / "open"
        open_parent.mkdir()
        (open_parent / "child").mkdir(mode=0o700)
        open_parent.chmod(0o777)

        sticky_parent = r / "sticky"
        sticky_parent.mkdir()
        (sticky_parent / "child").mkdir(mode=0o700)
        sticky_parent.chmod(0o1777)

        real_parent = r / "real-parent"
        real_parent.mkdir(mode=0o700)
        (real_parent / "child").mkdir(mode=0o700)
        os.symlink(real_parent, r / "via")
        os.symlink(open_parent, r / "via-open")

        (r / "file").write_text("x", encoding="utf-8")

        unsearchable = r / "unsearchable"
        unsearchable.mkdir()
        unsearchable.chmod(0o600)

        nl_parent = r / "nl\n"
        nl_parent.mkdir(mode=0o700)
        (nl_parent / "child").mkdir(mode=0o700)

        try:
            env = base_env(home, tmpdir, make_fake_bundle(case_dir))
            env["R"] = str(r)
            env["R_REAL"] = os.path.realpath(r)
            if ostype:
                env["OSTYPE"] = ostype
            else:
                env.pop("OSTYPE", None)
            script = f'source "{FISH_INTEGRATION}"\n{RULE_CASES_SCRIPT}\n'
            result = run_fish(fish, script, env)
            if result.returncode != 0:
                failures.append(f"{variant}: fish exited {result.returncode}: {result.stderr[-1000:]}")
                continue
            actual: dict[str, str] = {}
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) == 2:
                    actual[parts[0]] = parts[1]
            for name, expected in EXPECTED_RULES.items():
                got = actual.get(name)
                if got != expected:
                    failures.append(f"{variant}: {name} gave {got!r}, expected {expected!r}")
        finally:
            for p in (
                unsearchable,
                r / "group-low",
                r / "other-low",
                open_parent,
                sticky_parent,
            ):
                try:
                    p.chmod(0o700)
                except OSError:
                    pass
    return failures


def check_tmux_publish_is_batched(fish: str, root: Path) -> list[str]:
    root.mkdir()
    failures: list[str] = []

    home = root / "home"
    home.mkdir(mode=0o700)
    tmpdir = root / "tmp"
    tmpdir.mkdir()
    tmpdir.chmod(0o1777)
    tmux_tmpdir = root / "tmux-tmp"
    sock_dir = tmux_tmpdir / f"tmux-{os.getuid()}"
    sock_dir.mkdir(parents=True)
    log_path = root / "tmux.log"

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_dir / "default"))
    try:
        env = base_env(home, tmpdir, make_fake_bundle(root))
        env.update(
            {
                "CMUX_BUNDLE_ID": "com.cmuxterm.app",
                "CMUX_HISTORY_FILE": "/tmp/history-surface",
                "CMUX_PANEL_ID": "panel-1",
                "CMUX_SOCKET_CAPABILITY": "secret-cap-must-not-publish",
                "CMUX_SOCKET_PATH": "/tmp/cmux.sock",
                "CMUX_TAB_ID": "tab-1",
                "CMUX_TEST_TMUX_LOG": str(log_path),
                "CMUX_WORKSPACE_ID": "workspace-1",
                "TMUX_TMPDIR": str(tmux_tmpdir),
            }
        )
        script = f"""
source "{FISH_INTEGRATION}"
function tmux
    string join ' ' -- $argv >> "$CMUX_TEST_TMUX_LOG"
end
_cmux_tmux_publish_cmux_environment
_cmux_tmux_publish_cmux_environment
"""
        result = run_fish(fish, script, env)
        if result.returncode != 0:
            return [f"tmux-batch: fish exited {result.returncode}: {result.stderr[-1000:]}"]
    finally:
        server.close()

    lines = [line for line in log_path.read_text(encoding="utf-8").splitlines() if line]
    if len(lines) != 1:
        failures.append(
            f"tmux-batch: expected 1 batched tmux invocation, got {len(lines)}:\n  "
            + "\n  ".join(lines[:10])
        )
    else:
        invocation = lines[0]
        for expected in (
            "set-environment -g CMUX_BUNDLE_ID com.cmuxterm.app",
            "set-environment -g CMUX_SHELL_INTEGRATION 1",
            "set-environment -g CMUX_SOCKET_PATH /tmp/cmux.sock",
            "set-environment -g CMUX_TAB_ID tab-1",
            "set-environment -g CMUX_WORKSPACE_ID workspace-1",
            "set-environment -gu CMUX_HISTORY_FILE",
            "set-environment -gu CMUX_PANEL_ID",
            "set-environment -gu CMUX_SURFACE_ID",
        ):
            if expected not in invocation:
                failures.append(f"tmux-batch: missing {expected!r} in:\n  {invocation}")
        if "CMUX_SOCKET_CAPABILITY" in invocation:
            failures.append(f"tmux-batch: leaked CMUX_SOCKET_CAPABILITY in:\n  {invocation}")

    # Live tmux round-trip when tmux is installed.
    tmux_bin = shutil.which("tmux")
    if tmux_bin is not None:
        live_tmpdir = root / "tmux-live"
        live_tmpdir.mkdir()
        live_env = dict(os.environ, TMUX_TMPDIR=str(live_tmpdir))
        started = subprocess.run(
            [tmux_bin, "new-session", "-d", "-s", "cmux-fish-batch-test"],
            env=live_env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if started.returncode == 0:
            try:
                # Seed a surface-scoped key to confirm the batched -gu removes it.
                subprocess.run(
                    [tmux_bin, "set-environment", "-g", "CMUX_PANEL_ID", "stale-panel"],
                    env=live_env,
                    check=True,
                    timeout=10,
                )
                fish_env = base_env(home, tmpdir, make_fake_bundle(root / "live"))
                fish_env.update(
                    {
                        "CMUX_BUNDLE_ID": "com.cmuxterm.app",
                        "CMUX_PANEL_ID": "panel-live",
                        "CMUX_WORKSPACE_ID": "ws-live-42",
                        "PATH": f"{Path(tmux_bin).parent}:/usr/bin:/bin",
                        "TMUX_TMPDIR": str(live_tmpdir),
                    }
                )
                script = f'source "{FISH_INTEGRATION}"\n_cmux_tmux_publish_cmux_environment\n'
                res = run_fish(fish, script, fish_env)
                if res.returncode != 0:
                    failures.append(f"tmux-live: fish exited {res.returncode}: {res.stderr}")
                else:
                    shown = subprocess.run(
                        [tmux_bin, "show-environment", "-g"],
                        env=live_env,
                        capture_output=True,
                        text=True,
                        timeout=10,
                        check=True,
                    ).stdout
                    if "CMUX_WORKSPACE_ID=ws-live-42" not in shown:
                        failures.append(f"tmux-live: CMUX_WORKSPACE_ID not published:\n{shown}")
                    if "CMUX_PANEL_ID=" in shown:
                        failures.append(f"tmux-live: CMUX_PANEL_ID was not unset:\n{shown}")
            finally:
                subprocess.run(
                    [tmux_bin, "kill-server"],
                    env=live_env,
                    capture_output=True,
                    timeout=10,
                    check=False,
                )

    return failures


def main() -> int:
    fish = find_fish()
    previous_umask = os.umask(0o022)
    try:
        # Keep TemporaryDirectory under /tmp (sticky 1777) so parent ancestry is predictable.
        with tempfile.TemporaryDirectory(prefix="cmux-fish-budget-", dir="/tmp") as temp:
            base = Path(temp)
            base.chmod(0o700)
            failures: list[str] = []
            failures.extend(check_private_dir_spawn_budget(fish, base / "budget"))
            failures.extend(check_private_dir_rules(fish, base / "rules"))
            failures.extend(check_tmux_publish_is_batched(fish, base / "tmux"))
    finally:
        os.umask(previous_umask)

    if failures:
        print("FAIL:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("PASS: fish private-dir checks use bounded spawns, match find rules, and batch tmux publish")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
