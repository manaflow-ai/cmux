#!/usr/bin/env python3
"""Behavioral contract for the Nightly build decision in nightly.yml `decide`.

Runs the real `decide` github-script under Node with a mocked GitHub API and
checks that only pushes to main are throttled, by the age of the commit the
`nightly` tag points at; that a push whose changed paths cannot reach the app
skips the build; and that lookup failures before the first in-flight page build
while partial reads skip the tick. The build-input check
runs the real `scripts/ci/nightly_build_inputs.py`, so the classification it
asserts is the one the workflow gets.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"

HEAD_SHA = "a" * 40
TAG_SHA = "b" * 40


def comparison(paths, **overrides):
    """A complete `nightly`...HEAD comparison touching `paths`."""
    data = {
        "status": "ahead",
        "merge_base_commit": {"sha": TAG_SHA},
        "total_commits": 1,
        "commits": [{"sha": HEAD_SHA}],
        "files": [{"filename": path, "status": "modified"} for path in paths],
    }
    data.update(overrides)
    return data


# The default for every other test: the app itself changed, so the build
# decision is the one the throttle and the publish gates make.
APP_CHANGE = comparison(["Sources/AppDelegate.swift"])
# Two merges that cannot reach the app: the web deployment and a Linux guard.
NEUTRAL_CHANGE = comparison(["web/app/page.tsx", "tests/test_ci_change_areas.py"])

HARNESS = r"""
const scenario = JSON.parse(process.env.SCENARIO);
Date.now = () => scenario.nowMs;
const outputs = {};
const notices = [];
const warnings = [];
const tables = [];
const summary = {
  addHeading: () => summary,
  addTable: (rows) => { tables.push(rows); return summary; },
  write: () => summary,
};
const core = {
  setOutput: (k, v) => { outputs[k] = v; },
  notice: (m) => notices.push(m),
  warning: (m) => warnings.push(m),
  summary,
};
const context = {
  ref: scenario.ref,
  sha: scenario.headSha,
  eventName: scenario.eventName,
  payload: { schedule: scenario.schedule },
  repo: { owner: 'manaflow-ai', repo: 'cmux' },
};
const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });
// scenario.runs (main nightly runs, each with a status) and scenario.jobs (by run id)
// answer the in-flight read; an omitted list means the API answered with no runs.
const actions = {
  listWorkflowRuns: async ({ status, branch }) => {
    if (branch !== 'main') throw new Error(`expected main's runs, got ${branch}`);
    if (scenario.failStatus === status) throw new Error(`failed listing ${status} runs`);
    return { data: (scenario.runs || []).filter((run) => run.status === status) };
  },
  listJobsForWorkflowRun: async ({ run_id }) => ({ data: scenario.jobs[String(run_id)] || [] }),
};
const github = { paginate: async (fn, params, mapFn) => {
  const page = await fn(params);
  const mapped = mapFn ? mapFn(page, 0) : page.data;
  if (scenario.failAfterFirstPageStatus === params.status) {
    throw new Error(`failed listing the next ${params.status} page`);
  }
  return mapped;
}, rest: {
  actions,
  git: {
    getRef: async () => {
      if (!scenario.tagSha) throw notFound();
      return { data: { object: { type: 'commit', sha: scenario.tagSha } } };
    },
    getTag: async () => { throw new Error('unexpected annotated tag'); },
    getCommit: async () => {
      if (scenario.getCommitFails) throw new Error('boom');
      const date = new Date(Date.now() - scenario.tagAgeHours * 3600000).toISOString();
      return { data: { committer: { date } } };
    },
  },
  repos: {
    compareCommitsWithBasehead: async ({ basehead }) => {
      if (!scenario.compare) throw new Error('comparison unavailable');
      if (basehead !== `${scenario.tagSha}...${scenario.headSha}`) {
        throw new Error(`expected a cumulative comparison, got ${basehead}`);
      }
      return { data: scenario.compare };
    },
  },
} };
// Classify with the real script in the real checkout, so the workflow and this
// contract cannot disagree about what reaches the app.
const exec = { getExecOutput: async (command, args, options) => {
  const child = require('node:child_process');
  const result = scenario.classifier
    ? child.spawnSync('bash', ['-c', scenario.classifier],
        { cwd: scenario.root, input: options?.input, encoding: 'utf8' })
    : child.spawnSync(command, args,
        { cwd: scenario.root, input: options?.input, encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options?.ignoreReturnCode) {
    throw new Error(`The process ${command} failed with exit code ${result.status}`);
  }
  return { exitCode: result.status, stdout: result.stdout, stderr: result.stderr };
} };
const run = new Function('github', 'context', 'core', 'process', 'exec',
  `return (async () => {\n${scenario.script}\n})();`);
run(github, context, core, process, exec).then(() => {
  console.log(JSON.stringify({ outputs, notices, warnings, tables }));
}).catch((e) => { console.error(e); process.exit(1); });
"""


def decide_script() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = lines.index("      - name: Decide whether a nightly build is needed")
    script_at = next(
        i for i in range(start, len(lines)) if lines[i].strip() == "script: |"
    )
    body = []
    for line in lines[script_at + 1 :]:
        if line.strip() and not line.startswith(" " * 12):
            break
        body.append(line[12:])
    return "\n".join(body)


def env_value(name: str) -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    marker = f"          {name}: "
    return next(l for l in text.splitlines() if l.startswith(marker))[len(marker) :]


def run_decide(
    *,
    event: str,
    ref: str = "refs/heads/main",
    tag_sha=TAG_SHA,
    tag_age_hours: float = 0.5,
    interval: str = "2",
    get_commit_fails: bool = False,
    schedule: str = "2,17,32,47 * * * *",
    extra_env=None,
    comparison=None,
    classifier=None,
    now_ms: int = 1700000000000,
    main_push_builds: str = "1",
    runs=None,
    jobs=None,
    max_in_flight: str = "3",
    fail_status=None,
    fail_after_first_page_status=None,
):
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "FORCE_BUILD": "false",
        "FAST_BUILD": "false",
        "BUILD_ONLY": "false",
        "SEED_ONLY": "false",
        "COLD_CACHE": "false",
        "PUSH_MIN_INTERVAL_HOURS": interval,
        "MAIN_PUSH_BUILDS": main_push_builds,
        "MAX_IN_FLIGHT": max_in_flight,
        "SCENARIO": json.dumps(
            {
                "script": decide_script(),
                "nowMs": now_ms,
                "ref": ref,
                "headSha": HEAD_SHA,
                "eventName": event,
                "tagSha": tag_sha,
                "tagAgeHours": tag_age_hours,
                "getCommitFails": get_commit_fails,
                "schedule": schedule,
                "compare": APP_CHANGE if comparison is None else comparison,
                "classifier": classifier,
                "root": str(ROOT),
                "runs": runs,
                "jobs": jobs or {},
                "failStatus": fail_status,
                "failAfterFirstPageStatus": fail_after_first_page_status,
            }
        ),
    }
    env.update(extra_env or {})
    result = subprocess.run(
        [shutil.which("node") or "node", "-e", HARNESS],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def should_build(result) -> bool:
    return result["outputs"]["should_build"] == "true"


def summary_values(result) -> dict:
    return {row[0]["data"]: row[1] for row in result["tables"][0]}


def ci_scripts():
    """Import the CI scripts without leaving `scripts/ci` on the import path.

    `main()` runs every test in this file in one process, so an entry left
    behind here would sit in front of the import path for the tests after it.
    Nothing in `scripts/ci` shadows a module they import today; restoring the
    path is what keeps that true. `nightly_build_inputs` prepends the same
    directory when it is imported, so put the whole list back rather than
    dropping one copy of the entry.
    """
    original_path = sys.path.copy()
    try:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import detect_ci_change_areas as detect
        import nightly_build_inputs as nightly
    finally:
        sys.path[:] = original_path
    return detect, nightly


def test_decision_summary_distinguishes_push_throttle_from_manual_build() -> None:
    push = run_decide(event="push", tag_age_hours=0.5)
    assert summary_values(push)["app build selected"] == "false"
    assert summary_values(push)["publish app this run"] == "false"
    assert summary_values(push)["push minimum commit age (hours)"] == "2"
    assert "Skipping this push" in summary_values(push)["reason"]
    manual = run_decide(event="workflow_dispatch", tag_age_hours=0.5)
    assert should_build(manual)
    assert summary_values(manual)["app build selected"] == "true"
    assert "bypasses the push throttle" in summary_values(manual)["reason"]


def test_manual_same_commit_explains_force_without_changing_the_guard() -> None:
    same = run_decide(event="workflow_dispatch", tag_sha=HEAD_SHA)
    assert not should_build(same)
    assert "already published" in summary_values(same)["reason"]
    assert "force=true" in same["notices"][0]
    forced = run_decide(event="workflow_dispatch", tag_sha=HEAD_SHA,
                        extra_env={"FORCE_BUILD": "true"})
    assert should_build(forced)
    assert summary_values(forced)["app build selected"] == "true"


def test_cache_only_modes_explain_why_no_app_is_built() -> None:
    seed = run_decide(event="workflow_dispatch", extra_env={"SEED_ONLY": "true"})
    assert not should_build(seed)
    assert "cache-only" in summary_values(seed)["reason"]
    warm = run_decide(event="schedule", schedule="17 */6 * * *")
    # Keep the existing output: downstream schedule conditions own routing.
    assert should_build(warm)
    assert warm["outputs"]["should_publish"] == "true"
    assert summary_values(warm)["app build selected"] == "false"
    assert summary_values(warm)["publish app this run"] == "false"
    assert "cache warmup" in summary_values(warm)["reason"]
    daily = run_decide(event="schedule", schedule="2,17,32,47 * * * *")
    assert summary_values(daily)["app build selected"] == "true"


def test_push_skips_when_no_changed_path_reaches_the_app() -> None:
    result = run_decide(event="push", interval="0", comparison=NEUTRAL_CHANGE)
    assert not should_build(result)
    assert summary_values(result)["app build selected"] == "false"
    assert summary_values(result)["app build inputs changed"] == "false"
    assert "nothing that reaches the app changed" in summary_values(result)["reason"]
    assert "force=true" in result["notices"][0]
    assert not result["warnings"]


def test_paths_that_reach_the_app_still_build() -> None:
    for path in [
        "Sources/AppDelegate.swift",
        "Resources/bin/open-app",
        "cmux.xcodeproj/project.pbxproj",
        "package.json",
        # The app bundles skills/cmux-cua as a folder resource, so its
        # Markdown ships while other skills' Markdown does not.
        "skills/cmux-cua/SKILL.md",
        # Nightly signs and publishes; those helpers run in no PR lane.
        "scripts/sign-cmux-bundle.sh",
        "scripts/sparkle_generate_appcast.sh",
        ".github/workflows/nightly.yml",
        # Bundled into cmux.app and published beside it; no pull-request
        # macOS lane builds either, so the router alone calls them neutral.
        "cmux-tui/src/main.rs",
        "daemon/remote/src/lib.rs",
        # An unrecognized path is never assumed neutral.
        "unknown/new-directory/file.txt",
    ]:
        built = run_decide(event="push", interval="0", comparison=comparison([path]))
        assert should_build(built), f"{path} must rebuild the app"
        assert summary_values(built)["app build inputs changed"] == "true"
    mixed = run_decide(event="push", interval="0",
                       comparison=comparison(["web/app/page.tsx", "Sources/AppDelegate.swift"]))
    assert should_build(mixed)


def test_skill_markdown_outside_the_bundled_skill_is_neutral() -> None:
    assert not should_build(run_decide(event="push", interval="0",
                                       comparison=comparison(["skills/cmux-testing/SKILL.md"])))


def test_renames_are_classified_by_both_names() -> None:
    moved_out = comparison(["docs/moved.md"], files=[
        {"filename": "docs/moved.md", "status": "renamed",
         "previous_filename": "Sources/Moved.swift"},
    ])
    assert should_build(run_decide(event="push", interval="0", comparison=moved_out))
    moved_in = comparison([], files=[
        {"filename": "Sources/Moved.swift", "status": "renamed",
         "previous_filename": "docs/moved.md"},
    ])
    assert should_build(run_decide(event="push", interval="0", comparison=moved_in))


def test_force_and_manual_dispatch_bypass_the_input_check() -> None:
    forced = run_decide(event="push", interval="0", comparison=NEUTRAL_CHANGE,
                        extra_env={"FORCE_BUILD": "true"})
    assert should_build(forced)
    manual = run_decide(event="workflow_dispatch", interval="0", comparison=NEUTRAL_CHANGE)
    assert should_build(manual)
    assert summary_values(manual)["app build inputs changed"] == "(not checked)"


# 2026-11-25T08:17:00Z, 08:37:00Z and 09:17:00Z.
AT_0817 = 1795594620000
AT_0837 = AT_0817 + 20 * 60_000
AT_0917 = 1795598220000
BACKSTOP = "5 8 * * *"


def test_the_daily_catch_up_still_builds_as_a_backstop() -> None:
    """One delayed daily backstop bounds the cost of a path this check gets wrong."""
    daily = run_decide(event="schedule", schedule=BACKSTOP, interval="0",
                       comparison=NEUTRAL_CHANGE, now_ms=AT_0817)
    assert should_build(daily)
    assert summary_values(daily)["app build inputs changed"] == "(not checked)"
    delayed = run_decide(event="schedule", schedule=BACKSTOP, interval="0",
                         comparison=NEUTRAL_CHANGE, now_ms=AT_0837)
    assert should_build(delayed)
    assert summary_values(delayed)["app build inputs changed"] == "(not checked)"
    # Nothing at all changed: the published-commit check skips it as before.
    idle = run_decide(event="schedule", schedule="2,17,32,47 * * * *", interval="0",
                      tag_sha=HEAD_SHA)
    assert not should_build(idle)
    assert "already published" in summary_values(idle)["reason"]
    warm = run_decide(event="schedule", schedule="17 */6 * * *", interval="0",
                      comparison=NEUTRAL_CHANGE)
    assert should_build(warm), "the cache warmup keeps its routing output"
    assert summary_values(warm)["app build inputs changed"] == "(not checked)"


def test_what_the_nightly_ships_is_read_back_from_the_project() -> None:
    """The bundled set is derived, not listed, so a new resource cannot slip."""
    detect, nightly = ci_scripts()

    bundled = nightly.bundled_paths(ROOT)
    # The derivation finds the folder resource the router already knows about,
    # which is what shows it reads the real bundling phases.
    assert "skills/cmux-cua" in bundled
    # And it finds the two the router calls neutral: each needs no Release
    # compile, so `release_build` alone would let a change to them skip.
    for path in ("Resources/bin/open", "Resources/bin/cmux-claude-wrapper"):
        assert path in bundled, f"{path} is bundled but was not derived"
        assert not detect.classify_files([path]).release_build
        assert nightly.build_inputs_changed([path])[0]

    # The cmux-cli product is copied into the bundle, so CLI sources ship
    # without a Release compile ever covering them.
    assert not detect.classify_files(["CLI/cmux_open.swift"]).release_build
    assert nightly.build_inputs_changed(["CLI/cmux_open.swift"])[0]

    # The resolver's path list decides which client gets bundled.
    tui = nightly.tui_client_paths(ROOT)
    assert {"cmux-tui", ".github/workflows/cmux-tui-artifacts.yml",
            ".github/workflows/cmux-tui-build-package.yml"} <= tui
    for path in (".github/workflows/cmux-tui-artifacts.yml", "cmux-tui/src/main.rs"):
        assert nightly.build_inputs_changed([path])[0], f"{path} must rebuild"

    consumer = "scripts/build_remote_daemon_release_assets.sh"
    assert nightly.NIGHTLY_SHIPPED_SOURCES == ("daemon/remote/",)
    assert consumer in WORKFLOW.read_text(encoding="utf-8"), (
        f"the Nightly no longer runs {consumer}; drop daemon/remote/"
    )
    assert not detect.classify_files(["daemon/remote/src/lib.rs"]).release_build
    assert nightly.build_inputs_changed(["daemon/remote/src/lib.rs"])[0]


def test_decide_checks_out_before_it_classifies() -> None:
    """Without the checkout the gate silently never fires."""
    import yaml

    steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["decide"]["steps"]
    names = [step.get("id") or step.get("uses", "") for step in steps]
    checkout = next(i for i, n in enumerate(names) if n.startswith("actions/checkout@"))
    assert checkout < names.index("decide"), "decide must classify a checked-out tree"


def test_a_failing_classifier_builds() -> None:
    """The PR claims a fail-open here; drive it rather than assume it."""
    for command in ("false", "printf 'not json\\n'"):
        result = run_decide(event="push", interval="0", comparison=NEUTRAL_CHANGE,
                            classifier=command)
        assert should_build(result), f"{command} must rebuild the app"
        assert result["warnings"]


def test_a_partial_in_flight_read_skips_the_tick() -> None:
    result = run_decide(
        event="schedule",
        schedule="2,17,32,47 * * * *",
        runs=[],
        comparison=APP_CHANGE,
        fail_after_first_page_status="in_progress",
    )
    assert not should_build(result)
    assert "finish enumerating main nightly runs" in result["warnings"][0]


def test_a_first_page_in_flight_read_skips_the_tick() -> None:
    result = run_decide(
        event="schedule",
        schedule="2,17,32,47 * * * *",
        runs=[],
        comparison=APP_CHANGE,
        fail_status="in_progress",
    )
    assert not should_build(result)
    assert "finish enumerating main nightly runs" in result["warnings"][0]


def test_an_unproven_comparison_builds() -> None:
    for unusable in [
        # Not a fast-forward from the published commit, so the file list does
        # not describe the whole gap.
        comparison(["web/app/page.tsx"], status="diverged"),
        comparison(["web/app/page.tsx"], merge_base_commit={"sha": "c" * 40}),
        # GitHub truncates the list past 300 files.
        comparison(["web/app/page.tsx"] * 300),
        # No file list at all, or a comparison the API would not return.
        comparison([], files=None),
        comparison([]),
        {},
        # The comparison request itself failed.
        False,
    ]:
        result = run_decide(event="push", interval="0", comparison=unusable)
        assert should_build(result), f"{unusable} must rebuild the app"
    assert run_decide(event="push", interval="0", comparison=False)["warnings"]


def test_default_interval_is_two_hours_and_overridable() -> None:
    assert env_value("PUSH_MIN_INTERVAL_HOURS") == (
        "${{ vars.NIGHTLY_PUSH_MIN_INTERVAL_HOURS || '2' }}"
    )


def test_push_to_main_skips_while_published_commit_is_young() -> None:
    result = run_decide(event="push", tag_age_hours=0.5)
    assert not should_build(result)
    assert result["outputs"]["should_publish"] == "true"
    assert result["outputs"]["head_sha"] == HEAD_SHA
    assert len(result["notices"]) == 1 and "Skipping this push" in result["notices"][0]


def test_push_to_main_builds_once_published_commit_is_old_enough() -> None:
    assert not should_build(run_decide(event="push", tag_age_hours=1.999))
    assert should_build(run_decide(event="push", tag_age_hours=2))
    assert should_build(run_decide(event="push", tag_age_hours=2.5))


def test_non_default_interval_changes_the_push_decision() -> None:
    assert should_build(run_decide(event="push", tag_age_hours=2.5, interval="2"))
    assert not should_build(run_decide(event="push", tag_age_hours=2.5, interval="3"))


def test_zero_or_invalid_interval_restores_publish_every_push() -> None:
    assert should_build(run_decide(event="push", interval="0"))
    assert should_build(run_decide(event="push", interval="not-a-number"))


def test_lookup_failures_build() -> None:
    result = run_decide(event="push", get_commit_fails=True)
    assert should_build(result)
    assert result["warnings"]
    assert should_build(run_decide(event="push", tag_sha=None))


def test_same_commit_still_skips_as_before() -> None:
    assert not should_build(
        run_decide(event="push", tag_sha=HEAD_SHA, tag_age_hours=2.5)
    )


def test_schedule_dispatch_and_rc_are_not_throttled() -> None:
    assert should_build(run_decide(event="schedule", tag_age_hours=0.1))
    assert should_build(run_decide(event="workflow_dispatch", tag_age_hours=0.1))
    assert should_build(
        run_decide(event="push", ref="refs/heads/rc/v1.2.3", tag_age_hours=0.1)
    )


def test_main_push_builds_nothing_and_the_hourly_tick_publishes() -> None:
    """Leo, 2026-11-25: NIGHTLY should move at evenly spaced cutovers, not bunch up after a stall."""
    assert env_value("MAIN_PUSH_BUILDS") == "${{ vars.NIGHTLY_MAIN_PUSH_BUILDS || '0' }}"
    push = run_decide(event="push", interval="0", tag_age_hours=5, main_push_builds="0")
    assert not should_build(push)
    assert push["outputs"]["should_publish"] == "true"
    assert "15-minute tick" in summary_values(push)["reason"]
    # RC pushes still publish every push; force and manual dispatch still build.
    assert should_build(run_decide(event="push", ref="refs/heads/rc/v1.2.3", main_push_builds="0"))
    assert should_build(run_decide(event="push", interval="0", main_push_builds="0",
                                   extra_env={"FORCE_BUILD": "true"}))
    assert should_build(run_decide(event="workflow_dispatch", main_push_builds="0"))
    tick = run_decide(event="schedule", schedule="2,17,32,47 * * * *", main_push_builds="0", now_ms=AT_0917)
    assert should_build(tick)
    assert summary_values(tick)["app build selected"] == "true"


def test_the_hourly_tick_skips_when_no_app_input_changed() -> None:
    tick = run_decide(event="schedule", schedule="2,17,32,47 * * * *", interval="0",
                      comparison=NEUTRAL_CHANGE, now_ms=AT_0917)
    assert not should_build(tick)
    assert "nothing that reaches the app changed" in summary_values(tick)["reason"]


def test_the_workflow_runs_main_app_builds_on_the_hourly_tick() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert 'cron: "2,17,32,47 * * * *"' in text
    assert "47 8 * * *" not in text


TICK = "2,17,32,47 * * * *"


def building_run(run_id: int, sha: str, status: str = "in_progress") -> tuple[dict, list]:
    """A main tick run whose app build is under way, and its jobs."""
    run = {"id": run_id, "head_branch": "main", "event": "schedule", "head_sha": sha, "status": status}
    return run, [{"name": "build-nightly-app", "status": "in_progress", "conclusion": None}]


def in_flight(*specs) -> dict:
    runs, jobs = [], {}
    for run_id, sha in specs:
        run, run_jobs = building_run(run_id, sha)
        runs.append(run)
        jobs[str(run_id)] = run_jobs
    return {"runs": runs, "jobs": jobs}


def tick_minutes() -> list[int]:
    """The minutes past the hour the main app tick fires, read from the workflow."""
    text = WORKFLOW.read_text(encoding="utf-8")
    assert f'cron: "{TICK}"' in text
    return sorted(int(m) for m in TICK.split()[0].split(","))


def main_push_starts_a_run() -> bool:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = lines.index("  push:")
    block = []
    for line in lines[start + 1:]:
        if line and not line.startswith("    "):
            break
        block.append(line.strip())
    return "- main" in block


def test_a_burst_of_ten_pushes_in_five_minutes_starts_exactly_one_run() -> None:
    """Leo, 2026-11-25: "every commit to main starts its own nightly run, so 7 or more run at once.
    but why? prevent dumb shit like this" and "shouldnt we have like a 10 or 15 or 20 or 30 minute
    timer per?". A push to main starts no run; the 15-minute tick starts one, for the newest commit."""
    assert not main_push_starts_a_run(), "a push to main must not start a Nightly run"
    minutes = tick_minutes()
    gaps = [(b - a) for a, b in zip(minutes, minutes[1:] + [minutes[0] + 60])]
    assert gaps == [15] * len(gaps), gaps
    # Ten pushes from every starting second of the hour, one each 30 s: the runs
    # started from the first push until the build after them are the pushes'
    # (none) plus the ticks in that 15-minute window, exactly one, wherever it falls.
    for first in range(0, 3600, 30):
        pushes = [first + 30 * i for i in range(10)]
        assert pushes[-1] - pushes[0] <= 300
        window = range(first, first + 15 * 60)
        ticks = [s for s in window if s % 60 == 0 and (s // 60) % 60 in minutes]
        assert len(ticks) == 1, (first, ticks)
    # That one tick builds the newest commit.
    tick = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, **in_flight())
    assert should_build(tick)
    assert summary_values(tick)["main app builds in flight"] == "0 (at most 3)"


def test_a_requested_main_run_counts_toward_the_in_flight_cap() -> None:
    runs = in_flight((1, "c" * 40))
    # GitHub exposes a newly accepted scheduled run as `requested` before it
    # becomes queued. It still owns a future app build and must reserve one
    # of the cap's slots.
    runs["runs"][0]["status"] = "requested"
    result = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917,
                        max_in_flight="1", **runs)
    assert not should_build(result)
    assert "1 main app builds are already in flight" in summary_values(result)["reason"]


def test_a_tick_builds_nothing_while_three_main_builds_are_in_flight() -> None:
    full = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917,
                      **in_flight((1, "c" * 40), (2, "d" * 40), (3, "e" * 40)))
    assert not should_build(full)
    reason = summary_values(full)["reason"]
    assert "3 main app builds are already in flight" in reason and "runs 1, 2, 3" in reason
    assert "next 15-minute tick" in reason
    two = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917,
                     **in_flight((1, "c" * 40), (2, "d" * 40)))
    assert should_build(two)
    # The cap is a variable; `0` turns it off.
    off = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, max_in_flight="0",
                     **in_flight((1, "c" * 40), (2, "d" * 40), (3, "e" * 40)))
    assert should_build(off)
    assert env_value("MAX_IN_FLIGHT") == "${{ vars.NIGHTLY_MAIN_MAX_IN_FLIGHT || '3' }}"


def test_a_run_that_built_nothing_or_failed_is_not_in_flight() -> None:
    runs = in_flight((1, "c" * 40), (2, "d" * 40), (3, "e" * 40))
    runs["jobs"]["2"] = [{"name": "build-nightly-app", "status": "completed", "conclusion": "skipped"}]
    runs["jobs"]["3"] = [{"name": "build-nightly-app", "status": "completed", "conclusion": "failure"}]
    assert should_build(run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, **runs))


def test_a_tick_of_a_commit_already_building_is_a_duplicate_not_a_cap() -> None:
    dup = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, **in_flight((7, HEAD_SHA)))
    assert not should_build(dup)
    assert summary_values(dup)["duplicate of run"] == "7"


def test_a_failed_in_flight_read_skips_the_tick() -> None:
    result = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917,
                        runs=in_flight((1, "c" * 40))["runs"],
                        jobs={"1": in_flight((1, "c" * 40))["jobs"]["1"]},
                        fail_status="queued")
    assert not should_build(result)
    assert "complete main-run list" in summary_values(result)["reason"]
    assert result["warnings"]


def test_an_unavailable_in_flight_read_does_not_change_non_tick_liveness() -> None:
    assert should_build(run_decide(event="push", interval="0"))


def waiting_for_runner(run_id: int, sha: str) -> tuple[dict, list]:
    """A run decide chose to build whose app job does not exist yet: its runner pick waits on a Mac."""
    run = {"id": run_id, "head_branch": "main", "event": "schedule", "head_sha": sha, "status": "queued"}
    return run, [
        {"name": "decide", "status": "completed", "conclusion": "success"},
        {"name": "pick-nightly-app-runner", "status": "queued", "conclusion": None},
        {"name": "build-nightly-ghostty-cli-helper", "status": "queued", "conclusion": None},
    ]


def test_a_run_still_waiting_for_its_runner_counts_as_building() -> None:
    """11-25 17:49Z: ticks at 17:35 and 17:49 both started builds of a06e5975, because the first
    had no build-nightly-app job yet (pick-nightly-app-runner was waiting on the Mac pool)."""
    run, jobs = waiting_for_runner(7, HEAD_SHA)
    dup = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, runs=[run], jobs={"7": jobs})
    assert not should_build(dup)
    assert summary_values(dup)["duplicate of run"] == "7"
    runs = in_flight((1, "c" * 40), (2, "d" * 40))
    run, jobs = waiting_for_runner(3, "e" * 40)
    runs["runs"].append(run)
    runs["jobs"]["3"] = jobs
    assert not should_build(run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, **runs))
    # A run that chose not to build has its pick job skipped: it is not in flight.
    run, jobs = waiting_for_runner(7, HEAD_SHA)
    jobs[1] = {"name": "pick-nightly-app-runner", "status": "completed", "conclusion": "skipped"}
    assert should_build(run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, runs=[run], jobs={"7": jobs}))


def test_a_run_between_its_decide_and_its_pick_job_counts_as_building() -> None:
    """Run 45668811281's decide ended at 17:54Z and GitHub created its pick job seconds later. A
    tick reading in that gap saw a run with only `decide` and counted nothing."""
    run, jobs = waiting_for_runner(7, HEAD_SHA)
    decided_only = jobs[:1]
    dup = run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, runs=[run], jobs={"7": decided_only})
    assert not should_build(dup)
    assert summary_values(dup)["duplicate of run"] == "7"
    runs = in_flight((1, "c" * 40), (2, "d" * 40))
    run, jobs = waiting_for_runner(3, "e" * 40)
    runs["runs"].append(run)
    runs["jobs"]["3"] = jobs[:1]
    assert not should_build(run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, **runs))
    # A run whose decide is still queued or failed has started nothing.
    for state in ({"status": "queued", "conclusion": None}, {"status": "completed", "conclusion": "failure"}):
        run, jobs = waiting_for_runner(7, HEAD_SHA)
        jobs = [{"name": "decide", **state}]
        assert should_build(run_decide(event="schedule", schedule=TICK, now_ms=AT_0917, runs=[run], jobs={"7": jobs}))


def test_main_app_ticks_decide_one_at_a_time() -> None:
    """11-25: with the decide runner pool stalled, ticks queued with decide pending, then decided
    together; none saw the others' app jobs, so five main runs were in flight against a cap of 3.
    The main app ticks share one decide concurrency group (one running, one pending, nothing running
    cancelled); every other run, including the six-hour cache warmup, keeps a group of its own."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = lines.index("  decide:")
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("  ") and not lines[i].startswith("   "))
    block = lines[start:end]
    group = next(line for line in block if line.startswith("      group:"))
    assert "'nightly-main-tick-decide'" in group
    assert "github.event_name == 'schedule' && github.ref == 'refs/heads/main'" in group
    assert "github.event.schedule != '17 */6 * * *'" in group
    assert "format('nightly-decide-{0}', github.run_id)" in group
    i = block.index(group)
    assert block[i - 1] == "    concurrency:" and block[i + 1] == "      cancel-in-progress: false"


def test_each_main_tick_has_its_own_concurrency_group() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "github.event_name == 'schedule' && format('main-tick-{0}', github.run_id)" in text
    assert f'cron: "{BACKSTOP}"' in text


def main() -> None:
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: nightly push throttle")


if __name__ == "__main__":
    main()
