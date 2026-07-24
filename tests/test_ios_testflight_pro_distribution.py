from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def test_external_override_assigns_founders_and_pro_groups() -> None:
    text = workflow_text()

    assert (
        "CMUX_TESTFLIGHT_PRO_GROUP_ID: "
        "${{ vars.IOS_TESTFLIGHT_PRO_GROUP_ID }}"
    ) in text
    assert (
        "CMUX_TESTFLIGHT_ASSIGN_EXTERNAL_GROUP: "
        "${{ github.event.inputs.marketing_version_override != '' && '1' || '0' }}"
    ) in text


def test_external_override_skips_internal_group_assignment() -> None:
    text = workflow_text()

    assert (
        "if: github.ref == 'refs/heads/main' "
        "&& needs.upload.result == 'success' "
        "&& github.event.inputs.marketing_version_override == ''"
    ) in text


if __name__ == "__main__":
    test_external_override_assigns_founders_and_pro_groups()
    test_external_override_skips_internal_group_assignment()
    print("all iOS TestFlight Pro distribution tests passed")
