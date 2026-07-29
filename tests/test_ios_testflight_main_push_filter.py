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
IOS_SCHEDULES = (
    "7 * * * *",
    "37 5,17 * * *",
)
RESOLVED_DEMO_VARIANT_GUARD = "needs.decide.outputs.variant == 'demo'"
MARKETING_OVERRIDE_GUARD = "github.event.inputs.marketing_version_override != ''"


def variant_choice(demo: str, internal: str) -> str:
    return (
        f"${{{{ {RESOLVED_DEMO_VARIANT_GUARD} "
        f"&& '{demo}' || '{internal}' }}}}"
    )


def summary_choice(external: str, demo: str, internal: str) -> str:
    return (
        "${{ "
        f"{MARKETING_OVERRIDE_GUARD} && '{external}' "
        f"|| {RESOLVED_DEMO_VARIANT_GUARD} && '{demo}' "
        f"|| '{internal}' }}"
    )


def override_choice(external: str, normal: str) -> str:
    return (
        "${{ "
        f"{MARKETING_OVERRIDE_GUARD} && '{external}' "
        f"|| '{normal}' }}"
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


def sequence_mapping_values(
    text: str,
    key: str,
    indent: int,
) -> tuple[str, ...]:
    item_prefix = f"{' ' * indent}- {key}: "
    values = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(item_prefix):
            continue
        parsed = shlex.split(line.removeprefix(item_prefix), comments=True)
        assert len(parsed) == 1, f"invalid {key} value: {line}"
        values.append(parsed[0])
    return tuple(values)


def javascript_string_array(text: str, name: str) -> tuple[str, ...]:
    marker = f"const {name} = ["
    assert marker in text, f"missing {name} array"
    block = text.split(marker, 1)[1].split("];", 1)[0]
    values = []
    for line in block.splitlines():
        value = line.strip()
        if not value or value.startswith("//"):
            continue
        assert value.endswith(","), f"invalid {name} item: {line}"
        parsed = shlex.split(value.removesuffix(","), comments=True)
        assert len(parsed) == 1, f"invalid {name} value: {line}"
        values.append(parsed[0])
    return tuple(values)


def test_scheduled_uploads_filter_for_ios_affecting_main_changes() -> None:
    text = workflow_text()
    triggers = trigger_block(text)
    schedule = mapping_block(triggers, "schedule", indent=2)
    expected_workflow_paths = tuple(
        path.removesuffix("**") for path in IOS_PATHS
    )

    assert mapping_keys(triggers, indent=2) == (
        "schedule",
        "workflow_dispatch",
    )
    assert sequence_mapping_values(schedule, "cron", indent=4) == IOS_SCHEDULES
    assert (
        javascript_string_array(text, "iosRelevantPaths")
        == expected_workflow_paths
    )
    assert "let shouldBuild = true;" in text
    assert "if (context.eventName === 'schedule')" in text
    assert "github.rest.repos.compareCommits" in text


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


def test_scheduled_and_manual_runs_are_preserved_and_uploaded_in_order() -> None:
    text = workflow_text()

    assert "group: ios-testflight-${{ github.run_id }}" in text
    assert "github.event_name == 'push' && github.sha" not in text
    assert "group: ios-testflight-${{ github.ref_name }}" not in text
    assert "cancel-in-progress: false" in text
    assert "Number(run.id) < currentRunId" in text
    assert "['push', 'schedule', 'workflow_dispatch'].includes(run.event)" in text
    assert "uploadJob.status !== 'completed'" in text
    assert "could not inspect earlier TestFlight runs; retrying" in text
    assert "ios-testflight-assignment-state-complete" not in text
    assert "CMUX_TESTFLIGHT_ASSIGN_STATE_OUT_FILE" not in text


def test_automatic_lane_stays_on_cmux_internal_identity() -> None:
    text = workflow_text()
    decide = mapping_block(text, "decide", indent=2)
    upload = mapping_block(text, "upload", indent=2)
    assignment = mapping_block(text, "assign-internal-group", indent=2)

    bundle_choice = variant_choice("dev.cmux.app.demo", "dev.cmux.app.internal")
    display_name_choice = variant_choice("cmux DEMO", "cmux INTERNAL")
    group_choice = (
        "${{ "
        f"{RESOLVED_DEMO_VARIANT_GUARD} "
        "&& 'dd5c5cde-05a6-44e5-bd71-c2ec08a3ebfe' "
        "|| vars.IOS_TESTFLIGHT_INTERNAL_GROUP_ID }}"
    )

    assert "context.payload?.inputs?.variant === 'demo'" in decide
    assert (
        "context.eventName === 'schedule' "
        "&& context.payload?.schedule === demoCron"
        in decide
    )
    assert "core.setOutput('variant', variant)" in decide
    assert upload.count(f"IOS_BETA_BUNDLE_ID: {bundle_choice}") == 2
    assert upload.count(f"IOS_BETA_DISPLAY_NAME: {display_name_choice}") == 2
    assert (
        "CMUX_TESTFLIGHT_ASSIGN_EXTERNAL_GROUP: "
        f'{override_choice("1", "0")}'
        in upload
    )
    assert (
        "UPLOAD_BUNDLE_ID: "
        f"{summary_choice('dev.cmux.app.beta', 'dev.cmux.app.demo', 'dev.cmux.app.internal')}"
        in upload
    )
    assert (
        "UPLOAD_DISPLAY_NAME: "
        f"{summary_choice('cmux BETA', 'cmux DEMO', 'cmux INTERNAL')}"
        in upload
    )
    assert (
        "UPLOAD_AUDIENCE: "
        f"{override_choice('external TestFlight testers', 'internal TestFlight group')}"
        in upload
    )
    assert (
        "UPLOAD_REVIEW_NOTE: "
        f"{override_choice('Beta App Review may be required', 'no beta review needed')}"
        in upload
    )
    assert f"if: {RESOLVED_DEMO_VARIANT_GUARD}" in upload
    assert (
        'echo "- lane: \\`beta\\` '
        '(bundle id \\`${UPLOAD_BUNDLE_ID}\\`, ${UPLOAD_AUDIENCE})"'
        in upload
    )
    assert (
        'echo "- audience: ${UPLOAD_AUDIENCE} (${UPLOAD_DISPLAY_NAME}) '
        'on the ${UPLOAD_BUNDLE_ID} app; ${UPLOAD_REVIEW_NOTE}"'
        in upload
    )
    assert f"ASSIGN_BUNDLE_ID: {bundle_choice}" in assignment
    assert f"CMUX_TESTFLIGHT_INTERNAL_GROUP_ID: {group_choice}" in assignment
    assert assignment.count("needs: [decide, upload]") == 1
    assert (
        "if: github.ref == 'refs/heads/main' "
        "&& needs.upload.result == 'success' "
        "&& github.event.inputs.marketing_version_override == ''"
        in assignment
    )


if __name__ == "__main__":
    test_scheduled_uploads_filter_for_ios_affecting_main_changes()
    test_mapping_keys_normalizes_quoted_yaml_keys()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_scheduled_and_manual_runs_are_preserved_and_uploaded_in_order()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight scheduling tests passed")
