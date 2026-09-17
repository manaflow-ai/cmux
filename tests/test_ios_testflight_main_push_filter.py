import importlib.util
import json
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-testflight.yml"
NOTES_GENERATOR = ROOT / "ios" / "scripts" / "generate-testflight-notes.sh"
DISTRIBUTION_HELPER = ROOT / "ios" / "scripts" / "resolve_testflight_distribution.py"
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
    "7,27,47 * * * *",
    "37 5,17 * * *",
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


def resolved_metadata_artifact(
    variant: str,
    marketing_version_override: str,
) -> str:
    spec = importlib.util.spec_from_file_location(
        "resolve_testflight_distribution",
        DISTRIBUTION_HELPER,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.resolve_distribution(
        variant,
        marketing_version_override,
    ).metadata_artifact


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
    prior_artifact_minutes_ago: tuple[int, ...] = (),
    completed_prior_run_count: int = 0,
    head_sha: str = "head-sha",
    changed_files: tuple[str, ...] = (),
    blocking_prior_run: bool = False,
    upload_job_starts_late: bool = False,
    zombie_prior_run: bool = False,
    ordering_api_failure: Optional[str] = None,
    compare_api_failure: bool = False,
    artifact_api_failure: bool = False,
    expected_failure: Optional[str] = None,
) -> dict[str, object]:
    decision_job = mapping_block(workflow_text(), "decide", indent=2)
    decision_script = literal_block(decision_job, "script", indent=10)
    effective_variant = input_variant
    if event_name == "schedule":
        if schedule == IOS_SCHEDULES[0]:
            effective_variant = "internal"
        elif schedule == IOS_SCHEDULES[1]:
            effective_variant = "demo"
    try:
        produced_artifact_name = resolved_metadata_artifact(
            effective_variant,
            marketing_version_override,
        )
    except ValueError:
        produced_artifact_name = ""
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
    assert not prior_artifact_minutes_ago or len(
        prior_artifact_minutes_ago
    ) == len(upload_history), "artifact ages must match the upload history"
    run_ids = prior_run_ids or tuple(
        50 - index for index in range(len(upload_history))
    )
    artifact_ages = prior_artifact_minutes_ago or tuple(
        range(len(upload_history))
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
                    "minutesAgo": artifact_ages[run_index],
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
        "completedPriorRunCount": completed_prior_run_count,
        "headSha": head_sha,
        "changedFiles": changed_files,
        "blockingPriorRun": blocking_prior_run,
        "uploadJobStartsLate": upload_job_starts_late,
        "zombiePriorRun": zombie_prior_run,
        "orderingApiFailure": ordering_api_failure,
        "compareApiFailure": compare_api_failure,
        "artifactApiFailure": artifact_api_failure,
    }
    harness = f"""
const scenario = {json.dumps(scenario)};
const outputs = {{}};
const compareCalls = [];
const warnings = [];
const waitCalls = [];
const workflowRunRequests = [];
const artifactRequests = [];
const priorRunStatuses = [];
const uploadJobStatuses = [];
let workflowRunCalls = 0;
let uploadPhase = scenario.blockingPriorRun
  ? (scenario.uploadJobStartsLate ? 0 : 1)
  : 2;
let orderingFailurePending = scenario.orderingApiFailure !== null;
let artifactFailurePending = scenario.artifactApiFailure;
const allPriorRuns = scenario.priorRunPages.flat();
const firstPriorRunId = allPriorRuns[0]?.id;
const priorRuns = (request) => {{
  const page = Number(request.page ?? 1);
  const pageRuns = scenario.priorRunPages[page - 1] ?? [];
  const runs = pageRuns.map((run) => ({{
    id: run.id,
    status:
      scenario.zombiePriorRun && run.id === firstPriorRunId
        ? 'queued'
        : scenario.blockingPriorRun && run.id === firstPriorRunId
          ? 'in_progress'
          : 'completed',
    event: run.event,
    head_sha: run.sha,
    created_at:
      scenario.zombiePriorRun && run.id === firstPriorRunId
        ? '2020-01-01T00:00:00Z'
        : undefined,
  }}));
  const idleRunsBeforePage = (page - 1) * 100;
  const idleRunsOnPage = Math.min(
    Math.max(100 - runs.length, 0),
    Math.max(scenario.completedPriorRunCount - idleRunsBeforePage, 0)
  );
  for (let index = 0; index < idleRunsOnPage; index += 1) {{
    runs.push({{
      id: -1 - idleRunsBeforePage - index,
      status: 'completed',
      event: 'schedule',
      head_sha: `idle-sha-${{idleRunsBeforePage + index}}`,
    }});
  }}
  return runs;
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
        const isZombieRun =
          scenario.zombiePriorRun &&
          priorRun?.id === firstPriorRunId;
        if (isZombieRun) {{
          uploadJobStatuses.push(null);
          return {{ data: {{ jobs: [] }} }};
        }}
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
      listArtifactsForRepo: async (request) => {{
        artifactRequests.push(request);
        if (artifactFailurePending) {{
          artifactFailurePending = false;
          throw new Error('transient artifact failure');
        }}
        const artifacts = allPriorRuns
          .filter((run) => run.artifact === request.name)
          .filter(
            (run) =>
              !scenario.blockingPriorRun ||
              run.id !== firstPriorRunId ||
              uploadPhase === 2
          )
          .map((run) => ({{
            id: run.id,
            name: run.artifact,
            created_at: new Date(
              Date.UTC(2026, 6, 31) - run.minutesAgo * 60_000
            ).toISOString(),
            workflow_run: {{
              id: run.id,
              head_branch: 'main',
              head_sha: run.sha,
            }},
          }}));
        const perPage = Number(request.per_page ?? 30);
        const page = Number(request.page ?? 1);
        const start = (page - 1) * perPage;
        return {{
          data: {{
            total_count: artifacts.length,
            artifacts: artifacts.slice(start, start + perPage),
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
const producedArtifactName = {json.dumps(produced_artifact_name)};
process.stdout.write(JSON.stringify({{
  outputs,
  compareCalls,
  warnings,
  waitCalls,
  workflowRunCalls,
  workflowRunRequests,
  artifactRequests,
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
    if expected_failure is not None:
        assert result.returncode != 0
        assert expected_failure in result.stderr
        return {"error": expected_failure}
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


def test_internal_schedule_polls_every_twenty_minutes() -> None:
    internal_minutes = tuple(
        int(minute)
        for minute in IOS_SCHEDULES[0].split()[0].split(",")
    )

    assert internal_minutes == (7, 27, 47)
    assert tuple(
        later - earlier
        for earlier, later in zip(
            internal_minutes,
            internal_minutes[1:] + (internal_minutes[0] + 60,),
        )
    ) == (20, 20, 20)


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


def test_decision_rejects_unknown_schedule_and_dispatch_variant() -> None:
    expected = "unsupported TestFlight event, schedule, or variant"
    assert run_decision_scenario(
        event_name="schedule",
        schedule="1 2 3 4 5",
        input_variant="",
        expected_failure=expected,
    ) == {"error": expected}
    assert run_decision_scenario(
        event_name="workflow_dispatch",
        input_variant="unknown",
        expected_failure=expected,
    ) == {"error": expected}


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


def test_history_lookup_ignores_long_idle_workflow_run_history() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_upload_pages=((),) * 22
        + ((("base-sha", "ios-testflight-build-metadata"),),),
        completed_prior_run_count=2_200,
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }
    assert result["workflowRunCalls"] == 1
    assert result["uploadJobStatuses"] == []
    assert result["artifactRequests"] == [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "name": "ios-testflight-build-metadata",
            "per_page": 100,
            "page": 1,
        }
    ]


def test_history_lookup_paginates_artifacts_and_selects_newest() -> None:
    older_uploads = tuple(
        (f"older-sha-{index}", "ios-testflight-build-metadata")
        for index in range(100)
    )
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_upload_pages=(
            older_uploads,
            (("newest-sha", "ios-testflight-build-metadata"),),
        ),
        prior_artifact_minutes_ago=tuple(range(200, 100, -1)) + (0,),
        changed_files=("docs/cli-contract.md",),
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "newest-sha",
        "variant": "internal",
    }
    assert [request["page"] for request in result["artifactRequests"]] == [1, 2]
    assert result["compareCalls"] == [
        {
            "owner": "manaflow-ai",
            "repo": "cmux",
            "base": "newest-sha",
            "head": "head-sha",
        }
    ]


def test_scheduled_run_skips_when_upload_history_is_unavailable() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        artifact_api_failure=True,
    )

    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "",
        "variant": "internal",
    }
    assert result["warnings"] == [
        "could not resolve last uploaded sha; skipping scheduled upload"
    ]
    assert result["compareCalls"] == []


def test_manual_run_builds_when_upload_history_is_unavailable() -> None:
    result = run_decision_scenario(
        event_name="workflow_dispatch",
        artifact_api_failure=True,
    )

    assert result["outputs"] == {
        "should_build": "true",
        "last_uploaded_sha": "",
        "variant": "internal",
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
    assert result["workflowRunCalls"] == 2
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
    ]
    assert result["priorRunStatuses"] == [
        "in_progress",
        "in_progress",
    ]
    assert result["uploadJobStatuses"] == [
        "in_progress",
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
        assert result["workflowRunCalls"] == 3
        assert result["uploadJobStatuses"] == [
            "in_progress",
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
    ]
    assert result["uploadJobStatuses"] == []
    assert result["outputs"] == {
        "should_build": "false",
        "last_uploaded_sha": "base-sha",
        "variant": "internal",
    }


def test_ordering_skips_defunct_queued_prior_run() -> None:
    result = run_decision_scenario(
        event_name="schedule",
        schedule=IOS_SCHEDULES[0],
        prior_sha="base-sha",
        changed_files=("ios/cmux/App.swift",),
        zombie_prior_run=True,
    )

    assert result["waitCalls"] == []
    assert any("defunct" in str(warning) for warning in result["warnings"])
    assert result["outputs"] == {
        "should_build": "true",
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

    internal = resolved_metadata_artifact("internal", "")
    demo = resolved_metadata_artifact("demo", "")
    external = resolved_metadata_artifact("internal", "1.2.3")
    assert internal == "ios-testflight-build-metadata"
    assert demo == "ios-testflight-build-metadata-demo"
    assert external == "ios-testflight-build-metadata-override"

    assert "python3 ./ios/scripts/resolve_testflight_distribution.py" in upload
    assert "INPUT_VARIANT: ${{ needs.decide.outputs.variant }}" in upload
    assert (
        "INPUT_MARKETING_VERSION_OVERRIDE: "
        "${{ github.event.inputs.marketing_version_override }}"
        in upload
    )
    assert "IOS_BETA_BUNDLE_ID: ${{ steps.distribution.outputs.bundle_id }}" in upload
    assert "UPLOAD_BUNDLE_ID: ${{ steps.distribution.outputs.bundle_id }}" in upload
    assert "UPLOAD_DISPLAY_NAME: ${{ steps.distribution.outputs.display_name }}" in upload
    assert "UPLOAD_AUDIENCE: ${{ steps.distribution.outputs.audience }}" in upload
    assert "UPLOAD_REVIEW_NOTE: ${{ steps.distribution.outputs.review_note }}" in upload
    assert "name: ${{ steps.distribution.outputs.metadata_artifact }}" in upload
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
    assert "ASSIGN_BUNDLE_ID: ${{ needs.upload.outputs.bundle_id }}" in assignment
    assert assignment.count("needs: [decide, upload]") == 1
    assert (
        "if: github.ref == 'refs/heads/main' "
        "&& needs.upload.result == 'success' "
        "&& needs.upload.outputs.assign_internal_group == '1'"
        in assignment
    )


if __name__ == "__main__":
    test_literal_block_accepts_whitespace_only_lines()
    test_scheduled_uploads_filter_for_ios_affecting_main_changes()
    test_internal_schedule_polls_every_twenty_minutes()
    test_schedule_decision_executes_ios_path_filter()
    test_truncated_schedule_comparison_fails_open()
    test_schedule_comparison_failure_fails_open()
    test_unchanged_scheduled_head_skips_without_comparing()
    test_schedule_decision_routes_demo_cron_to_demo_history()
    test_schedule_decision_routes_internal_cron_to_internal_history()
    test_decision_rejects_unknown_schedule_and_dispatch_variant()
    test_demo_history_skips_newer_internal_artifact()
    test_history_lookup_ignores_long_idle_workflow_run_history()
    test_history_lookup_paginates_artifacts_and_selects_newest()
    test_scheduled_run_skips_when_upload_history_is_unavailable()
    test_manual_run_builds_when_upload_history_is_unavailable()
    test_manual_demo_dispatch_builds_even_when_head_already_uploaded()
    test_manual_override_artifact_is_excluded_from_canonical_history()
    test_scheduled_run_waits_for_an_earlier_upload()
    test_scheduled_run_waits_before_upload_job_exists()
    test_ordering_retries_transient_api_failures()
    test_ordering_ignores_later_active_runs()
    test_ordering_skips_defunct_queued_prior_run()
    test_ordering_includes_manual_current_and_prior_runs()
    test_mapping_keys_normalizes_quoted_yaml_keys()
    test_testflight_notes_use_the_same_ios_path_contract()
    test_scheduled_and_manual_runs_use_independent_concurrency_groups()
    test_automatic_lane_stays_on_cmux_internal_identity()
    print("all iOS TestFlight scheduling tests passed")
