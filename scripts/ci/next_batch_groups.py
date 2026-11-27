"""Labeled PR groups for the cmux NEXT batch queue (docs/ci/cmux-next-batch.md#groups).

A group is the open PRs that carry the same `batch:<name>` label. The queue
stacks them on feat-cmux-next as one combined head, runs the union of the
checks each member's paths route to once on that head, and when it passes and
every member has an independent review (next_batch.reviewed), merges them in
order without waiting on each PR's own CI. This module holds the pure parts:
membership, order and the check plan. next_batch.Controller runs them.
"""
from __future__ import annotations

import dataclasses
import importlib.util
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_next_route  # noqa: E402
import web_subareas  # noqa: E402

GROUP_PREFIX = "batch:"

_PATH_MAP = Path(__file__).resolve().parents[1] / "cmux-next/media/path_map.py"
_spec = importlib.util.spec_from_file_location("cmux_next_media_path_map", _PATH_MAP)
path_map = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(path_map)


class Member(Protocol):
    number: int
    sha: str
    labels: list[str]


def group_of(labels: Iterable[str]) -> str | None:
    """The PR's group: its `batch:<name>` label. Two such labels is no group
    (the PR is held until one is removed), so it is never landed twice."""
    labels = list(labels)
    if conflicting_groups(labels):
        return None
    names = sorted({label[len(GROUP_PREFIX):] for label in labels
                    if label.startswith(GROUP_PREFIX) and label[len(GROUP_PREFIX):].strip()})
    return names[0] if len(names) == 1 else None


def conflicting_groups(labels: Iterable[str]) -> list[str]:
    names = sorted({label for label in labels if label.startswith(GROUP_PREFIX)})
    return names if len(names) > 1 else []


def assemble(prs: Iterable[Member]) -> dict[str, list[Member]]:
    groups: dict[str, list[Member]] = {}
    for pr in prs:
        name = group_of(pr.labels)
        if name is not None:
            groups.setdefault(name, []).append(pr)
    return groups


def order(members: list[Member], labeled_at: dict[int, str],
          is_ancestor: Callable[[str, str], bool]) -> list[Member]:
    """Stack order first: a member whose head contains another member's head
    comes after it. Otherwise the order the group label was put on (ISO
    times compare as strings), then the PR number."""
    def key(pr: Member) -> tuple[str, int]:
        return (labeled_at.get(pr.number) or "~", pr.number)

    after = {pr.number: {other.number for other in members
                         if other.number != pr.number and other.sha != pr.sha and is_ancestor(other.sha, pr.sha)}
             for pr in members}
    placed: list[Member] = []
    left = sorted(members, key=key)
    while left:
        ready = [pr for pr in left if not after[pr.number] - {item.number for item in placed}]
        pick = ready[0] if ready else left[0]  # a cycle cannot happen in git; never loop forever
        placed.append(pick)
        left.remove(pick)
    return placed


@dataclass
class CheckPlan:
    """The union of what each member's paths route to (one combined run)."""
    cmux_tiers: set[str] = field(default_factory=set)  # cmux_next_route.Route flags
    cmux_tests: set[str] = field(default_factory=set)
    web: set[str] = field(default_factory=set)  # web_subareas.WebSubareas fields
    tours: list[str] = field(default_factory=list)  # media tours, in path_map.TOUR_ORDER
    members: dict[int, dict] = field(default_factory=dict)  # per member, for the receipt

    def lanes(self) -> list[str]:
        """The dispatched lanes this plan needs beyond the heavy tier and the fleet build."""
        return (["web"] if self.web else []) + (["tour"] if self.tours else [])


ROUTE_FLAGS = tuple(item.name for item in dataclasses.fields(cmux_next_route.Route)
                    if item.type in (bool, "bool"))
WEB_FLAGS = tuple(item.name for item in dataclasses.fields(web_subareas.WebSubareas))


def check_plan(root: Path, files: dict[int, list[str]], labels: dict[int, list[str]] | None = None) -> CheckPlan:
    """Route each member as its own pull request would, then take the union, so
    each member's focused checks and tours are all in the combined run."""
    plan = CheckPlan()
    tours: set[str] = set()
    for number, changed in files.items():
        route = cmux_next_route.route(root, "pull_request", list(changed), set((labels or {}).get(number, [])))
        tiers = {flag for flag in ROUTE_FLAGS if getattr(route, flag)}
        web = web_subareas.classify_paths(list(changed), root)
        web_set = {flag for flag in WEB_FLAGS if getattr(web, flag)}
        mapped = path_map.map_paths(list(changed))
        plan.cmux_tiers |= tiers
        plan.cmux_tests |= set(route.tests)
        plan.web |= web_set
        tours |= set(mapped["tours"])
        plan.members[number] = {"tiers": sorted(tiers), "web": sorted(web_set), "tours": list(mapped["tours"])}
    plan.tours = [tour for tour in path_map.TOUR_ORDER if tour in tours]
    return plan
