#!/usr/bin/env python3
"""Reconcile beads, open pull requests and merged work into one idea ledger page.

Every ask becomes one item with one owner and one state:
  idea      a bead or issue with no pull request and nobody building it
  building  a bead in progress with no pull request yet
  pr-open   at least one open pull request
  merged    every pull request merged, not yet in a nightly
  shipped   merged and contained in a nightly release
  verified  shipped and carrying a verified gallery receipt

Items join through what already links them: a pull request that names a bead
(title, body, commits, or the bead-autoclose link comment), a bead whose
external ref is the pull request, and a pull request that closes an issue.
Open pull requests that pursue the same idea are then clustered: by Claude
(`claude -p`, or LEDGER_MODEL_COMMAND) when it is available, otherwise by
shared rarely-touched files and title words. A curated clusters file
(--clusters, JSON list of {"name", "prs", "owner"?}) overrides both. Each
cluster keeps one pull request as its owner and lists the rest to fold in.

Items with no owner, or no movement for 48 hours, or duplicates, sort first.
The page is static HTML (index.html) next to its data (ledger.json), the same page as Markdown
for an issue body (ledger.md) and a short digest (digest.md).

The board is read only, never written. It is reached the way
bead-autoclose.py reaches it (BEADS_SSH_HOST or BEADS_BD_COMMAND), or from a
`bd list --json` export given with --beads. With none of them the ledger is
built from GitHub alone and says so on the page.

Usage: scripts/cmux-next/idea-ledger.py --out DIR [--beads FILE] [--clusters FILE]
       [--no-model] [--days 7] [--now ISO8601]
"""
from __future__ import annotations

import argparse
import collections
import html
import itertools
import json
import math
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = "manaflow-ai/cmux"
BASE = "feat-cmux-next"
ASKERS = ("teamleaderleo", "lawrencecchen")
STALL = timedelta(hours=48)
MAX_FANOUT = 3  # open PRs that may share one bead or issue before it counts as an umbrella
BEAD_ID = re.compile(r"\bcx-[a-z0-9]{2,8}(?:\.[0-9]+)*\b")
CLOSES_BEAD = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(" + BEAD_ID.pattern[2:] + r")", re.I)
CLOSES_ISSUE = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b", re.I)
VERIFIED = re.compile(r"<!--\s*cmux-gallery-link\b[^>]*\bverified\b|\bgallery:\s*verified\b|✅\s*verified", re.I)
GALLERY_URL = re.compile(r"https://[^\s)>\"]{0,200}gallery[^\s)>\"]{0,200}", re.I)
# Only an org member's comment can mark a landed PR verified; a body or outside comment can't.
TRUSTED = ("OWNER", "MEMBER")
STATES = ("idea", "building", "pr-open", "merged", "shipped", "verified")
# Files nearly every change touches say nothing about which idea a change is.
GENERATED = re.compile(r"(Localizable\.xcstrings|/generated/|\.sha256$|Package\.(swift|resolved)$|"
                       r"ci-target-graph|^schemas/|^docs/mdm/|\.lock$|CHANGELOG)")
STOPWORDS = set("a an the of to in on and or for with from by is are be as at it its no not when that "
                "this cmux next cmux-next fix feat chore perf test tests pr ui make makes keep keeps "
                "show shows one each every".split())

OPEN_QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 50, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title body url createdAt isDraft mergeable headRefName
      author { login }
      files(first: 100) { nodes { path } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
      comments(last: 30) { nodes { body createdAt authorAssociation author { login } } }
    } }
  }
}
"""
MERGED_QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 50, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest {
      number title body url mergedAt headRefName mergeCommit { oid }
      author { login }
      comments(last: 30) { nodes { body authorAssociation author { login } } }
    } }
  }
}
"""
ISSUE_QUERY = """
query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 50, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on Issue { number title url createdAt updatedAt author { login } assignees(first: 3) { nodes { login } } } }
  }
}
"""


# ---------------------------------------------------------------- inputs

def search(query: str, q: str) -> list[dict]:
    nodes, after = [], None
    while True:
        args = ["gh", "api", "graphql", "-f", f"query={query}", "-f", f"q={q}"]
        if after:
            args += ["-f", f"after={after}"]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"idea-ledger: GitHub search failed: {(result.stderr or result.stdout).strip()[:300]}")
        found = json.loads(result.stdout)["data"]["search"]
        nodes += [node for node in found["nodes"] if node]
        if not found["pageInfo"]["hasNextPage"]:
            return nodes
        after = found["pageInfo"]["endCursor"]


def published_nightly(tag: str = "nightly-next") -> dict | None:
    """The commit the moving nightly tag last published, from its release body marker."""
    result = subprocess.run(["gh", "api", f"repos/{REPO}/releases/tags/{tag}", "--jq", ".body"],
                            capture_output=True, text=True)
    sha = re.search(r"cmux-published-sha:\s*([0-9a-f]{40})", result.stdout or "")
    if result.returncode or not sha:
        print(f"idea-ledger: no published {tag} commit ({(result.stderr or 'no marker').strip()[:160]}); "
              "landed work shows as merged, not shipped", file=sys.stderr)
        return None
    build = re.search(r"cmux-published-build:\s*(\d+)", result.stdout)
    label = f"{tag} {build.group(1)}" if build else f"{tag} @ {sha.group(1)[:7]}"
    return {"tag": label, "sha": sha.group(1), "url": f"https://github.com/{REPO}/releases/tag/{tag}"}


def nightly_commits(published: str, since: datetime) -> set[str] | None:
    """Commits the published nightly contains, dated after `since` (a squash merge is dated at its
    merge): one local rev-list, else the commits API. None when neither answers."""
    stamp = since.strftime("%Y-%m-%dT%H:%M:%SZ")
    local = subprocess.run(["git", "rev-list", f"--since={stamp}", published], capture_output=True, text=True)
    if local.returncode == 0:
        return set(local.stdout.split())
    found: set[str] = set()
    for page in range(1, 11):
        result = subprocess.run(["gh", "api", f"repos/{REPO}/commits?sha={published}&since={stamp}&per_page=100"
                                 f"&page={page}", "--jq", ".[].sha"], capture_output=True, text=True)
        if result.returncode:
            return None  # a partial listing would mark shipped work as merged
        shas = result.stdout.split()
        found.update(shas)
        if len(shas) < 100:
            return found
    return found


def read_board(path: str | None) -> tuple[list[dict], str]:
    """Beads as a list of dicts, and where they came from (empty when none)."""
    if path:
        data = json.loads(Path(path).read_text())
        return (data if isinstance(data, list) else data.get("issues", [])), f"export {Path(path).name}"
    command = os.environ.get("BEADS_BD_COMMAND")
    host = os.environ.get("BEADS_SSH_HOST")
    if not command and not host:
        return [], ""
    beads: dict[str, dict] = {}
    since = (datetime.now(timezone.utc) - timedelta(days=14)).strftime("%Y-%m-%d")
    for extra in ([], ["--all", "--closed-after", since]):
        args = ["list", "--json", "--readonly", "-n", "5000", *extra]
        # No stdin: the nightly runs from a pipe, and ssh would swallow the rest of the script.
        if command:
            result = subprocess.run([command, *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        else:
            remote = "cd ~/agent-tasks && bd " + " ".join(shlex.quote(arg) for arg in args)
            result = subprocess.run(["ssh", "-n", "-o", "BatchMode=yes", host, remote],
                                    capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if result.returncode:
            print(f"idea-ledger: the board did not answer ({(result.stderr or result.stdout).strip()[:200]})",
                  file=sys.stderr)
            # The open beads still stand without the recently closed ones.
            return (list(beads.values()), "board") if beads else ([], "")
        for bead in json.loads(result.stdout or "[]"):
            beads[bead["id"]] = bead
    return list(beads.values()), "board"


# ---------------------------------------------------------------- linking

def parse_time(text: str | None) -> datetime | None:
    return datetime.fromisoformat(text.replace("Z", "+00:00")) if text else None


def beads_in(*texts: str) -> list[str]:
    return list(dict.fromkeys(m.lower() for text in texts for m in BEAD_ID.findall(text or "")))


AUTOCLOSE_LINK = re.compile(r"Bead `(cx-[a-z0-9.]+)` created for this PR")


def linked_beads(pull: dict, board: set[str]) -> list[str]:
    """The beads a pull request is for: named in its title, closed by its body, or linked by
    bead-autoclose. Passing mentions in bodies and comments chain unrelated work, so they don't
    count. Without the board, an id needs a digit (cx-next, cx-cmux and cx-fleet are words)."""
    found = beads_in(pull.get("title") or "") + [m.lower() for m in CLOSES_BEAD.findall(pull.get("body") or "")]
    found += [m.lower() for c in (pull.get("comments") or {}).get("nodes", [])
              for m in AUTOCLOSE_LINK.findall(c.get("body") or "")]
    return [b for b in dict.fromkeys(found) if (b in board if board else re.search(r"\d", b))]


def pull_texts(pull: dict) -> list[str]:
    return [pull.get("title") or "", pull.get("body") or "",
            *((c.get("body") or "") for c in (pull.get("comments") or {}).get("nodes", []))]


def last_move(pull: dict) -> datetime | None:
    """The latest push or human comment: bot comments and CI do not count as movement."""
    moments = [parse_time(pull.get("createdAt"))]
    moments += [parse_time(((n.get("commit") or {}).get("committedDate")))
                for n in (pull.get("commits") or {}).get("nodes", [])]
    for comment in (pull.get("comments") or {}).get("nodes", []):
        login = ((comment.get("author") or {}).get("login") or "")
        if not login.endswith("[bot]") and "github-actions" not in login:
            moments.append(parse_time(comment.get("createdAt")))
    return max((m for m in moments if m), default=None)


def checks(pull: dict) -> str:
    nodes = (pull.get("commits") or {}).get("nodes", [])
    rollup = ((nodes[-1].get("commit") or {}).get("statusCheckRollup") or {}) if nodes else {}
    return (rollup.get("state") or "").lower()


class Links:
    def __init__(self) -> None:
        self.parent: dict[str, str] = {}

    def find(self, key: str) -> str:
        self.parent.setdefault(key, key)
        while self.parent[key] != key:
            self.parent[key] = self.parent[self.parent[key]]
            key = self.parent[key]
        return key

    def join(self, a: str, b: str) -> None:
        self.parent[self.find(a)] = self.find(b)

    def groups(self) -> list[list[str]]:
        out: dict[str, list[str]] = collections.defaultdict(list)
        for key in list(self.parent):
            out[self.find(key)].append(key)
        return list(out.values())


# ---------------------------------------------------------------- clustering

def title_words(title: str) -> list[str]:
    title = re.sub(r"\(cx-[^)]*\)|#\d+|\b[0-9a-f]{7,}\b", "", title.lower())
    return [w for w in re.findall(r"[a-z][a-z+-]{2,}", title) if w not in STOPWORDS]


def heuristic_clusters(pulls: list[dict], threshold: float = 0.4) -> list[list[int]]:
    """Average-linkage clusters over shared rare files and title words."""
    count = max(len(pulls), 2)
    files = {p["number"]: {f["path"] for f in (p.get("files") or {}).get("nodes", [])
                           if not GENERATED.search(f["path"])} for p in pulls}
    file_df = collections.Counter(path for paths in files.values() for path in paths)
    words = {p["number"]: title_words(p["title"]) for p in pulls}
    word_df = collections.Counter(w for ws in words.values() for w in set(ws))
    vectors = {}
    for number, ws in words.items():
        tally = collections.Counter(ws)
        vec = {w: n * math.log(count / word_df[w]) for w, n in tally.items()}
        norm = math.sqrt(sum(x * x for x in vec.values())) or 1.0
        vectors[number] = {w: x / norm for w, x in vec.items()}
    similar: dict[tuple[int, int], float] = {}
    for a, b in itertools.combinations(files, 2):
        shared = sum(math.log(count / file_df[f]) for f in files[a] & files[b] if file_df[f] <= 6)
        words_alike = sum(x * vectors[b].get(w, 0.0) for w, x in vectors[a].items())
        score = 0.6 * min(1.0, shared / 15) + 0.4 * min(1.0, words_alike / 0.5)
        if score > 0.05:
            similar[(a, b)] = similar[(b, a)] = score
    clusters = [[n] for n in files]
    while True:
        best = None
        for i, j in itertools.combinations(range(len(clusters)), 2):
            total = sum(similar.get((a, b), 0.0) for a in clusters[i] for b in clusters[j])
            if not total:
                continue
            mean = total / (len(clusters[i]) * len(clusters[j]))
            if mean >= threshold and (best is None or mean > best[0]):
                best = (mean, i, j)
        if not best:
            break
        _, i, j = best
        clusters[i] += clusters.pop(j)
    return [sorted(c) for c in clusters if len(c) > 1]


MODEL_PROMPT = """You group open pull requests that serve the same user-facing idea, so one owner can
finish the idea and fold the rest in. Group pull requests that are competing attempts at one thing, or
separate pieces of one small feature that should have landed together (for example a running-status
indicator spread over a settings toggle, a row glyph, a tab badge and a motion fix). Do not group
pull requests that only share an area of the code, or separate features that happen to sit on the
same screen. Candidate groups from file overlap are hints and may be wrong.

Answer with JSON only: {"clusters": [{"name": "<3-6 word idea name>", "prs": [<numbers>], "why": "<one short sentence>"}]}

Pull requests (number | title | beads | top folders):
%(pulls)s

Candidate groups: %(hints)s
"""


MODEL_COMMANDS = ("claude -p --model sonnet", "codex exec --skip-git-repo-check -")


def first_json(text: str, key: str) -> dict | None:
    """The first JSON object in `text` that has `key` (CLIs may echo the answer or add chatter)."""
    decoder = json.JSONDecoder()
    for start in (m.start() for m in re.finditer(r"\{", text)):
        try:
            value, _ = decoder.raw_decode(text[start:])
        except ValueError:
            continue
        if isinstance(value, dict) and key in value:
            return value
    return None


def model_clusters(pulls: list[dict], hints: list[list[int]]) -> list[dict] | None:
    """Clusters from the first model CLI that answers (LEDGER_MODEL_COMMAND, else Claude, else Codex)."""
    commands = [os.environ["LEDGER_MODEL_COMMAND"]] if os.environ.get("LEDGER_MODEL_COMMAND") else MODEL_COMMANDS
    lines = []
    for p in pulls:
        folders = collections.Counter("/".join(f["path"].split("/")[:4])
                                      for f in (p.get("files") or {}).get("nodes", [])
                                      if not GENERATED.search(f["path"]))
        lines.append(f"#{p['number']} | {p['title'][:140]} | {','.join(linked_beads(p, set())) or '-'} | "
                     f"{', '.join(k for k, _ in folders.most_common(2))}")
    prompt = MODEL_PROMPT % {"pulls": "\n".join(lines), "hints": json.dumps(hints)}
    answer = None
    for command in commands:
        try:
            result = subprocess.run(shlex.split(command), input=prompt, capture_output=True, text=True,
                                    timeout=900, cwd=Path(os.environ.get("TMPDIR", "/tmp")))
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"idea-ledger: {command.split()[0]} did not cluster ({error})", file=sys.stderr)
            continue
        answer = first_json(result.stdout, "clusters") if result.returncode == 0 else None
        if answer is not None:
            break
        print(f"idea-ledger: {command.split()[0]} did not cluster (exit {result.returncode}: "
              f"{(result.stderr or result.stdout).strip()[-160:]})", file=sys.stderr)
    if answer is None:
        return None
    clusters = answer.get("clusters") or []
    known = {p["number"] for p in pulls}
    out, taken = [], set()
    for cluster in clusters:
        prs = sorted({int(n) for n in cluster.get("prs", []) if str(n).isdigit() and int(n) in known} - taken)
        taken.update(prs)
        if len(prs) > 1:
            out.append({"name": str(cluster.get("name") or ""), "prs": prs, "why": str(cluster.get("why") or "")})
    return out


# ---------------------------------------------------------------- ledger

def reconcile(open_pulls: list[dict], merged: list[dict], issues: list[dict], beads: list[dict],
              clusters: list[dict], nightly: dict | None, now: datetime) -> list[dict]:
    links = Links()
    board = {b["id"] for b in beads}
    oldest = min((parse_time(p["mergedAt"]) for p in merged), default=now) - timedelta(days=1)
    in_nightly = (nightly_commits(nightly["sha"], oldest) or set()) if nightly and merged else set()
    by_key: dict[str, dict] = {}
    for pull in open_pulls:
        by_key[f"pr:{pull['number']}"] = {**pull, "kind": "pr", "state": "pr-open"}
    for pull in merged:
        by_key.setdefault(f"pr:{pull['number']}", {**pull, "kind": "pr", "state": "merged"})
    for issue in issues:
        by_key[f"issue:{issue['number']}"] = {**issue, "kind": "issue"}
    for bead in beads:
        by_key[f"bead:{bead['id']}"] = {**bead, "kind": "bead"}
    # What each PR links to, and how many open PRs name each bead or issue: one that more than
    # MAX_FANOUT open PRs name is an umbrella, not one idea, so it joins none of them.
    targets = {key: [f"bead:{b}" for b in linked_beads(node, board)]
               + [f"issue:{n}" for n in CLOSES_ISSUE.findall(node.get("body") or "") if f"issue:{n}" in by_key]
               for key, node in by_key.items() if node["kind"] == "pr"}
    fanout = collections.Counter(t for key, ts in targets.items() if by_key[key]["state"] == "pr-open"
                                 for t in set(ts))
    for key, node in list(by_key.items()):
        links.find(key)
        if node["kind"] == "pr":
            for target in targets[key]:
                if fanout[target] > MAX_FANOUT:
                    continue
                if target.startswith("bead:"):
                    by_key.setdefault(target, {"id": target[5:], "kind": "bead", "unseen": True})
                links.join(key, target)
        elif node["kind"] == "bead":
            ref = str(node.get("external_ref") or "")
            pr = re.search(r"/pull/(\d+)", ref)
            if pr and f"pr:{pr.group(1)}" in by_key:
                links.join(key, f"pr:{pr.group(1)}")
    cluster_of: dict[int, dict] = {}
    for cluster in clusters:
        # A PR stays in the first cluster that names it (curated clusters come first).
        members = [n for n in cluster["prs"] if f"pr:{n}" in by_key and n not in cluster_of]
        for a, b in zip(members, members[1:]):
            links.join(f"pr:{a}", f"pr:{b}")
        for n in members:
            cluster_of[n] = cluster

    items = []
    for group in links.groups():
        nodes = [by_key[k] for k in group]
        pulls = [n for n in nodes if n["kind"] == "pr"]
        open_ = [p for p in pulls if p["state"] == "pr-open"]
        landed = [p for p in pulls if p["state"] == "merged"]
        beads_ = [n for n in nodes if n["kind"] == "bead"]
        issues_ = [n for n in nodes if n["kind"] == "issue"]
        known_beads = [b for b in beads_ if not b.get("unseen")]
        if not pulls and known_beads and all(b.get("status") == "closed" for b in known_beads):
            continue  # finished or dropped on the board with nothing on GitHub
        if not pulls and not known_beads and not issues_:
            continue
        item = {"beads": sorted({b["id"] for b in beads_}), "prs": sorted(p["number"] for p in pulls),
                "issues": sorted(i["number"] for i in issues_), "flags": [], "fold": []}
        cluster = next((cluster_of[p["number"]] for p in open_ if p["number"] in cluster_of), None)
        if open_:
            keeper = choose_keeper(open_, known_beads)
            item.update(state="pr-open", title=keeper["title"], url=keeper["url"],
                        owner=owner_of(keeper, known_beads), keeper=keeper["number"],
                        mergeable=keeper.get("mergeable"), checks=checks(keeper),
                        moved=max(filter(None, (last_move(p) for p in open_)), default=None))
            item["fold"] = sorted(p["number"] for p in open_ if p is not keeper)
            if cluster:
                item["cluster"] = {"name": cluster.get("name", ""), "why": cluster.get("why", "")}
            if item["fold"]:
                item["flags"].append("duplicates")
            if keeper.get("mergeable") == "CONFLICTING":
                item["flags"].append("conflicting")
            if item["checks"] in ("failure", "error"):
                item["flags"].append("red")
        elif landed:
            last = max(landed, key=lambda p: p["mergedAt"])
            sha = (last.get("mergeCommit") or {}).get("oid")
            shipped = nightly if sha and sha in in_nightly else None
            verified = any(VERIFIED.search(c.get("body") or "") for p in landed
                           for c in (p.get("comments") or {}).get("nodes", [])
                           if c.get("authorAssociation") in TRUSTED)
            gallery = next((m.group(0) for p in landed for t in pull_texts(p) for m in [GALLERY_URL.search(t)] if m),
                           None)
            item.update(state="verified" if verified and shipped else "shipped" if shipped else "merged",
                        title=last["title"], url=last["url"], owner=f"@{(last.get('author') or {}).get('login', '?')}",
                        moved=parse_time(last["mergedAt"]), nightly=shipped, gallery=gallery,
                        keeper=last["number"])
        else:
            bead = (known_beads or [None])[0]
            issue = (issues_ or [None])[0]
            assignee = next((b.get("assignee") for b in known_beads
                             if b.get("assignee") not in (None, "", "unassigned")), None)
            if not assignee and issue:
                assignee = next((a["login"] for a in (issue.get("assignees") or {}).get("nodes", [])), None)
            building = any(b.get("status") in ("in_progress", "hooked", "blocked") for b in known_beads)
            item.update(state="building" if building else "idea",
                        title=(bead or issue)["title"],
                        url=(issue or {}).get("url") or "",
                        owner=assignee or "",
                        moved=max(filter(None, [parse_time(b.get("updated_at")) for b in known_beads]
                                      + [parse_time((issue or {}).get("updatedAt"))]), default=None))
        if not item["owner"]:
            item["flags"].append("no-owner")
        if item["state"] in ("idea", "building", "pr-open") and item["moved"] and now - item["moved"] > STALL:
            item["flags"].append("stalled")
        items.append(item)
    items.sort(key=sort_key(now))
    return items


def choose_keeper(open_pulls: list[dict], beads: list[dict]) -> dict:
    """The pull request that finishes the idea: the bead's own, else mergeable and green, else freshest."""
    claimed = {str(b.get("external_ref") or "") for b in beads if b.get("status") == "in_progress"}

    def rank(pull: dict) -> tuple:
        moved = last_move(pull)
        return (pull.get("url") in claimed,
                pull.get("mergeable") != "CONFLICTING",
                checks(pull) == "success",
                not pull.get("isDraft"),
                moved.timestamp() if moved else 0.0)
    return max(open_pulls, key=rank)


def owner_of(pull: dict, beads: list[dict]) -> str:
    assignee = next((b.get("assignee") for b in beads if b.get("assignee") not in (None, "", "unassigned")), None)
    return assignee or f"#{pull['number']} ({pull.get('headRefName') or '?'})"


def sort_key(now: datetime):
    def key(item: dict) -> tuple:
        flags = item["flags"]
        trouble = 0 if ("stalled" in flags or "no-owner" in flags) and item["state"] in STATES[:3] else \
            1 if "duplicates" in flags else 2 if item["state"] in STATES[:3] else 3
        moved = item.get("moved")
        return (trouble, -(len(item["fold"])), moved.timestamp() if moved and trouble < 3 else
                -(moved.timestamp() if moved else 0))
    return key


# ---------------------------------------------------------------- output

def age(moment: datetime | None, now: datetime) -> str:
    if not moment:
        return "?"
    hours = (now - moment).total_seconds() / 3600
    return f"{int(hours)}h" if hours < 48 else f"{int(hours // 24)}d"


def pr_link(number: int) -> str:
    return f'<a href="https://github.com/{REPO}/pull/{number}">#{number}</a>'


def render_html(items: list[dict], meta: dict, now: datetime) -> str:
    def row(item: dict) -> str:
        flags = "".join(f'<span class="flag {f}">{f.replace("-", " ")}</span>' for f in item["flags"])
        title = html.escape(item["title"])
        title = f'<a href="{html.escape(item["url"])}">{title}</a>' if item.get("url") else title
        extra = []
        if item.get("cluster", {}).get("name"):
            extra.append(f'<b>{html.escape(item["cluster"]["name"])}</b>: keep {pr_link(item["keeper"])}, '
                         f'fold {", ".join(pr_link(n) for n in item["fold"])}')
        elif item["fold"]:
            extra.append(f'keep {pr_link(item["keeper"])}, fold {", ".join(pr_link(n) for n in item["fold"])}')
        if item.get("nightly"):
            extra.append(f'in <a href="{item["nightly"]["url"]}">{html.escape(item["nightly"]["tag"])}</a>')
        if item.get("gallery"):
            extra.append(f'<a href="{html.escape(item["gallery"])}">gallery</a>')
        if item["beads"]:
            extra.append(" ".join(f"<code>{b}</code>" for b in item["beads"][:4]))
        owner = html.escape(item["owner"]) if item["owner"] else "nobody"
        return (f'<li class="item"><span class="state s-{item["state"]}">{item["state"]}</span>'
                f'<div class="body"><div class="title">{title}</div>'
                f'<div class="meta">{flags}<span>owner {owner}</span><span>moved {age(item.get("moved"), now)} ago</span>'
                f'{"".join(f"<span>{e}</span>" for e in extra)}</div></div></li>')

    counts = collections.Counter(i["state"] for i in items)
    tiles = "".join(f'<div class="tile"><b>{counts.get(s, 0)}</b><span>{s}</span></div>' for s in STATES)
    body = "".join(
        f'<section><h2>{name} <small>{len(rows)}</small></h2><p class="hint">{hint}</p>'
        f'<ol>{"".join(row(i) for i in rows[:SHOWN]) or "<li class=empty>Nothing here.</li>"}</ol>'
        + (f'<details><summary>{len(rows) - SHOWN} more</summary><ol>{"".join(row(i) for i in rows[SHOWN:])}</ol>'
           f'</details>' if len(rows) > SHOWN else "") + '</section>'
        for name, hint, rows in sections(items, now))
    source = meta["beads_source"] or "not read on this run (GitHub only)"
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Idea Ledger</title>
<style>
:root {{ --bg:#fbfbfa; --fg:#1d1d1f; --muted:#6e6e73; --line:#e6e6e3; --card:#fff;
  --idea:#8e8e93; --building:#0a84ff; --open:#bf5af2; --merged:#30b0c7; --shipped:#34c759; --verified:#248a3d;
  --warn:#ff9f0a; --bad:#ff3b30; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#111113; --fg:#f2f2f7;
  --muted:#98989f; --line:#2c2c2e; --card:#1c1c1e; }} }}
:root[data-theme="dark"] {{ --bg:#111113; --fg:#f2f2f7; --muted:#98989f; --line:#2c2c2e; --card:#1c1c1e; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; }}
main {{ max-width:920px; margin:0 auto; padding:24px 16px 64px; }}
h1 {{ font-size:22px; margin:0 0 4px; }} h2 {{ font-size:16px; margin:28px 0 2px; }}
h2 small {{ color:var(--muted); font-weight:500; }} .hint, .sub {{ color:var(--muted); margin:0 0 10px; }}
a {{ color:inherit; text-decoration-color:var(--line); text-underline-offset:2px; }} a:hover {{ text-decoration-color:currentColor; }}
.tiles {{ display:grid; grid-template-columns:repeat(6, 1fr); gap:8px; margin:16px 0 4px; }}
.tile {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:8px 10px; }}
.tile b {{ display:block; font-size:20px; }} .tile span {{ color:var(--muted); font-size:12px; }}
ol {{ list-style:none; margin:0; padding:0; border:1px solid var(--line); border-radius:12px; background:var(--card); overflow:hidden; }}
.item {{ display:flex; gap:10px; padding:9px 12px; border-top:1px solid var(--line); }} .item:first-child {{ border-top:0; }}
.empty {{ padding:10px 12px; color:var(--muted); }}
.state {{ flex:0 0 68px; font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.03em; padding-top:2px; }}
.s-idea {{ color:var(--idea); }} .s-building {{ color:var(--building); }} .s-pr-open {{ color:var(--open); }}
.s-merged {{ color:var(--merged); }} .s-shipped {{ color:var(--shipped); }} .s-verified {{ color:var(--verified); }}
.body {{ min-width:0; }} .title {{ font-weight:500; overflow-wrap:anywhere; }}
.meta {{ display:flex; flex-wrap:wrap; gap:4px 12px; color:var(--muted); font-size:12px; margin-top:2px; }}
.flag {{ font-weight:600; }} .flag.stalled, .flag.no-owner {{ color:var(--bad); }} .flag.duplicates, .flag.conflicting, .flag.red {{ color:var(--warn); }}
code {{ font-size:11px; }}
details {{ margin-top:6px; }} summary {{ color:var(--muted); cursor:pointer; padding:4px 2px; }}
@media (max-width:600px) {{ .tiles {{ grid-template-columns:repeat(3, 1fr); }} .state {{ flex-basis:56px; }} }}
</style></head><body><main>
<h1>Idea ledger</h1>
<p class="sub">{len(items)} items from {meta['open']} open pull requests on {BASE}, {meta['merged']} merged in {meta['days']} days,
{meta['issues']} asks in issues touched this month ({meta['dormant']} older ones not listed) and {meta['beads']} beads (beads: {html.escape(source)}). Clusters by {html.escape(meta['clustered_by'])}.
Built {now.strftime('%Y-%m-%d %H:%M UTC')}.</p>
<div class="tiles">{tiles}</div>
{body}
</main></body></html>
"""


SHOWN = 12  # rows per section before the rest fold away; the page is for a one-minute scan


def sections(items: list[dict], now: datetime) -> list[tuple[str, str, list[dict]]]:
    trouble = {"stalled", "no-owner"}
    day = now - timedelta(hours=24)
    stuck = [i for i in items if i["state"] in STATES[:3] and trouble & set(i["flags"])]
    recent_first = lambda i: -(i["moved"].timestamp() if i.get("moved") else 0)  # noqa: E731
    return [
        ("Stalled pull requests", "Open, and nothing pushed or said in 48 hours. The most recently stalled first.",
         sorted([i for i in stuck if i["state"] == "pr-open"], key=recent_first)),
        ("Duplicates to fold", "One idea, several open pull requests. Keep one, fold the rest.",
         [i for i in items if "duplicates" in i["flags"] and not trouble & set(i["flags"])]),
        ("Asks with no owner", "Issues and beads nobody has taken. The newest first.",
         sorted([i for i in stuck if i["state"] != "pr-open" and "no-owner" in i["flags"]], key=recent_first)),
        ("Asks owned but quiet", "Someone has it, and nothing moved in 48 hours.",
         sorted([i for i in stuck if i["state"] != "pr-open" and "no-owner" not in i["flags"]], key=recent_first)),
        ("Moving", "Owned and moved in the last 48 hours.",
         [i for i in items if i["state"] in STATES[:3] and not (trouble | {"duplicates"}) & set(i["flags"])]),
        ("Landed", "Merged and not yet in a nightly, then everything that landed in the last 24 hours.",
         [i for i in items if i["state"] == "merged"]
         + [i for i in items if i["state"] in STATES[4:] and i.get("moved") and i["moved"] >= day]),
    ]


ISSUE_BODY_LIMIT = 60000  # GitHub refuses bodies over 65,536 characters


def render_markdown(items: list[dict], meta: dict, now: datetime, limit: int = SHOWN) -> str:
    """The same page as Markdown for a GitHub issue body: each section's top rows as a table, the
    rest as one-line links in a collapsed list, dropped section by section if the body runs long."""
    def cell(text: str) -> str:
        # Escaped so a title can't open an HTML comment or tag that hides the rest of the body.
        return html.escape(text, quote=False).replace("|", "\\|").replace("\n", " ")

    counts = collections.Counter(i["state"] for i in items)
    out = [f"**{len(items)} items**: " + " · ".join(f"{counts.get(s, 0)} {s}" for s in STATES),
           f"From {meta['open']} open pull requests on `{BASE}`, {meta['merged']} merged in {meta['days']} days, "
           f"{meta['issues']} asks in issues touched this month ({meta['dormant']} older ones not listed) and {meta['beads']} beads "
           f"({meta['beads_source'] or 'beads not read on this run'}). Clusters by {meta['clustered_by']}. "
           f"Built {now.strftime('%Y-%m-%d %H:%M UTC')}.", ""]
    folded: list[tuple[int, str, str]] = []
    nonce = os.urandom(6).hex()  # escaped titles can't contain a marker, but don't rely on it
    for name, hint, rows in sections(items, now):
        out += [f"### {name} ({len(rows)})", hint, ""]
        if not rows:
            out += ["Nothing here.", ""]
            continue
        out += ["| State | Item | Owner | Moved | Notes |", "| --- | --- | --- | --- | --- |"]
        for item in rows[:limit]:
            title = cell(item["title"][:90])
            title = f"[{title}]({item['url']})" if item.get("url") else title
            notes = [f.replace("-", " ") for f in item["flags"] if f != "duplicates"]
            if item["fold"]:
                name_ = item.get("cluster", {}).get("name")
                notes.append(f"{cell(name_) + ': ' if name_ else ''}keep #{item['keeper']}, fold "
                             + ", ".join(f"#{n}" for n in item["fold"]))
            if item.get("nightly"):
                notes.append(f"in [{item['nightly']['tag']}]({item['nightly']['url']})")
            if item.get("gallery"):
                notes.append(f"[gallery]({item['gallery']})")
            if item["beads"]:
                notes.append(" ".join(f"`{b}`" for b in item["beads"][:3]))
            out.append(f"| {item['state']} | {title} | {cell(item['owner'] or '**nobody**')} | "
                       f"{age(item.get('moved'), now)} | {'; '.join(notes)} |")
        if len(rows) > limit:
            rest = "\n".join(f"- {item['state']}: " + (f"[{cell(item['title'][:80])}]({item['url']})"
                                                      if item.get("url") else cell(item["title"][:80]))
                             + f" · {cell(item['owner'] or 'nobody')} · {age(item.get('moved'), now)}"
                             for item in rows[limit:])
            marker = f"<!-- folded {nonce} {len(folded)} -->"
            folded.append((len(rows) - limit, marker,
                           f"\n<details><summary>{len(rows) - limit} more</summary>\n\n{rest}\n\n</details>"))
            out.append(marker)
        out.append("")
    body = "\n".join(out)
    # Expand the folded lists while they fit; a list that doesn't becomes a count.
    for count, marker, full in folded:
        room = ISSUE_BODY_LIMIT - len(body) + len(marker)
        body = body.replace(marker, full if len(full) <= room else f"\n{count} more not shown (the body is full).")
    if len(body) > ISSUE_BODY_LIMIT:  # the tables alone can't push the issue past GitHub's limit
        body = body[:ISSUE_BODY_LIMIT].rsplit("\n", 1)[0] + "\n\n(cut at the issue size limit)"
    return body


def render_digest(items: list[dict], meta: dict, now: datetime) -> str:
    stuck = [i for i in items if i["state"] in STATES[:3] and {"stalled", "no-owner"} & set(i["flags"])]
    stalled_prs = sum(i["state"] == "pr-open" for i in stuck)
    dups = [i for i in items if i["fold"]]
    folded = sum(len(i["fold"]) for i in dups)
    lines = [f"Idea ledger {now.strftime('%Y-%m-%d')}: {stalled_prs} stalled pull requests, "
             f"{len(stuck) - stalled_prs} asks stuck, {len(dups)} ideas with "
             f"{folded} duplicate pull requests to fold, "
             f"{sum(i['state'] in STATES[3:] for i in items)} landed in {meta['days']} days.", ""]
    for item in dups[:15]:
        name = item.get("cluster", {}).get("name") or item["title"][:60]
        lines.append(f"- {name}: keep #{item['keeper']}, fold {', '.join(f'#{n}' for n in item['fold'])}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--out", required=True, help="directory for index.html, ledger.json and digest.md")
    parser.add_argument("--beads", help="a `bd list --json` export to read instead of the board")
    parser.add_argument("--clusters", help="curated clusters JSON that overrides the computed ones")
    parser.add_argument("--no-model", action="store_true", help="cluster by files and titles only")
    parser.add_argument("--days", type=int, default=3, help="merged window in days (default 3)")
    parser.add_argument("--replay", help="rebuild from a raw.json an earlier run saved, without GitHub")
    parser.add_argument("--now", help="the time to judge movement against (default: now)")
    args = parser.parse_args()
    now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
    since = (now - timedelta(days=args.days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.replay:
        raw = json.loads(Path(args.replay).read_text())
    else:
        raw = {"open": search(OPEN_QUERY, f"repo:{REPO} is:pr is:open base:{BASE}"),
               "merged": search(MERGED_QUERY, f"repo:{REPO} is:pr is:merged base:{BASE} merged:>={since}"),
               # One search per asker: repeated qualifiers in one search may AND together.
               "issues": [issue for login in ASKERS for issue in
                          search(ISSUE_QUERY, f"repo:{REPO} is:issue is:open author:{login}")],
               "nightly": published_nightly()}
    open_pulls, merged, nightly = raw["open"], raw["merged"], raw["nightly"]
    # Asks nobody touched in 30 days are counted, not listed: the page is for this month's work.
    recent = (now - timedelta(days=30)).isoformat()
    issues = [i for i in raw["issues"] if (parse_time(i.get("updatedAt")) or now).isoformat() >= recent]
    dormant = len(raw["issues"]) - len(issues)
    beads, beads_source = read_board(args.beads)

    hints = heuristic_clusters(open_pulls)
    clustered_by = "shared files and titles"
    clusters = [{"name": "", "prs": c, "why": ""} for c in hints]
    if not args.no_model:
        found = model_clusters(open_pulls, hints)
        if found is not None:
            clusters, clustered_by = found, "a model reading titles, beads and files"
    if args.clusters:
        curated = json.loads(Path(args.clusters).read_text())
        taken = {n for c in curated for n in c["prs"]}
        clusters = curated + [c for c in clusters if not taken & set(c["prs"])]
        clustered_by += " plus curated clusters"

    items = reconcile(open_pulls, merged, issues, beads, clusters, nightly, now)
    meta = {"open": len(open_pulls), "merged": len(merged), "issues": len(issues), "dormant": dormant,
            "beads": len(beads),
            "beads_source": beads_source, "clustered_by": clustered_by, "days": args.days}
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if not args.replay:
        (out / "raw.json").write_text(json.dumps(raw) + "\n")
    (out / "index.html").write_text(render_html(items, meta, now))
    (out / "digest.md").write_text(render_digest(items, meta, now))
    (out / "ledger.md").write_text(render_markdown(items, meta, now))
    (out / "ledger.json").write_text(json.dumps(
        {"built": now.isoformat(), "meta": meta, "clusters": clusters, "items": items},
        default=lambda v: v.isoformat() if isinstance(v, datetime) else str(v), indent=1) + "\n")
    print((out / "digest.md").read_text(), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
