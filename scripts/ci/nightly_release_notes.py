#!/usr/bin/env python3
"""Summarize merged PRs between verified nightly publications, without changing assets."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import quote
from xml.dom import minidom

MARKER = re.compile(r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->", re.I)
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
COMMIT_BATCH = 4
PR_LIMIT = 5
LABEL_LIMIT = 20
MAX_PAGES = 50
FILE_LIMIT = 30
TRANSIENT = re.compile(r"HTTP 5\d\d|timed? ?out|timeout", re.I)
REPAIR = "https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    @staticmethod
    def request(args: list[str]) -> dict:
        # GitHub answers a heavy GraphQL batch with a transient 5xx now and
        # then; retry those with backoff. Other failures stop immediately.
        for attempt in range(4):
            try:
                result = subprocess.run(["gh", "api", *args], capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired:
                result = subprocess.CompletedProcess(args, 1, "", "timeout")
            if not result.returncode or not TRANSIENT.search(result.stderr) or attempt == 3:
                break
            time.sleep(2 ** (attempt + 1))
        if result.returncode:
            raise RuntimeError("GitHub metadata request failed; check Actions token contents/pull-requests read access and API availability")
        value = json.loads(result.stdout)
        if isinstance(value, dict) and value.get("errors"):
            raise RuntimeError("GitHub GraphQL metadata query returned errors; retry after checking API access")
        return value

    def rest(self, endpoint: str) -> dict:
        return self.request([f"repos/{self.repo}/{endpoint}"])

    def graphql(self, query: str) -> dict:
        return self.request(["graphql", "-f", f"query={query}"])["data"]["repository"]


def published_sha(body: str) -> str | None:
    match = MARKER.search(body)
    return match.group(1).lower() if match else None


def collect_prs(github: GitHub, base: str, head: str, branch: str) -> list[dict]:
    """Use commit membership, not merge dates, so late/backported PRs cannot leak in."""
    if base == head:
        return []
    commits = []
    for page in range(1, 101):
        comparison = github.rest(f"compare/{base}...{head}?per_page=100&page={page}")
        if comparison["status"] == "diverged" and branch.startswith("rc/") and page == 1:
            # A new RC line is a new rc/vX.Y.Z branch cut from main, so the
            # previous line's published commit is not its ancestor. Summarize
            # from where the two lines split.
            merge_base = (comparison.get("merge_base_commit") or {}).get("sha")
            if merge_base and merge_base != base:
                return collect_prs(github, merge_base, head, branch)
        if comparison["status"] not in ("ahead", "identical"):
            raise RuntimeError("Published SHA is not an ancestor of the built SHA; verify the channel marker before retrying")
        commits.extend(c["sha"] for c in comparison["commits"])
        if len(commits) >= comparison["total_commits"]:
            break
        if not comparison["commits"]:
            raise RuntimeError("GitHub compare pagination ended early; retry metadata generation")
    else:
        raise RuntimeError("More than 10000 commits since publication; repair the channel marker before retrying")
    owner, name = github.repo.split("/")
    repository = "repository(owner: " + json.dumps(owner) + ", name: " + json.dumps(name) + ")"
    members = set(commits)
    prs = {}
    # Keep each query small (was 10 commits x 10 PRs x 100 labels x 100 files,
    # which timed out in run 45858610960). Larger lists are paged, never cut:
    # a commit's PRs and a PR's labels page with `after:`; a PR whose files
    # exceed FILE_LIMIT counts as product (see infrastructure()).
    pr_fields = (f"pageInfo {{ hasNextPage endCursor }} nodes {{ number title url mergedAt baseRefName mergeCommit {{ oid }} "
                 f"labels(first: {LABEL_LIMIT}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ name }} }} "
                 f"files(first: {FILE_LIMIT}) {{ totalCount nodes {{ path }} }} }}")

    def commit_query(alias: str, sha: str, cursor: str | None = None) -> str:
        after = f", after: {json.dumps(cursor)}" if cursor else ""
        return (f'{alias}: object(oid: "{sha}") {{ ... on Commit {{ associatedPullRequests(first: {PR_LIMIT}{after}) '
                f"{{ {pr_fields} }} }} }}")

    def read(fields: str) -> dict:
        return github.graphql("query { " + repository + " { " + fields + " } }")

    def associated_prs(obj: dict, sha: str) -> list[dict]:
        nodes = []
        for _ in range(MAX_PAGES):
            associated = obj["associatedPullRequests"]
            nodes += associated["nodes"]
            if not associated["pageInfo"]["hasNextPage"]:
                return nodes
            cursor = associated["pageInfo"].get("endCursor")
            if not cursor:
                raise RuntimeError("GitHub associated PR pagination returned no cursor; retry metadata generation")
            obj = read(commit_query("c0", sha, cursor))["c0"]
            if obj is None:
                raise RuntimeError("GitHub could not resolve a compared commit; retry metadata generation")
        raise RuntimeError("A commit has too many associated PRs; inspect its associations before retrying")

    def complete_labels(pr: dict) -> None:
        """category() needs the call labels wherever they sit in the list."""
        labels = pr.get("labels") or {}
        for _ in range(MAX_PAGES):
            info = labels.get("pageInfo") or {}
            if not info.get("hasNextPage") or any(CALL_LABEL(x["name"]) for x in labels.get("nodes", [])):
                return
            cursor = info.get("endCursor")
            if not cursor:
                raise RuntimeError("GitHub label pagination returned no cursor; retry metadata generation")
            page = read(f'pr: pullRequest(number: {int(pr["number"])}) {{ labels(first: {LABEL_LIMIT}, after: {json.dumps(cursor)}) '
                        "{ pageInfo { hasNextPage endCursor } nodes { name } } }")["pr"]["labels"]
            labels = {"pageInfo": page["pageInfo"], "nodes": labels.get("nodes", []) + page["nodes"]}
            pr["labels"] = labels
        raise RuntimeError("A PR has too many labels; inspect its labels before retrying")

    for offset in range(0, len(commits), COMMIT_BATCH):
        batch = commits[offset:offset + COMMIT_BATCH]
        result = read(" ".join(commit_query(f"c{index}", sha) for index, sha in enumerate(batch)))
        for index, sha in enumerate(batch):
            obj = result.get(f"c{index}")
            if obj is None:
                raise RuntimeError("GitHub could not resolve a compared commit; retry metadata generation")
            for pr in associated_prs(obj, sha):
                merged = pr.get("mergeCommit") or {}
                # An RC branch is cut from main and gets picks, so its notes
                # include PRs merged to main in the compared range.
                bases = {branch, "main"} if branch.startswith("rc/") else {branch}
                if pr["mergedAt"] and pr["baseRefName"] in bases and merged.get("oid") in members:
                    if pr["number"] not in prs:
                        complete_labels(pr)
                    prs[pr["number"]] = pr
    return list(prs.values())


def infrastructure(pr: dict) -> bool:
    title = pr["title"].strip().lower()
    if re.match(r"^(ci|docs?|tests?)(\([^)]*\))?\s*[:!]", title):
        return True
    files = pr.get("files", {})
    paths = [f["path"] for f in files.get("nodes", [])]
    if not paths or len(paths) != files.get("totalCount"):
        return False
    return all(p.startswith((".github/", "docs/", "tests/", "cmuxTests/", "cmuxUITests/", "scripts/ci/"))
               or p.endswith((".md", ".mdx")) or "/Tests/" in p for p in paths)


def CALL_LABEL(name: str) -> bool:
    return name.lower().replace("-", " ") in {"default call", "needs a call"}


def category(pr: dict) -> str:
    labels = {x["name"].lower().replace("-", " ") for x in pr.get("labels", {}).get("nodes", [])}
    title = pr["title"].lower()
    if labels & {"default call", "needs a call"} or re.search(r"\bdefaults?\b", title):
        return "Changed defaults"
    if re.match(r"^(feat|new)(\([^)]*\))?\s*[:!]", title) or re.match(r"^(add|introduce|support|enable|show)\b", title):
        return "New"
    return "Fixes"


def clean_title(title: str) -> str:
    return " ".join(title.split())


def markdown_title(title: str) -> str:
    return re.sub(r"([\\`*_\[\]<>])", r"\\\1", clean_title(title))


def summarize(prs: list[dict], repo: str, base: str | None, head: str, limit: int = 40) -> tuple[str, str]:
    ordered = sorted({p["number"]: p for p in prs}.values(), key=lambda p: (p["mergedAt"], p["number"]), reverse=True)
    infra = sum(infrastructure(p) for p in ordered)
    product = [p for p in ordered if not infrastructure(p)]
    visible = product[:limit]
    lines = ["## What changed", ""]
    if base is None:
        lines += ["The previous published commit was not recorded, so a change range is not available for this build.", ""]
    elif not product:
        lines += ["No product PRs merged since the previous published build.", ""]
    for group in ("Fixes", "New", "Changed defaults"):
        entries = [p for p in visible if category(p) == group]
        if entries:
            lines += [f"### {group}", ""]
            lines += [f'- {markdown_title(p["title"])} ([#{p["number"]}](https://github.com/{repo}/pull/{p["number"]}))' for p in entries]
            lines += [""]
    if len(product) > limit:
        lines += [f"[and {len(product) - limit} more](https://github.com/{repo}/compare/{base}...{head})", ""]
    if infra:
        lines += [f"Infrastructure: {infra}", ""]
    if base and base != head:
        lines += [f"[Compare published builds](https://github.com/{repo}/compare/{base}...{head})", ""]
    plain_lines = [f'{clean_title(p["title"])} (#{p["number"]})' for p in product[:5]]
    if len(product) > 5:
        plain_lines.append(f"and {len(product) - 5} more")
    if infra:
        plain_lines.append(f"Infrastructure: {infra}")
    plain = "\n".join(plain_lines)
    if not plain:
        plain = "No product PRs merged since the previous published build." if base else "See the release page for build details."
    return "\n".join(lines), plain


def update_appcasts(directory: Path, build: str, summary: str) -> None:
    expected = {"appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml"}
    feeds = sorted(directory.glob("appcast*.xml"))
    if {feed.name for feed in feeds} != expected:
        raise RuntimeError("Expected all four nightly appcasts before generating notes; download the complete signed variant artifacts")
    # Build all replacements before writing, so a missing current item fails cleanly.
    replacements = []
    for feed in feeds:
        doc = minidom.parse(str(feed))
        matches = []
        for item in doc.getElementsByTagName("item"):
            versions = item.getElementsByTagNameNS(SPARKLE, "version")
            enclosures = item.getElementsByTagName("enclosure")
            if any(v.firstChild and v.firstChild.nodeValue == build for v in versions) or any(e.getAttributeNS(SPARKLE, "version") == build for e in enclosures):
                matches.append(item)
        if len(matches) != 1:
            raise RuntimeError(f"{feed.name} must contain exactly one item for build {build}; check downloaded artifacts")
        item = matches[0]
        for old in list(item.childNodes):
            if old.nodeType == old.ELEMENT_NODE and old.tagName == "description":
                item.removeChild(old)
        description = doc.createElement("description")
        description.appendChild(doc.createTextNode(summary))
        item.appendChild(description)
        replacements.append((feed, doc.toxml(encoding="utf-8")))
    for feed, xml in replacements:
        feed.write_bytes(xml)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--details", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--appcasts", type=Path, required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or not re.fullmatch(r"[0-9a-f]{40}", args.head):
        raise ValueError("Expected owner/repo and a full built SHA")
    github = GitHub(args.repo)
    release = github.rest(f"releases/tags/{quote(args.tag, safe='')}")
    base = published_sha(release.get("body") or "")
    if base is None:
        print(f"::warning::No previous publication marker; restore cmux-published-sha in the release body to recover the change range. Repair: {REPAIR}")
    prs = collect_prs(github, base, args.head, args.branch) if base else []
    markdown, plain = summarize(prs, args.repo, base, args.head)
    body = markdown + "\n## Downloads\n\n" + args.details.read_text()
    args.out.write_text(body)
    args.out.with_suffix(".published.md").write_text(f"<!-- cmux-published-sha: {args.head} -->\n" + body)
    update_appcasts(args.appcasts, args.build, plain)
    print(f"Prepared nightly notes for {len(prs)} merged PRs; baseline {base or 'unavailable'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"::error::{error}. Fix metadata access, publication marker, or downloaded appcasts and rerun the publish job. Repair: {REPAIR}", file=sys.stderr)
        sys.exit(1)
