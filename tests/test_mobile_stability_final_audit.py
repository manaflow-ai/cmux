#!/usr/bin/env python3
"""Behavioral tests for final mobile-soak process identity checks."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mobile-stability-soak" / "final-audit.py"


def load_final_audit_module():
    spec = importlib.util.spec_from_file_location("mobile_final_audit", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_mac_process_identity_uses_requested_tag() -> None:
    audit = load_final_audit_module()
    irfast = (
        "/tmp/DerivedData/cmux-irfast/Build/Products/Debug/"
        "cmux DEV irfast.app/Contents/MacOS/cmux DEV"
    )
    swmob = (
        "/tmp/DerivedData/cmux-swmob/Build/Products/Debug/"
        "cmux DEV swmob.app/Contents/MacOS/cmux DEV"
    )

    assert audit.process_command_matches("mac", irfast, tag="irfast")
    assert not audit.process_command_matches("mac", swmob, tag="irfast")
    assert audit.process_command_matches("iphone", "/container/cmux.app/cmux", tag="irfast")
