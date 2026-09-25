#!/usr/bin/env python3
"""Label an owned Mac's root runner with the main commits it starts from warm.

An owned Mac keeps compile admission's DerivedData between jobs
(owned_build_state.py `keep`), so a later admission merging onto the main
commit that build sat on recompiles only its own diff. GitHub hands a
root-label job to any free root runner, though, so that admission usually
lands on another Mac and compiles from a seed instead. ci-macos.yml compile
admission uploads `owned-warm-keys-<run>-<attempt>` on an owned Mac: the
output of `owned_build_state.py warm-keys`,

    {"runner": "<runner name>", "pool": "glaeda-root-std-xcode-26.6",
     "keys": ["<sha12>", ...]}

with the kept build's merge base first. ci-owned-warm-labels.yml runs this
script from main when that CI run completes. It gives the runner that ran
admission one `glaeda-warm-<sha12>` label per key (at most MAX_KEYS), removes
its other `glaeda-warm-` labels, and removes its keys from every other runner
of the same root pool, so one runner per pool carries each key. The picker
(pr_runner_pool.py, warm affinity) then sends an admission whose merge base
has a label to that runner when it is idle.

The runner is the one the jobs API says ran admission, never the name in the
artifact, which the pull request's own code wrote: an artifact naming another
runner, or another pool than the runner's root label, changes nothing. A key
that is not 12 hex digits is dropped. A wrong key only sends an admission to a
Mac whose build is further away, which compiles as it would elsewhere.

Needs GH_TOKEN (actions: read, for the run's jobs) and ROUTE_TOKEN (the org
route App with administration: write for repository runners, and the
organization permission Self-hosted runners: write for the minis, which are
org runners in the glaeda-minis group since glaeda#1222).
"""
from __future__ import annotations

import dataclasses
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import ROOT_PREFIX, WARM_KEY, WARM_PREFIX, persistent  # noqa: E402

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
# ci-macos.yml's compile admission job; the jobs API prefixes the caller's job name.
ADMISSION_JOB = "macOS compile admission"
# Labels one runner carries at most: its kept build's merge base and a few
# commits past it that still build cheaply from it.
MAX_KEYS = 4
PAGE_SIZE = 100
API = "https://api.github.com"
# The org runner group holding the glaeda minis (glaeda#1222 moved them there).
RUNNER_GROUP = "glaeda-minis"


def keys(document: Any) -> list[str]:
    """The artifact's valid keys, deduplicated in order, at most MAX_KEYS."""
    raw = document.get("keys") if isinstance(document, Mapping) else None
    found: list[str] = []
    for key in raw if isinstance(raw, list) else []:
        key = str(key).strip().lower()[:12]
        if WARM_KEY.fullmatch(key) and key not in found:
            found.append(key)
    return found[:MAX_KEYS]


def label_names(runner: Mapping[str, Any]) -> set[str]:
    return {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}


def root_pool(runner: Mapping[str, Any]) -> str:
    """The runner's root label (glaeda-root-<class>-xcode-<version>), or ""."""
    return next((name for name in sorted(label_names(runner))
                 if name.startswith(ROOT_PREFIX) and persistent(name)), "")


@dataclasses.dataclass(frozen=True)
class Change:
    runner_id: int
    add: tuple[str, ...] = ()
    remove: tuple[str, ...] = ()


def plan(runners: Sequence[Mapping[str, Any]], runner_id: int, wanted: Sequence[str]) -> tuple[list[Change], str]:
    """The label changes that make `runner_id` the one runner of its pool warm for `wanted`.

    Other runners of the pool lose those keys first, then the runner drops its
    stale warm labels and gains the new ones. Returns the changes and why.
    """
    target = next((runner for runner in runners if runner.get("id") == runner_id), None)
    if target is None:
        return [], f"runner {runner_id} is not registered here"
    pool = root_pool(target)
    if not pool:
        return [], f"runner {target.get('name')} carries no root label"
    labels = [WARM_PREFIX + key for key in wanted]
    changes = []
    for runner in runners:
        if runner is target or pool not in label_names(runner):
            continue
        taken = tuple(label for label in labels if label in label_names(runner))
        if taken:
            changes.append(Change(int(runner["id"]), remove=taken))
    have = label_names(target)
    add = tuple(label for label in labels if label not in have)
    stale = tuple(sorted(name for name in have if name.startswith(WARM_PREFIX) and name not in labels))
    if add or stale:
        changes.append(Change(runner_id, add=add, remove=stale))
    return changes, f"{target.get('name')} in {pool}: {', '.join(labels) or 'no warm keys'}"


def admission_job(jobs: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The run's compile admission job that ran on a runner, or None."""
    for job in jobs:
        name = str(job.get("name") or "")
        if (name == ADMISSION_JOB or name.endswith(" / " + ADMISSION_JOB)) and job.get("runner_id"):
            return job
    return None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-owned-warm-labels",
        }
        self.org_ids: set[Any] = set()

    def request(self, method: str, path: str, body: Any = None) -> Any:
        """A request to a path under this repository."""
        return self.api(method, f"/repos/{self.repo}{path}", body)

    def api(self, method: str, path: str, body: Any = None) -> Any:
        """A request to any API path (an org endpoint, for one)."""
        data = None if body is None else json.dumps(body).encode()
        headers = {**self.headers, **({"Content-Type": "application/json"} if data else {})}
        request = urllib.request.Request(f"{API}{path}", data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read()
        return json.loads(payload) if payload else None

    def jobs(self, run_id: int, attempt: int) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, 4):
            batch = self.request("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs"
                                        f"?per_page={PAGE_SIZE}&page={page}").get("jobs") or []
            found.extend(job for job in batch if isinstance(job, Mapping))
            if len(batch) < PAGE_SIZE:
                break
        return found

    def runners(self) -> list[Mapping[str, Any]]:
        """The org's RUNNER_GROUP runners (the glaeda minis), then this repository's own.

        Reading and labeling the org runners needs the App's organization
        permission "Self-hosted runners: write". Without it this warns and
        goes on with the repository's runners, which the minis are not.
        """
        owner, _, name = self.repo.partition("/")
        org: list[Mapping[str, Any]] = []
        try:
            groups = self.api("GET", f"/orgs/{owner}/actions/runner-groups?per_page={PAGE_SIZE}"
                                     f"&visible_to_repository={urllib.parse.quote(name)}").get("runner_groups") or []
            group = next((group for group in groups if isinstance(group, Mapping)
                          and group.get("name") == RUNNER_GROUP and isinstance(group.get("id"), int)), None)
            if group is None:
                print(f"::warning title=owned warm labels::no runner group {RUNNER_GROUP} is visible to "
                      f"{self.repo}; labeling repository runners only")
            else:
                org = self._pages(f"/orgs/{owner}/actions/runner-groups/{group['id']}/runners")
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                raise
            print(f"::warning title=owned warm labels::org runner group {RUNNER_GROUP} unreadable "
                  f"(HTTP {error.code}); labeling repository runners only. The routing App needs the "
                  "organization permission Self-hosted runners: read and write")
        self.org_ids = {runner.get("id") for runner in org}
        found = {runner.get("id"): runner for runner in org}
        for runner in self._pages(f"/repos/{self.repo}/actions/runners"):
            found.setdefault(runner.get("id"), runner)
        return list(found.values())

    def _pages(self, path: str) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, 6):
            batch = self.api("GET", f"{path}?per_page={PAGE_SIZE}&page={page}").get("runners") or []
            found.extend(runner for runner in batch if isinstance(runner, Mapping))
            if len(batch) < PAGE_SIZE:
                break
        return found

    def labels_path(self, runner_id: int) -> str:
        """A runner's labels endpoint: the org's for an org runner, else this repository's."""
        owner = self.repo.partition("/")[0]
        scope = f"/orgs/{owner}" if runner_id in self.org_ids else f"/repos/{self.repo}"
        return f"{scope}/actions/runners/{runner_id}/labels"

    def apply(self, change: Change) -> None:
        path = self.labels_path(change.runner_id)
        for label in change.remove:
            try:
                self.api("DELETE", f"{path}/{urllib.parse.quote(label, safe='')}")
            except urllib.error.HTTPError as error:
                if error.code != 404:  # already gone
                    raise
        if change.add:
            self.api("POST", path, {"labels": list(change.add)})


def run(env: Mapping[str, str], actions: GitHub, admin: GitHub) -> str:
    """Label the runner that ran this run's admission; returns what it did."""
    if (env.get("RUN_PATH") or "").strip() != CI_WORKFLOW_PATH:
        return f"not a run of {CI_WORKFLOW_PATH}"
    try:
        document = json.loads(Path(env["KEYS_FILE"]).read_text(encoding="utf-8"))
    except (KeyError, OSError, ValueError) as error:
        return f"no readable warm keys ({error})"
    if not isinstance(document, Mapping):
        return "the warm keys are not a JSON object"
    wanted = keys(document)
    job = admission_job(actions.jobs(int(env["RUN_ID"]), int(env.get("RUN_ATTEMPT") or 1)))
    if job is None:
        return "no compile admission job ran on a runner"
    if str(document.get("runner") or "") != str(job.get("runner_name") or ""):
        return f"the keys name runner {document.get('runner')!r}, but admission ran on {job.get('runner_name')!r}"
    runners = admin.runners()
    target = next((runner for runner in runners if runner.get("id") == job["runner_id"]), {})
    if document.get("pool") and document["pool"] != root_pool(target):
        return f"the keys name pool {document['pool']!r}, but the runner's root label is {root_pool(target)!r}"
    changes, why = plan(runners, int(job["runner_id"]), wanted)
    for change in changes:
        admin.apply(change)
    return f"{why} ({len(changes)} runner(s) changed)"


def main(env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    repo = env.get("GITHUB_REPOSITORY") or ""
    token, route_token = env.get("GH_TOKEN") or "", env.get("ROUTE_TOKEN") or ""
    if not (repo and token and route_token and (env.get("RUN_ID") or "").isdigit()):
        print("GITHUB_REPOSITORY, GH_TOKEN, ROUTE_TOKEN and RUN_ID are required; nothing labeled")
        return 0
    try:
        result = run(env, GitHub(token, repo), GitHub(route_token, repo))
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        # Labels are only a routing hint: a failure leaves the old ones.
        print(f"::warning title=owned warm labels::{error}")
        return 0
    print(result)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"### Owned warm labels\n\n{result}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
