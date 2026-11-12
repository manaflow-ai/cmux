#!/usr/bin/env python3
"""Subprocess environment and wire helpers for tests that drive the cmux CLI against a fake socket.

A shell that cmux launched carries CMUX_SOCKET_PATH, CMUX_SOCKET_CAPABILITY and
the focused workspace and surface ids. A CLI started with that environment wraps
every request in a capability envelope and resolves targets the fake server never
defined, so the test fails at the socket before it reaches the behavior under
test. Build the subprocess environment with ``cli_environment`` instead of
copying ``os.environ``, and run wire lines through ``unwrap_capability`` in a
fake server that reads them directly, so a stray envelope is still understood.
"""

from __future__ import annotations

import functools
import os
import tempfile

# What a cmux-launched shell adds that would point the CLI at the running app,
# make it authenticate against a fake server that speaks the bare protocol, or
# pre-resolve the focused target the test meant to leave undefined.
INHERITED_SOCKET_KEYS = (
    "CMUX_SOCKET_PATH",
    "CMUX_SOCKET",
    "CMUX_SOCKET_PASSWORD",
    "CMUX_SOCKET_PASSWORD_FILE",
    "CMUX_SOCKET_CAPABILITY",
    "CMUX_RELAY_ID",
    "CMUX_RELAY_TOKEN",
    "CMUX_WORKSPACE_ID",
    "CMUX_SURFACE_ID",
    "CMUX_TAB_ID",
    "CMUX_PANEL_ID",
    "CMUX_PANE_ID",
)

# Resources/shell-integration prefixes a request with this when the shell
# holds a capability; the CLI does the same from CMUX_SOCKET_CAPABILITY.
CAPABILITY_PREFIX = "_cmux_capability_v1 "


@functools.cache
def _empty_foundation_home() -> tempfile.TemporaryDirectory:
    # Cached for the process, removed by TemporaryDirectory's finalizer at exit.
    return tempfile.TemporaryDirectory(prefix="cmux-cli-test-home-")


def cli_environment(socket_path: "str | os.PathLike[str] | None" = None, *,
                    home: "str | os.PathLike[str] | None" = None, **overrides: str) -> dict[str, str]:
    """A copy of the environment with the inherited socket state removed.

    ``socket_path`` sets both spellings the CLI reads, ``CMUX_SOCKET_PATH`` and
    ``CMUX_SOCKET``. ``home`` points the CLI at a test-owned home directory:
    it sets ``HOME`` for shells and scripts and ``CFFIXED_USER_HOME`` for the
    CLI itself, because Foundation resolves the home directory through
    getpwuid unless that variable is set, so ``HOME`` alone moves nothing for
    Swift code and ``~/.local/state/cmux`` would still be the real one.
    Without ``home``, the CLI still gets an empty Foundation home, as
    ``scripts/ci/run_python_test_lane.py`` gives each test in CI, so a socket
    password saved there is never sent to the fake socket as ``auth``; a
    ``CFFIXED_USER_HOME`` that runner already set is kept.
    Keyword overrides are applied last, so a test can still pin a workspace
    or surface id of its own.
    """
    env = {key: value for key, value in os.environ.items() if key not in INHERITED_SOCKET_KEYS}
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    if socket_path is not None:
        env["CMUX_SOCKET_PATH"] = str(socket_path)
        env["CMUX_SOCKET"] = str(socket_path)
    if home is not None:
        env["HOME"] = str(home)
        env["CFFIXED_USER_HOME"] = str(home)
    else:
        env.setdefault("CFFIXED_USER_HOME", _empty_foundation_home().name)
    env.update(overrides)
    return env


def unwrap_capability(line: str) -> str:
    """The request inside a ``_cmux_capability_v1 <token> <request>`` envelope, or the line unchanged."""
    if not line.startswith(CAPABILITY_PREFIX):
        return line
    parts = line.split(" ", 2)
    if len(parts) != 3 or not parts[1] or not parts[2]:
        return line
    return parts[2]
