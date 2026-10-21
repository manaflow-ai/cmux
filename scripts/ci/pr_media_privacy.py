#!/usr/bin/env python3
"""Remove agent-written pr-media files that show private machine or account names.

Many tools write screenshots, GIFs and videos to the public ``pr-media``
branch (cmux-next-media.yml tours, nightly.yml reels, scripts/pr-media.py,
scripts/showcase-publish.py, HQ tools), and most of them run no privacy check.
Captures from the fleet minis show terminal prompts such as
``cmux@cmux7s-Mac-mini``, the Inspector's ``cmux7's Mac mini`` and the capture
account's ``/Users/cmux``. This gate scans what changed on the branch, so it
covers every writer at once.

``.github/workflows/pr-media-privacy.yml`` runs it. Each run diffs the last
scanned commit (``refs/pr-media-privacy/scanned``) against the branch tip and
reads the added and modified files: text files directly, images, GIF frames
and one video frame per second through Apple Vision (``pr_media_ocr.swift``).
Matching folds Cyrillic and Greek look-alikes, which Vision often returns
(``сmux7's Mас mini``), back to Latin.

Built-in patterns name no specific machine. Personal machine and account
names come from ``PR_MEDIA_PRIVATE_TERMS`` (a secret holding a JSON list), and
no output ever echoes what they matched.

With ``--apply``, hits whose owner is an agent are removed in one ordinary
commit on top of the tip (never a history rewrite): a numeric top folder
``<N>/`` is pull request N, removable only when its author is listed in
``PR_MEDIA_AGENT_AUTHORS``; ``nightly-next/`` is the nightly bot's own output.
A teammate's file, any other folder, or an author that cannot be looked up is
reported and kept. The run fails whenever anything was found, so the hit stays
visible on the run page even after its removal.

The first run, with no marker, scans nothing and only records the tip: the
branch's existing files are not flagged wholesale.

Exit status: 0 clean, 1 something was found, 2 bad input.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata

BRANCH = "pr-media"
NIGHTLY_FOLDER = "nightly-next"
PR_FOLDER = re.compile(r"[1-9][0-9]{0,6}")
MEDIA_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp4", ".mov"})
TEXT_SUFFIXES = frozenset({".html", ".json", ".md", ".txt"})
FRAME_SEPARATOR = re.compile(r"@@frame (\d+)\s*$")
PUSH_ATTEMPTS = 3
AUTHOR_BATCH = 50

# Cyrillic and Greek letters Vision reads in place of Latin ones. Digits are
# never folded: `cmux7` and `cmux1` must stay different machines.
LOOK_ALIKES = str.maketrans({
    "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
    "р": "p", "с": "c", "т": "m", "у": "y", "х": "x", "и": "u", "і": "i",
    "ј": "j", "ѕ": "s", "ь": "b",
    "α": "a", "β": "b", "ε": "e", "η": "n", "ι": "i", "κ": "k", "μ": "u",
    "ν": "v", "ο": "o", "ρ": "p", "σ": "o", "ς": "c", "τ": "t", "υ": "u",
    "χ": "x", "γ": "y", "ζ": "z",
    "‘": "'", "’": "'", "ʼ": "'",
})

# Generic shapes of the capture and fleet machines; none names one machine.
# A lookbehind keeps each from firing inside a longer word.
_EDGE = r"(?<![a-z0-9_])"
GENERIC_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = tuple(
    (name, re.compile(_EDGE + pattern)) for name, pattern in (
        ("mini-name", r"cmux\d*'?s[- ]mac[- ]mini(?:-\d+)?(?![a-z0-9])"),
        ("mini-host", r"cmux-mac-mini(?:-cua)?(?:-\d+)?(?![a-z0-9])"),
        ("mini-host", r"cmux-austin-mini(?:-\d+)?(?![a-z0-9])"),
        ("fleet-host", r"cmux\d{1,2}(?![a-z0-9_])"),
        ("shell-prompt", r"cmux@[\w.-]+"),
        ("capture-account", r"/users/cmux(?![a-z0-9_])"),
        ("capture-account", r"/users/shared/cmux-capture"),
    )
)
EMAIL = re.compile(r"(?<![a-z0-9._%+-])[a-z0-9._%+-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?![a-z0-9-])")
# Reserved documentation domains and GitHub's public no-reply addresses.
PUBLIC_EMAIL_DOMAINS = ("example.com", "example.org", "example.net", "test", "users.noreply.github.com")


class BadInput(Exception):
    pass


def fold(text: str) -> str:
    return text.translate(LOOK_ALIKES)


def normalize(text: str) -> str:
    return unicodedata.normalize("NFKC", text).lower()


def private_patterns(raw: str | None) -> list[tuple[str, re.Pattern[str]]]:
    """Whole-word, case-insensitive, look-alike folded patterns from the secret."""
    if not raw or not raw.strip():
        return []
    try:
        terms = json.loads(raw)
    except json.JSONDecodeError as error:
        raise BadInput(f"PR_MEDIA_PRIVATE_TERMS is not JSON ({error.msg})") from error
    if not isinstance(terms, list) or not all(isinstance(term, str) for term in terms):
        raise BadInput("PR_MEDIA_PRIVATE_TERMS must be a JSON list of strings")
    patterns = []
    for term in terms:
        folded = fold(normalize(term.strip()))
        if folded:
            patterns.append(("private-term", re.compile(
                rf"(?<![a-z0-9_]){re.escape(folded)}(?![a-z0-9_])")))
    return patterns


def public_email(domain: str) -> bool:
    return any(domain == public or domain.endswith("." + public) for public in PUBLIC_EMAIL_DOMAINS)


def findings(lines: list[str], patterns: list[tuple[str, re.Pattern[str]]]) -> list[dict]:
    """Return [{kind, text, line}] for every private name in the OCR or text lines."""
    found: list[dict] = []
    for number, raw in enumerate(lines, start=1):
        lowered = normalize(raw)
        seen: set[tuple[str, str]] = set()
        for variant in dict.fromkeys((lowered, fold(lowered))):
            for kind, pattern in patterns:
                for match in pattern.finditer(variant):
                    seen.add((kind, match.group(0)))
            for match in EMAIL.finditer(variant):
                if not match.group(0).isascii():
                    continue
                if not public_email(match.group(1)):
                    seen.add(("email", match.group(0)))
        found.extend({"kind": kind, "text": text, "line": number} for kind, text in sorted(seen))
    return found


def git(*args: str, cwd: Path, input: str | None = None, env: dict[str, str] | None = None) -> str:
    command_env = {**os.environ, **env} if env else None
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True,
                          text=True, input=input, env=command_env).stdout


def changed_files(repo: Path, start: str, end: str) -> list[str]:
    """Added or modified paths between two commits; works when start is not an ancestor."""
    raw = git("diff", "--name-status", "--no-renames", "-z", start, end, cwd=repo)
    fields = [field for field in raw.split("\0") if field]
    paths = []
    for status, path in zip(fields[0::2], fields[1::2]):
        if status in {"A", "M"} and Path(path).suffix.lower() in MEDIA_SUFFIXES | TEXT_SUFFIXES:
            paths.append(path)
    return paths


def ocr_lines(ocr: str, repo: Path, commit: str, path: str) -> list[str]:
    suffix = Path(path).suffix.lower()
    data = subprocess.run(["git", "cat-file", "blob", f"{commit}:{path}"], cwd=repo,
                          check=True, capture_output=True).stdout
    if suffix in TEXT_SUFFIXES:
        return data.decode("utf-8", errors="replace").splitlines()
    with tempfile.TemporaryDirectory(prefix="cmux-pr-media-privacy-") as directory:
        local = Path(directory) / Path(path).name
        local.write_bytes(data)
        done = subprocess.run([ocr, str(local)], capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        raise RuntimeError(f"OCR exited {done.returncode}")
    return [line for line in done.stdout.splitlines() if not FRAME_SEPARATOR.match(line)]


def owner(path: str) -> tuple[str, int | None]:
    """('pr', N), ('nightly', None) or ('other', None) from the top folder."""
    top = path.split("/", 1)[0] if "/" in path else ""
    if PR_FOLDER.fullmatch(top):
        return "pr", int(top)
    if top == NIGHTLY_FOLDER:
        return "nightly", None
    return "other", None


def github_authors(numbers: list[int]) -> dict[int, str] | None:
    """PR author logins in one batched GraphQL call; None when the lookup fails."""
    repository = os.environ.get("REPOSITORY", "")
    if "/" not in repository:
        return None
    owner_name, name = repository.split("/", 1)
    authors: dict[int, str] = {}
    for start in range(0, len(numbers), AUTHOR_BATCH):
        batch = numbers[start:start + AUTHOR_BATCH]
        fields = " ".join(f"p{n}: pullRequest(number: {n}) {{ author {{ login }} }}" for n in batch)
        query = f'query {{ repository(owner: "{owner_name}", name: "{name}") {{ {fields} }} }}'
        done = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                              capture_output=True, text=True)
        # A partial answer (one number is an issue, one PR is gone) also exits non-zero:
        # treat it as a failed lookup so nothing in the batch is removed.
        if done.returncode != 0:
            return None
        try:
            repo = (json.loads(done.stdout or "{}").get("data") or {}).get("repository") or {}
        except json.JSONDecodeError:
            return None
        for key, value in repo.items():
            login = ((value or {}).get("author") or {}).get("login")
            if isinstance(login, str):
                authors[int(key[1:])] = login
    return authors


def agent_authors(raw: str | None) -> frozenset[str]:
    return frozenset(part.strip().casefold() for part in (raw or "").split(",") if part.strip())


def removable(hits: dict[str, list[dict]], agents: frozenset[str], lookup) -> dict[str, str]:
    """Map each hit path to 'remove' or the reason it is only reported."""
    numbers = sorted({number for path in hits for kind, number in [owner(path)] if kind == "pr"})
    authors: dict[int, str] | None = {}
    if numbers and agents:
        try:
            authors = lookup(numbers)
        except Exception:  # noqa: BLE001 - any lookup failure keeps the files
            authors = None
    decisions: dict[str, str] = {}
    for path in hits:
        kind, number = owner(path)
        if kind == "nightly":
            decisions[path] = "remove"
        elif kind == "other":
            decisions[path] = "not an agent folder"
        elif not agents:
            decisions[path] = "PR_MEDIA_AGENT_AUTHORS is empty"
        elif authors is None or number not in authors:
            decisions[path] = "PR author unknown"
        elif authors[number].casefold() in agents:
            decisions[path] = "remove"
        else:
            decisions[path] = "PR author is not an agent"
    return decisions


def remove_paths(repo: Path, tip: str, paths: dict[str, str], message: str) -> str:
    """Commit removing paths (path -> blob scanned) on top of tip; returns the commit."""
    listing = git("ls-tree", "-r", "-z", tip, "--", *paths, cwd=repo)
    present = {}
    for record in listing.split("\0"):
        if "\t" in record:
            meta, path = record.split("\t", 1)
            present[path] = meta.split()[2]
    # A writer that replaced the file since the scan is scanned on the next run.
    targets = [path for path, blob in paths.items() if present.get(path) == blob]
    if not targets:
        return tip
    with tempfile.NamedTemporaryFile(prefix="cmux-pr-media-privacy-index-", delete=False) as handle:
        index = Path(handle.name)
    index.unlink()
    env = {"GIT_INDEX_FILE": str(index)}
    try:
        git("read-tree", tip, cwd=repo, env=env)
        git("update-index", "--force-remove", "-z", "--stdin", cwd=repo, env=env,
            input="\0".join(targets) + "\0")
        # --missing-ok: a blob:none clone holds no blobs, and none are needed.
        tree = git("write-tree", "--missing-ok", cwd=repo, env=env).strip()
    finally:
        index.unlink(missing_ok=True)
    return git("commit-tree", tree, "-p", tip, "-m", message, cwd=repo).strip()


def apply_removal(repo: Path, remote: str, paths: dict[str, str], message: str) -> str | None:
    """Push one removal commit with a lease on the tip; refetch and retry on a race."""
    refspec = f"+refs/heads/{BRANCH}:refs/remotes/{remote}/{BRANCH}"
    for _attempt in range(PUSH_ATTEMPTS):
        tip = git("rev-parse", f"refs/remotes/{remote}/{BRANCH}", cwd=repo).strip()
        commit = remove_paths(repo, tip, paths, message)
        if commit == tip:
            return None
        try:
            git("push", f"--force-with-lease=refs/heads/{BRANCH}:{tip}", remote,
                f"{commit}:refs/heads/{BRANCH}", cwd=repo)
            return commit
        except subprocess.CalledProcessError:
            git("fetch", "--no-tags", "--filter=blob:none", "--depth=1", remote, refspec, cwd=repo)
    raise RuntimeError(f"{BRANCH} kept moving; removal not pushed after {PUSH_ATTEMPTS} attempts")


def annotation(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def annotation_property(text: str) -> str:
    return annotation(text).replace(":", "%3A").replace(",", "%2C")


def scan(repo: Path, start: str | None, end: str, ocr: str | None, patterns, apply: bool,
         agents: frozenset[str], lookup, remote: str = "origin") -> dict:
    report: dict = {"from": start, "to": end, "files": [], "unscanned": [], "removal": None, "marker": end}
    if not start:
        print(f"No scanned marker yet; recording {end[:12]} without scanning the existing branch.", flush=True)
        return report
    hits: dict[str, list[dict]] = {}
    for path in changed_files(repo, start, end):
        is_text = Path(path).suffix.lower() in TEXT_SUFFIXES
        if not is_text and not ocr:
            raise BadInput("--ocr is required to scan media files")
        try:
            lines = ocr_lines(ocr or "", repo, end, path)
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            report["unscanned"].append({"path": path, "error": str(error)})
            print(f"::error file={annotation_property(path)},title=pr-media privacy::could not read {annotation(path)} ({error})",
                  flush=True)
            continue
        found = findings(lines, patterns)
        if found:
            hits[path] = found
    decisions = removable(hits, agents, lookup) if hits else {}
    blobs = {}
    if hits:
        listing = git("ls-tree", "-r", "-z", end, "--", *hits, cwd=repo)
        for record in listing.split("\0"):
            if "\t" in record:
                meta, path = record.split("\t", 1)
                blobs[path] = meta.split()[2]
    to_remove = {path: blobs[path] for path, decision in decisions.items() if decision == "remove" and path in blobs}
    if apply and to_remove:
        lines = [f"PR media privacy: remove {len(to_remove)} file(s) showing private names", ""]
        lines += [f"- {path} ({', '.join(sorted({hit['kind'] for hit in hits[path]}))})" for path in sorted(to_remove)]
        lines += ["", "Found by scripts/ci/pr_media_privacy.py (.github/workflows/pr-media-privacy.yml)."]
        report["removal"] = apply_removal(repo, remote, to_remove, "\n".join(lines) + "\n")
        # The removal holds nothing new to scan when it sits right on the scanned tip.
        if report["removal"] and git("rev-parse", f"{report['removal']}^", cwd=repo).strip() == end:
            report["marker"] = report["removal"]
    for path in sorted(hits):
        kinds = sorted({hit["kind"] for hit in hits[path]})
        if path not in to_remove:
            action = f"reported, not removed: {decisions[path]}"
        elif not apply:
            action = "would be removed (dry run)"
        elif report["removal"] is None:
            action = "reported, not removed: replaced on the branch since the scan"
        else:
            action = "removed"
        kind, number = owner(path)
        report["files"].append({"path": path, "folder": path.split("/", 1)[0] if "/" in path else "",
                                "pr": number, "kinds": kinds, "action": action,
                                "lines": sorted({hit["line"] for hit in hits[path]})})
        where = f"PR #{number}" if kind == "pr" else (f"folder {path.split('/', 1)[0]}" if "/" in path else "branch root")
        print(f"::error file={annotation_property(path)},title=pr-media privacy::{annotation(path)} ({where}) shows "
              f"{', '.join(kinds)}; {action}", flush=True)
    return report


def write_summary(report: dict) -> None:
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    rows = ["## pr-media privacy", ""]
    if not report["from"]:
        rows.append(f"First run: recorded `{report['to'][:12]}` without scanning.")
    elif not report["files"]:
        rows.append(f"Clean: `{(report['from'] or '')[:12]}..{report['to'][:12]}`.")
    else:
        rows += ["| File | Folder | Found | Action |", "| --- | --- | --- | --- |"]
        rows += [f"| `{item['path']}` | {item['folder'] or '-'} | {', '.join(item['kinds'])} | {item['action']} |"
                 for item in report["files"]]
    if report["unscanned"]:
        rows += ["", "Could not read: " + ", ".join(f"`{item['path']}`" for item in report["unscanned"])]
    with open(target, "a", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")


def main(argv: list[str] | None = None, lookup=github_authors) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd(),
                        help="git directory holding the pr-media tip and the last scanned commit")
    parser.add_argument("--from", dest="start", default="",
                        help="last scanned commit; empty records the tip without scanning")
    parser.add_argument("--to", dest="end", required=True, help="commit to scan up to (the pr-media tip)")
    parser.add_argument("--ocr", help="compiled scripts/ci/pr_media_ocr.swift")
    parser.add_argument("--apply", action="store_true", help="push one commit removing agent-owned hits")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--report", type=Path, help="write a JSON report here")
    args = parser.parse_args(argv)
    try:
        patterns = [*GENERIC_PATTERNS, *private_patterns(os.environ.get("PR_MEDIA_PRIVATE_TERMS"))]
        start = "" if args.start in {"", "empty"} else args.start
        for value in filter(None, (start, args.end)):
            try:
                git("rev-parse", "--verify", "--quiet", f"{value}^{{commit}}", cwd=args.repo)
            except subprocess.CalledProcessError as error:
                raise BadInput(f"{value} is not a commit in {args.repo}") from error
        report = scan(args.repo, start or None, args.end, args.ocr, patterns, args.apply,
                      agent_authors(os.environ.get("PR_MEDIA_AGENT_AUTHORS")), lookup, args.remote)
    except BadInput as error:
        print(f"::error title=pr-media privacy::{annotation(str(error))}", flush=True)
        return 2
    except Exception as error:  # noqa: BLE001 - any crash must hold the marker, not pass as "hits found"
        # Only the type: a git error's text can carry paths or commit messages.
        print(f"::error title=pr-media privacy::scan stopped with {type(error).__name__}; the marker is kept",
              flush=True)
        return 3
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_summary(report)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"marker={report['marker']}\n")
    found, unread = len(report["files"]), len(report["unscanned"])
    print(f"pr-media privacy: {found} file(s) with private names, {unread} unreadable.", flush=True)
    # An unreadable file is not retried, so it fails the run like a hit.
    return 1 if found or unread else 0


if __name__ == "__main__":
    sys.exit(main())
