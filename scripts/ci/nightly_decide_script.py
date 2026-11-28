#!/usr/bin/env python3
"""Write nightly.yml decide's github-script body as a CommonJS module for decide-main.

decide-main (main's first-attempt decide, on the glaeda-route App's own read budget) runs
decide's own script, read from the same commit's workflow file, so the two jobs cannot drift.
The one change: the module does not install gh_budget_wait.cjs; decide-main's step installs it, with
GITHUB_TOKEN (SPARE_READ_TOKEN) as its spare client, on the line the scheduled-call guard reads
(tests/test_scheduled_workflow_gh_retry.py). Installing it twice would nest every retry.
Standard library only (the JIT runner has no PyYAML): the script is the `script: |` block of
the step `id: decide` in `jobs.decide`; tests/test_ci_nightly_decide_main.py checks it against
a YAML parse.

usage: nightly_decide_script.py WORKFLOW OUT
"""
import sys
from pathlib import Path

INSTALL = "require(process.env.GH_BUDGET_WAIT_JS).install({ github, core });"
SPARE = ("require(process.env.GH_BUDGET_WAIT_JS).install({ github, core, spare: process.env.SPARE_READ_TOKEN"
         " ? getOctokit(process.env.SPARE_READ_TOKEN) : undefined });")
STRIPPED = "// gh_budget_wait.cjs: installed by decide-main's step, with GITHUB_TOKEN as its spare."
ARGS = "{ github, context, core, exec, getOctokit }"
INDENT = " " * 12


def raw_script(workflow: str) -> str:
    lines = workflow.splitlines()
    try:
        start = lines.index("  decide:")
    except ValueError:
        raise SystemExit("no jobs.decide in the workflow")
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("  ") and not lines[i].startswith("   ") and lines[i].strip()
                and not lines[i].lstrip().startswith("#")), len(lines))
    job = lines[start:end]
    ids = [i for i, line in enumerate(job) if line == "        id: decide"]
    if len(ids) != 1:
        raise SystemExit(f"expected one `id: decide` step in jobs.decide, found {len(ids)}")
    step_end = next((i for i in range(ids[0] + 1, len(job)) if job[i].startswith("      - ")), len(job))
    heads = [i for i in range(ids[0], step_end) if job[i] == "          script: |"]
    if len(heads) != 1:
        raise SystemExit("decide's step has no `script: |` block")
    body = []
    for line in job[heads[0] + 1:step_end]:
        if line.strip() and not line.startswith(INDENT):
            break
        body.append(line[len(INDENT):] if line.strip() else "")
    while body and not body[-1]:
        body.pop()
    return "\n".join(body) + "\n"


def decide_script(workflow: str) -> str:
    script = raw_script(workflow)
    if script.count(f"if (process.env.GH_BUDGET_WAIT_JS) {INSTALL}") != 1:
        raise SystemExit("decide's script no longer installs gh_budget_wait.cjs on one line")
    return script.replace(f"if (process.env.GH_BUDGET_WAIT_JS) {INSTALL}", STRIPPED, 1)


def module(script: str) -> str:
    return f"module.exports = async ({ARGS}) => {{\n{script}\n}};\n"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    Path(argv[2]).write_text(module(decide_script(Path(argv[1]).read_text())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
