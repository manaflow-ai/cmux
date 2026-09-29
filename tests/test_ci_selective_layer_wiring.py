#!/usr/bin/env python3
"""Contract checks for selective app-host layer wiring in the current macOS workflow."""

from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"


def load():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def step_by_id(job, ident):
    return next(step for step in job["steps"] if step.get("id") == ident)


def step_by_name(job, name):
    return next(step for step in job["steps"] if step.get("name") == name)


def test_aggregate_products_are_default_and_layers_opt_in():
    workflow = load()
    event = workflow.get("on", workflow.get(True))
    product = event["workflow_call"]["inputs"]["product_artifacts"]
    assert product["default"] == "aggregate"
    assert product["type"] == "string"


def test_compile_admission_publishes_exact_layer_index_outputs():
    job = load()["jobs"]["macos-compile-admission"]
    assert job["outputs"]["layer_index_artifact_id"] == "${{ steps.upload-layer-index.outputs.artifact-id }}"
    assert job["outputs"]["layer_index_digest"] == "${{ steps.upload-layer-index.outputs.artifact-digest }}"
    package = step_by_id(job, "package-layers")
    assert "inputs.full_suite == 'true'" in package["if"]
    assert "inputs.product_artifacts == 'layered'" in package["if"]
    for ident in (
        "upload-layer-app-cli",
        "upload-layer-runtime",
        "upload-layer-tests",
        "upload-layer-diagnostics",
        "pin-layer-index",
        "upload-layer-index",
    ):
        step_by_id(job, ident)


if __name__ == "__main__":
    test_aggregate_products_are_default_and_layers_opt_in()
    test_compile_admission_publishes_exact_layer_index_outputs()
