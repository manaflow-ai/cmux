#!/usr/bin/env python3
"""
Regression coverage for nushell wrapper-shim shadowing.

cmux routes ``claude`` through a per-surface shim in ``$TMPDIR/cmux-cli-shims/
<surface-id>/`` so ``cmux-claude-wrapper`` can inject session tracking and
notification hooks. The shim directory is prepended to ``PATH`` when the
terminal spawns, but a nushell user's ``env.nu`` typically re-prepends their
own directories (``~/.local/bin`` and friends) on top of the inherited
``PATH``, shadowing the shim. zsh/bash/fish recover via cmux shell
integration that re-fronts the shim after user config runs; nushell had no
integration at all, so the wrapper never ran, sessions were never captured
into ``~/.cmuxterm/claude-hook-sessions.json``, and Claude session resume
never worked.

This test drives the *actual* bundled nushell bootstrap
(``Resources/shell-integration/nushell/cmux-nushell-bootstrap.nu``) through
real ``nu``, launched the same way cmux launches it (``nu -l`` with the
squashed bootstrap; the test appends its probe where cmux's ``-e`` payload
would sit, which shares the same post-config execution point). It asserts:

1. Control: with a user ``env.nu`` that prepends a decoy ``claude`` dir, plain
   ``nu -l`` resolves the decoy (the bug bites; the sandbox is faithful).
2. With the bootstrap applied, ``which claude`` resolves to the shim again.
3. Actually running ``claude`` executes the shim, arguments intact.
4. The bootstrap normalizes a user config that left ``PATH`` a string.

It is deterministic: no PTY, no sleeps, no network. Skips loudly when ``nu``
is not installed locally, but fails when ``CI`` is set so the suite can never
silently skip on CI (see the repo pitfall about silently-skipping tests).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

REPO_ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = REPO_ROOT / "Resources/shell-integration/nushell/cmux-nushell-bootstrap.nu"

SURFACE_ID = "nushell-refront-test"


def _find_nu() -> Optional[str]:
    """Locate a nu binary: CMUX_TEST_NU_BIN override, PATH, then Homebrew paths."""
    override = os.environ.get("CMUX_TEST_NU_BIN")
    candidates = [
        override,
        shutil.which("nu"),
        "/opt/homebrew/bin/nu",
        "/usr/local/bin/nu",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _require_nu() -> Optional[str]:
    """Return a nu path, skip loudly when absent locally, fail when CI is set."""
    nu = _find_nu()
    if nu is None:
        if os.environ.get("CI"):
            raise AssertionError(
                "nushell (nu) is required on CI for this test but was not found; "
                "the CI workflow must install a pinned nushell before running it"
            )
        print("SKIP: nushell (nu) not found; install nushell to run this test")
    return nu


def _bootstrap_one_liner() -> str:
    """Squash the bootstrap exactly like the Swift spawn path does.

    The bundled file must stay join-safe: statement-per-line, comments and
    blank lines removable, the remainder joinable with '; '.
    """
    assert BOOTSTRAP.exists(), f"missing bundled nushell bootstrap: {BOOTSTRAP}"
    lines = []
    for raw in BOOTSTRAP.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        lines.append(stripped)
    one_liner = "; ".join(lines)
    assert one_liner, "bootstrap squashed to an empty command"
    assert "\n" not in one_liner
    return one_liner


def _write_executable(path: Path, contents: str) -> None:
    """Write `contents` to `path` and mark it executable."""
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _make_sandbox(tmp: Path, env_nu_body: str) -> dict:
    """Build an isolated HOME/XDG tree with a decoy claude, a shim claude, and the env cmux would spawn with."""
    home = tmp / "home"
    xdg = tmp / "xdg"
    nushell_config = xdg / "nushell"
    nushell_config.mkdir(parents=True)
    home.mkdir()

    (nushell_config / "env.nu").write_text(env_nu_body, encoding="utf-8")
    (nushell_config / "config.nu").write_text("", encoding="utf-8")

    decoy_dir = tmp / "decoy-bin"
    decoy_dir.mkdir()
    _write_executable(
        decoy_dir / "claude",
        '#!/bin/sh\nprintf \'DECOY-CLAUDE %s\\n\' "$*"\n',
    )

    shim_dir = tmp / "cmux-cli-shims" / SURFACE_ID
    shim_dir.mkdir(parents=True)
    _write_executable(
        shim_dir / "claude",
        '#!/bin/sh\nprintf \'SHIM-CLAUDE %s\\n\' "$*"\n',
    )

    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            "LC_ALL": "C",
            "LANG": "C",
            "TERM": "xterm-256color",
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(xdg),
            # cmux spawns the surface with the shim dir already first on PATH.
            "PATH": os.pathsep.join(
                [str(shim_dir), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            ),
            "CMUX_SURFACE_ID": SURFACE_ID,
        }
    )
    return {"env": env, "decoy_dir": decoy_dir, "shim_dir": shim_dir}


def _run_nu(nu: str, env: dict, script: str) -> subprocess.CompletedProcess:
    """Run `script` through `nu -l -c`, mirroring how cmux launches login nushell."""
    return subprocess.run(
        [nu, "-l", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


_DECOY_PREPEND_ENV_NU = """
$env.PATH = ($env.PATH | split row (char esep) | prepend "__DECOY_DIR__")
"""

_DECOY_PREPEND_STRING_PATH_ENV_NU = """
$env.PATH = ($env.PATH | split row (char esep) | prepend "__DECOY_DIR__" | str join (char esep))
"""


def _debug(proc: subprocess.CompletedProcess) -> str:
    """Render process output for assertion failure messages."""
    return (
        f"\nexit={proc.returncode}"
        f"\n--- nu stdout ---\n{proc.stdout}"
        f"\n--- nu stderr ---\n{proc.stderr}"
    )


def test_nushell_bootstrap_refronts_shim_over_user_path_prepends() -> None:
    nu = _require_nu()
    if nu is None:
        return
    one_liner = _bootstrap_one_liner()

    with tempfile.TemporaryDirectory(prefix="cmux-nu-refront-") as td:
        tmp = Path(td)
        sandbox = _make_sandbox(
            tmp,
            _DECOY_PREPEND_ENV_NU.replace("__DECOY_DIR__", str(tmp / "decoy-bin")),
        )
        env = sandbox["env"]
        decoy_claude = str(sandbox["decoy_dir"] / "claude")
        shim_claude = str(sandbox["shim_dir"] / "claude")

        # Control: the user prepend shadows the shim without the bootstrap.
        control = _run_nu(nu, env, "which claude | get 0.path")
        assert control.returncode == 0, "control `which claude` failed" + _debug(control)
        assert control.stdout.strip() == decoy_claude, (
            "sandbox is not faithful: expected the decoy claude to shadow the "
            f"shim without the bootstrap (got {control.stdout.strip()!r})"
            + _debug(control)
        )

        # With the bootstrap (same post-config execution point as cmux's -e
        # payload), the shim must win again.
        fixed = _run_nu(nu, env, one_liner + "; which claude | get 0.path")
        assert fixed.returncode == 0, "bootstrap run failed" + _debug(fixed)
        assert fixed.stdout.strip() == shim_claude, (
            "bootstrap did not re-front the cmux shim dir over the user's "
            f"PATH prepends (got {fixed.stdout.strip()!r})" + _debug(fixed)
        )

        # And actually running `claude` must hit the shim, args intact.
        ran = _run_nu(nu, env, one_liner + "; claude --resume 0123-fake-id")
        assert ran.returncode == 0, "running claude via bootstrap failed" + _debug(ran)
        assert "SHIM-CLAUDE --resume 0123-fake-id" in ran.stdout, (
            "running `claude` did not execute the cmux shim" + _debug(ran)
        )
        assert "DECOY-CLAUDE" not in ran.stdout, (
            "running `claude` executed the user binary instead of the shim"
            + _debug(ran)
        )


def test_nushell_bootstrap_normalizes_string_path() -> None:
    nu = _require_nu()
    if nu is None:
        return
    one_liner = _bootstrap_one_liner()

    with tempfile.TemporaryDirectory(prefix="cmux-nu-strpath-") as td:
        tmp = Path(td)
        sandbox = _make_sandbox(
            tmp,
            _DECOY_PREPEND_STRING_PATH_ENV_NU.replace(
                "__DECOY_DIR__", str(tmp / "decoy-bin")
            ),
        )
        env = sandbox["env"]
        shim_claude = str(sandbox["shim_dir"] / "claude")

        fixed = _run_nu(
            nu,
            env,
            one_liner + "; print ($env.PATH | describe); which claude | get 0.path",
        )
        assert fixed.returncode == 0, (
            "bootstrap failed on a user config that left PATH a string"
            + _debug(fixed)
        )
        stdout_lines = [line for line in fixed.stdout.splitlines() if line.strip()]
        assert stdout_lines and stdout_lines[0].startswith("list"), (
            "bootstrap must normalize a string PATH back to a list "
            f"(got type {stdout_lines[0] if stdout_lines else '<empty>'!r})"
            + _debug(fixed)
        )
        assert stdout_lines[-1] == shim_claude, (
            "bootstrap did not re-front the shim when PATH was a string"
            + _debug(fixed)
        )


def test_nushell_bootstrap_noops_outside_cmux() -> None:
    nu = _require_nu()
    if nu is None:
        return
    one_liner = _bootstrap_one_liner()

    with tempfile.TemporaryDirectory(prefix="cmux-nu-noop-") as td:
        tmp = Path(td)
        sandbox = _make_sandbox(
            tmp,
            _DECOY_PREPEND_ENV_NU.replace("__DECOY_DIR__", str(tmp / "decoy-bin")),
        )
        env = sandbox["env"]
        env.pop("CMUX_SURFACE_ID", None)
        decoy_claude = str(sandbox["decoy_dir"] / "claude")

        outside = _run_nu(nu, env, one_liner + "; which claude | get 0.path")
        assert outside.returncode == 0, (
            "bootstrap errored outside a cmux surface" + _debug(outside)
        )
        assert outside.stdout.strip() == decoy_claude, (
            "bootstrap must not reorder PATH outside a cmux surface "
            f"(got {outside.stdout.strip()!r})" + _debug(outside)
        )


if __name__ == "__main__":
    test_nushell_bootstrap_refronts_shim_over_user_path_prepends()
    test_nushell_bootstrap_normalizes_string_path()
    test_nushell_bootstrap_noops_outside_cmux()
    if _find_nu() is None:
        print("SKIP: nushell (nu) not found; nothing was verified")
    else:
        print("PASS: cmux nushell bootstrap re-fronts the CLI shim over user PATH prepends")
