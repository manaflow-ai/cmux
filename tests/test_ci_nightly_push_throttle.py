#!/usr/bin/env python3
"""Behavioral contract for the Nightly push throttle in nightly.yml `decide`.

Runs the real `decide` github-script under Node with a mocked GitHub API and
checks that only pushes to main are throttled, by the age of the commit the
`nightly` tag points at, and that every lookup failure builds.
"""

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"

HEAD_SHA = "a" * 40
TAG_SHA = "b" * 40

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
const github = { rest: { git: {
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
} } };
const run = new Function('github', 'context', 'core', 'process',
  `return (async () => {\n${scenario.script}\n})();`);
run(github, context, core, process).then(() => {
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
