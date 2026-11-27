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

- named anywhere in a pin file's history on either branch (--pin-file: `git log -p` of
  cmux-tui.pin and the VM image locks), any 40-hex in it: a Release build installs its pin's prefix,
  and some pins were PR heads squashed away;
- named by a `<family>/latest/manifest.json`, or by a tree's `source.json` or
  `completion-windows.json` (a tree serves the binaries of its source commit, and republishing copies
  from it and from the Windows build it recorded);
- a relay commit that is kept, for its `cmux-tui/<sha>/` (a chatmux-relay manifest depends on it);
- published within the last 14 days, so a dev build of a branch keeps its remote install that long;
- on main, feat-cmux-next or nightly-next (--trunk-commits) and published within the last 30 days,
  for rebuilds of recent commits;
- one of the 3 newest published commits (a prefix with a manifest.json) in a --windows line: each
  tip's history and each release tag's history (what the app resolvers pick when that revision is
  built), and the 64 commits behind every nightly-next build still on the nightly-next release. Tag
  commits (cmux-tui-v*, cmux-app-ffi-*, cmux-next-dev) come in through --pin-file.

A shipped nightly-next app fetches the `commit=` of its bundled cmux-tui.version at runtime: the
source commit of the tree its build resolved, which may lie outside that window or off trunk. Those
are kept because every tree's source commit is; a tree rule that prunes trees must keep the trees
shipped builds resolved.

An older trunk prefix is COLD when its commit is the newest trunk commit with a cmux-tui build
published that UTC day (one build a day kept for bisects; its relays go with it), otherwise deleted. COLD prefixes stay in R2 until the cmux-lawrence
cold-copy job has written them to both cold SSD images and verified sha256: with --cold-out this
writes `queue.json` (each object's key, size and sha256, read from R2) and `deletes.json`
(a presigned DELETE URL per object, valid 7 days), which the workflow encrypts to cmux-lawrence's
public certificate and publishes under `cold-queue/`. The host deletes an object only after both
copies match the queued sha256, so no R2 credential is ever on the host.

Everything else is a branch head nobody pins or an old trunk build that is not a day's snapshot:
deleted, metadata first (`manifest.json`, `source.json`,
`completion*.json`) so a reader never finds a manifest naming a missing binary, oldest prefix first,
at most MAX_DELETES objects a run. A write-once upload only checks that the key exists, so a pruned
prefix can be published again. Trees are kept until their owner's rule lands. The run stops before
any delete when the listing is incomplete, the trunk list looks truncated, or a `latest` manifest or
tree's metadata cannot be read, or the pin history names no commit. A deployment pinned through
CMUX_VM_CMUX_TUI_MANIFEST_URL is not visible here; point it at a trunk commit.

Without --delete this is a dry run. Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
"""
from __future__ import annotations

import argparse
import collections
from dataclasses import dataclass, field
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sys
from typing import Callable
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import r2_cache_census as census  # noqa: E402
import r2_cache_prune  # noqa: E402
import r2_storage_census  # noqa: E402

BUCKET = "cmux-binaries"
BRANCH_DAYS = 14
TRUNK_DAYS = 30
WINDOW_KEEP = 3  # newest published commits kept per --windows line, per family
COLD_MAX_BYTES = 20 * 1024**3  # queued for the SSDs per run; the rest wait a day
PRESIGN_SECONDS = 7 * 86400
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
    windows: dict[str, set[str]] = field(default_factory=dict)  # family -> kept by a window
    snapshots: dict[str, set[str]] = field(default_factory=dict)  # family -> a day's newest old trunk build


@dataclass
class Family:
    name: str
    pattern: re.Pattern
    decide: Callable[[Group, Context], str]  # "delete", "cold", or why it is kept


def keep_commit(group: Group, ctx: Context) -> str:
    sha = group.id
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
    if sha not in ctx.trunk:
        return "delete"
    if age < TRUNK_DAYS:
        return f"keep: trunk, under {TRUNK_DAYS} days old"
    if sha in ctx.windows.get(group.family, ()):
        return "keep: newest published behind a tip or a shipped build"
    if sha in ctx.snapshots.get(group.family, ()):
        return "cold"
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
        data = read_json(bucket, key) or {}
        # cmux-tui and cmux-relay write `commit`, chatmux-relay only `sourceCommit`; keep every
        # commit the manifest mentions, its dependency URLs included.
        commit = data.get("commit") or data.get("sourceCommit") or ""
        if not SHA.fullmatch(commit):
            raise RuntimeError(f"{key} names no commit; refusing to prune")
        commits.update(SHA.findall(json.dumps(data)))
    return commits


def tree_commits(bucket, trees: list[Group]) -> set[str]:
    commits = set()
    for tree in trees:
        names = {item["key"].rsplit("/", 1)[1] for item in tree.objects}
        # An unfinished publish has no source.json yet: nothing to protect.
        for name, field_name in (("source.json", "commit"), ("completion-windows.json", "sourceCommit")):
            if name in names:
                data = read_json(bucket, tree.prefix + name) or {}
                commits.update(SHA.findall(str(data.get(field_name, ""))))
    return commits


def window_keeps(by_family: dict[str, list[Group]], windows: list[list[str]]) -> dict[str, set[str]]:
    keeps = {}
    for family, groups in by_family.items():
        # A failed upload without a manifest is not something a resolver would pick.
        published = {group.id for group in groups
                     if any(item["key"].endswith("/manifest.json") for item in group.objects)}
        kept = keeps.setdefault(family, set())
        for window in windows:
            kept.update([sha for sha in window if sha in published][:WINDOW_KEEP])
    return keeps


def daily_snapshots(by_family: dict[str, list[Group]], trunk: set[str], now: dt.datetime) -> dict[str, set[str]]:
    """One commit a day, chosen by its cmux-tui build, for every family: a cold relay always has
    its cmux-tui beside it."""
    newest_of_day: dict[str, Group] = {}
    for group in by_family.get("cmux-tui", []):
        age = census.age_days(group.newest, now)
        if group.id not in trunk or age is None or age < TRUNK_DAYS:
            continue
        day = group.newest[:10]
        if day not in newest_of_day or group.newest > newest_of_day[day].newest:
            newest_of_day[day] = group
    commits = {group.id for group in newest_of_day.values()}
    return {family: commits for family in by_family}


def plan(by_family: dict[str, list[Group]], ctx: Context) -> tuple[list[Group], dict, list[Group]]:
    deletes, kept, cold = [], {}, []
    for family in FAMILIES:
        for group in by_family[family.name]:
            verdict = family.decide(group, ctx)
            if verdict == "delete":
                deletes.append(group)
                continue
            if verdict == "cold":
                cold.append(group)
                continue
            if family.name in RELAY_FAMILIES:
                ctx.kept_relays.add(group.id)
            row = kept.setdefault(f"{family.name}: {verdict}", [0, 0])
            row[0] += 1
            row[1] += group.size
    deletes.sort(key=lambda group: group.newest)
    cold.sort(key=lambda group: group.newest)
    return deletes, kept, cold


def delete_order(group: Group) -> list[str]:
    names = sorted(group.objects, key=lambda item: (not METADATA.match(item["key"].rsplit("/", 1)[1]), item["key"]))
    return [item["key"] for item in names]


def presign(method: str, endpoint_url: str, bucket: str, key: str, *, now: dt.datetime,
            expires: int = PRESIGN_SECONDS) -> str:
    """A SigV4 query-signed URL for one request on one object, valid `expires` seconds."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    region = os.environ.get("AWS_DEFAULT_REGION", "auto")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required")
    parsed = urllib.parse.urlsplit(endpoint_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("R2 endpoint URL must use HTTPS and include a host")
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    scope = f"{amz_date[:8]}/{region}/s3/aws4_request"
    canonical_uri = "/" + urllib.parse.quote(bucket, safe="~") + "/" + urllib.parse.quote(key, safe="~/")
    query = {"X-Amz-Algorithm": "AWS4-HMAC-SHA256", "X-Amz-Credential": f"{access_key}/{scope}",
             "X-Amz-Date": amz_date, "X-Amz-Expires": str(expires), "X-Amz-SignedHeaders": "host"}
    canonical_query = "&".join(f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(v, safe='~')}"
                               for k, v in sorted(query.items()))
    canonical_request = "\n".join([method, canonical_uri, canonical_query, f"host:{parsed.netloc}\n", "host",
                                   "UNSIGNED-PAYLOAD"])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode()).hexdigest()])
    signature = hmac.new(census._signing_key(secret_key, amz_date[:8], region), to_sign.encode(),
                         hashlib.sha256).hexdigest()
    return f"{parsed.scheme}://{parsed.netloc}{canonical_uri}?{canonical_query}&X-Amz-Signature={signature}"


def write_cold_queue(bucket, cold: list[Group], out: Path, now: dt.datetime, signer) -> tuple[int, int]:
    """queue.json for the host and deletes.json (secret: the workflow encrypts it, never uploads it
    plain). Returns the groups and bytes queued."""
    groups, deletes, queued = [], {}, 0
    for group in cold:
        if queued and queued + group.size > COLD_MAX_BYTES:
            break
        objects = []
        for key in delete_order(group):
            data = bucket.read_bytes(key)
            objects.append({"key": key, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
            deletes[key] = signer("DELETE", key)
        groups.append({"family": group.family, "commit": group.id, "objects": objects})
        queued += group.size
    out.mkdir(parents=True, exist_ok=True)
    (out / "queue.json").write_text(json.dumps(
        {"generated": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "bucket": BUCKET,
         "public_base": "https://files.cmux.com", "groups": groups}, indent=1) + "\n")
    fd = os.open(out / "deletes.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(deletes, handle)
    return len(groups), queued


def prune(bucket, now: dt.datetime, *, trunk: set[str], pins: set[str], delete: bool,
          windows: list[list[str]] | None = None, cold_out: Path | None = None, signer=None) -> dict:
    if len(trunk) < MIN_TRUNK_COMMITS:
        raise RuntimeError(f"only {len(trunk)} trunk commits; refusing to prune from a shallow history")
    objects, complete = bucket.list()
    if not complete:
        raise RuntimeError("bucket listing is incomplete; refusing to prune")
    by_family = group_objects(objects)
    ctx = Context(now=now, trunk=trunk, pins=pins,
                  latest=latest_commits(bucket, {item["key"] for item in objects}),
                  tree_commits=tree_commits(bucket, by_family["cmux-tui-tree"]),
                  windows=window_keeps(by_family, windows or []),
                  snapshots=daily_snapshots(by_family, trunk, now))
    deletes, kept, cold = plan(by_family, ctx)
    summary = {"objects": len(objects), "kept": kept, "candidates": {}, "deleted_objects": 0,
               "deleted_bytes": 0, "capped": False, "cold": {}, "cold_queued": (0, 0)}
    for group in cold:
        row = summary["cold"].setdefault(group.family, [0, 0])
        row[0] += 1
        row[1] += group.size
    if delete and cold_out is not None and signer is not None:
        summary["cold_queued"] = write_cold_queue(bucket, cold, cold_out, now, signer)
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
    for family, (count, size) in sorted(summary["cold"].items()):
        lines.append(f"  cold {family}: {count} daily snapshots, {gib(size)}")
    if summary["cold_queued"][0]:
        lines.append(f"  queued for the cold SSDs: {summary['cold_queued'][0]} prefixes, {gib(summary['cold_queued'][1])}")
    for reason, (count, size) in sorted(summary["kept"].items(), key=lambda kv: -kv[1][1]):
        lines.append(f"  {reason}: {count} prefixes, {gib(size)}")
    return "\n".join(lines)


class Bucket(r2_cache_prune.Bucket):
    def list(self) -> tuple[list[dict], bool]:
        return census.collect(self.endpoint_url, self.bucket, lister=r2_storage_census.list_page)

    def read(self, key: str) -> str:
        return self.read_bytes(key).decode("utf-8", "replace")

    def read_bytes(self, key: str) -> bytes:
        return r2_cache_prune.signed("GET", self.endpoint_url, self.bucket, key, timeout=300)


def presign_works(signer) -> bool:
    """The host can only delete with these URLs if R2 accepts the signature: try one GET."""
    try:
        with urllib.request.urlopen(signer("GET", LATEST[0]), timeout=60) as response:
            return json.loads(response.read()).get("commit") is not None
    except (OSError, ValueError):
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--endpoint-url", required=True)
    parser.add_argument("--bucket", default=BUCKET)
    parser.add_argument("--trunk-commits", required=True, type=Path, help="git rev-list output, one sha a line")
    parser.add_argument("--pin-file", action="append", default=[], type=Path)
    parser.add_argument("--windows", type=Path, help="one line per window: commits newest first")
    parser.add_argument("--cold-out", type=Path, help="write queue.json and deletes.json here (with --delete)")
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args(argv)
    trunk = set(SHA.findall(args.trunk_commits.read_text()))
    pins = {sha for path in args.pin_file for sha in SHA.findall(path.read_text())}
    if not pins:
        raise SystemExit("the pin files name no commit; refusing to prune without them")
    windows = [SHA.findall(line) for line in args.windows.read_text().splitlines()] if args.windows else []
    if args.windows and not any(windows):
        raise SystemExit("the windows file names no commit; refusing to prune without it")
    now = dt.datetime.now(dt.timezone.utc)
    bucket = Bucket(args.endpoint_url, args.bucket)
    signer = lambda method, key: presign(method, args.endpoint_url, args.bucket, key, now=now)  # noqa: E731
    cold_out = args.cold_out
    if cold_out is not None and args.delete and not presign_works(signer):
        print("warning: a presigned GET of cmux-tui/latest/manifest.json failed; not queueing cold copies",
              file=sys.stderr)
        cold_out = None
    summary = prune(bucket, now, trunk=trunk, pins=pins, delete=args.delete, windows=windows,
                    cold_out=cold_out, signer=signer)
    print(render(summary, args.delete))
    return 0


if __name__ == "__main__":
    sys.exit(main())
