#!/usr/bin/env python3
"""TestFlight "What to Test" notes for the cmux-next INTERNAL iOS builder.

Design: plans/cmux-next/ios-testflight-builder-DESIGN.md ("What to Test").

The note lists what changed in the iPhone app between the last uploaded build
(BASE) and the build's commit (SHA): the `## Changelog` lines of the pull
requests whose commits in BASE..SHA touch the app's paths, grouped under
Added / Changed / Fixed / Removed. A commit with no pull request contributes
its subject under "Other changes". The first line names the version, the
commit and the audience; the commit there is how the next build finds its
BASE in App Store Connect.

  ios_internal_notes.py notes --sha SHA [--base SHA] [--asc-ref HEX] [--repo DIR] [--out FILE]
      writes the note (needs GH_TOKEN; no signing secret)
  ios_internal_notes.py asc-previous [--app ID]
      prints the commit recorded in the newest processed build's note
      (needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH; reads only)
"""
from __future__ import annotations

import argparse
import base64
import dataclasses
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

REPO = "manaflow-ai/cmux"
BRANCH = "feat-cmux-next"
APP_ID = "6791408425"  # App Store Connect "cmux INTERNAL", dev.cmux.app.internal
LIMIT = 4000  # App Store Connect's What to Test limit, in characters
ITEM_MAX = 300
UNKNOWN_BASE_LINES = 20
UNKNOWN_BASE_COMMITS = 200
GRAPHQL_BATCH = 25
BUILD_WORKFLOWS = ("ios-internal-nightly.yml", "cnx-ios-testflight.yml")  # the builder, then the retired manual lane

# The iPhone app's sources besides the local packages cmux-next-ios/CmuxMobileKit/Package.swift
# names. `cnx-ios/` is the same app before the 2026-10-20 rename: a range that spans the rename
# still lists its older commits. Builder files (workflows, scripts) change no app behavior and are
# left out.
APP_PREFIXES = (
    "cmux-next-ios/",
    "cnx-ios/",
    "AppIcon.icon/",
    "cmux-tui/crates/cmux-wg/",
    "cmux-tui/crates/cmux-transport/",
)
CATEGORIES = ("Added", "Changed", "Fixed", "Removed")
OTHER = "Other changes"
ALIASES = {"added": "Added", "add": "Added", "new": "Added", "changed": "Changed", "change": "Changed",
           "improved": "Changed", "fixed": "Fixed", "fix": "Fixed", "fixes": "Fixed", "removed": "Removed",
           "remove": "Removed"}
# "abc123def456" after the branch name in the first line; older builds wrote 10 hex digits.
RECORDED_SHA = re.compile(r"\bfeat-cmux-next ([0-9a-f]{10,40})\b")
INTERNAL_TYPES = {"test", "tests", "ci", "docs", "doc", "chore", "lint", "style", "build", "refactor", "bench"}

_BUILDER = None


def builder():
    """scripts/ci/ios_internal_builder.py (package paths, marketing version); loaded by path so `python3 -I` works."""
    global _BUILDER
    if _BUILDER is None:
        spec = importlib.util.spec_from_file_location("ios_internal_builder", Path(__file__).with_name("ios_internal_builder.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules.setdefault("ios_internal_builder", module)  # its dataclasses look their module up
        spec.loader.exec_module(module)
        _BUILDER = module
    return _BUILDER


# ---- pure logic (tests/test_ios_internal_notes.py) ----

@dataclasses.dataclass(frozen=True)
class Entry:
    category: str  # one of CATEGORIES or OTHER
    text: str


HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
BULLET = re.compile(r"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?")
CATEGORY_LINE = re.compile(
    r"^(?:\*\*|__)?\s*(?P<cat>[A-Za-z]+)\s*(?:\*\*|__)?\s*(?::|\s[-–—]\s?)\s*(?:\*\*|__)?\s*(?P<rest>.*)$")
THEMATIC_BREAK = re.compile(r"(?:-\s*){3,}|(?:\*\s*){3,}|(?:_\s*){3,}")
FOOTER = re.compile(r"generated with \[?claude|^co-authored-by:|^signed-off-by:", re.I)
NONE_LINE = re.compile(r"^(?:none|n/?a|no user[- ]visible changes?)\s*(?:[-\u2013\u2014:,]\s*.*|\(.*\))?\.?$", re.I)


def _clean(text: str) -> str:
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)  # images
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # links keep their words
    text = re.sub(r"(\*\*|__)(.+?)\1", r"\2", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"\1", text)
    text = text.replace("`", "")
    text = re.sub(r"\s+", " ", text).strip().strip("*_").strip()
    if len(text) > ITEM_MAX:
        cut = text[:ITEM_MAX - 1].rsplit(" ", 1)[0]
        text = cut.rstrip(",;:") + "…"
    if re.match(r"(?i)cmux\b|cnx\b", text):  # brand names stay lowercase
        return text
    return text[:1].upper() + text[1:]


def _category(word: str) -> str | None:
    return ALIASES.get(word.lower())


def parse_changelog(body: str | None) -> list[Entry] | None:
    """The user-facing lines of a PR body's `## Changelog` section.

    None when the body has no such section (or only the template comment);
    [] when the section says `none`. A line names its category inline
    ("Fixed: ...", "- **Added:** ...") or under a category line or heading
    ("### Fixed", "Fixed:"); a line with neither is "Changed".
    """
    if not body:
        return None
    body = re.sub(r"<!--.*?-->", "", body.replace("\r\n", "\n"), flags=re.S)
    lines = body.split("\n")
    start = level = None
    for i, line in enumerate(lines):
        m = HEADING.match(line)
        if m and re.fullmatch(r"(?i)change\s*log:?", m.group(2).strip()):
            start, level = i + 1, len(m.group(1))
            break
    if start is None:
        return None
    entries: list[Entry] = []
    current: str | None = None  # from a category heading or a bare "Fixed:" line
    last: str | None = None  # the last inline category: a plain bullet after "Fixed: A" is a fix too
    saw_text = False
    in_details = False
    in_fence = False
    for line in lines[start:]:
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = HEADING.match(line)
        if m:
            cat = _category(m.group(2).strip().strip(":*_ "))
            if cat and len(m.group(1)) > level:
                current = cat
                continue
            break
        if THEMATIC_BREAK.fullmatch(stripped) or FOOTER.search(stripped):
            break  # what follows is a footer (a bot badge, "Generated with ...", trailers)
        if re.match(r"(?i)<details\b", stripped):
            in_details = True
        if in_details:
            in_details = not re.search(r"(?i)</details>", stripped)
            continue  # collapsed detail is for reviewers
        if stripped.startswith("<"):
            continue  # HTML: images, badges
        text = BULLET.sub("", stripped).strip()
        if not text:
            continue
        first, saw_text = not saw_text, True
        bulleted = text != stripped
        plain = _clean(text)
        if NONE_LINE.match(plain.strip(" .")):
            continue
        m = CATEGORY_LINE.match(text)
        if m and _category(m.group("cat")):
            rest = _clean(m.group("rest"))
            if not rest:  # "Fixed:" introduces the bullets below it
                current = _category(m.group("cat"))
                continue
            if NONE_LINE.match(rest.strip(" .")):
                continue
            entries.append(Entry(_category(m.group("cat")), rest))
            last = _category(m.group("cat"))
        elif current or first or bulleted:
            entries.append(Entry(current or last or "Changed", plain))
        # else: prose after the release lines (a note to reviewers), not a line for testers
    if not saw_text:
        return None
    return entries


def _key(text: str) -> str:
    return re.sub(r"[\W_]+", " ", text.casefold()).strip()


def group(entries: list[Entry]) -> dict[str, list[str]]:
    """Entries by category in display order, each text once (first occurrence wins)."""
    out: dict[str, list[str]] = {c: [] for c in (*CATEGORIES, OTHER)}
    seen: set[str] = set()
    for e in entries:
        k = _key(e.text)
        if not k or k in seen:
            continue
        seen.add(k)
        out[e.category if e.category in out else OTHER].append(e.text)
    return {c: items for c, items in out.items() if items}


# "cnx-ios: ", "cmux-next iOS: ", "cmux NEXT perf-palette3: ": the area, not the change.
AREA_LABEL = re.compile(r"^(?:cnx-ios|cmux[- ]?next|cmux-tui)(?: [\w/-]+){0,2}:\s+", re.I)


def subject_entry(subject: str) -> Entry | None:
    """A commit with no pull request: its subject under "Other changes"; None for internal work (tests, CI, red)."""
    s = subject.strip()
    m = re.match(r"^(?P<type>[A-Za-z-]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<rest>.+)$", s)
    if m and (m.group("type").lower() in INTERNAL_TYPES or (m.group("scope") or "").lower() in INTERNAL_TYPES):
        return None
    if re.search(r"\((?:red|failing)\)|\bfailing tests?\b|^merge\b|^revert\b", s, re.I):
        return None
    if m and m.group("type").lower() in ("fix", "feat", "perf"):
        s = m.group("rest")
    s = AREA_LABEL.sub("", s)
    # Trailing references for engineers: "(#123)", "(GhosttyNextKit 43ffe4171, #21341)", "(cx-8w027.24)".
    s = re.sub(r"\s*\((?=[^()]*(?:#\d+|\b[0-9a-f]{7,40}\b|\bcx-\w))[^()]*\)\s*$", "", s)
    return Entry(OTHER, _clean(s)) if s else None


NOT_IN_APP = re.compile(r"(^|/)[\w.-]*Tests?/|Tests?\.swift$|(^|/)tests?/|^(?:cmux-next-ios|cnx-ios)/(?:scripts|verify|docs)/|\.md$")


def only_tests(files: list[str]) -> bool:
    """Every file is a test, a build script or a document: the app itself did not change."""
    return bool(files) and all(NOT_IN_APP.search(f) for f in files)


def ui_len(text: str) -> int:
    """Length as App Store Connect counts it (UTF-16 code units)."""
    return len(text.encode("utf-16-le")) // 2


def lead_line(version: str | None, sha: str) -> str:
    v = f" {version}" if version else ""
    return f"cmux-next iPhone{v}, feat-cmux-next {sha[:12]}. Internal testers only."


def format_note(lead: str, intro: str | None, groups: dict[str, list[str]], limit: int = LIMIT) -> str:
    """The note: lead line, intro, then each group's items; items past the limit become "...and N more"."""
    items = [(c, t) for c, texts in groups.items() for t in texts]

    def render(n: int) -> str:
        parts = [lead]
        if intro:
            parts += ["", intro]
        last = None
        for c, t in items[:n]:
            if c != last:
                parts += ["", c]
                last = c
            parts.append(f"- {t}")
        if n < len(items):
            parts += ["", f"…and {len(items) - n} more"]
        return "\n".join(parts)

    n = len(items)
    while n > 0 and ui_len(render(n)) > limit:
        n -= 1
    text = render(n)
    if ui_len(text) > limit:  # the lead and intro alone are over the limit (never in practice)
        while text and ui_len(text) > limit:
            text = text[:-1]
    return text


def build_note(*, sha: str, version: str | None, base: str | None, base_source: str,
               commits: list[dict], prs: dict[str, dict | None]) -> str:
    """commits: newest first {oid, subject, files}; prs: oid -> {number, body, title} or None (no PR)."""
    entries: list[Entry] = []
    seen_prs: set[int] = set()
    for c in commits:
        pr = prs.get(c["oid"])
        if pr:
            if pr["number"] in seen_prs:
                continue
            seen_prs.add(pr["number"])
            parsed = parse_changelog(pr.get("body"))
            if parsed is None:  # no section: the title stands in, as /release does
                title = subject_entry(pr.get("title") or "")
                entries += [title] if title else []
            else:
                entries += parsed
            continue
        if only_tests(c.get("files") or []):
            continue
        e = subject_entry(c["subject"])
        if e:
            entries.append(e)
    groups = group(entries)
    lead = lead_line(version, sha)
    if base is None:
        groups = _first_n(groups, UNKNOWN_BASE_LINES)
        intro = "First continuous build. Recent changes:" if groups else "First continuous build."
    elif groups:
        intro = f"Changes since the last build ({base[:12]}{', ' + base_source if base_source else ''}):"
    else:
        intro = f"No app changes since the last build ({base[:12]})."
    return format_note(lead, intro, groups)


def _first_n(groups: dict[str, list[str]], n: int) -> dict[str, list[str]]:
    """The first n items in display order (entries arrive newest first)."""
    out: dict[str, list[str]] = {}
    for c, texts in groups.items():
        take = texts[:max(0, n)]
        if take:
            out[c] = take
        n -= len(take)
    return out


def recorded_sha(whats_new: str | None) -> str | None:
    m = RECORDED_SHA.search(whats_new or "")
    return m.group(1) if m else None


def newest_build_ref(asc_json: dict) -> str | None:
    """The commit in the en-US note of the first build of an App Store Connect /v1/builds response."""
    builds = asc_json.get("data") or []
    if not builds:
        return None
    wanted = {d.get("id") for d in (builds[0].get("relationships", {}).get("betaBuildLocalizations", {}).get("data") or [])}
    locs = [i for i in asc_json.get("included") or [] if i.get("type") == "betaBuildLocalizations" and i.get("id") in wanted]
    locs.sort(key=lambda i: i.get("attributes", {}).get("locale") != "en-US")
    for loc in locs:
        ref = recorded_sha(loc.get("attributes", {}).get("whatsNew"))
        if ref:
            return ref
    return None


def pick_previous_run(runs: list[dict], sha: str, current_run: str | None) -> str | None:
    """The commit of the newest successful upload run that built something other than sha."""
    ok = [r for r in runs if r.get("conclusion") == "success" and r.get("sha") and r["sha"] != sha
          and str(r.get("id")) != str(current_run or "")]
    ok.sort(key=lambda r: r.get("created_at") or "", reverse=True)
    return ok[0]["sha"] if ok else None


def pick_pr(oid: str, nodes: list[dict], hinted: dict | None) -> dict | None:
    """The merged PR that brought commit oid: its merge commit, else one into feat-cmux-next, else any merged one."""
    merged = [n for n in nodes if n and n.get("merged")]
    for n in merged:
        if (n.get("mergeCommit") or {}).get("oid") == oid:
            return n
    for n in merged:
        if n.get("baseRefName") == BRANCH:
            return n
    if merged:
        return merged[0]
    if hinted and hinted.get("merged"):
        return hinted
    return None


# ---- git ----

def _git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def resolve(repo: str, ref: str | None) -> str | None:
    if not ref or not re.fullmatch(r"[0-9a-f]{7,40}", ref):
        return None
    try:
        return _git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip() or None
    except subprocess.CalledProcessError:
        if len(ref) == 40:
            subprocess.run(["git", "-C", repo, "fetch", "-q", "--no-tags", "--filter=blob:none", "origin", ref],
                           capture_output=True, timeout=300)
            try:
                return _git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip() or None
            except subprocess.CalledProcessError:
                return None
        return None


def app_prefixes(repo: str, sha: str) -> tuple[str, ...]:
    try:
        package = _git(repo, "show", f"{sha}:{builder().PACKAGE_SWIFT}")
    except subprocess.CalledProcessError:
        package = ""
    return APP_PREFIXES + tuple(builder().package_paths(package))


def app_version(repo: str, sha: str) -> str | None:
    try:
        return builder().marketing_version(_git(repo, "show", f"{sha}:{builder().PROJECT_YML}"))
    except (subprocess.CalledProcessError, ValueError):
        return None


def app_commits(repo: str, rev_range: list[str], prefixes: tuple[str, ...], limit: int | None = None) -> list[dict]:
    """Non-merge commits (newest first) that change the app's paths, with the app files each changed."""
    args = ["log", "--no-merges", "--no-renames", "--format=%x1e%H%x1f%s", "--name-only"]
    if limit:
        args.append(f"-n{limit}")
    out = _git(repo, *args, *rev_range, "--", *[p.rstrip("/") for p in prefixes])
    commits = []
    for chunk in out.split("\x1e")[1:]:
        head, _, files = chunk.partition("\n")
        oid, _, subject = head.partition("\x1f")
        commits.append({"oid": oid, "subject": subject, "files": [f for f in files.splitlines() if f]})
    return commits


# ---- GitHub ----

def _gh(args: list[str], stdin: str | None = None) -> dict:
    out = subprocess.run(["gh", "api", *args], input=stdin, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


LINK_FIELDS = "number merged baseRefName mergeCommit { oid }"
BODY_FIELDS = "number title body"


def _graphql(fields: list[str]) -> dict:
    owner, name = REPO.split("/")
    query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {" ".join(fields)} }} }}'
    # `gh api graphql` exits 1 when any field errors (a "(#N)" that names an issue, not a PR),
    # but the other fields' data still comes back: keep it, and fail only with no data.
    proc = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=json.dumps({"query": query}),
                          capture_output=True, text=True)
    try:
        data = json.loads(proc.stdout) if proc.stdout.strip() else {}
    except json.JSONDecodeError:
        data = {}
    if not data.get("data"):
        raise subprocess.CalledProcessError(proc.returncode or 1, "gh api graphql", proc.stdout, proc.stderr)
    return data["data"].get("repository") or {}


def _batched(items: list, size: int, read) -> dict:
    """read(batch) for each batch; a batch GitHub refuses (502 on a heavy query) is split in half and retried."""
    out: dict = {}
    pending = [items[i:i + size] for i in range(0, len(items), size)]
    while pending:
        batch = pending.pop(0)
        try:
            out.update(read(batch))
        except subprocess.CalledProcessError:
            if len(batch) <= 1:  # one item GitHub keeps refusing: it falls back alone, the rest keep their PRs
                key = batch[0]["oid"] if isinstance(batch[0], dict) else batch[0]
                out[key] = None
                continue
            half = len(batch) // 2
            pending[:0] = [batch[:half], batch[half:]]
    return out


def fetch_prs(commits: list[dict]) -> dict[str, dict | None]:
    """oid -> the PR that brought it ({number, title, body}), in batched GraphQL reads (GitHub quota is shared).

    associatedPullRequests also lists open PRs that branched from a commit, so the
    first read takes only links (many nodes, no bodies); the second reads the bodies
    of the chosen PRs.
    """
    hints = {c["oid"]: int(m.group(1)) for c in commits if (m := re.search(r"\(#(\d+)\)\s*$", c["subject"]))}

    def read_links(batch: list[dict]) -> dict:
        fields = [f'c{j}: object(oid: "{c["oid"]}") {{ ... on Commit {{ associatedPullRequests(first: 30) '
                  f'{{ nodes {{ {LINK_FIELDS} }} }} }} }}' for j, c in enumerate(batch)]
        numbers = sorted({hints[c["oid"]] for c in batch if c["oid"] in hints})
        fields += [f"p{n}: pullRequest(number: {n}) {{ {LINK_FIELDS} }}" for n in numbers]
        repo = _graphql(fields)
        picked = {}
        for j, c in enumerate(batch):
            nodes = (((repo.get(f"c{j}") or {}).get("associatedPullRequests") or {}).get("nodes")) or []
            hinted = repo.get(f"p{hints[c['oid']]}") if c["oid"] in hints else None
            pr = pick_pr(c["oid"], nodes, hinted)
            picked[c["oid"]] = pr["number"] if pr else None
        return picked

    def read_bodies(batch: list[int]) -> dict:
        repo = _graphql([f"p{n}: pullRequest(number: {n}) {{ {BODY_FIELDS} }}" for n in batch])
        return {n: repo.get(f"p{n}") for n in batch}

    links = _batched(commits, GRAPHQL_BATCH, read_links)
    bodies = _batched(sorted({n for n in links.values() if n}), GRAPHQL_BATCH, read_bodies)
    return {oid: (bodies.get(n) if n else None) for oid, n in links.items()}


def builder_runs() -> list[dict]:
    """Recent upload runs of the builder and the retired manual lane: {id, sha, conclusion, created_at}."""
    runs = []
    for wf in BUILD_WORKFLOWS:
        try:
            data = _gh([f"repos/{REPO}/actions/workflows/{wf}/runs?per_page=30"])
        except subprocess.CalledProcessError:
            continue
        for r in data.get("workflow_runs", []):
            if wf == "ios-internal-nightly.yml":
                m = re.search(r"\b([0-9a-f]{40})\b", r.get("display_title") or "")
                sha = m.group(1) if m else None
            else:  # the retired lane built its branch head on push
                sha = r.get("head_sha")
            runs.append({"id": r["id"], "sha": sha, "conclusion": r.get("conclusion"), "created_at": r.get("created_at")})
    return runs


# ---- App Store Connect (read only) ----

def _der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to the JWS r||s form (32 bytes each)."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("integer too long for P-256")
        out += value.rjust(32, b"\x00")
        i += 2 + n
    return out


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def asc_token(key_id: str, issuer: str, key_path: str, now: int | None = None) -> str:
    """An App Store Connect API JWT (ES256), signed with openssl so no Python package is needed."""
    now = int(now if now is not None else time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{claims}.{_b64url(_der_to_raw(der))}"


def asc_newest_build(app_id: str, token: str) -> dict:
    query = urllib.parse.urlencode({
        "filter[app]": app_id, "filter[processingState]": "VALID", "sort": "-uploadedDate", "limit": "1",
        "include": "betaBuildLocalizations", "fields[betaBuildLocalizations]": "whatsNew,locale",
        "fields[builds]": "version,uploadedDate,processingState,betaBuildLocalizations"})
    req = urllib.request.Request(f"https://api.appstoreconnect.apple.com/v1/builds?{query}",
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


# ---- commands ----

def _output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as fh:
            for k, v in values.items():
                fh.write(f"{k}={v}\n")


def cmd_asc_previous(app_id: str) -> int:
    key_id, issuer, key_path = (os.environ.get(k, "") for k in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH"))
    if not (key_id and issuer and key_path and Path(key_path).is_file()):
        print("asc-previous: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH are required", file=sys.stderr)
        return 2
    ref = newest_build_ref(asc_newest_build(app_id, asc_token(key_id, issuer, key_path)))
    print(f"newest processed build records {ref or 'no commit'}")
    _output(ref=ref or "")
    return 0


def find_base(repo: str, sha: str, base: str | None, asc_ref: str | None) -> tuple[str | None, str]:
    """BASE and where it came from: the dispatch input, App Store Connect's newest build, or the last upload run."""
    # A candidate equal to sha (a rebuild of an uploaded commit) gives no range: try the next source.
    resolved = resolve(repo, base)
    if resolved and resolved != sha:
        return resolved, ""
    resolved = resolve(repo, asc_ref)
    if resolved and resolved != sha:
        return resolved, "from App Store Connect"
    try:
        resolved = resolve(repo, pick_previous_run(builder_runs(), sha, os.environ.get("GITHUB_RUN_ID")))
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError):
        resolved = None
    return (resolved, "from the last upload run") if resolved and resolved != sha else (None, "")


def cmd_notes(sha: str, base: str | None, asc_ref: str | None, repo: str, out: Path | None) -> int:
    sha = resolve(repo, sha) or sys.exit(f"notes: {sha} is not a commit here")
    base, source = find_base(repo, sha, base, asc_ref)
    prefixes = app_prefixes(repo, sha)
    if base:
        commits = app_commits(repo, [f"{base}..{sha}"], prefixes)
    else:
        commits = app_commits(repo, [sha], prefixes, limit=UNKNOWN_BASE_COMMITS)
    try:
        prs = fetch_prs(commits)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as error:
        # The note still ships: commit subjects stand in for every PR.
        print(f"notes: PR lookup failed ({type(error).__name__}); using commit subjects", file=sys.stderr)
        prs = {}
    text = build_note(sha=sha, version=app_version(repo, sha), base=base, base_source=source, commits=commits, prs=prs)
    if out:
        out.write_text(text)
    print(text)
    print(f"\n[{ui_len(text)} of {LIMIT} characters; base {base or 'unknown'} {source}; {len(commits)} app commits]",
          file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("notes")
    n.add_argument("--sha", required=True)
    n.add_argument("--base", default="")
    n.add_argument("--asc-ref", default="")
    n.add_argument("--repo", default=".")
    n.add_argument("--out", type=Path)
    a = sub.add_parser("asc-previous")
    a.add_argument("--app", default=APP_ID)
    args = parser.parse_args(argv)
    if args.cmd == "asc-previous":
        return cmd_asc_previous(args.app)
    return cmd_notes(args.sha, args.base or None, args.asc_ref or None, args.repo, args.out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
