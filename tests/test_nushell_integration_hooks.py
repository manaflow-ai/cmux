#!/usr/bin/env python3
"""
Behavior coverage for the cmux nushell shell integration
(``Resources/shell-integration/nushell/cmux-nushell-integration.nu``).

The integration brings nushell to fish parity (see
``Resources/shell-integration/fish/config.fish``): socket reporting of tty,
shell activity state (running/prompt), pwd changes, and port-scan kicks,
driven from nushell ``pre_execution`` / ``pre_prompt`` hooks. This test
sources the *actual* bundled integration file in real ``nu``, simulates the
hook entry points, and asserts the exact payloads cmux's app side consumes
(``report_tty`` / ``report_shell_state`` / ``report_pwd`` / ``ports_kick``,
same wire format as the fish integration) arrive on a fake unix socket.

Covered:

1. Hook registration: sourcing appends cmux entries to
   ``$env.config.hooks.pre_prompt`` and ``pre_execution``.
2. ``report_tty`` is sent once (deduped), honoring a preset ``_CMUX_TTY_NAME``
   (subprocesses have no tty; the preset mirrors the zsh/fish globals).
3. ``report_shell_state running`` then ``prompt``, deduped across repeated
   prompts.
4. ``report_pwd`` fires on first prompt and again only after ``cd``.
5. ``ports_kick --reason=command`` fires from pre-execution.
6. The keyboard-protocol reset escape is emitted under
   ``CMUX_TEST_FORCE_KEYBOARD_RESET`` (same test knob as fish/zsh).
7. The integration stays silent on stderr and exits 0.

``CMUX_TEST_SYNC_SEND=1`` makes sends synchronous (the interactive path uses
``job spawn`` background sends, which nushell kills at shell exit — real
prompts outlive them, a ``-c`` script does not).

Deterministic: no PTY, no network beyond the local unix socket, no sleeps in
the shell. Skips loudly without ``nu`` locally; fails when ``CI`` is set so
CI can never silently skip.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import List, Optional

REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = (
    REPO_ROOT / "Resources/shell-integration/nushell/cmux-nushell-integration.nu"
)

TAB_ID = "tab-nu-hooks"
PANEL_ID = "panel-nu-hooks"
TTY_NAME = "ttys042"


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


class _SocketCollector:
    """Accepts unix-socket connections and collects newline-terminated lines."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines: List[str] = []
        self._lock = threading.Lock()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(str(path))
        self._server.listen(16)
        self._server.settimeout(0.2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                conn.settimeout(2)
                chunks = []
                try:
                    while True:
                        data = conn.recv(4096)
                        if not data:
                            break
                        chunks.append(data)
                except socket.timeout:
                    pass
            text = b"".join(chunks).decode("utf-8", errors="replace")
            with self._lock:
                for line in text.splitlines():
                    if line.strip():
                        self.lines.append(line.strip())

    def stop(self) -> List[str]:
        self._stop.set()
        self._thread.join(timeout=5)
        self._server.close()
        with self._lock:
            return list(self.lines)


def _short_tmpdir() -> str:
    """Create a short-prefix temp dir under /tmp (AF_UNIX socket paths are length-limited)."""
    return tempfile.mkdtemp(prefix="cmux-nu-", dir="/tmp")


def _debug(proc: subprocess.CompletedProcess, lines: List[str]) -> str:
    """Render process (and socket) state for assertion failure messages."""
    return (
        f"\nexit={proc.returncode}"
        f"\n--- nu stdout ---\n{proc.stdout}"
        f"\n--- nu stderr ---\n{proc.stderr}"
        f"\n--- socket lines ---\n" + "\n".join(lines)
    )


def test_nushell_integration_hook_reports() -> None:
    nu = _require_nu()
    if nu is None:
        return
    assert INTEGRATION.exists(), f"missing bundled nushell integration: {INTEGRATION}"

    td = _short_tmpdir()
    try:
        # Resolve /tmp's /private/tmp symlink so payload assertions match
        # nushell's resolved $env.PWD.
        tmp = Path(td).resolve()
        sock_path = tmp / "cmux.sock"
        collector = _SocketCollector(sock_path)

        home = tmp / "home"
        other_dir = tmp / "elsewhere"
        home.mkdir()
        other_dir.mkdir()

        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CMUX")
        }
        env.update(
            {
                "LC_ALL": "C",
                "LANG": "C",
                "TERM": "xterm-256color",
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": str(sock_path),
                "CMUX_TAB_ID": TAB_ID,
                "CMUX_PANEL_ID": PANEL_ID,
                "CMUX_SURFACE_ID": "surface-nu-hooks",
                "CMUX_TEST_SYNC_SEND": "1",
                # Subprocesses have no tty; preset the name like the zsh/fish
                # integrations' globals allow.
                "_CMUX_TTY_NAME": TTY_NAME,
            }
        )

        script = "; ".join(
            [
                f'source "{INTEGRATION}"',
                "_cmux_pre_execution",
                "_cmux_pre_prompt",
                "_cmux_pre_prompt",
                f'cd "{other_dir}"',
                "_cmux_pre_prompt",
                "print ($env.config.hooks.pre_prompt | length)",
                "print ($env.config.hooks.pre_execution | length)",
            ]
        )
        proc = subprocess.run(
            [nu, "-n", "-c", script],
            env=env,
            cwd=str(home),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        lines = collector.stop()
        debug = _debug(proc, lines)

        assert proc.returncode == 0, "integration errored" + debug
        assert proc.stderr.strip() == "", (
            "integration must stay silent on stderr" + debug
        )

        hook_lengths = [line for line in proc.stdout.splitlines() if line.strip()]
        assert len(hook_lengths) >= 2, "hook length probes missing" + debug
        assert int(hook_lengths[-2]) >= 1, "pre_prompt hook not registered" + debug
        assert int(hook_lengths[-1]) >= 1, "pre_execution hook not registered" + debug

        suffix = f"--tab={TAB_ID} --panel={PANEL_ID}"
        expected_once = [
            f"report_tty {TTY_NAME} {suffix}",
            f"report_shell_state running {suffix}",
            f"report_shell_state prompt {suffix}",
            f'report_pwd "{home}" {suffix}',
            f'report_pwd "{other_dir}" {suffix}',
        ]
        for payload in expected_once:
            count = lines.count(payload)
            assert count == 1, (
                f"expected exactly one {payload!r}, saw {count}" + debug
            )

        kick = f"ports_kick {suffix} --reason=command"
        assert lines.count(kick) == 1, (
            f"expected exactly one {kick!r} from pre-execution" + debug
        )

        for line in lines:
            assert line.startswith(
                ("report_tty ", "report_shell_state ", "report_pwd ", "ports_kick ")
            ), f"unexpected socket payload {line!r}" + debug
    finally:
        shutil.rmtree(td, ignore_errors=True)


def test_nushell_integration_background_sends_deliver() -> None:
    """Without CMUX_TEST_SYNC_SEND, reports go through `job spawn` — the
    spawned job must still resolve the sourced `_cmux_send` def and deliver.
    (The interactive path always uses background sends, so this cannot be
    covered only by the sync-mode test above.)"""
    nu = _require_nu()
    if nu is None:
        return
    assert INTEGRATION.exists(), f"missing bundled nushell integration: {INTEGRATION}"

    td = _short_tmpdir()
    try:
        tmp = Path(td).resolve()
        sock_path = tmp / "cmux.sock"
        collector = _SocketCollector(sock_path)
        home = tmp / "home"
        home.mkdir()

        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CMUX")
        }
        env.update(
            {
                "LC_ALL": "C",
                "LANG": "C",
                "TERM": "xterm-256color",
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_SOCKET_PATH": str(sock_path),
                "CMUX_TAB_ID": TAB_ID,
                "CMUX_PANEL_ID": PANEL_ID,
                "CMUX_SURFACE_ID": "surface-nu-bg",
                "_CMUX_TTY_NAME": TTY_NAME,
                # No CMUX_TEST_SYNC_SEND: exercise the job spawn path. The
                # trailing sleep keeps the shell alive long enough for the
                # background job to flush (nushell kills jobs at exit; real
                # prompts outlive them).
            }
        )
        script = "; ".join(
            [
                f'source "{INTEGRATION}"',
                "_cmux_pre_execution",
                "sleep 800ms",
            ]
        )
        proc = subprocess.run(
            [nu, "-n", "-c", script],
            env=env,
            cwd=str(home),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        lines = collector.stop()
        debug = _debug(proc, lines)

        assert proc.returncode == 0, "integration errored on background sends" + debug
        suffix = f"--tab={TAB_ID} --panel={PANEL_ID}"
        assert f"report_shell_state running {suffix}" in lines, (
            "background (job spawn) send did not deliver report_shell_state"
            + debug
        )
        assert f"report_tty {TTY_NAME} {suffix}" in lines, (
            "background (job spawn) send did not deliver report_tty" + debug
        )
    finally:
        shutil.rmtree(td, ignore_errors=True)


def test_nushell_integration_keyboard_reset_test_knob() -> None:
    nu = _require_nu()
    if nu is None:
        return
    assert INTEGRATION.exists(), f"missing bundled nushell integration: {INTEGRATION}"

    td = _short_tmpdir()
    try:
        tmp = Path(td)
        home = tmp / "home"
        home.mkdir()
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CMUX")
        }
        env.update(
            {
                "LC_ALL": "C",
                "LANG": "C",
                "TERM": "xterm-256color",
                "HOME": str(home),
                "XDG_CONFIG_HOME": str(home / ".config"),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                # No socket: reporting no-ops, only the terminal reset runs.
                "CMUX_SOCKET_PATH": "",
                "CMUX_TEST_FORCE_KEYBOARD_RESET": "1",
            }
        )
        proc = subprocess.run(
            [nu, "-n", "-c", f'source "{INTEGRATION}"; _cmux_pre_prompt'],
            env=env,
            cwd=str(home),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        assert proc.returncode == 0, (
            f"pre-prompt errored without a socket\n{proc.stdout}\n{proc.stderr}"
        )
        assert "\x1b[>m\x1b[<8u" in proc.stdout, (
            "keyboard-protocol reset escape missing under "
            f"CMUX_TEST_FORCE_KEYBOARD_RESET\n{proc.stdout!r}\n{proc.stderr}"
        )
    finally:
        shutil.rmtree(td, ignore_errors=True)


if __name__ == "__main__":
    test_nushell_integration_hook_reports()
    test_nushell_integration_background_sends_deliver()
    test_nushell_integration_keyboard_reset_test_knob()
    if _find_nu() is None:
        print("SKIP: nushell (nu) not found; nothing was verified")
    else:
        print("PASS: cmux nushell integration reports tty/state/pwd/ports like fish")
