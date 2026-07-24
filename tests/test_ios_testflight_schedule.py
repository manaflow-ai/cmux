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


def mapping_keys(text: str, indent: int) -> tuple[str, ...]:
    keys = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) - len(line.lstrip()) != indent:
            continue
        key, separator, _ = line.strip().partition(":")
        assert separator, f"invalid mapping entry: {line}"
        parsed = shlex.split(key, comments=True)
        assert len(parsed) == 1, f"invalid mapping key: {line}"
        keys.append(parsed[0])
    return tuple(keys)


def test_automatic_upload_runs_every_thirty_minutes() -> None:
    text = workflow_text()
    triggers = trigger_block(text)

    assert mapping_keys(triggers, indent=2) == ("schedule", "workflow_dispatch")
    assert '    - cron: "7,37 * * * *"' in triggers
    assert "\n  push:" not in triggers
    assert "context.eventName === 'workflow_dispatch'" in text


def test_mapping_keys_normalizes_quoted_yaml_keys() -> None:
    triggers = "  push:\n  'schedule':\n  \"workflow_dispatch\":\n"

    assert mapping_keys(triggers, indent=2) == (
        "push",
        "schedule",
        "workflow_dispatch",
    )


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


def test_scheduled_runs_are_batched_and_uploaded_in_order() -> None:
    text = workflow_text()

    assert (
        "group: ios-testflight-${{ github.event_name == 'schedule' && 'scheduled' || github.run_id }}"
        in text
    )
    assert "cancel-in-progress: false" in text
    assert "Number(run.id) < currentRunId" in text
    assert "['schedule', 'workflow_dispatch'].includes(run.event)" in text
    assert "uploadJob.status !== 'completed'" in text
    assert "could not inspect earlier TestFlight runs; retrying" in text
    assert "ios-testflight-assignment-state-complete" not in text
    assert "CMUX_TESTFLIGHT_ASSIGN_STATE_OUT_FILE" not in text


def test_scheduled_run_skips_uploaded_or_non_ios_main() -> None:
    text = workflow_text()

    assert "lastUploadedSha === context.sha" in text
    assert "github.rest.repos.compareCommitsWithBasehead" in text
    assert "iosPathPattern.test(file.filename)" in text
    assert "iosPathPattern.test(file.previous_filename)" in text
    assert "context.eventName === 'schedule' && lookupFailed" in text
    assert "refusing to auto-upload" in text
    for path in IOS_PATHS:
        escaped = (
            path.removesuffix("/**")
            .replace(".", r"\.")
            .replace("/", r"\/")
        )
        suffix = r"\/" if path.endswith("/**") else r"$"
        assert f"{escaped}{suffix}" in text, f"missing scheduled path gate for {path}"


def test_automatic_lane_stays_on_cmux_internal_identity() -> None:
    text = workflow_text()

    assert "IOS_BETA_BUNDLE_ID: dev.cmux.app.internal" in text
    assert "IOS_BETA_DISPLAY_NAME: cmux INTERNAL" in text
    assert "--bundle-id dev.cmux.app.internal" in text


if __name__ == "__main__":
    test_automatic_upload_runs_every_thirty_minutes()
    test_mapping_keys_normalizes_quoted_yaml_keys()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_scheduled_runs_are_batched_and_uploaded_in_order()
    test_scheduled_run_skips_uploaded_or_non_ios_main()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight schedule tests passed")
