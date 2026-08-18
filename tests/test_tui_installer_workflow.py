from __future__ import annotations

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-sdks.yml"
REQUIRED_PATHS = {
    "tests/test_tui_installers.py",
    "web/app/tui/install.sh/route.ts",
    "web/app/tui/install.ps1/route.ts",
    "web/public/tui/install-static.sh",
    "web/public/tui/install-static.ps1",
    "web/tests/install-analytics.test.tsx",
}


def _workflow() -> dict[str, object]:
    document = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    assert isinstance(document, dict)
    return document


def _paths(document: dict[str, object], event: str) -> set[str]:
    triggers = document["on"]
    assert isinstance(triggers, dict)
    event_config = triggers[event]
    assert isinstance(event_config, dict)
    paths = event_config["paths"]
    assert isinstance(paths, list)
    return {str(path) for path in paths}


def _run_steps(document: dict[str, object]) -> list[dict[str, object]]:
    jobs = document["jobs"]
    assert isinstance(jobs, dict)
    contract = jobs["contract"]
    assert isinstance(contract, dict)
    steps = contract["steps"]
    assert isinstance(steps, list)
    return [step for step in steps if isinstance(step, dict)]


def test_tui_installer_checks_run_in_the_hosted_contract_job() -> None:
    document = _workflow()
    steps = _run_steps(document)
    run_commands = [str(step.get("run", "")) for step in steps]

    assert any("pytest -q tests/test_tui_installers.py" in command for command in run_commands)
    assert any(
        "bun test --isolate tests/install-analytics.test.tsx" in command
        and step.get("working-directory") == "web"
        for step, command in zip(steps, run_commands)
    )
    assert any(
        step.get("uses", "").startswith("oven-sh/setup-bun@")
        for step in steps
    )
    assert any(
        "bun install --frozen-lockfile" in command
        and step.get("working-directory") == "web"
        for step, command in zip(steps, run_commands)
    )

    for event in ("push", "pull_request"):
        assert REQUIRED_PATHS <= _paths(document, event)
