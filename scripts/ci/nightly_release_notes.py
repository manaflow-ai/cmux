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
from datetime import datetime, timedelta
from urllib.parse import quote
from xml.dom import minidom

MARKER = re.compile(r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->", re.I)
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPAIR = "https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
# Pages of 25 merged PRs read before giving up (newest update first).
MERGED_PR_PAGES = 80
PR_FIELDS = """number title url mergedAt baseRefName mergeCommit { oid }
                labels(first: 100) { nodes { name } }
                files(first: 100) { totalCount nodes { path } }"""


class TransientGitHubError(RuntimeError):
    """A GitHub 5xx or timeout that persisted through the request retries."""


# A 4xx is a real access or request error. Anything else (a 5xx, a timeout,
# an empty or cut-off body: "unexpected end of JSON input") is retried.
CLIENT_ERROR = re.compile(r"HTTP 4\d\d")


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    @staticmethod
    def request(args: list[str]) -> dict:
        for attempt in range(3):
            try:
                result = subprocess.run(["gh", "api", *args], capture_output=True, text=True, timeout=90)
            except subprocess.TimeoutExpired:
                result = None
            if result is not None and not result.returncode:
                break
            transient = result is None or not CLIENT_ERROR.search(result.stderr or "")
            if not transient:
                raise RuntimeError("GitHub metadata request failed; check Actions token contents/pull-requests read access and API availability")
            if attempt < 2:
                time.sleep(5 * (attempt + 1))
        else:
            raise TransientGitHubError("GitHub metadata request kept failing with a server error or timeout; retry later")
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
    base_date = ((comparison.get("base_commit") or {}).get("commit") or {}).get("committer", {}).get("date")
    if not base_date:
        raise RuntimeError("GitHub compare returned no base commit date; retry metadata generation")
    # A PR merged into the range was updated at or after its merge, which is
    # after the base commit; a day of slack covers clock skew between the two.
    cutoff = datetime.fromisoformat(base_date.replace("Z", "+00:00")) - timedelta(days=1)
    prs = {}
    cursor = None
    for _ in range(MERGED_PR_PAGES):
        after = f", after: {json.dumps(cursor)}" if cursor else ""
        result = github.graphql(
            "query { " + repository + f" {{ pullRequests(baseRefName: {json.dumps(branch)}, states: MERGED, "
            f"first: 25, orderBy: {{field: UPDATED_AT, direction: DESC}}{after}) {{ "
            f"pageInfo {{ hasNextPage endCursor }} nodes {{ updatedAt {PR_FIELDS} }} }} }} }}")
        page = result["pullRequests"]
        for pr in page["nodes"]:
            merged = pr.get("mergeCommit") or {}
            if pr["mergedAt"] and pr["baseRefName"] == branch and merged.get("oid") in members:
                prs[pr["number"]] = pr
        nodes = page["nodes"]
        oldest = min((datetime.fromisoformat(pr["updatedAt"].replace("Z", "+00:00")) for pr in nodes), default=None)
        if not page["pageInfo"]["hasNextPage"] or oldest is None or oldest < cutoff:
            break
        cursor = page["pageInfo"].get("endCursor")
        if not cursor:
            raise RuntimeError("GitHub merged PRs pagination returned no cursor; retry metadata generation")
    else:
        raise RuntimeError(f"More than {MERGED_PR_PAGES * 25} merged PRs since the published build; inspect the channel marker")
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


def metadata_fallback(repo: str, base: str | None, head: str) -> tuple[str, str]:
    """Notes for a build whose PR metadata GitHub would not serve."""
    if base:
        link = f"https://github.com/{repo}/compare/{base}...{head}"
        plain = f"Change list unavailable; see {link}"
    else:
        link = f"https://github.com/{repo}/commit/{head}"
        plain = "Change list unavailable; see the release page for build details."
    return f"## Changes\n\nThe change list could not be read from GitHub for this build. [Compare the changes]({link}).\n", plain


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
    base = None
    try:
        release = github.rest(f"releases/tags/{quote(args.tag, safe='')}")
        base = published_sha(release.get("body") or "")
        if base is None:
            print(f"::warning::No previous publication marker; restore cmux-published-sha in the release body to recover the change range. Repair: {REPAIR}")
        prs = collect_prs(github, base, args.head, args.branch) if base else []
        markdown, plain = summarize(prs, args.repo, base, args.head)
    except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError) as error:
        # The change list is cosmetic: a nightly is never lost to GitHub metadata. The marker below
        # and the appcast descriptions still name this build, and the compare link covers the range.
        print(f"::warning::Publishing without a change list: {error}")
        markdown, plain = metadata_fallback(args.repo, base, args.head)
        prs = []
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
