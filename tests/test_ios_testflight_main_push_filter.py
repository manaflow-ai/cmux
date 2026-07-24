import shlex
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
NOTES_GENERATOR = ROOT / "ios" / "scripts" / "generate-testflight-notes.sh"
IOS_PATHS = (
    "ios/**",
    "Packages/iOS/**",
    "Packages/Shared/**",
    "Sources/Mobile/**",
    "vendor/stack-auth-swift-sdk-prerelease/**",
    "ghostty",
    "ghostty.h",
    "scripts/ensure-ghosttykit.sh",
    "scripts/ghosttykit-checksums.txt",
    "scripts/install-zig-ci.sh",
    "scripts/validate-xcframework-archive.py",
    ".github/workflows/ios-testflight.yml",
)


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def trigger_block(text: str) -> str:
    return text[text.index("on:\n") : text.index("\nconcurrency:\n")]


def trigger_paths(triggers: str) -> tuple[str, ...]:
    lines = triggers[triggers.index("    paths:\n") :].splitlines()[1:]
    return tuple(
        line.removeprefix('      - "').removesuffix('"')
        for line in lines
        if line.startswith('      - "')
    )


def test_main_push_triggers_only_for_ios_affecting_paths() -> None:
    text = workflow_text()
    triggers = trigger_block(text)

    assert "  push:\n    branches:\n      - main\n" in triggers
    assert "  workflow_dispatch:\n" in triggers
    assert "schedule:" not in triggers
    assert trigger_paths(triggers) == IOS_PATHS
    assert "'schedule'" not in text
    assert "context.eventName === 'push' || context.eventName === 'workflow_dispatch'" in text


def test_testflight_notes_use_the_same_ios_path_contract() -> None:
    generator = NOTES_GENERATOR.read_text(encoding="utf-8")
    path_assignment = next(
        line for line in generator.splitlines() if line.startswith("PATHS=")
    )
    notes_paths = tuple(
        shlex.split(path_assignment.removeprefix("PATHS="))[0].split()
    )
    expected_notes_paths = tuple(
        path.removesuffix("/**") for path in IOS_PATHS
    )

    assert notes_paths == expected_notes_paths


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
    test_main_push_triggers_only_for_ios_affecting_paths()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_main_push_runs_are_preserved_and_uploaded_in_order()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight main-push filter tests passed")
