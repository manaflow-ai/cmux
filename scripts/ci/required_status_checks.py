#!/usr/bin/env python3
"""The required status checks on main, and the two ways this copy goes stale.

GitHub holds the real list in a repository ruleset. It is not in this tree, and
nobody who edits this file can see it change. `REQUIRED_CHECKS` below is a
mirror, and a mirror drifts in two directions that are each invisible on their
own:

  settings -> tree   an admin adds a required check and no pull request updates
                     the tuple. `tests/test_ci_merge_queue_required_checks.py`
                     keeps passing, because it only ever reads the tuple. Every
                     pull request afterwards sits on "Expected - Waiting for
                     status to be reported" for a context nothing produces,
                     and no check anywhere is red to say why.
  tree -> reality    a pull request renames the job behind a required check.
                     The tuple and the ruleset still agree with each other;
                     both now name something that no longer reports.

Only GitHub can answer either question, so this runs from
`.github/workflows/required-checks-drift.yml` on a schedule rather than from
the offline guard lane. Two endpoints answer it:

  GET /repos/{owner}/{repo}/rules/branches/{branch}
      the contexts the branch actually requires. This is the rulesets
      endpoint, not `branches/{branch}/protection/required_status_checks`:
      the protection endpoint needs `administration: read`, which pull request
      CI must not have, while this one reads with the repository's ordinary
      read scope and needs no token at all on a public repository.
  GET /repos/{owner}/{repo}/commits/{sha}/{check-runs,status}
      for the heads of recently merged pull requests, what actually reported
      there. A required context that reported on none of them is a name
      nothing produces, whatever the settings say.

Everything that decides is a pure function over already-fetched JSON; the
client at the bottom only fetches. Every one of those functions raises
`DriftCheckError` when it cannot establish an answer, and `main` treats that as
a failure. Reporting success from a reconciliation that could not read its
source would reintroduce exactly the silence this exists to break.
"""

from __future__ import annotations

import dataclasses
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Mapping
from typing import Any


API = "https://api.github.com"
BRANCH = "main"

# A mirror of the `required_status_checks` rule on BRANCH. Regenerate with:
#   gh api repos/manaflow-ai/cmux/rules/branches/main \
#     --jq '[.[] | select(.type=="required_status_checks")
#            | .parameters.required_status_checks[].context] | sort'
REQUIRED_CHECKS = (
    "CLA Assistant",
    "CLA policy guard",
    "Web complexity",
    "ci-status",
    "web-validation",
)

# How many recently merged pull request heads to ask about production. Each
# costs two requests. A required check reported on every one of these heads
# before its pull request could merge, so a context absent from all of them is
# strong evidence that nothing produces it -- while a single absence is not,
# since a path-filtered check legitimately skips most merges.
MERGED_PULL_SAMPLE = 10


class DriftCheckError(RuntimeError):
    """The reconciliation could not establish an answer. Never swallow this."""


def contexts_from_rules(payload: Any) -> frozenset[str]:
    """The contexts a branch requires, from the rules endpoint's response.

    Several rulesets can apply to one branch and each may require checks, so
    the contexts are unioned. An error body, a branch with no required-checks
    rule, or a rule requiring nothing all raise: each means protection is not
    what this file claims, and none of them is an answer.
    """
    if not isinstance(payload, list):
        raise DriftCheckError(
            f"the rules endpoint answered with {type(payload).__name__}, not a list of rules: "
            f"{_excerpt(payload)}"
        )
    contexts: set[str] = set()
    rules_seen = 0
    for rule in payload:
        if not isinstance(rule, Mapping) or rule.get("type") != "required_status_checks":
            continue
        rules_seen += 1
        parameters = rule.get("parameters")
        required = parameters.get("required_status_checks") if isinstance(parameters, Mapping) else None
        if not isinstance(required, list):
            raise DriftCheckError(
                f"a required_status_checks rule has no list of checks: {_excerpt(rule)}"
            )
        for check in required:
            if not isinstance(check, Mapping) or not isinstance(check.get("context"), str):
                raise DriftCheckError(f"unrecognised required check entry: {_excerpt(check)}")
            contexts.add(check["context"])
    if not rules_seen:
        raise DriftCheckError(
            f"no required_status_checks rule applies to {BRANCH}. Either protection was "
            "removed or this is reading the wrong branch; both need a human."
        )
    if not contexts:
        raise DriftCheckError(f"{BRANCH} has a required_status_checks rule that requires nothing")
    return frozenset(contexts)


def reported_contexts(check_runs: Any, statuses: Any) -> frozenset[str]:
    """What reported on one commit, across both kinds of check GitHub accepts.

    A required context can be an Actions check run or a legacy commit status.
    Reading only one endpoint would report every context of the other kind as
    a phantom, so both are unioned. A commit with neither is empty, not an
    error; a response that is not either shape is an error.
    """
    names: set[str] = set()
    runs = check_runs.get("check_runs") if isinstance(check_runs, Mapping) else None
    if not isinstance(runs, list):
        raise DriftCheckError(f"the check-runs endpoint answered with no run list: {_excerpt(check_runs)}")
    for run in runs:
        if isinstance(run, Mapping) and isinstance(run.get("name"), str):
            names.add(run["name"])
    reported = statuses.get("statuses") if isinstance(statuses, Mapping) else None
    if not isinstance(reported, list):
        raise DriftCheckError(f"the status endpoint answered with no status list: {_excerpt(statuses)}")
    for status in reported:
        if isinstance(status, Mapping) and isinstance(status.get("context"), str):
            names.add(status["context"])
    return frozenset(names)


@dataclasses.dataclass(frozen=True)
class Drift:
    """What disagrees, in the three ways it can."""

    unmirrored: tuple[str, ...]
    stale: tuple[str, ...]
    unproduced: tuple[str, ...]
    sampled: int

    def ok(self) -> bool:
        return not (self.unmirrored or self.stale or self.unproduced)

    def report(self) -> str:
        script = "scripts/ci/required_status_checks.py"
        if self.ok():
            return (
                f"PASS: {script} matches the {BRANCH} ruleset, and every required check "
                f"reported on the {self.sampled} merged pull request heads sampled."
            )
        lines = [f"FAIL: the required status checks on {BRANCH} and {script} disagree."]
        if self.unmirrored:
            lines += [
                "",
                f"  Required by GitHub, missing from REQUIRED_CHECKS: {', '.join(self.unmirrored)}",
                "    Every pull request now waits on these unless a workflow already produces",
                f"    them. Add them to {script} and give each one a producing job.",
            ]
        if self.stale:
            lines += [
                "",
                f"  In REQUIRED_CHECKS, no longer required by GitHub: {', '.join(self.stale)}",
                f"    Remove them from {script}; the merge-queue guard is spending an",
                "    assertion on a check that gates nothing.",
            ]
        if self.unproduced:
            lines += [
                "",
                f"  Required, and reported on none of the {self.sampled} sampled merged heads: "
                f"{', '.join(self.unproduced)}",
                "    Nothing produces this name. Either a producing job was renamed, or the",
                "    required context is a typo. Pull requests will hang on it.",
            ]
        return "\n".join(lines)


def findings(
    *,
    live: Iterable[str],
    committed: Iterable[str],
    reported_by_commit: Mapping[str, frozenset[str]],
) -> Drift:
    """Compare the live contexts against the tuple and against what reports.

    An empty sample raises. "No merged pull requests to look at, so nothing is
    wrong" is a verdict this function is not entitled to reach.
    """
    if not reported_by_commit:
        raise DriftCheckError(
            "no merged pull request heads were sampled, so whether each required check is "
            "produced could not be established"
        )
    live = frozenset(live)
    committed_set = frozenset(committed)
    ever_reported: set[str] = set()
    for names in reported_by_commit.values():
        ever_reported |= set(names)
    return Drift(
        unmirrored=tuple(sorted(live - committed_set)),
        stale=tuple(sorted(committed_set - live)),
        unproduced=tuple(sorted(live - ever_reported)),
        sampled=len(reported_by_commit),
    )


def _excerpt(payload: Any) -> str:
    text = json.dumps(payload, default=str)
    return text if len(text) <= 300 else text[:300] + "..."


class GitHub:
    """Fetch only. A failed request raises rather than returning a default."""

    def __init__(self, repo: str, token: str | None) -> None:
        self.repo = repo
        self.token = token

    def get(self, path: str) -> Any:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-required-checks-drift",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(API + path, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")[:300]
            raise DriftCheckError(f"GET {path} failed with HTTP {error.code}: {body}") from error
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as error:
            raise DriftCheckError(f"GET {path} failed: {error}") from error

    def branch_rules(self, branch: str) -> Any:
        return self.get(f"/repos/{self.repo}/rules/branches/{urllib.parse.quote(branch)}")

    def merged_heads(self, branch: str, limit: int) -> list[str]:
        query = urllib.parse.urlencode(
            {"state": "closed", "base": branch, "sort": "updated", "direction": "desc", "per_page": 100}
        )
        payload = self.get(f"/repos/{self.repo}/pulls?{query}")
        if not isinstance(payload, list):
            raise DriftCheckError(f"the pulls endpoint answered with no list: {_excerpt(payload)}")
        heads: list[str] = []
        for pull in payload:
            if not isinstance(pull, Mapping) or not pull.get("merged_at"):
                continue
            head = pull.get("head")
            sha = head.get("sha") if isinstance(head, Mapping) else None
            if isinstance(sha, str) and sha not in heads:
                heads.append(sha)
            if len(heads) >= limit:
                break
        if not heads:
            raise DriftCheckError(f"no merged pull requests into {branch} were found to sample")
        return heads

    def reported_on(self, sha: str) -> frozenset[str]:
        runs = self.get(f"/repos/{self.repo}/commits/{sha}/check-runs?per_page=100")
        statuses = self.get(f"/repos/{self.repo}/commits/{sha}/status?per_page=100")
        return reported_contexts(runs, statuses)


def _summarise(report: str) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    with open(summary, "a", encoding="utf-8") as handle:
        handle.write(f"## Required status checks on {BRANCH}\n\n```\n{report}\n```\n")


def main() -> int:
    repo = os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY")
    if not repo:
        print("FAIL: set GH_REPO (or GITHUB_REPOSITORY) to the owner/name to reconcile")
        return 1
    github = GitHub(repo, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
    try:
        live = contexts_from_rules(github.branch_rules(BRANCH))
        reported = {sha: github.reported_on(sha) for sha in github.merged_heads(BRANCH, MERGED_PULL_SAMPLE)}
        drift = findings(live=live, committed=REQUIRED_CHECKS, reported_by_commit=reported)
    except DriftCheckError as error:
        report = (
            f"FAIL: could not reconcile the required status checks on {BRANCH}: {error}\n"
            "  This is a failure, not a skip. Until it is readable, a required check could "
            "have been added with nothing in this repository able to notice."
        )
        print(report)
        _summarise(report)
        return 1
    report = drift.report()
    print(report)
    _summarise(report)
    return 0 if drift.ok() else 1


if __name__ == "__main__":
    sys.exit(main())
