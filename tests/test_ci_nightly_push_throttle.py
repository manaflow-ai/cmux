#!/usr/bin/env python3
"""Behavioral contract for the Nightly build decision in nightly.yml `decide`.

Runs the real `decide` github-script under Node with a mocked GitHub API and
checks that only pushes to main are throttled, by the age of the commit the
`nightly` tag points at; that a push whose changed paths cannot reach the app
skips the build; and that every lookup failure builds. The build-input check
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
const github = { rest: {
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
    schedule: str = "47 8 * * *",
    extra_env=None,
    comparison=None,
    classifier=None,
):
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "FORCE_BUILD": "false",
        "FAST_BUILD": "false",
        "BUILD_ONLY": "false",
        "SEED_ONLY": "false",
        "COLD_CACHE": "false",
        "PUSH_MIN_INTERVAL_HOURS": interval,
        "SCENARIO": json.dumps(
            {
                "script": decide_script(),
                "nowMs": 1700000000000,
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
    daily = run_decide(event="schedule", schedule="47 8 * * *")
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


def test_the_daily_catch_up_still_builds_as_a_backstop() -> None:
    """One build a day bounds the cost of a path this check gets wrong."""
    daily = run_decide(event="schedule", schedule="47 8 * * *", interval="0",
                       comparison=NEUTRAL_CHANGE)
    assert should_build(daily)
    assert summary_values(daily)["app build inputs changed"] == "(not checked)"
    # Nothing at all changed: the published-commit check skips it as before.
    idle = run_decide(event="schedule", schedule="47 8 * * *", interval="0",
                      tag_sha=HEAD_SHA)
    assert not should_build(idle)
    assert "already published" in summary_values(idle)["reason"]
    warm = run_decide(event="schedule", schedule="17 */6 * * *", interval="0",
                      comparison=NEUTRAL_CHANGE)
    assert should_build(warm), "the cache warmup keeps its routing output"
    assert summary_values(warm)["app build inputs changed"] == "(not checked)"


def test_what_the_nightly_ships_is_read_back_from_the_project() -> None:
    """The bundled set is derived, not listed, so a new resource cannot slip."""
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import detect_ci_change_areas as detect
    import nightly_build_inputs as nightly

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


def main() -> None:
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: nightly push throttle")


if __name__ == "__main__":
    main()
