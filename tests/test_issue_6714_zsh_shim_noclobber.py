#!/usr/bin/env python3
"""
Regression coverage for https://github.com/manaflow-ai/cmux/issues/6714.

When a user enables ``setopt noclobber`` in their interactive zsh, cmux's shell
integration prints a spurious error on startup:

    _cmux_install_cli_command_shim:13: file exists: \
        /var/folders/.../T//cmux-cli-shims/<surface-id>/claude

Root cause: ``Resources/shell-integration/cmux-zsh-integration.zsh`` writes a
per-surface CLI shim with a plain ``>`` redirection::

    } >"$shim_path" 2>/dev/null || return 0

``_cmux_install_cli_command_shim`` runs more than once per shell (once at source
time via the top-level ``_cmux_install_cli_wrapper claude`` call, and again on
the first prompt via the ``_cmux_fix_path`` precmd hook). The second write
targets a shim that already exists, so under ``noclobber`` zsh refuses to
overwrite the file and emits ``file exists``. The ``2>/dev/null`` does not
suppress the message because the no-clobber failure is reported by the shell's
redirection machinery on the compound-command redirect itself, and the
``|| return 0`` then *skips* the write entirely -- so the shim is also left
stale (not refreshed to the latest wrapper path).

The fix is zsh's explicit clobber redirection (``>|``) for this cmux-owned
generated file, which overwrites regardless of the user's global ``noclobber``
setting -- the same operator the rest of this integration already uses for its
own generated marker/cache files.

This test drives the *actual* integration file through real zsh with
``noclobber`` enabled and asserts that a second shim write is silent **and**
actually refreshes the shim contents. It is deterministic (no PTY, no sleeps,
no network) and locale-pinned so the assertions do not depend on zsh's message
wording.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = REPO_ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh"

# Drive the real shim writer twice under noclobber. The first call creates the
# shim; the second must overwrite the existing file (cmux owns it) without
# tripping noclobber. We embed two *different* wrapper paths so we can prove the
# second write actually refreshed the file rather than silently no-op'ing.
#
# Sourcing the integration with no CMUX_SHELL_INTEGRATION_DIR makes the
# top-level `_cmux_install_cli_wrapper claude` early-return (no shim written at
# source time), so the only writes are our two explicit calls. The precmd hooks
# the integration registers never fire under `zsh -c` (non-interactive, no
# prompt), keeping the scenario focused on the shim writer.
DRIVER = r"""
setopt noclobber
source "$CMUX_ZSH_INTEGRATION" 2>/dev/null
export TMPDIR="$CMUX_TEST_TMPDIR"
export CMUX_SURFACE_ID="$CMUX_TEST_SURFACE_ID"
_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER_A"
_cmux_install_cli_command_shim claude "$CMUX_TEST_WRAPPER_B"
"""


def _run_driver(tmp: Path) -> subprocess.CompletedProcess[str]:
    # Two distinct wrapper paths so the shim content differs between writes.
    wrapper_a = tmp / "wrapper-a"
    wrapper_b = tmp / "wrapper-b"
    wrapper_a.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    wrapper_b.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    wrapper_a.chmod(0o755)
    wrapper_b.chmod(0o755)

    # Clean env: drop ambient CMUX_* so nothing the integration reads leaks in,
    # and explicitly disable the socket/ghostty paths so sourcing stays quiet.
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            "LC_ALL": "C",
            "LANG": "C",
            "CMUX_ZSH_INTEGRATION": str(INTEGRATION),
            "CMUX_TEST_TMPDIR": str(tmp),
            "CMUX_TEST_SURFACE_ID": "issue-6714-shim",
            "CMUX_TEST_WRAPPER_A": str(wrapper_a),
            "CMUX_TEST_WRAPPER_B": str(wrapper_b),
            # Keep sourcing side-effect-free: no socket sends, no nested ghostty
            # integration.
            "CMUX_SOCKET_PATH": "",
            "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
            "GHOSTTY_RESOURCES_DIR": "",
        }
    )

    return subprocess.run(
        ["zsh", "-f", "-c", DRIVER],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_zsh_shim_refresh_is_silent_and_refreshes_under_noclobber() -> None:
    assert INTEGRATION.exists(), f"missing integration file: {INTEGRATION}"

    with tempfile.TemporaryDirectory(prefix="cmux-6714-") as td:
        tmp = Path(td)
        proc = _run_driver(tmp)
        debug = (
            f"\nexit={proc.returncode}"
            f"\n--- driver stdout ---\n{proc.stdout}"
            f"\n--- driver stderr ---\n{proc.stderr}"
        )

        # The reported symptom: zsh prints `file exists` from the shim writer
        # when it refuses to clobber the existing shim.
        assert "file exists" not in proc.stderr.lower(), (
            "cmux printed a noclobber 'file exists' error while refreshing its own "
            "generated shim" + debug
        )
        # Locale-independent guard: no error should be attributed to the shim
        # writer at all (the noclobber failure carries this function name).
        assert "_cmux_install_cli_command_shim" not in proc.stderr, (
            "the shim writer reported an error to stderr while refreshing the shim"
            + debug
        )

        shim_path = tmp / "cmux-cli-shims" / "issue-6714-shim" / "claude"
        assert shim_path.exists(), f"shim was not created at {shim_path}" + debug
        assert os.access(shim_path, os.X_OK), (
            f"shim is not executable: {shim_path}" + debug
        )

        # The second write must have actually overwritten the shim: under the
        # bug, noclobber makes the redirect fail and `|| return 0` skips the
        # write, so the shim still embeds wrapper A. With the fix it embeds B.
        contents = shim_path.read_text(encoding="utf-8")
        wrapper_b = str(tmp / "wrapper-b")
        wrapper_a = str(tmp / "wrapper-a")
        assert f'cmux_wrapper="{wrapper_b}"' in contents, (
            "cmux did not refresh its generated shim on the second write under "
            f"noclobber (expected wrapper {wrapper_b!r}).\n--- shim ---\n{contents}"
            + debug
        )
        assert f'cmux_wrapper="{wrapper_a}"' not in contents, (
            "stale wrapper path from the first write survived the refresh.\n"
            f"--- shim ---\n{contents}" + debug
        )


if __name__ == "__main__":
    test_zsh_shim_refresh_is_silent_and_refreshes_under_noclobber()
    print("PASS: cmux refreshes its zsh CLI shim silently under noclobber")
