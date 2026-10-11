#!/usr/bin/env python3
"""Delete superseded commit-addressed builds from the cmux-binaries R2 bucket.

    cmux_binaries_prune.py --endpoint-url URL --trunk-commits FILE [--pin-file FILE ...] [--delete]

feat-cmux-next's cmux-tui-artifacts.yml publishes on a push to any branch, so every branch head gets
write-once `cmux-tui/<sha>/`, `cmux-relay/<sha>/`, `chatmux-relay/<sha>/` and `cmux-tui-windows/<sha>/`
prefixes, and nothing deletes them (2026-10-10 census: 1.6 TiB, about 70 GiB a day). This removes a
prefix only when nothing can still ask for it.

A family is a key pattern plus a decide function, so the families another owner prunes (the
`cmux-tui/tree/<key>/` trees, op-ci-tiers) plug into the same run. A key that matches no family is
never touched: `*/latest/`, `mux/` (read outside this repo until manaflow-ai/cmux-cloud#2),
`cmux-next-web/`, the `nightly/`, `rc/` and `stable/` appcasts, and anything new.

A commit-addressed prefix is kept when its commit is any of:

- on main or feat-cmux-next (--trunk-commits, from `git rev-list`): the app resolvers, nightly and
  nightly-next pick trunk commits, and a release pin is one;
- named by a pin file at a tip (--pin-file: cmux-tui.pin, the VM image locks), any 40-hex in it;
- named by a `<family>/latest/manifest.json`, or by a tree's `source.json` (a tree serves the
  binaries of its source commit, and republishing copies from it);
- a relay commit that is kept, for its `cmux-tui/<sha>/` (a chatmux-relay manifest depends on it);
- published within the last 14 days, so a dev build of a branch keeps its remote install that long.

Everything else is a branch head nobody pins: deleted, metadata first (`manifest.json`, `source.json`,
`completion*.json`) so a reader never finds a manifest naming a missing binary, oldest prefix first,
at most MAX_DELETES objects a run. A write-once upload only checks that the key exists, so a pruned
prefix can be published again. Trees are kept until their owner's rule lands. The run stops before
any delete when the listing is incomplete, the trunk list looks truncated, or a `latest` manifest or
tree `source.json` cannot be read.

Without --delete this is a dry run. Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import datetime as dt
import json
from pathlib import Path
import re
import sys
from typing import Callable
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2_cache_census as census  # noqa: E402
import r2_cache_prune  # noqa: E402
import r2_storage_census  # noqa: E402

BUCKET = "cmux-binaries"
BRANCH_DAYS = 14
MAX_DELETES = 5000
MIN_TRUNK_COMMITS = 1000  # fewer means the checkout was shallow: every commit would look like a branch
SHA = re.compile(r"\b[0-9a-f]{40}\b")
METADATA = re.compile(r"^(manifest|source|completion[^/]*)\.json$")
COMMIT_FAMILIES = ("cmux-tui", "cmux-relay", "chatmux-relay", "cmux-tui-windows")
RELAY_FAMILIES = ("cmux-relay", "chatmux-relay")
LATEST = tuple(f"{family}/latest/manifest.json" for family in ("cmux-tui", "cmux-relay", "chatmux-relay"))


@dataclass
class Group:
    family: str
    id: str
    prefix: str
    objects: list[dict] = field(default_factory=list)

    @property
    def size(self) -> int:
        return sum(item["size"] for item in self.objects)

    @property
    def newest(self) -> str:
        return max(item["last_modified"] for item in self.objects)


@dataclass
class Context:
    now: dt.datetime
    trunk: set[str]
    pins: set[str]
    latest: set[str]
    tree_commits: set[str]
    kept_relays: set[str] = field(default_factory=set)


@dataclass
class Family:
    name: str
    pattern: re.Pattern
    decide: Callable[[Group, Context], str]  # "delete", or why it is kept


def keep_commit(group: Group, ctx: Context) -> str:
    sha = group.id
    if sha in ctx.trunk:
        return "keep: trunk commit"
    if sha in ctx.pins:
        return "keep: pinned at a tip"
    if sha in ctx.latest:
        return "keep: a latest manifest names it"
    if sha in ctx.tree_commits:
        return "keep: a tree's source commit"
    if group.family in ("cmux-tui", "cmux-tui-windows") and sha in ctx.kept_relays:
        return "keep: a kept relay depends on it"
    age = census.age_days(group.newest, ctx.now)
    if age is None or age < BRANCH_DAYS:
        return f"keep: under {BRANCH_DAYS} days old"
    return "delete"


def keep_tree(group: Group, ctx: Context) -> str:
    # op-ci-tiers owns the tree rule (source.json "family": trunk|branch); until it lands, keep all.
    return "keep: tree (owner rule pending)"


# Relays first: a kept relay keeps its commit's cmux-tui prefix.
FAMILIES = (
    Family("cmux-relay", re.compile(r"^cmux-relay/(?P<id>[0-9a-f]{40})/[^/]+$"), keep_commit),
    Family("chatmux-relay", re.compile(r"^chatmux-relay/(?P<id>[0-9a-f]{40})/[^/]+$"), keep_commit),
    Family("cmux-tui", re.compile(r"^cmux-tui/(?P<id>[0-9a-f]{40})/[^/]+$"), keep_commit),
    Family("cmux-tui-windows", re.compile(r"^cmux-tui-windows/(?P<id>[0-9a-f]{40})/[^/]+$"), keep_commit),
    Family("cmux-tui-tree", re.compile(r"^cmux-tui/tree/(?P<id>[A-Za-z0-9._-]+)/[^/]+$"), keep_tree),
)


def group_objects(objects: list[dict]) -> dict[str, list[Group]]:
    groups: dict[tuple[str, str], Group] = {}
    for item in objects:
        for family in FAMILIES:
            match = family.pattern.match(item["key"])
            if match:
                key = (family.name, match.group("id"))
                if key not in groups:
                    prefix = item["key"].rsplit("/", 1)[0] + "/"
                    groups[key] = Group(family.name, match.group("id"), prefix)
                groups[key].objects.append(item)
                break
    by_family: dict[str, list[Group]] = {family.name: [] for family in FAMILIES}
    for group in groups.values():
        by_family[group.family].append(group)
    return by_family


def read_json(bucket, key: str) -> dict | None:
    """The object as JSON, None when it does not exist. Any other failure stops the run."""
    try:
        return json.loads(bucket.read(key))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def latest_commits(bucket, keys: set[str]) -> set[str]:
    commits = set()
    for key in LATEST:
        if key not in keys:
            continue
        data = read_json(bucket, key)
        commit = (data or {}).get("commit", "")
        if not SHA.fullmatch(commit):
            raise RuntimeError(f"{key} names no commit; refusing to prune")
        commits.add(commit)
    return commits


def tree_commits(bucket, trees: list[Group]) -> set[str]:
    commits = set()
    for tree in trees:
        if not any(item["key"].endswith("/source.json") for item in tree.objects):
            continue  # an unfinished publish: no source to protect
        data = read_json(bucket, tree.prefix + "source.json") or {}
        commits.update(SHA.findall(json.dumps(data.get("commit", ""))))
    return commits


def plan(by_family: dict[str, list[Group]], ctx: Context) -> tuple[list[Group], dict]:
    deletes, kept = [], {}
    for family in FAMILIES:
        for group in by_family[family.name]:
            verdict = family.decide(group, ctx)
            if verdict == "delete":
                deletes.append(group)
                continue
            if family.name in RELAY_FAMILIES:
                ctx.kept_relays.add(group.id)
            row = kept.setdefault(f"{family.name}: {verdict}", [0, 0])
            row[0] += 1
            row[1] += group.size
    deletes.sort(key=lambda group: group.newest)
    return deletes, kept


def delete_order(group: Group) -> list[str]:
    names = sorted(group.objects, key=lambda item: (not METADATA.match(item["key"].rsplit("/", 1)[1]), item["key"]))
    return [item["key"] for item in names]


def prune(bucket, now: dt.datetime, *, trunk: set[str], pins: set[str], delete: bool) -> dict:
    if len(trunk) < MIN_TRUNK_COMMITS:
        raise RuntimeError(f"only {len(trunk)} trunk commits; refusing to prune from a shallow history")
    objects, complete = bucket.list()
    if not complete:
        raise RuntimeError("bucket listing is incomplete; refusing to prune")
    by_family = group_objects(objects)
    ctx = Context(now=now, trunk=trunk, pins=pins,
                  latest=latest_commits(bucket, {item["key"] for item in objects}),
                  tree_commits=tree_commits(bucket, by_family["cmux-tui-tree"]))
    deletes, kept = plan(by_family, ctx)
    summary = {"objects": len(objects), "kept": kept, "candidates": {}, "deleted_objects": 0,
               "deleted_bytes": 0, "capped": False}
    for group in deletes:
        row = summary["candidates"].setdefault(group.family, [0, 0])
        row[0] += 1
        row[1] += group.size
    if not delete:
        return summary
    for group in deletes:
        if summary["deleted_objects"] + len(group.objects) > MAX_DELETES:
            summary["capped"] = True
            break
        for key in delete_order(group):
            bucket.delete(key)
            summary["deleted_objects"] += 1
        summary["deleted_bytes"] += group.size
    return summary


def render(summary: dict, delete: bool) -> str:
    gib = r2_storage_census.gib
    total = sum(row[1] for row in summary["candidates"].values())
    lines = [f"{BUCKET}: {summary['objects']} objects listed; "
             f"{'deleted ' + str(summary['deleted_objects']) + ' objects, ' + gib(summary['deleted_bytes']) if delete else 'dry run'}; "
             f"superseded prefixes {sum(r[0] for r in summary['candidates'].values())}, {gib(total)}"
             + ("; capped, the rest go next run" if summary["capped"] else "")]
    for family, (count, size) in sorted(summary["candidates"].items()):
        lines.append(f"  superseded {family}: {count} prefixes, {gib(size)}")
    for reason, (count, size) in sorted(summary["kept"].items(), key=lambda kv: -kv[1][1]):
        lines.append(f"  {reason}: {count} prefixes, {gib(size)}")
    return "\n".join(lines)


class Bucket(r2_cache_prune.Bucket):
    def list(self) -> tuple[list[dict], bool]:
        return census.collect(self.endpoint_url, self.bucket, lister=r2_storage_census.list_page)

    def read(self, key: str) -> str:
        return r2_cache_prune.signed("GET", self.endpoint_url, self.bucket, key).decode("utf-8", "replace")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", default=BUCKET)
    parser.add_argument("--trunk-commits", required=True, type=Path, help="git rev-list output, one sha a line")
    parser.add_argument("--pin-file", action="append", default=[], type=Path)
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args(argv)
    trunk = set(SHA.findall(args.trunk_commits.read_text()))
    pins = {sha for path in args.pin_file if path.exists() for sha in SHA.findall(path.read_text())}
    summary = prune(Bucket(args.endpoint_url, args.bucket), dt.datetime.now(dt.timezone.utc),
                    trunk=trunk, pins=pins, delete=args.delete)
    print(render(summary, args.delete))
    return 0


if __name__ == "__main__":
    sys.exit(main())
