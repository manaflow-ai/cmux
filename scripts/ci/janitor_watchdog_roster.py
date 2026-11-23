#!/usr/bin/env python3
"""Say whether a runner label is starved or saturated, from its live runner roster.

ci-queue-janitor-watchdog.yml calls this when the newest janitor snapshot is
stale. The janitor sweep runs on the label it diagnoses, so a label too busy to
start the sweep left the snapshot stale just as a dead one does: cmux#47855
paged "Runner label starved: cmux-fleet-linux-x64" while the label had 64
runners online and 82 busy, 214 booting and 3453 jobs queued, and the sweep
itself waited 77 minutes for a runner (run 44679246255). A stale snapshot is
not proof of no runners, so the watchdog reads the roster first.

Prints one line, `<state> <detail>`:
  saturated  a runner carrying the label is online (idle or busy): the label is
             served, and the sweep waits behind its queue
  starved    the roster reads, and no runner carrying the label is online
  unknown    the roster cannot be read (no token, a refusal, a timeout), or one
             read said starved and the other could not be read: the watchdog
             files nothing and says the roster is unknown

"starved" is the only state that files an issue, so it takes two reads that
both say starved, CONFIRM_SECONDS apart (confirmed()); either read finding an
online runner is saturated. One read was the whole verdict until 2026-11-23,
and an unreadable roster filed the issue too: cmux#50767, #51512 and #51605
opened on "runner roster unknown: ... API rate limit exceeded" and the next
watchdog run, a minute later, read the roster and closed each one as
"saturated, not starved" (192 to 221 runners online). Open and close now read
the same classification.

The roster is the repository's runners and those of every org runner group
visible to it, read with ROUTE_TOKEN (the routing App's token, minted with
Administration: read and the organization's Self-hosted runners: read; the
workflow token can list neither). GitHub lists a runner that is registered but
not yet connected (booting) as offline, so offline runners are only counted in
the detail. Requests go through `gh api` with GH_TOKEN set to ROUTE_TOKEN, so
they spend the App's budget, not GITHUB_TOKEN's. This script always exits 0.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.parse
from collections.abc import Callable, Iterable, Mapping
from typing import Any

PAGE_SIZE = 100
MAX_PAGES = 5
TIMEOUT_SECONDS = 30
# The pause between the two reads a "starved" verdict needs (confirmed()).
CONFIRM_SECONDS = 30

Fetch = Callable[[str], Any]


def gh_fetch(token: str) -> Fetch:
    def fetch(path: str) -> Any:
        env = {**os.environ, "GH_TOKEN": token}
        done = subprocess.run(["gh", "api", path], env=env, capture_output=True, text=True,
                              timeout=TIMEOUT_SECONDS, check=False)
        if done.returncode != 0:
            raise RuntimeError(f"gh api {path.split('?')[0]} failed: {(done.stderr or done.stdout).strip()[:200]}")
        return json.loads(done.stdout)
    return fetch


def _pages(fetch: Fetch, path: str, key: str, max_pages: int = MAX_PAGES) -> list[Mapping[str, Any]]:
    found: list[Mapping[str, Any]] = []
    for page in range(1, max_pages + 1):
        batch = (fetch(f"{path}{'&' if '?' in path else '?'}per_page={PAGE_SIZE}&page={page}") or {}).get(key) or []
        found.extend(item for item in batch if isinstance(item, Mapping))
        if len(batch) < PAGE_SIZE:
            break
    return found


def roster(fetch: Fetch, repo: str, max_pages: int = MAX_PAGES) -> list[Mapping[str, Any]]:
    """The repository's self-hosted runners and those of every org group visible to it.

    max_pages bounds each listing (PAGE_SIZE runners a page). The watchdog's default (5) suits its own question; a
    caller that counts idle runners on a pool of hundreds passes more, or its count is a sample.
    """
    owner, _, name = repo.partition("/")
    found = {runner.get("id"): runner for runner in _pages(fetch, f"repos/{repo}/actions/runners", "runners", max_pages)}
    groups = _pages(fetch, f"orgs/{owner}/actions/runner-groups?visible_to_repository={urllib.parse.quote(name)}",
                    "runner_groups")
    for group in groups:
        if isinstance(group.get("id"), int):
            found.update((runner.get("id"), runner) for runner in
                         _pages(fetch, f"orgs/{owner}/actions/runner-groups/{group['id']}/runners", "runners",
                                max_pages))
    return list(found.values())


def _labels(runner: Mapping[str, Any]) -> set[str]:
    return {str(label.get("name") if isinstance(label, Mapping) else label) for label in runner.get("labels") or ()}


def classify(label: str, runners: Iterable[Mapping[str, Any]]) -> tuple[str, str]:
    carrying = [runner for runner in runners if label in _labels(runner)]
    online = [runner for runner in carrying if str(runner.get("status") or "").lower() == "online"]
    busy = sum(1 for runner in online if runner.get("busy") is True)
    offline = len(carrying) - len(online)
    counts = f"{len(online)} online ({busy} busy, {len(online) - busy} idle), {offline} offline or booting"
    if online:
        return "saturated", f"runners carrying `{label}`: {counts}"
    return "starved", f"no runner carrying `{label}` is online: {counts}"


def verdict(env: Mapping[str, str], fetch: Fetch | None = None) -> tuple[str, str]:
    label = (env.get("LABEL") or "").strip()
    repo = (env.get("GH_REPO") or "").strip()
    token = (env.get("ROUTE_TOKEN") or "").strip()
    if not label or not repo:
        return "unknown", "runner roster unknown: LABEL or GH_REPO is not set"
    if fetch is None and not token:
        return "unknown", "runner roster unknown: no routing token was minted"
    try:
        return classify(label, roster(fetch or gh_fetch(token), repo))
    except Exception as error:  # noqa: BLE001 - an unreadable roster keeps the snapshot-only verdict
        return "unknown", f"runner roster unknown: {error}"


def confirmed(env: Mapping[str, str], fetch: Fetch | None = None,
              sleep: Callable[[float], None] = time.sleep) -> tuple[str, str]:
    """verdict(), read twice when the first read is not saturated: starved only when both reads say so.

    An online runner in either read is saturated. Starved on one read and unreadable on the other is unknown, as
    is unreadable twice: the watchdog files no issue on a roster it could not read.
    """
    first = verdict(env, fetch)
    if first[0] == "saturated":
        return first
    sleep(float(env.get("CONFIRM_SECONDS") or CONFIRM_SECONDS))
    second = verdict(env, fetch)
    if second[0] == "saturated" or first[0] == second[0]:
        return second
    unread = first if first[0] == "unknown" else second
    return "unknown", f"{unread[1]} (the other read said starved, so starved is not confirmed)"


def main(env: Mapping[str, str] = os.environ) -> int:
    state, detail = confirmed(env)
    print(f"{state} {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
