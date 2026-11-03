#!/usr/bin/env python3
"""Regression: the bash integration's private-directory checks start a fixed
number of processes, however deep the folder is.

https://github.com/manaflow-ai/cmux/issues/33072: `_cmux_private_dirs` started
`/usr/bin/find` two or three times for every parent folder, and again for the
realpath chain, so sourcing the integration from the first prompt took about a
second on some Macs. On macOS one `realpath` and one `/usr/bin/stat` now cover a
folder and all of its parents.

Other systems (the integration also runs on remote Linux hosts) keep the `find`
checks. Both paths must give the same answers, so each case runs twice: with
the shell's own OSTYPE and with OSTYPE set to linux-gnu.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASH_INTEGRATION = ROOT / "Resources" / "shell-integration" / "cmux-bash-integration.bash"
SPAWNED = ("/usr/bin/find", "/usr/bin/stat", "/usr/bin/realpath", "/bin/realpath", "/usr/bin/readlink")


def bashes() -> list[str]:
    # macOS ships bash 3.2 as /bin/bash; also cover a newer bash when present.
    return list(dict.fromkeys(filter(None, ["/bin/bash", shutil.which("bash")])))


def environment(home: Path, tmpdir: Path, integration_dir: Path) -> dict[str, str]:
    return {
        "CMUX_NO_GIT_WATCH": "1",
        "CMUX_NO_PR_WATCH": "1",
        "CMUX_SHELL_INTEGRATION": "1",
        "CMUX_SHELL_INTEGRATION_DIR": str(integration_dir),
        "CMUX_SURFACE_ID": "11111111-1111-1111-1111-111111111111",
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
        "TMPDIR": str(tmpdir),
    }


def bundle(root: Path) -> Path:
    """An app-like layout, so sourcing also installs the claude shim."""
    integration_dir = root / "bundle" / "shell-integration"
    integration_dir.mkdir(parents=True)
    wrapper = root / "bundle" / "bin" / "cmux-claude-wrapper"
    wrapper.parent.mkdir()
    wrapper.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    wrapper.chmod(0o755)
    return integration_dir


def run(bash: str, script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [bash, "--noprofile", "--norc", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def spawns_while_sourcing(bash: str, depth: int, root: Path) -> tuple[int, str]:
    case = root / f"depth-{depth}"
    tmpdir = case.joinpath(*[f"d{index}" for index in range(depth)])
    tmpdir.mkdir(parents=True)
    home = case / "home"
    home.mkdir()
    env = environment(home, tmpdir, bundle(case))
    script = f'PS4="+ "\nset -x\nsource "{BASH_INTEGRATION}"\nset +x\nprintf "STATE=%s\\n" "$_CMUX_BASH_STATE_DIR"\n'
    result = run(bash, script, env)
    if result.returncode != 0:
        raise AssertionError(f"{bash} exited {result.returncode}: {result.stderr[-2000:]}")
    if f"STATE={tmpdir}/cmux-bash-{os.geteuid()}" not in result.stdout:
        raise AssertionError(f"{bash}: state dir under {tmpdir} was not accepted:\n{result.stdout}")
    hits = []
    for line in result.stderr.splitlines():
        body = line.lstrip("+").lstrip()
        if body.split(" ", 1)[0] in SPAWNED:
            hits.append(body[:160])
    return len(hits), "\n  ".join(hits[:12])


def check_spawn_budget(bash: str, root: Path) -> list[str]:
    root.mkdir()
    if not sys.platform.startswith("darwin"):
        return []
    shallow, _ = spawns_while_sourcing(bash, 1, root)
    deep, sample = spawns_while_sourcing(bash, 12, root)
    failures = []
    if deep != shallow:
        failures.append(
            f"{bash}: sourcing started {shallow} checks under a 1-level TMPDIR and {deep} "
            f"under a 12-level one; the count must not grow with depth:\n  {sample}"
        )
    # The state dir plus the three shim dirs, one realpath and one stat each.
    if deep > 8:
        failures.append(f"{bash}: sourcing started {deep} checks (budget 8):\n  {sample}")
    return failures


CASES = """
check() { if _cmux_private_dirs "$@"; then printf '%s accept\\n' "$label"; else printf '%s reject\\n' "$label"; fi; }
label=private; check 0 "$R/private"
label=group-writable; check 0 "$R/group"
label=other-writable; check 0 "$R/other"
label=symlink; check 0 "$R/link"
label=under-open-parent; check 0 "$R/open/child"
label=under-sticky-parent; check 0 "$R/sticky/child"
label=under-symlinked-parent; check 0 "$R/via/child"
label=symlink-into-open-parent; check 0 "$R/via-open/child"
label=missing; check 0 "$R/missing"
label=created; check 1 "$R/created"
label=relative; check 0 "relative/dir"
label=file; check 0 "$R/file"
"""

EXPECTED = {
    "private": "accept",
    "group-writable": "reject",
    "other-writable": "reject",
    "symlink": "reject",
    "under-open-parent": "reject",
    "under-sticky-parent": "accept",
    "under-symlinked-parent": "accept",
    "symlink-into-open-parent": "reject",
    "missing": "reject",
    "created": "accept",
    "relative": "reject",
    "file": "reject",
}


def make_cases(base: Path) -> Path:
    base.mkdir(mode=0o700)
    for name, mode in (("private", 0o700), ("group", 0o770), ("other", 0o702)):
        (base / name).mkdir()
        (base / name).chmod(mode)
    (base / "link").symlink_to(base / "private")
    for name, mode in (("open", 0o777), ("sticky", 0o1777)):
        (base / name).mkdir()
        (base / name).chmod(mode)
        (base / name / "child").mkdir(mode=0o700)
    target = base / "target"
    target.mkdir(mode=0o700)
    (target / "child").mkdir(mode=0o700)
    (base / "via").symlink_to(target)
    (base / "via-open").symlink_to(base / "open")
    (base / "file").write_text("x", encoding="utf-8")
    return base


def check_rules(bash: str, root: Path, ostype: str | None) -> list[str]:
    label = ostype or "native"
    base = make_cases(root / f"rules-{label}")
    home = base / "home"
    home.mkdir()
    env = environment(home, root, root / "no-bundle" / "shell-integration")
    set_ostype = f"OSTYPE={ostype}\n" if ostype else ""
    script = f'{set_ostype}source "{BASH_INTEGRATION}"\nR="{base}"\n{CASES}'
    result = run(bash, script, env)
    if result.returncode != 0:
        return [f"{bash} ({label}) exited {result.returncode}: {result.stderr[-2000:]}"]
    seen = dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)
    failures = []
    for case, expected in EXPECTED.items():
        if seen.get(case) != expected:
            failures.append(f"{bash} ({label}): {case} gave {seen.get(case)!r}, expected {expected}")
    created = base / "created"
    if not created.is_dir() or (created.stat().st_mode & 0o7777) != 0o700:
        failures.append(f"{bash} ({label}): created dir missing or not 0700")
    return failures


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-private-dirs-", dir="/tmp") as temp:
        root = Path(temp)
        previous_umask = os.umask(0o022)
        try:
            for index, bash in enumerate(bashes()):
                shell_root = root / f"bash-{index}"
                shell_root.mkdir()
                failures += check_rules(bash, shell_root, None)
                failures += check_rules(bash, shell_root, "linux-gnu")
                failures += check_spawn_budget(bash, shell_root / "budget")
        finally:
            os.umask(previous_umask)
    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: bash private-dir checks keep their rules and start a fixed number of processes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
