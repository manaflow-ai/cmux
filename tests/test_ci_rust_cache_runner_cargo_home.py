#!/usr/bin/env python3
"""Swatinem/rust-cache never cleans a CARGO_HOME that sibling runners share.

The owned Macs run 7-14 runner instances as one user, so by default every job
shares ~/.cargo. rust-cache's post step (cleanRegistry, cache-all-crates:
false) deletes every crate source in $CARGO_HOME/registry/src. On a shared home
that broke the cargo builds of sibling runners mid-build (2026-11-08: runs
42477732646 and 42478799348 failed with "os error 2" less than a second after
another runner's cleanup began).

So a rust-cache step that can run on a persistent runner must come after a step
that gives the runner its own CARGO_HOME: the runner-cargo-home action, or
setup-cmux-tui-rust, which ends by running it. A job may instead set CARGO_HOME
itself to anything but the shared $HOME/.cargo (job, workflow or step env, or an
earlier step that writes it to GITHUB_ENV), or keep the step off self-hosted runners with
`runner.environment != 'self-hosted'` in its `if`. Jobs whose every runner is a
literal ephemeral Linux or Windows label need nothing. A composite action under
.github/actions can be called from any job, so it needs the step itself.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUST_CACHE = "swatinem/rust-cache@"
OWN_HOME_ACTION = "./.github/actions/runner-cargo-home"
SETUP_ACTION = "./.github/actions/setup-cmux-tui-rust"
SCRIPT = "runner-cargo-home/runner-cargo-home.sh"
NOT_SELF_HOSTED = re.compile(r"runner\.environment\s*!=\s*'self-hosted'")
# Exact shapes of GitHub-hosted and Blacksmith ephemeral Linux/Windows labels.
# Anything else (a suffix such as -glaeda, a custom ubuntu-self-hosted, macOS)
# may be a persistent host that shares HOME with other runner instances.
EPHEMERAL_LABEL = re.compile(
    r"^(ubuntu-(\d{2}\.\d{2}|latest)(-arm)?|windows-(\d{4}|latest)"
    r"|blacksmith-\d+vcpu-(ubuntu-\d{4}(-arm)?|windows-\d{4}))$"
)
MATRIX_REF = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")


def is_rust_cache(step: object) -> bool:
    return isinstance(step, dict) and str(step.get("uses", "")).lower().startswith(RUST_CACHE)


def runner_labels(job: dict) -> list[object] | None:
    """Every label the job's runs-on can be, or None when that is not static."""
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        return None
    labels = runs_on if isinstance(runs_on, list) else [runs_on]
    resolved: list[object] = []
    for label in labels:
        match = MATRIX_REF.match(str(label).strip())
        if not match:
            resolved.append(label)
            continue
        matrix = (job.get("strategy") or {}).get("matrix")
        if not isinstance(matrix, dict):
            return None
        key = match.group(1)
        values = matrix.get(key, [])
        include = matrix.get("include", [])
        if not isinstance(values, list) or not isinstance(include, list):
            return None
        values = list(values) + [entry[key] for entry in include if isinstance(entry, dict) and key in entry]
        if not values:
            return None
        resolved.extend(values)
    return resolved


def ephemeral_only(job: dict) -> bool:
    labels = runner_labels(job)
    if not labels:
        return False
    return all(isinstance(label, str) and "${{" not in label and EPHEMERAL_LABEL.match(label.strip())
               for label in labels)


SHARED_HOME = re.compile(r"(\$\{?HOME\}?|~|\$\{\{\s*env\.HOME\s*\}\})/\.cargo/?(\s|\"|'|$)")


def own_home_value(value: object) -> bool:
    """A CARGO_HOME value that is not the shared $HOME/.cargo (dtolnay/rust-toolchain writes that one)."""
    return not SHARED_HOME.search(f"{value} ")


def sets_cargo_home(env: object) -> bool:
    return isinstance(env, dict) and "CARGO_HOME" in env and own_home_value(env["CARGO_HOME"])


def gives_own_home(step: object) -> bool:
    """Whether this earlier step leaves the job a CARGO_HOME of its own."""
    if not isinstance(step, dict):
        return False
    uses = str(step.get("uses", ""))
    if uses in (OWN_HOME_ACTION, SETUP_ACTION):
        return True
    run = str(step.get("run", ""))
    return "CARGO_HOME" in run and "GITHUB_ENV" in run and own_home_value(run)


def step_label(step: dict) -> str:
    return str(step.get("name") or step.get("uses"))


def steps_failures(where: str, steps: list[object], covered: bool) -> tuple[int, list[str]]:
    found, failures = 0, []
    for index, step in enumerate(steps):
        if not is_rust_cache(step):
            continue
        found += 1
        if covered or sets_cargo_home(step.get("env")) or NOT_SELF_HOSTED.search(str(step.get("if", ""))):
            continue
        if any(gives_own_home(earlier) for earlier in steps[:index]):
            continue
        failures.append(
            f"{where}: '{step_label(step)}' can run on a runner that shares HOME with other runner "
            f"instances; add `uses: {OWN_HOME_ACTION}` before it (after the toolchain install)"
        )
    return found, failures


def workflow_failures(path: Path, document: dict) -> tuple[int, list[str]]:
    found, failures = 0, []
    for job_name, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict) or not isinstance(job.get("steps"), list):
            continue
        covered = ephemeral_only(job) or sets_cargo_home(job.get("env")) or sets_cargo_home(document.get("env"))
        n, errors = steps_failures(f"{path} {job_name}", job["steps"], covered)
        found += n
        failures += errors
    return found, failures


def action_failures(path: Path, document: dict) -> tuple[int, list[str]]:
    return steps_failures(str(path), (document.get("runs") or {}).get("steps") or [], False)


def provider_failures() -> list[str]:
    """The two providers really give the job its own CARGO_HOME, last in setup-cmux-tui-rust."""
    failures = []
    own = yaml.safe_load((ROOT / ".github/actions/runner-cargo-home/action.yml").read_text(encoding="utf-8"))
    if not any(SCRIPT.split("/")[1] in str(s.get("run", "")) for s in own["runs"]["steps"]):
        failures.append("runner-cargo-home/action.yml does not run runner-cargo-home.sh")
    setup = yaml.safe_load((ROOT / ".github/actions/setup-cmux-tui-rust/action.yml").read_text(encoding="utf-8"))
    last = setup["runs"]["steps"][-1]
    if SCRIPT not in str(last.get("run", "")) and last.get("uses") != OWN_HOME_ACTION:
        failures.append("setup-cmux-tui-rust/action.yml must end by running runner-cargo-home.sh")
    if not (ROOT / ".github/actions" / SCRIPT).is_file():
        failures.append(f".github/actions/{SCRIPT} is missing")
    return failures


def self_test() -> list[str]:
    errors = []
    for job, expected in [
        ({"runs-on": "ubuntu-24.04"}, True),
        ({"runs-on": "blacksmith-4vcpu-ubuntu-2404-arm"}, True),
        ({"runs-on": "blacksmith-6vcpu-macos-15"}, False),
        ({"runs-on": "blacksmith-4vcpu-ubuntu-2404-glaeda"}, False),
        ({"runs-on": ["self-hosted", "macOS"]}, False),
        ({"runs-on": "${{ vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}"}, False),
        ({"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"include": [{"runner": "ubuntu-24.04"}]}}}, True),
        ({"runs-on": "${{ matrix.runner }}",
          "strategy": {"matrix": {"include": [{"runner": "ubuntu-24.04"}, {"runner": "macos-26"}]}}}, False),
    ]:
        if ephemeral_only(job) is not expected:
            errors.append(f"self-test: ephemeral_only({job['runs-on']!r}) should be {expected}")
    cache = {"uses": "Swatinem/rust-cache@abc"}
    cases = [
        ("bare rust-cache on a mini", [{"uses": "x/rust-toolchain@1"}, cache], 1),
        ("runner-cargo-home first", [{"uses": OWN_HOME_ACTION}, cache], 0),
        ("setup-cmux-tui-rust first", [{"uses": SETUP_ACTION}, cache], 0),
        ("runner-cargo-home after", [cache, {"uses": OWN_HOME_ACTION}], 1),
        ("CARGO_HOME to GITHUB_ENV", [{"run": 'echo "CARGO_HOME=$RUNNER_TEMP/c" >> "$GITHUB_ENV"'}, cache], 0),
        ("step env", [dict(cache, env={"CARGO_HOME": "/x"})], 0),
        ("step env is the shared home", [dict(cache, env={"CARGO_HOME": "${{ env.HOME }}/.cargo"})], 1),
        ("dtolnay-style shared home to GITHUB_ENV",
         [{"run": 'echo CARGO_HOME=${CARGO_HOME:-"$HOME/.cargo"} >> $GITHUB_ENV'}, cache], 1),
        ("~/.cargo to GITHUB_ENV", [{"run": "echo CARGO_HOME=~/.cargo >> $GITHUB_ENV"}, cache], 1),
        ("never self-hosted", [dict(cache, **{"if": "runner.environment != 'self-hosted' && x"})], 0),
    ]
    for name, steps, want in cases:
        _, failures = steps_failures("self-test", steps, False)
        if len(failures) != want:
            errors.append(f"self-test: {name}: {len(failures)} failures, expected {want}")
    jobs = {"jobs": {"mini": {"runs-on": "macos-26", "steps": [cache]},
                     "hosted": {"runs-on": "ubuntu-24.04", "steps": [cache]},
                     "own": {"runs-on": "macos-26", "env": {"CARGO_HOME": "/x"}, "steps": [cache]}}}
    if len(workflow_failures(Path("self-test.yml"), jobs)[1]) != 1:
        errors.append("self-test: only the macOS job without its own CARGO_HOME should fail")
    return errors


def main() -> int:
    failures = self_test() + provider_failures()
    total = 0
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        found, errors = workflow_failures(path.relative_to(ROOT), document)
        total += found
        failures += errors
    for path in sorted((ROOT / ".github/actions").rglob("action.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        found, errors = action_failures(path.relative_to(ROOT), document)
        total += found
        failures += errors
    if total == 0:
        failures.append("no Swatinem/rust-cache step found; this guard is reading the wrong files")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"ok: {total} rust-cache steps clean only a CARGO_HOME of their own runner")
    return 0


if __name__ == "__main__":
    sys.exit(main())
