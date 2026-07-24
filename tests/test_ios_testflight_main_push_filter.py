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


def mapping_block(text: str, key: str, indent: int) -> str:
    marker = f"{' ' * indent}{key}:\n"
    assert marker in text, f"missing {key} mapping"
    lines = text[text.index(marker) + len(marker) :].splitlines()
    block = []
    for line in lines:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        block.append(line)
    return "\n".join(block)


def sequence_values(text: str, key: str, indent: int) -> tuple[str, ...]:
    marker = f"{' ' * indent}{key}:\n"
    assert marker in text, f"missing {key} sequence"
    lines = text[text.index(marker) + len(marker) :].splitlines()
    item_prefix = f"{' ' * (indent + 2)}- "
    values = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        line_indent = len(line) - len(line.lstrip())
        if line_indent <= indent:
            break
        assert line.startswith(item_prefix), f"invalid {key} item: {line}"
        parsed = shlex.split(line.removeprefix(item_prefix), comments=True)
        assert len(parsed) == 1, f"invalid {key} value: {line}"
        values.append(parsed[0])
    return tuple(values)


def test_main_push_triggers_only_for_ios_affecting_paths() -> None:
    text = workflow_text()
    triggers = trigger_block(text)
    push = mapping_block(triggers, "push", indent=2)

    assert sequence_values(push, "branches", indent=4) == ("main",)
    assert sequence_values(push, "paths", indent=4) == IOS_PATHS
    assert "  workflow_dispatch:\n" in triggers
    assert "schedule:" not in triggers
    assert "'schedule'" not in text
    assert "context.eventName === 'push' || context.eventName === 'workflow_dispatch'" in text


def test_testflight_notes_use_the_same_ios_path_contract() -> None:
    generator = NOTES_GENERATOR.read_text(encoding="utf-8")
    path_assignment = next(
        (line for line in generator.splitlines() if line.startswith("PATHS=")),
        None,
    )
    assert path_assignment is not None, "missing PATHS assignment"
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
