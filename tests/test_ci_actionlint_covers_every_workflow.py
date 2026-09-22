#!/usr/bin/env python3
"""actionlint must be pointed at the repository, not at a list of files.

Before this guard, the lint step named two workflows out of 89. A list is the
wrong shape for this job: the workflows it omits are exactly the ones nobody
remembered, and a list cannot omit a file loudly. Running actionlint with no
file arguments makes it discover every workflow itself, so a workflow added
tomorrow is linted tomorrow.

That only holds if two things stay true, which is what this checks: the lint
invocation keeps taking no paths, and it runs from a workflow with no path
filter -- a lint that only fires when certain files change cannot see a
workflow that was broken by an edit somewhere else.

Suppressions are allowed, but only in .github/actionlint.yaml, where every one
of them is visible together and next to a reason. This file pins the set, so
adding a suppression is an edit to a test rather than a line lost in a config.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
LINT_WORKFLOW = WORKFLOW_DIR / "testbox-broker-guard.yml"
CONFIG = ROOT / ".github" / "actionlint.yaml"

# Files actionlint is allowed to skip a rule in. An entry here is a deferred
# defect, not an exemption: the reason belongs beside it in actionlint.yaml.
SUPPRESSED = {".github/workflows/test-ios.yml"}

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"ok: {message}")
    else:
        failures.append(message)
        print(f"FAIL: {message}")


def lint_step(text: str) -> str:
    start = text.find("      - name: Lint every workflow")
    if start == -1:
        return ""
    end = text.find("\n      - name: ", start + 1)
    return text[start:] if end == -1 else text[start:end]


def main() -> int:
    text = LINT_WORKFLOW.read_text(encoding="utf-8")
    step = lint_step(text)
    check(bool(step), "testbox-broker-guard.yml has a `Lint every workflow` step")

    invocation = [
        line.strip()
        for line in step.splitlines()
        if '"$RUNNER_TEMP/actionlint"' in line
    ]
    check(
        invocation == ['"$RUNNER_TEMP/actionlint"'],
        f"actionlint is invoked with no file arguments (found {invocation})",
    )
    check(
        "SHELLCHECK_OPTS" in step,
        "the shellcheck severity floor is set explicitly rather than inherited",
    )
    check(
        "./scripts/ci/install-actionlint.sh" in step and "ACTIONLINT_SHA256:" in step,
        "the linter is still the pinned, checksum-verified download",
    )

    # A lint behind a paths filter is a lint that misses the workflow broken by
    # an edit to some other file.
    trigger = text[: text.index("\njobs:")]
    check(
        "pull_request:\n" in trigger and "paths:" not in trigger,
        "the lint runs on every pull request with no path filter",
    )

    config = CONFIG.read_text(encoding="utf-8")
    suppressed = {
        line.strip().rstrip(":")
        for line in config.splitlines()
        if line.startswith("  .github/workflows/")
    }
    check(
        suppressed == SUPPRESSED,
        f"the suppression list is unchanged (config has {sorted(suppressed)}, "
        f"this test expects {sorted(SUPPRESSED)})",
    )
    for path in sorted(suppressed):
        check(
            (ROOT / path).exists(),
            f"{path} is suppressed in actionlint.yaml and still exists",
        )

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nactionlint covers every workflow")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
