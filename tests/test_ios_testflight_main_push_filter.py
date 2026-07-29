import json
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
NOTES_GENERATOR = ROOT / "ios" / "scripts" / "generate-testflight-notes.sh"
BUN = shutil.which("bun")
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


def literal_block(text: str, key: str, indent: int) -> str:
    marker = f"{' ' * indent}{key}: |\n"
    assert marker in text, f"missing {key} literal block"
    lines = text[text.index(marker) + len(marker) :].splitlines()
    content_prefix = " " * (indent + 2)
    block = []
    for line in lines:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        if not line.strip():
            block.append("")
            continue
        assert line.startswith(content_prefix), f"invalid {key} line: {line}"
        block.append(line.removeprefix(content_prefix))
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


def test_literal_block_accepts_whitespace_only_lines() -> None:
    text = "  script: |\n    first\n  \n    second\nnext:\n"

    assert literal_block(text, "script", indent=2) == "first\n\nsecond"


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


def run_decision_scenario(
    *,
    event_name: str,
    schedule: Optional[str] = None,
    input_variant: str = "internal",
    prior_sha: Optional[str] = None,
    prior_artifact: str = "ios-testflight-build-metadata",
    head_sha: str = "head-sha",
    changed_files: tuple[str, ...] = (),
    blocking_prior_run: bool = False,
) -> dict[str, object]:
    decision_job = mapping_block(workflow_text(), "decide", indent=2)
    decision_script = literal_block(decision_job, "script", indent=10)
    scenario = {
        "eventName": event_name,
        "schedule": schedule,
        "inputVariant": input_variant,
        "priorSha": prior_sha,
        "priorArtifact": prior_artifact,
        "headSha": head_sha,
        "changedFiles": changed_files,
        "blockingPriorRun": blocking_prior_run,
    }
    harness = f"""
const scenario = {json.dumps(scenario)};
const outputs = {{}};
const compareCalls = [];
const warnings = [];
const waitCalls = [];
let workflowRunCalls = 0;
let blockingReleased = !scenario.blockingPriorRun;
const priorRuns = () => scenario.priorSha
  ? [{{
      id: 50,
      status: blockingReleased ? 'completed' : 'in_progress',
      event: 'schedule',
      head_sha: scenario.priorSha,
    }}]
  : [];
const setTimeout = (resolve, milliseconds) => {{
  waitCalls.push(milliseconds);
  blockingReleased = true;
  resolve();
}};
const context = {{
  repo: {{ owner: 'manaflow-ai', repo: 'cmux' }},
  eventName: scenario.eventName,
  payload: {{
    schedule: scenario.schedule,
    inputs: {{ variant: scenario.inputVariant }},
  }},
  ref: 'refs/heads/main',
  runId: 100,
  sha: scenario.headSha,
}};
const github = {{
  rest: {{
    actions: {{
      listWorkflowRuns: async () => {{
        workflowRunCalls += 1;
        return {{
          data: {{ workflow_runs: priorRuns() }},
        }};
      }},
      listJobsForWorkflowRun: async () => ({{
        data: {{
          jobs: [{{
            name: 'Upload to TestFlight',
            status: blockingReleased ? 'completed' : 'in_progress',
            conclusion: blockingReleased ? 'success' : null,
          }}],
        }},
      }}),
      listWorkflowRunArtifacts: async () => ({{
        data: {{
          artifacts: [{{ name: scenario.priorArtifact }}],
        }},
      }}),
    }},
    repos: {{
      compareCommits: async (request) => {{
        compareCalls.push(request);
        return {{
          data: {{
            files: scenario.changedFiles.map((filename) => ({{ filename }})),
          }},
        }};
      }},
    }},
  }},
}};
const core = {{
  setOutput: (name, value) => {{
    outputs[name] = value;
  }},
  setFailed: (message) => {{
    throw new Error(message);
  }},
  warning: (message) => {{
    warnings.push(message);
  }},
  info: () => {{}},
  summary: {{
    addHeading() {{
      return this;
    }},
    addTable() {{
      return this;
    }},
    write() {{
      return this;
    }},
  }},
}};
async function runDecision() {{
{decision_script}
}}
await runDecision();
process.stdout.write(JSON.stringify({{
  outputs,
  compareCalls,
  warnings,
  waitCalls,
  workflowRunCalls,
}}));
"""
    assert BUN is not None, "bun is required to execute the decide job harness"
    result = subprocess.run(
        [BUN, "-e", harness],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


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


def test_schedule_decision_executes_ios_path_filter() -> None:
    ios_change = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=("Sources/Mobile/MobileHostService.swift",),
    )
    non_ios_change = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=("docs/cli-contract.md",),
    )

    assert ios_change["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }
    assert non_ios_change["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }
    expected_compare = [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "base": "base-sha",
            "head": "head-sha",
        }
    ]
    assert ios_change["compareCalls"] == expected_compare
    assert non_ios_change["compareCalls"] == expected_compare


def test_schedule_decision_routes_demo_cron_to_demo_history() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[1],
        prior_sha="demo-base-sha",
        prior_artifact="ios-testflight-build-metadata-demo",
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "demo-base-sha",
        "variant": "demo",
    }


def test_manual_demo_dispatch_builds_even_when_head_already_uploaded() -> None:
    result = run_decision_scenario(
        event_name="workflow_dispatch",
        input_variant="demo",
        prior_sha="head-sha",
        prior_artifact="ios-testflight-build-metadata-demo",
        head_sha="head-sha",
    )

    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "head-sha",
        "variant": "demo",
    }
    assert result["compareCalls"] == []


def test_scheduled_run_waits_for_an_earlier_upload() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=("ios/cmux/App.swift",),
        blocking_prior_run=True,
    )

    assert result["waitCalls"] == [60_000]
    assert result["workflowRunCalls"] == 3
    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


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


def test_scheduled_and_manual_runs_use_independent_concurrency_groups() -> None:
    text = workflow_text()

    assert "group: ios-testflight-${{ github.run_id }}" in text
    assert "github.event_name == 'push' && github.sha" not in text
    assert "group: ios-testflight-${{ github.ref_name }}" not in text
    assert "cancel-in-progress: false" in text
    assert "ios-testflight-assignment-state-complete" not in text
    assert "CMUX_TESTFLIGHT_ASSIGN_STATE_OUT_FILE" not in text


def test_automatic_lane_stays_on_cmux_internal_identity() -> None:
    text = workflow_text()
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
    test_literal_block_accepts_whitespace_only_lines()
    test_scheduled_uploads_filter_for_ios_affecting_main_changes()
    test_schedule_decision_executes_ios_path_filter()
    test_schedule_decision_routes_demo_cron_to_demo_history()
    test_manual_demo_dispatch_builds_even_when_head_already_uploaded()
    test_scheduled_run_waits_for_an_earlier_upload()
    test_mapping_keys_normalizes_quoted_yaml_keys()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_scheduled_and_manual_runs_use_independent_concurrency_groups()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight scheduling tests passed")
