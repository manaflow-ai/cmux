#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "perf-activation-session.py"
spec = importlib.util.spec_from_file_location("perf_activation_session", SCRIPT)
assert spec is not None
perf_activation_session = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(perf_activation_session)


def default_surface_roles() -> list[tuple[str, bool]]:
    heavy = [(f"surface-heavy-{idx}", True) for idx in range(11)]
    other = [(f"surface-other-{idx}", False) for idx in range(55)]
    return heavy + other


def test_default_scrollback_seed_is_bounded_above_budget_floor() -> None:
    plan, summary = perf_activation_session.build_scrollback_line_plan(
        default_surface_roles(),
        heavy_lines=2400,
        other_lines=1400,
        line_payload_chars=96,
        target_chars=perf_activation_session.DEFAULT_SCROLLBACK_TARGET_CHARS,
    )

    assert len(plan) == 66
    assert min(plan.values()) > 0
    assert summary["scrollback_target_applied"] is True
    assert summary["scrollback_requested_estimated_chars"] > 11_000_000
    assert 1_000_000 <= summary["scrollback_effective_estimated_chars"] <= 1_600_000
    assert summary["heavy_scrollback_lines_effective"] > summary["other_scrollback_lines_effective"]


def test_scrollback_target_can_be_disabled_for_manual_stress_runs() -> None:
    plan, summary = perf_activation_session.build_scrollback_line_plan(
        default_surface_roles(),
        heavy_lines=2400,
        other_lines=1400,
        line_payload_chars=96,
        target_chars=0,
    )

    assert summary["scrollback_target_applied"] is False
    assert summary["scrollback_effective_estimated_chars"] == summary["scrollback_requested_estimated_chars"]
    assert plan["surface-heavy-0"] == 2400
    assert plan["surface-other-0"] == 1400


def test_small_requested_fixture_is_not_scaled_up() -> None:
    plan, summary = perf_activation_session.build_scrollback_line_plan(
        default_surface_roles(),
        heavy_lines=1,
        other_lines=1,
        line_payload_chars=8,
        target_chars=perf_activation_session.DEFAULT_SCROLLBACK_TARGET_CHARS,
    )

    assert summary["scrollback_target_applied"] is False
    assert set(plan.values()) == {1}


def test_persisted_snapshot_fingerprint_uses_exact_tagged_primary_file(
    tmp_path: Path, monkeypatch: object
) -> None:
    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    args = argparse.Namespace(
        tag="Fingerprint Test",
        app_path=str(tmp_path / "cmux.app"),
        fixture_root=str(tmp_path / "fixture"),
        launch_timeout=1.0,
        snapshot_timeout=1.0,
    )
    runner = perf_activation_session.CmuxPerfRunner(args)
    payload = b'{"owned":"snapshot"}'
    snapshot_path = (
        home
        / "Library/Application Support/cmux"
        / "session-com.cmuxterm.app.debug.fingerprint.test.json"
    )
    snapshot_path.parent.mkdir(parents=True)
    snapshot_path.write_bytes(payload)

    assert runner.persisted_snapshot_fingerprint() == {
        "algorithm": "sha256",
        "digest": hashlib.sha256(payload).hexdigest(),
        "byte_count": len(payload),
    }


if __name__ == "__main__":
    test_default_scrollback_seed_is_bounded_above_budget_floor()
    test_scrollback_target_can_be_disabled_for_manual_stress_runs()
    test_small_requested_fixture_is_not_scaled_up()
