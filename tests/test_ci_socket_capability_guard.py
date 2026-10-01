#!/usr/bin/env python3
"""Regression guard for public socket capability discovery."""

import os
import subprocess
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "scripts", "check-socket-capabilities.py")


def test_public_dispatcher_methods_are_advertised():
    result = subprocess.run(
        [sys.executable, GUARD, "--root", ROOT],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert result.returncode == 0, result.stdout
    assert "socket capability parity: ok" in result.stdout
