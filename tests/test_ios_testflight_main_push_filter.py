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
    "scripts/ghostty-zig-version.sh",
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


def scalar_mapping(text: str, indent: int) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if len(line) - len(line.lstrip()) != indent:
            continue
        key, separator, value = line.strip().partition(":")
        assert separator and value.strip(), f"invalid scalar mapping: {line}"
        assert key not in values, f"duplicate scalar key: {key}"
        values[key] = value.strip()
    return values


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


def github_expression_containing(text: str, needle: str) -> str:
    matches = [
        line.strip()
        for line in text.splitlines()
        if needle in line and "${{" in line
    ]
    assert len(matches) == 1, f"expected one expression containing {needle}"
    expression = matches[0]
    return expression.split("${{", 1)[1].rsplit("}}", 1)[0].strip()


def run_decision_scenario(
    *,
    event_name: str,
    schedule: Optional[str] = None,
    input_variant: str = "internal",
    marketing_version_override: str = "",
    prior_sha: Optional[str] = None,
    prior_event: str = "schedule",
    prior_artifact: str = "ios-testflight-build-metadata",
    prior_uploads: tuple[tuple[str, str], ...] = (),
    prior_upload_pages: tuple[
        tuple[tuple[str, str], ...],
        ...,
    ] = (),
    prior_run_ids: tuple[int, ...] = (),
    head_sha: str = "head-sha",
    changed_files: tuple[str, ...] = (),
    blocking_prior_run: bool = False,
    upload_job_starts_late: bool = False,
    ordering_api_failure: Optional[str] = None,
    compare_api_failure: bool = False,
) -> dict[str, object]:
    decision_job = mapping_block(workflow_text(), "decide", indent=2)
    decision_script = literal_block(decision_job, "script", indent=10)
    artifact_expression = github_expression_containing(
        workflow_text(),
        "ios-testflight-build-metadata-override",
    )
    history_sources = sum(
        bool(source)
        for source in (prior_sha, prior_uploads, prior_upload_pages)
    )
    assert history_sources <= 1, "use only one prior upload source"
    assert ordering_api_failure in (
        None,
        "runs",
        "jobs",
    ), "ordering_api_failure must be runs or jobs"
    upload_pages = prior_upload_pages
    if not upload_pages:
        upload_history = prior_uploads
        if prior_sha:
            upload_history = ((prior_sha, prior_artifact),)
        upload_pages = (upload_history,) if upload_history else ()
    upload_history = tuple(
        upload for page in upload_pages for upload in page
    )
    assert not prior_run_ids or len(prior_run_ids) == len(
        upload_history
    ), "prior_run_ids must match the upload history"
    run_ids = prior_run_ids or tuple(
        50 - index for index in range(len(upload_history))
    )
    prior_run_pages = []
    run_index = 0
    for page in upload_pages:
        page_runs = []
        for sha, artifact in page:
            page_runs.append(
                {
                    "id": run_ids[run_index],
                    "sha": sha,
                    "artifact": artifact,
                    "event": prior_event,
                }
            )
            run_index += 1
        prior_run_pages.append(page_runs)
    scenario = {
        "eventName": event_name,
        "schedule": schedule,
        "inputVariant": input_variant,
        "marketingVersionOverride": marketing_version_override,
        "priorRunPages": prior_run_pages,
        "headSha": head_sha,
        "changedFiles": changed_files,
        "blockingPriorRun": blocking_prior_run,
        "uploadJobStartsLate": upload_job_starts_late,
        "orderingApiFailure": ordering_api_failure,
        "compareApiFailure": compare_api_failure,
    }
    harness = f"""
const scenario = {json.dumps(scenario)};
const outputs = {{}};
const compareCalls = [];
const warnings = [];
const waitCalls = [];
const workflowRunRequests = [];
const priorRunStatuses = [];
const uploadJobStatuses = [];
let workflowRunCalls = 0;
let uploadPhase = scenario.blockingPriorRun
  ? (scenario.uploadJobStartsLate ? 0 : 1)
  : 2;
let orderingFailurePending = scenario.orderingApiFailure !== null;
const allPriorRuns = scenario.priorRunPages.flat();
const firstPriorRunId = allPriorRuns[0]?.id;
const priorRuns = (request) => {{
  const page = Number(request.page ?? 1);
  const pageRuns = scenario.priorRunPages[page - 1] ?? [];
  return pageRuns.map((run) => ({{
  id: run.id,
  status:
    scenario.blockingPriorRun && run.id === firstPriorRunId
      ? 'in_progress'
      : 'completed',
  event: run.event,
  head_sha: run.sha,
  }}));
}};
const setTimeout = (resolve, milliseconds) => {{
  waitCalls.push(milliseconds);
  uploadPhase = Math.min(uploadPhase + 1, 2);
  resolve();
}};
const context = {{
  repo: {{ owner: 'manaflow-ai', repo: 'cmux' }},
  eventName: scenario.eventName,
  payload: {{
    schedule: scenario.schedule,
    inputs: {{
      marketing_version_override: scenario.marketingVersionOverride,
      variant: scenario.inputVariant,
    }},
  }},
  ref: 'refs/heads/main',
  runId: 100,
  sha: scenario.headSha,
}};
const github = {{
  event: {{
    inputs: {{
      marketing_version_override: scenario.marketingVersionOverride,
      variant: scenario.inputVariant,
    }},
  }},
  rest: {{
    actions: {{
      listWorkflowRuns: async (request) => {{
        workflowRunCalls += 1;
        workflowRunRequests.push(request);
        if (
          orderingFailurePending &&
          scenario.orderingApiFailure === 'runs'
        ) {{
          orderingFailurePending = false;
          throw new Error('transient runs failure');
        }}
        const workflowRuns = priorRuns(request);
        priorRunStatuses.push(...workflowRuns.map((run) => run.status));
        return {{
          data: {{ workflow_runs: workflowRuns }},
        }};
      }},
      listJobsForWorkflowRun: async (request) => {{
        if (
          orderingFailurePending &&
          scenario.orderingApiFailure === 'jobs'
        ) {{
          orderingFailurePending = false;
          throw new Error('transient jobs failure');
        }}
        const priorRun = allPriorRuns.find(
          (run) => run.id === Number(request.run_id)
        );
        const isBlockingRun =
          scenario.blockingPriorRun &&
          priorRun?.id === firstPriorRunId;
        const phase = isBlockingRun ? uploadPhase : 2;
        if (phase === 0) {{
          uploadJobStatuses.push(null);
          return {{ data: {{ jobs: [] }} }};
        }}
        const status = phase === 2 ? 'completed' : 'in_progress';
        uploadJobStatuses.push(status);
        return {{
          data: {{
            jobs: [{{
              name: 'Upload to TestFlight',
              status,
              conclusion: phase === 2 ? 'success' : null,
            }}],
          }},
        }};
      }},
      listWorkflowRunArtifacts: async (request) => {{
        const priorRun = allPriorRuns.find(
          (run) => run.id === Number(request.run_id)
        );
        return {{
          data: {{
            artifacts: priorRun ? [{{ name: priorRun.artifact }}] : [],
          }},
        }};
      }},
    }},
    repos: {{
      compareCommits: async (request) => {{
        compareCalls.push(request);
        if (scenario.compareApiFailure) {{
          throw new Error('transient compare failure');
        }}
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
const needs = {{ decide: {{ outputs }} }};
const producedArtifactName = {artifact_expression};
process.stdout.write(JSON.stringify({{
  outputs,
  compareCalls,
  warnings,
  waitCalls,
  workflowRunCalls,
  workflowRunRequests,
  priorRunStatuses,
  uploadJobStatuses,
  producedArtifactName,
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
    ios_changes = [
        run_decision_scenario(
            event_name="schedule",
            schedule=IOS_SCHEDULES[0],
            prior_sha="base-sha",
            head_sha="head-sha",
            changed_files=(
                path.removesuffix("**") + "changed"
                if path.endswith("**")
                else path,
            ),
        )
        for path in IOS_PATHS
    ]
    non_ios_change = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=("docs/cli-contract.md",),
    )

    for ios_change in ios_changes:
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
    assert all(
        ios_change["compareCalls"] == expected_compare
        for ios_change in ios_changes
    )
    assert non_ios_change["compareCalls"] == expected_compare


def test_truncated_schedule_comparison_fails_open() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=tuple(f"docs/generated-{index}.md" for index in range(300)),
    )

    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


def test_schedule_comparison_failure_fails_open() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        compare_api_failure=True,
    )

    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }
    assert result["warnings"] == [
        "could not compare against last upload: transient compare failure"
    ]


def test_unchanged_scheduled_head_skips_without_comparing() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="head-sha",
        head_sha="head-sha",
        compare_api_failure=True,
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "head-sha",
        "variant": "internal",
    }
    assert result["compareCalls"] == []
    assert result["warnings"] == []


def test_schedule_decision_routes_demo_cron_to_demo_history() -> None:
    first_run = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[1],
        input_variant="",
    )
    produced_artifact = first_run["producedArtifactName"]
    assert isinstance(produced_artifact, str)
    assert first_run["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "",
        "variant": "demo",
    }
    assert produced_artifact == "ios-testflight-build-metadata-demo"

    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[1],
        input_variant="",
        prior_sha="demo-base-sha",
        prior_artifact=produced_artifact,
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "demo-base-sha",
        "variant": "demo",
    }


def test_schedule_decision_routes_internal_cron_to_internal_history() -> None:
    first_run = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        input_variant="",
    )
    produced_artifact = first_run["producedArtifactName"]
    assert isinstance(produced_artifact, str)
    assert first_run["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "",
        "variant": "internal",
    }
    assert produced_artifact == "ios-testflight-build-metadata"

    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        input_variant="",
        prior_sha="internal-base-sha",
        prior_artifact=produced_artifact,
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "internal-base-sha",
        "variant": "internal",
    }


def test_demo_history_skips_newer_internal_artifact() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[1],
        input_variant="",
        prior_uploads=(
            ("newer-internal-sha", "ios-testflight-build-metadata"),
            ("demo-base-sha", "ios-testflight-build-metadata-demo"),
        ),
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "demo-base-sha",
        "variant": "demo",
    }
    assert result["compareCalls"] == [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "base": "demo-base-sha",
            "head": "head-sha",
        }
    ]


def test_demo_history_paginates_to_matching_artifact() -> None:
    first_page = tuple(
        (
            f"internal-sha-{index}",
            "ios-testflight-build-metadata",
        )
        for index in range(100)
    )
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[1],
        input_variant="",
        prior_upload_pages=(
            first_page,
            (("demo-base-sha", "ios-testflight-build-metadata-demo"),),
        ),
        prior_run_ids=tuple(range(1_000, 899, -1)),
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "demo-base-sha",
        "variant": "demo",
    }
    assert [
        request.get("page")
        for request in result["workflowRunRequests"]
        if "page" in request
    ] == [1, 2]
    assert result["compareCalls"] == [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "base": "demo-base-sha",
            "head": "head-sha",
        }
    ]


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


def test_manual_override_artifact_is_excluded_from_canonical_history() -> None:
    override_run = run_decision_scenario(
        event_name="workflow_dispatch",
        marketing_version_override="1.2.3",
    )
    produced_artifact = override_run["producedArtifactName"]
    assert produced_artifact == "ios-testflight-build-metadata-override"

    scheduled_run = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="override-sha",
        prior_artifact=produced_artifact,
        changed_files=("docs/cli-contract.md",),
    )

    assert scheduled_run["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "",
        "variant": "internal",
    }
    assert scheduled_run["compareCalls"] == []


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
    assert result["workflowRunRequests"] == [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "workflow_id": "ios-testflight.yml",
            "branch": "main",
            "per_page": 100,
        },
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "workflow_id": "ios-testflight.yml",
            "branch": "main",
            "per_page": 100,
        },
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "workflow_id": "ios-testflight.yml",
            "branch": "main",
            "per_page": 100,
            "page": 1,
        },
    ]
    assert result["priorRunStatuses"] == [
        "in_progress",
        "in_progress",
        "in_progress",
    ]
    assert result["uploadJobStatuses"] == [
        "in_progress",
        "completed",
        "completed",
    ]
    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


def test_scheduled_run_waits_before_upload_job_exists() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        head_sha="head-sha",
        changed_files=("ios/cmux/App.swift",),
        blocking_prior_run=True,
        upload_job_starts_late=True,
    )

    assert result["waitCalls"] == [60_000, 60_000]
    assert result["uploadJobStatuses"] == [
        None,
        "in_progress",
        "completed",
        "completed",
    ]
    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


def test_ordering_retries_transient_api_failures() -> None:
    for failed_api in ("runs", "jobs"):
        result = run_decision_scenario(
            event_name="schedule",
            schedule=IOS_SCHEDULES[0],
            prior_sha="base-sha",
            head_sha="head-sha",
            changed_files=("ios/cmux/App.swift",),
            blocking_prior_run=True,
            upload_job_starts_late=True,
            ordering_api_failure=failed_api,
        )

        assert result["waitCalls"] == [60_000, 60_000]
        assert result["workflowRunCalls"] == 4
        assert result["uploadJobStatuses"] == [
            "in_progress",
            "completed",
            "completed",
        ]
        assert result["warnings"] == [
            "could not inspect earlier TestFlight runs; retrying: "
            f"transient {failed_api} failure"
        ]
        assert result["outputs"] == {
            "should_build": "true",
            "last_uploaded_sha": "base-sha",
            "variant": "internal",
        }


def test_ordering_ignores_later_active_runs() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_uploads=(
            ("newer-active-sha", "ios-testflight-build-metadata"),
            ("base-sha", "ios-testflight-build-metadata"),
        ),
        prior_run_ids=(150, 50),
        head_sha="head-sha",
        changed_files=("docs/cli-contract.md",),
        blocking_prior_run=True,
        upload_job_starts_late=True,
    )

    assert result["waitCalls"] == []
    assert result["priorRunStatuses"] == [
        "in_progress",
        "completed",
        "in_progress",
        "completed",
    ]
    assert result["uploadJobStatuses"] == [None, "completed"]
    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


def test_ordering_includes_manual_current_and_prior_runs() -> None:
    scenarios = (
        ("workflow_dispatch", "schedule"),
        ("schedule", "workflow_dispatch"),
    )

    for event_name, prior_event in scenarios:
        result = run_decision_scenario(
            event_name=event_name,
            schedule=IOS_SCHEDULES[0],
            prior_sha="base-sha",
            prior_event=prior_event,
            head_sha="head-sha",
            changed_files=("ios/cmux/App.swift",),
            blocking_prior_run=True,
        )

        assert result["waitCalls"] == [60_000]
        assert result["uploadJobStatuses"] == [
            "in_progress",
            "completed",
            "completed",
        ]
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
    concurrency = scalar_mapping(
        mapping_block(text, "concurrency", indent=0),
        indent=2,
    )
    group_template = concurrency["group"]
    run_id_token = "${{ github.run_id }}"

    assert concurrency == {
        "group": "ios-testflight-${{ github.run_id }}",
        "cancel-in-progress": "false",
    }
    assert group_template.count(run_id_token) == 1
    scheduled_group = group_template.replace(run_id_token, "100")
    manual_group = group_template.replace(run_id_token, "101")
    assert scheduled_group == "ios-testflight-100"
    assert manual_group == "ios-testflight-101"
    assert scheduled_group != manual_group


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
    test_truncated_schedule_comparison_fails_open()
    test_schedule_comparison_failure_fails_open()
    test_unchanged_scheduled_head_skips_without_comparing()
    test_schedule_decision_routes_demo_cron_to_demo_history()
    test_schedule_decision_routes_internal_cron_to_internal_history()
    test_demo_history_skips_newer_internal_artifact()
    test_demo_history_paginates_to_matching_artifact()
    test_manual_demo_dispatch_builds_even_when_head_already_uploaded()
    test_manual_override_artifact_is_excluded_from_canonical_history()
    test_scheduled_run_waits_for_an_earlier_upload()
    test_scheduled_run_waits_before_upload_job_exists()
    test_ordering_retries_transient_api_failures()
    test_ordering_ignores_later_active_runs()
    test_ordering_includes_manual_current_and_prior_runs()
    test_mapping_keys_normalizes_quoted_yaml_keys()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_scheduled_and_manual_runs_use_independent_concurrency_groups()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight scheduling tests passed")
