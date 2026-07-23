from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def trigger_block(text: str) -> str:
    return text[text.index("on:\n") : text.index("\nconcurrency:\n")]


def test_every_main_push_triggers_without_path_or_schedule_gates() -> None:
    text = workflow_text()
    triggers = trigger_block(text)

    assert "  push:\n    branches:\n      - main\n" in triggers
    assert "  workflow_dispatch:\n" in triggers
    assert "schedule:" not in triggers
    assert "paths:" not in triggers
    assert "context.eventName === 'push' || context.eventName === 'workflow_dispatch'" in text


def test_main_push_runs_are_preserved_and_uploaded_in_order() -> None:
    text = workflow_text()

    assert (
        "group: ios-testflight-${{ github.event_name == 'push' && github.sha || github.run_id }}"
        in text
    )
    assert "group: ios-testflight-${{ github.ref_name }}" not in text
    assert "cancel-in-progress: false" in text
    assert "Number(run.id) < currentRunId" in text
    assert "uploadJob.status !== 'completed'" in text
    assert "could not inspect earlier TestFlight runs; retrying" in text
    assert "ios-testflight-assignment-state-complete" not in text
    assert "CMUX_TESTFLIGHT_ASSIGN_STATE_OUT_FILE" not in text


def test_automatic_lane_stays_on_cmux_internal_identity() -> None:
    text = workflow_text()

    assert "IOS_BETA_BUNDLE_ID: dev.cmux.app.internal" in text
    assert "IOS_BETA_DISPLAY_NAME: cmux INTERNAL" in text
    assert "--bundle-id dev.cmux.app.internal" in text


if __name__ == "__main__":
    test_every_main_push_triggers_without_path_or_schedule_gates()
    test_main_push_runs_are_preserved_and_uploaded_in_order()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight main-push workflow tests passed")
