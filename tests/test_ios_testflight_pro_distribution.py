import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
DISTRIBUTION_HELPER = ROOT / "ios" / "scripts" / "resolve_testflight_distribution.py"


def load_distribution_helper():
    spec = importlib.util.spec_from_file_location(
        "resolve_testflight_distribution",
        DISTRIBUTION_HELPER,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def workflow_job(text: str, name: str) -> str:
    marker = f"\n  {name}:\n"
    start = text.index(marker) + 1
    next_job = text.find("\n  ", start + len(marker))
    while next_job != -1:
        line_end = text.find("\n", next_job + 1)
        if line_end == -1:
            break
        candidate = text[next_job + 3 : line_end]
        if candidate.endswith(":") and " " not in candidate:
            return text[start:next_job]
        next_job = text.find("\n  ", line_end)
    return text[start:]


def test_distribution_helper_resolves_automatic_internal_upload() -> None:
    helper = load_distribution_helper()

    decision = helper.resolve_distribution("internal", "")

    assert decision.bundle_id == "dev.cmux.app.internal"
    assert decision.display_name == "cmux INTERNAL"
    assert decision.profile_type == "internal"
    assert decision.assign_external_group is False
    assert decision.assign_internal_group is True
    assert decision.metadata_artifact == "ios-testflight-build-metadata"


def test_distribution_helper_resolves_demo_upload() -> None:
    helper = load_distribution_helper()

    decision = helper.resolve_distribution("demo", "")

    assert decision.bundle_id == "dev.cmux.app.demo"
    assert decision.display_name == "cmux DEMO"
    assert decision.profile_type == "demo"
    assert decision.assign_external_group is False
    assert decision.assign_internal_group is True
    assert decision.metadata_artifact == "ios-testflight-build-metadata-demo"


def test_distribution_helper_resolves_manual_external_override() -> None:
    helper = load_distribution_helper()

    decision = helper.resolve_distribution("internal", "1.2.3")

    assert decision.bundle_id == "dev.cmux.app.beta"
    assert decision.display_name == "cmux BETA"
    assert decision.profile_type == "beta"
    assert decision.assign_external_group is True
    assert decision.assign_internal_group is False
    assert decision.metadata_artifact == "ios-testflight-build-metadata-override"


def test_workflow_executes_distribution_helper_and_consumes_its_outputs() -> None:
    text = workflow_text()
    upload_job = workflow_job(text, "upload")
    assign_job = workflow_job(text, "assign-internal-group")

    assert "python3 ./ios/scripts/resolve_testflight_distribution.py" in upload_job
    assert "IOS_BETA_BUNDLE_ID: ${{ steps.distribution.outputs.bundle_id }}" in upload_job
    assert "name: ${{ steps.distribution.outputs.metadata_artifact }}" in upload_job
    assert "needs.upload.outputs.assign_internal_group == '1'" in assign_job
    assert "ASSIGN_BUNDLE_ID: ${{ needs.upload.outputs.bundle_id }}" in assign_job


def test_ci_executes_this_testflight_workflow_guard() -> None:
    ci_text = CI_WORKFLOW.read_text(encoding="utf-8")

    assert "run: python3 tests/test_ios_testflight_pro_distribution.py" in ci_text


if __name__ == "__main__":
    test_distribution_helper_resolves_automatic_internal_upload()
    test_distribution_helper_resolves_demo_upload()
    test_distribution_helper_resolves_manual_external_override()
    test_workflow_executes_distribution_helper_and_consumes_its_outputs()
    test_ci_executes_this_testflight_workflow_guard()
    print("all iOS TestFlight Pro distribution tests passed")
