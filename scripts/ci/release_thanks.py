#!/usr/bin/env python3
"""The "thank you" line at the end of a cmux release's notes, in the style of Next.js releases.

For a commit range it finds the pull requests that landed (a squash subject ending "(#1234)" or a
"Merge pull request #1234" merge), reads each one's author, and names every outside contributor:

    Huge thanks to @alice, @bob and @carol for helping with this release!
    Thanks also to the folks at Acme and Initech.

Left out: the maintainers and bots in .github/release-thanks.json, and any author GitHub reports as a
Bot or whose login ends in "[bot]". A company is credited only from the company field of a
contributor's public GitHub profile, minus the companies the config leaves out (the maintainers' own).
Logins and companies are sorted case-insensitively, so the same range always prints the same text.
With no outside contributor it prints nothing, so a caller can append its output unconditionally.

  release_thanks.py --head SHA [--since SHA] [--repo O/R] [--config FILE]   reads git and the GitHub API (gh)
  release_thanks.py --authors FILE.json                                     [{"login", "company", "bot"}]: no git or network
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = ROOT / ".github/release-thanks.json"
SQUASH_PR = re.compile(r"\(#(\d+)\)\s*$")
MERGE_PR = re.compile(r"^Merge pull request #(\d+)\b")
BATCH = 50
COMPANY_LIMIT = 60
GH_TIMEOUT_S = 120


def load_config(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    fold = lambda values: {str(value).strip().lstrip("@").casefold() for value in values}
    return {"exclude_logins": fold(data.get("maintainers", [])) | fold(data.get("bots", [])),
            "exclude_companies": fold(data.get("exclude_companies", []))}


def pr_numbers(subjects):
    """Each PR number named by a commit subject, once, in first-seen order."""
    seen = []
    for subject in subjects:
        match = SQUASH_PR.search(subject) or MERGE_PR.match(subject)
        if match and int(match.group(1)) not in seen:
            seen.append(int(match.group(1)))
    return seen


def range_subjects(since, head):
    span = f"{since}..{head}" if since else head
    out = subprocess.run(["git", "log", "--first-parent", "-z", "--format=%s", span],
                         capture_output=True, text=True, check=True).stdout
    return [subject for subject in out.split("\0") if subject.strip()]


def fetch_authors(repo, numbers):
    """[{"login", "company", "bot"}] for each merged PR, from batched GraphQL queries through gh."""
    owner, name = repo.split("/", 1)
    authors = []
    for start in range(0, len(numbers), BATCH):
        fields = " ".join(
            f"p{n}: pullRequest(number: {n}) {{ merged author {{ __typename login ... on User {{ company }} }} }}"
            for n in numbers[start:start + BATCH])
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        try:
            result = subprocess.run(["gh", "api", "graphql", "-f", f"query={query}"],
                                    capture_output=True, text=True, timeout=GH_TIMEOUT_S)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"gh api graphql timed out after {GH_TIMEOUT_S} s") from error
        # A number from a subject can name an issue or another repo's PR: GraphQL then answers that
        # field with null and an error, and the rest of the batch still holds.
        try:
            data = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            data = {}
        repository = (data.get("data") or {}).get("repository")
        if repository is None:
            raise RuntimeError(f"gh api graphql failed: {result.stderr.strip() or result.stdout.strip()}")
        for pr in repository.values():
            author = (pr or {}).get("author")
            if pr and pr.get("merged") and author:
                authors.append({"login": author["login"], "company": author.get("company") or "",
                                "bot": author.get("__typename") == "Bot"})
    return authors


def clean_company(company):
    """A profile's company as plain text: no leading "@" (an org mention), no Markdown or HTML."""
    text = re.sub(r"\s+", " ", str(company or "")).strip().lstrip("@").strip()
    text = re.sub(r"[<>\[\]()*_`|\\#!~]", "", text).replace("@", "").strip(" ,.;")
    # A URL or domain would be auto-linked in the release body: leave it out rather than link it.
    if re.search(r"://|^www\.|\.[a-z]{2,}(?:/|$)", text, re.I):
        return ""
    return text if 0 < len(text) <= COMPANY_LIMIT else ""


def join(names):
    return names[0] if len(names) == 1 else f"{', '.join(names[:-1])} and {names[-1]}"


def thanks(authors, config):
    """The thank-you text (ending in a newline), or "" when no outside contributor is left."""
    logins, companies = {}, {}
    for author in authors:
        login = str(author.get("login") or "").strip()
        key = login.casefold()
        if (not login or author.get("bot") or key.endswith("[bot]") or key in config["exclude_logins"]
                or not re.fullmatch(r"[A-Za-z0-9-]+", login)):
            continue
        # Spellings that differ only in case are one name; the smallest spelling shows, whatever the order.
        logins[key] = min(logins.get(key, login), login)
        company = clean_company(author.get("company"))
        if company and company.casefold() not in config["exclude_companies"]:
            companies[company.casefold()] = min(companies.get(company.casefold(), company), company)
    if not logins:
        return ""
    people = [f"@{logins[key]}" for key in sorted(logins)]
    lines = [f"Huge thanks to {join(people)} for helping with this release!"]
    if companies:
        lines.append(f"Thanks also to the folks at {join([companies[key] for key in sorted(companies)])}.")
    return "\n".join(["### Thank you", "", *lines]) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--head")
    parser.add_argument("--since", default="")
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--authors", help="a JSON list of authors instead of git and gh (tests, dry runs)")
    args = parser.parse_args(argv)
    if not args.authors and not args.head:
        parser.error("--head (or --authors) is required")
    config = load_config(args.config)
    if args.authors:
        authors = json.loads(Path(args.authors).read_text(encoding="utf-8"))
    else:
        numbers = pr_numbers(range_subjects(args.since, args.head))
        authors = fetch_authors(args.repo, numbers) if numbers else []
    sys.stdout.write(thanks(authors, config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
