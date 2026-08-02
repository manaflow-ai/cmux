#!/usr/bin/env python3
"""
Regression coverage for the bash half of
https://github.com/manaflow-ai/cmux/issues/6714.

The zsh half was fixed in #6815. The identical defect still exists in the bash
integration: when a user enables ``set -o noclobber`` in their interactive bash,
cmux's shell integration prints a spurious error on startup::

    cmux-bash-integration.bash: line 281: \
        /var/folders/.../T/cmux-cli-shims/<surface-id>/claude: \
        cannot overwrite existing file

Root cause: ``Resources/shell-integration/cmux-bash-integration.bash`` writes a
per-surface CLI shim with a plain ``>`` redirection::

    } >"$shim_path" 2>/dev/null || return 0

``_cmux_install_cli_command_shim`` runs more than once per shell (once at source
time via the top-level ``_cmux_install_cli_wrapper claude`` call, and again from
the ``_cmux_fix_path`` prompt hook). The second write targets a shim that
already exists, so under ``noclobber`` bash refuses to overwrite the file. The
``2>/dev/null`` does not suppress the message, because the no-clobber failure is
reported by the shell's redirection machinery on the compound-command redirect
itself rather than by anything running inside the group.

The failure is not merely cosmetic: ``|| return 0`` then *skips* the write, so
the shim is also left stale and keeps pointing at the wrapper path captured by
the first write.

The fix is bash's explicit clobber redirection (``>|``) for this cmux-owned
generated file, which overwrites regardless of the user's global ``noclobber``
setting -- the same operator the zsh integration adopted in #6815.

This test drives the *actual* integration file through real bash with
``noclobber`` enabled and asserts that a second shim write is silent **and**
actually refreshes the shim contents. It is deterministic (no PTY, no sleeps,
no network) and locale-pinned so the assertions do not depend on bash's message
wording.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = REPO_ROOT / "Resources/shell-integration/cmux-bash-integration.bash"

# Drive the real shim writer twice under noclobber. The first call creates the
# shim; the second must overwrite the existing file (cmux owns it) without
# tripping noclobber. We embed two *different* wrapper paths so we can prove the
# second write actually refreshed the file rather than silently no-op'ing.
#
# Sourcing the integration with no CMUX_SHELL_INTEGRATION_DIR makes the
# top-level `_cmux_install_cli_wrapper claude` early-return (no shim written at
# source time), so the only writes are our two explicit calls. The prompt hooks
# the integration registers never fire under `bash -c` (non-interactive, no
# prompt), keeping the scenario focused on the shim writer.
#
# Sourcing is deliberately *not* stderr-suppressed: with the clean environment
# below the integration sources silently, so any initialization noise is a real
# signal and must fail the test rather than hide behind `2>/dev/null`. The
# explicit `declare -F` guard then fails loudly (exit 90) if the shim writer is
# missing, so a broken driver can never look like a passing scenario.
DRIVER = r"""
set -o noclobber
if ! source "$CMUX_BASH_INTEGRATION"; then
    printf '%s\n' 'driver: sourcing the integration returned non-zero' >&2
    exit 91
fi
if ! declare -F _cmux_install_cli_command_shim >/dev/null 2>&1; then
    printf '%s\n' 'driver: _cmux_install_cli_command_shim undefined after sourcing' >&2
    exit 90
fi
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
    # and explicitly disable the socket path so sourcing stays quiet.
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
    env.update(
        {
            "LC_ALL": "C",
            "LANG": "C",
            "CMUX_BASH_INTEGRATION": str(INTEGRATION),
            "CMUX_TEST_TMPDIR": str(tmp),
            "CMUX_TEST_SURFACE_ID": "issue-6714-bash-shim",
            "CMUX_TEST_WRAPPER_A": str(wrapper_a),
            "CMUX_TEST_WRAPPER_B": str(wrapper_b),
            # Keep sourcing side-effect-free: no socket sends.
            "CMUX_SOCKET_PATH": "",
        }
    )

    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-c", DRIVER],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_bash_shim_refresh_is_silent_and_refreshes_under_noclobber() -> None:
    assert INTEGRATION.exists(), f"missing integration file: {INTEGRATION}"

    with tempfile.TemporaryDirectory(prefix="cmux-6714-bash-") as td:
        tmp = Path(td)
        proc = _run_driver(tmp)
        debug = (
            f"\nexit={proc.returncode}"
            f"\n--- driver stdout ---\n{proc.stdout}"
            f"\n--- driver stderr ---\n{proc.stderr}"
        )

        # Fail fast on a broken driver: a non-zero exit means sourcing or the
        # `declare -F` precondition failed, so nothing below would be testing
        # the scenario we think it is.
        assert proc.returncode == 0, (
            "driver did not complete cleanly; the noclobber scenario never ran"
            + debug
        )

        # The reported symptom: bash refuses to clobber the existing shim and
        # prints `cannot overwrite existing file` from the shim writer.
        assert "cannot overwrite" not in proc.stderr.lower(), (
            "cmux printed a noclobber 'cannot overwrite existing file' error while "
            "refreshing its own generated shim" + debug
        )
        # Locale-independent guard: no error should be attributed to the
        # integration file at all (the noclobber failure carries its path).
        assert "cmux-bash-integration.bash" not in proc.stderr, (
            "the bash integration reported an error to stderr while refreshing the "
            "shim" + debug
        )

        shim_path = tmp / "cmux-cli-shims" / "issue-6714-bash-shim" / "claude"
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
    test_bash_shim_refresh_is_silent_and_refreshes_under_noclobber()
    print("PASS: cmux refreshes its bash CLI shim silently under noclobber")
