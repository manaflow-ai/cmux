"""cmux-next Mac pull request jobs on a label the CI controller grants (CI v2 step 9).

Leo: "i thought we were only gonna label things cmux-linux and therefore likewise cmux-mac?" A Mac's asker
sees free capacity, asks the controller, and gets a one-job JIT runner carrying the job's labels, sized by
the scheduler, so the controller decides both its own ci-steps work and GitHub's Mac jobs on the same Macs
instead of the two queues starving each other.

The switch is SWITCH_FILE, read from the trusted base by cmux-next.yml's macos-placement (and by
cmux-next-pr-autofix.yml's action-areas, for action-exports):

    {"jobs": ["generated-files"], "per_run": false}

`jobs` names the job ids that take a grant; empty (or the file missing or malformed) is off,
and every route is what it was. A job id moves one job at a time, the heaviest first. `per_run` false gives
plain `cmux-mac` (the CI v2 lead's ruling, 2026-11-21); true gives the opt-in per-run label
`cmux-<run_id>-<run_attempt>-mac`, which no standing runner carries. Either rides with `xcode-<version>`
from the job's Xcode path (vars.CMUX_CI_XCODE_APP_MACOS_26), which the controller matches to a Mac that
has it.

Only a same-repository pull request in manaflow-ai takes a grant; forks keep their own labels.

`python3 scripts/ci/mac_grants.py` writes to $GITHUB_OUTPUT:
    grant_runner=<JSON label array>   ("" when no grant)
    grant_jobs=" generated-files "    (space-padded for contains(); "" when no grant)
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable, Mapping

SWITCH_FILE = Path(__file__).with_name("mac-grants.json")
OWNER = "manaflow-ai"
MAC_LABEL = "cmux-mac"
_JOB = re.compile(r"[a-z0-9][a-z0-9_-]*")
_XCODE = re.compile(r"(?:-xcode-|(?:^|/)Xcode[_-])(?P<version>[0-9]+(?:\.[0-9]+)*)(?:\.app)?(?:/|$)")


def read_switch(path: Path | str | None = None) -> dict:
    """The switch as {"jobs": [...], "per_run": bool}; a missing or malformed file is off."""
    try:
        data = json.loads(Path(SWITCH_FILE if path is None else path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"jobs": [], "per_run": False}
    if not isinstance(data, dict):
        return {"jobs": [], "per_run": False}
    jobs = data.get("jobs")
    jobs = [j for j in jobs if isinstance(j, str) and _JOB.fullmatch(j)] if isinstance(jobs, list) else []
    return {"jobs": jobs, "per_run": data.get("per_run") is True}


def grant_label(run_id: str | int, attempt: str | int) -> str:
    return f"cmux-{run_id}-{attempt}-mac"


def xcode_label(sources: Iterable[str | None]) -> str:
    """`xcode-<version>` from the first source naming one (`/Applications/Xcode_26.6.app`,
    `glaeda-std-xcode-26.6`); "" with none."""
    for source in sources:
        match = _XCODE.search((source or "").strip())
        if match:
            return f"xcode-{match.group('version')}"
    return ""


def same_repo_pr(env: Mapping[str, str]) -> bool:
    repo = (env.get("GITHUB_REPOSITORY") or "").strip()
    owner = (env.get("GITHUB_REPOSITORY_OWNER") or repo.partition("/")[0]).strip()
    return (env.get("GITHUB_EVENT_NAME") or "") == "pull_request" and owner == OWNER and bool(repo) \
        and (env.get("HEAD_REPO") or "").strip() == repo


def outputs(env: Mapping[str, str], path: Path | str | None = None) -> dict[str, str]:
    """{"grant_runner": JSON array or "", "grant_jobs": " a b " or ""}."""
    none = {"grant_runner": "", "grant_jobs": ""}
    switch = read_switch(path)
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "1").strip()
    if not (switch["jobs"] and run_id.isdigit() and attempt.isdigit() and same_repo_pr(env)):
        return none
    labels = [grant_label(run_id, attempt) if switch["per_run"] else MAC_LABEL]
    xcode = xcode_label([env.get("XCODE_APP")])
    if xcode:
        labels.append(xcode)
    return {"grant_runner": json.dumps(labels, separators=(",", ":")),
            "grant_jobs": " " + " ".join(switch["jobs"]) + " "}


def main(env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    out = outputs(env)
    lines = "".join(f"{key}={value}\n" for key, value in out.items())
    target = env.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(lines)
    sys.stdout.write(lines)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
