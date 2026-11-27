#!/usr/bin/env python3
"""Behavioral contract tests for the mobile simulator soak."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mobile-stability-soak" / "mobile-soak.py"


def load_mobile_soak_module():
    previous_simulator_id = os.environ.get("SIMULATOR_ID")
    os.environ["SIMULATOR_ID"] = "mobile-soak-contract-test"
    try:
        spec = importlib.util.spec_from_file_location("mobile_soak_contract", SCRIPT)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        if previous_simulator_id is None:
            os.environ.pop("SIMULATOR_ID", None)
        else:
            os.environ["SIMULATOR_ID"] = previous_simulator_id
    module.external_ticket_path = ""
    module.attach_route_id = "debug_loopback"
    module.attach_route_kind = ""
    return module


def test_create_ticket_requests_simulator_injection_url_contract() -> None:
    mobile_soak = load_mobile_soak_module()
    observed_params = None
    ticket = {
        "version": 1,
        "workspaceID": "workspace-test",
        "auth_token": "token-test",
        "routes": [
            {
                "id": "debug_loopback",
                "kind": "debug_loopback",
                "endpoint": {"host": "127.0.0.1", "port": 58465},
            }
        ],
    }

    def fake_cmux_rpc(method, params):
        nonlocal observed_params
        assert method == "mobile.attach_ticket.create"
        observed_params = params
        payload = {"ticket": ticket}
        if params.get("target") == "simulator_injection":
            payload["attach_url"] = mobile_soak.attach_url_for_ticket(ticket)
        return payload

    mobile_soak.cmux_rpc = fake_cmux_rpc

    created = mobile_soak.create_ticket("workspace-test")

    assert observed_params == {
        "ttl_seconds": mobile_soak.ticket_ttl_seconds,
        "target": "simulator_injection",
        "workspace_id": "workspace-test",
    }
    assert created["workspace_id"] == "workspace-test"
    assert created["host"] == "127.0.0.1"
    assert created["port"] == 58465
    assert created["attach_url"].startswith("cmux-ios-dev://attach?v=1&payload=")


if __name__ == "__main__":
    test_create_ticket_requests_simulator_injection_url_contract()
