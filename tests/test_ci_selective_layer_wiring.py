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


def test_layered_products_are_default_for_full_suite_transport():
    workflow = load()
    event = workflow.get("on", workflow.get(True))
    product = event["workflow_call"]["inputs"]["product_artifacts"]
    assert product["default"] == "layered"
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


def test_consumers_prefer_warm_aggregate_then_selective_layers_before_remote_aggregate():
    for name in ("app-host-unit-tests", "tests-build-and-lag"):
        job = load()["jobs"][name]
        labels = [step.get("name") for step in job["steps"]]
        local = labels.index("Try node-local compiled product cache")
        peer = labels.index("Try trusted fleet peer artifact source")
        layers = labels.index("Restore selective app-host product layers")
        r2 = labels.index("Try shared R2 artifact transport")
        parallel = labels.index("Try parallel GitHub artifact transport")
        github = labels.index("Download compiled app-host test product")
        assert local < peer < layers < r2 < parallel < github

        layer_step = step_by_id(job, "restore-layers")
        assert layer_step["env"]["CMUX_APP_HOST_LAYER_PROFILE"] == "app-host-tests"
        assert "steps.node-products.outputs.hit != 'true'" in layer_step["if"]
        assert "steps.peer-products.outputs.hit != 'true'" in layer_step["if"]

        restore = step_by_name(job, "Restore compiled app-host test product")
        assert restore["env"]["CMUX_LAYER_RESTORED"] == "${{ steps.restore-layers.outputs.hit }}"

        finalize = step_by_name(job, "Finalize node-local compiled product cache")
        assert "steps.restore-layers.outputs.hit != 'true'" in finalize["env"]["CMUX_PRODUCT_RESTORE_SUCCEEDED"]


if __name__ == "__main__":
    test_layered_products_are_default_for_full_suite_transport()
    test_compile_admission_publishes_exact_layer_index_outputs()
    test_consumers_prefer_warm_aggregate_then_selective_layers_before_remote_aggregate()
