from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"


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


def test_external_override_assigns_founders_and_pro_groups() -> None:
    upload_job = workflow_job(workflow_text(), "upload")

    assert (
        "CMUX_TESTFLIGHT_EXTERNAL_GROUP_ID: "
        "${{ vars.IOS_TESTFLIGHT_EXTERNAL_GROUP_ID }}"
    ) in upload_job
    assert (
        "CMUX_TESTFLIGHT_EXTERNAL_GROUP_NAME: "
        "${{ vars.IOS_TESTFLIGHT_EXTERNAL_GROUP_NAME }}"
    ) in upload_job
    assert (
        "CMUX_TESTFLIGHT_PRO_GROUP_ID: "
        "${{ vars.IOS_TESTFLIGHT_PRO_GROUP_ID }}"
    ) in upload_job
    assert (
        "CMUX_TESTFLIGHT_ASSIGN_EXTERNAL_GROUP: "
        "${{ github.event.inputs.marketing_version_override != '' && '1' || '0' }}"
    ) in upload_job

    job_env = upload_job.split("    steps:\n", 1)[0]
    assert (
        "github.event.inputs.marketing_version_override != '' "
        "&& 'dev.cmux.app.beta'"
    ) in job_env


def test_external_override_skips_internal_group_assignment() -> None:
    assign_job = workflow_job(workflow_text(), "assign-internal-group")

    assert (
        "if: github.ref == 'refs/heads/main' "
        "&& needs.upload.result == 'success' "
        "&& github.event.inputs.marketing_version_override == ''"
    ) in assign_job


if __name__ == "__main__":
    test_external_override_assigns_founders_and_pro_groups()
    test_external_override_skips_internal_group_assignment()
    print("all iOS TestFlight Pro distribution tests passed")
