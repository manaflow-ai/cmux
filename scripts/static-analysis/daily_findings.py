#!/usr/bin/env python3
"""Turn the daily static-analysis reports into one GitHub issue per new finding.

Reads what osv-scanner.sh, cargo-deny.sh, cargo-machete.sh and knip.sh left in OUT_DIR
(FAST_CHECKS_OUT), gives every finding a stable key, drops the keys in the baseline
(daily-baseline.txt: the tree's findings when it was written, so only new ones count) and
files an issue for each remaining key that no issue carries yet. The key sits in the issue
body as `<!-- static-analysis-key: KEY -->`; an issue with that key that is open, or closed
for any reason but "completed" (not planned, duplicate), means the finding is never filed
again. A finding closed as completed that comes back is filed again, naming the old issue.

Nothing here is a gate: the daily job that runs it is no pull request check, and a finding
only ever becomes an issue.

  daily_findings.py OUT_DIR --list                  print every finding's key and title
  daily_findings.py OUT_DIR --write-baseline FILE   record today's findings as the baseline
  daily_findings.py OUT_DIR --baseline FILE [--file --repo OWNER/REPO] [--max-new N]

Without --file it prints the issues it would file. --file needs GITHUB_TOKEN. Keys:
  advisory:<ecosystem>:<package>:<id>   osv-scanner and cargo-deny (one key for both tools)
  license:<crate>:<expression>          cargo-deny
  cargo-machete:<crate dir>:<dep>
  knip:<package>:<type>:<file>[:<name>] unused files and dependencies only (exports churn)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

LABEL = "static-analysis-daily"
ISSUE_LABELS = [LABEL, "needs-triage", "follow-up", "area: build-and-ci"]
KEY_RE = re.compile(r"<!-- static-analysis-key: (.+?) -->")
# Classic web/ is frozen: knip still reports it, but nothing there should change.
FROZEN_KNIP = {"web"}
KNIP_TYPES = ("files", "dependencies", "devDependencies", "optionalPeerDependencies", "unlisted", "binaries", "unresolved")
ID_RANK = ("RUSTSEC-", "GHSA-", "CVE-")


@dataclass
class Finding:
    key: str
    tool: str
    title: str
    details: list[str] = field(default_factory=list)


def canonical_id(ids: list[str]) -> str:
    for prefix in ID_RANK:
        hits = sorted(i for i in ids if i.startswith(prefix))
        if hits:
            return hits[0]
    return sorted(ids)[0]


def merge(findings: dict[str, Finding], new: Finding) -> None:
    if new.key in findings:
        for line in new.details:
            if line not in findings[new.key].details:
                findings[new.key].details.append(line)
    else:
        findings[new.key] = new


def read_osv(out_dir: Path, root: str, findings: dict[str, Finding]) -> None:
    path = out_dir / "osv-scanner.json"
    if not path.exists():
        return
    data = json.loads(path.read_text())
    for result in data.get("results") or []:
        source = (result.get("source") or {}).get("path", "")
        if root and source.startswith(root):
            source = source[len(root):].lstrip("/")
        for pkg in result.get("packages") or []:
            p = pkg.get("package") or {}
            eco, name, version = p.get("ecosystem", "?"), p.get("name", "?"), p.get("version", "?")
            for group in pkg.get("groups") or []:
                ids = group.get("ids") or group.get("aliases") or []
                if not ids:
                    continue
                vid = canonical_id(ids)
                merge(findings, Finding(
                    key=f"advisory:{eco}:{name}:{vid}",
                    tool="osv-scanner",
                    title=f"{name} ({eco}) is affected by {vid}",
                    details=[f"`{source}`: {name}@{version}, ids {', '.join(sorted(ids))}, max severity {group.get('max_severity') or '-'}"],
                ))


def read_cargo_deny(out_dir: Path, findings: dict[str, Finding]) -> None:
    for path in sorted((out_dir / "cargo-deny").glob("*.jsonl")):
        workspace = path.stem.replace("__", "/")
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            f = event.get("fields") or {}
            if event.get("type") != "diagnostic" or f.get("severity") != "error":
                continue
            krate = ((f.get("graphs") or [{}])[0].get("Krate")) or {}
            name, version = krate.get("name", "?"), krate.get("version", "?")
            advisory = f.get("advisory") or {}
            if advisory.get("id"):
                aid = advisory["id"]
                merge(findings, Finding(
                    key=f"advisory:crates.io:{name}:{aid}",
                    tool="cargo-deny",
                    title=f"{name} (crates.io) is affected by {aid}",
                    details=[f"`{workspace}/Cargo.lock`: {name}@{version}, {f.get('code')}: {advisory.get('title') or f.get('message')}"],
                ))
            elif f.get("code") in ("rejected", "unlicensed"):
                expr = ((f.get("labels") or [{}])[0].get("span")) or "no license"
                merge(findings, Finding(
                    key=f"license:{name}:{expr}",
                    tool="cargo-deny",
                    title=f"{name} brings a license deny.toml does not allow ({expr})",
                    details=[f"`{workspace}/Cargo.lock`: {name}@{version}, {f.get('message')}"],
                ))


def read_cargo_machete(out_dir: Path, findings: dict[str, Finding]) -> None:
    path = out_dir / "cargo-machete.txt"
    if not path.exists():
        return
    crate_dir = ""
    for line in path.read_text().splitlines():
        m = re.search(r" -- (.*)/Cargo\.toml:$", line)
        if m:
            crate_dir = m.group(1)
            continue
        if line.startswith("\t") and "(not counted:" not in line:
            dep = line.strip().split(" ")[0]
            if dep and crate_dir:
                merge(findings, Finding(
                    key=f"cargo-machete:{crate_dir}:{dep}",
                    tool="cargo-machete",
                    title=f"{crate_dir}: unused Rust dependency {dep}",
                    details=[f"`{crate_dir}/Cargo.toml` declares `{dep}`, which no source in the crate names. Verify by hand (macros and build.rs can hide a use) before deleting; a false positive goes in `[package.metadata.cargo-machete] ignored`."],
                ))


def read_knip(out_dir: Path, findings: dict[str, Finding]) -> None:
    for path in sorted((out_dir / "knip").glob("*.json")):
        if path.name.endswith(".config.json"):
            continue
        pkg = path.stem.replace("__", "/")
        if pkg in FROZEN_KNIP:
            continue
        try:
            data = json.loads(path.read_text())
        except ValueError:
            continue
        for issue in data.get("issues") or []:
            file = issue.get("file", "?")
            for kind in KNIP_TYPES:
                value = issue.get(kind)
                items = value if isinstance(value, list) else list(value.values()) if isinstance(value, dict) else []
                for item in items:
                    if kind == "files":
                        key, what = f"knip:{pkg}:files:{file}", f"unused file {file}"
                    else:
                        name = item.get("name", "?") if isinstance(item, dict) else str(item)
                        key, what = f"knip:{pkg}:{kind}:{file}:{name}", f"{kind} {name} in {file}"
                    merge(findings, Finding(
                        key=key, tool="knip", title=f"{pkg}: {what}",
                        details=[f"knip reports {what} in package `{pkg}`. Verify by hand before deleting: entries built from shell variables or loaded by Swift are invisible to knip."],
                    ))


def collect(out_dir: Path, root: str) -> dict[str, Finding]:
    findings: dict[str, Finding] = {}
    read_osv(out_dir, root, findings)
    read_cargo_deny(out_dir, findings)
    read_cargo_machete(out_dir, findings)
    read_knip(out_dir, findings)
    return findings


# Licenses allowed for every crate in the deny.toml baseline when the tree already uses them.
# Anything else in use today (copyleft, unusual terms) is an exception for the one crate that has it.
PERMISSIVE = {"MIT", "MIT-0", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause",
              "ISC", "Zlib", "0BSD", "BSL-1.0", "CC0-1.0", "Unlicense", "Unicode-3.0", "Unicode-DFS-2016", "CDLA-Permissive-2.0"}


def deny_toml(out_dir: Path, date: str) -> str:
    """A deny.toml that passes today's tree: from cargo-deny run with an empty config."""
    allowed: set[str] = set()
    exceptions: dict[str, set[str]] = {}
    advisories: dict[str, str] = {}
    unlicensed: set[str] = set()
    for path in sorted((out_dir / "cargo-deny").glob("*.jsonl")):
        for line in path.read_text().splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            f = event.get("fields") or {}
            if event.get("type") != "diagnostic" or f.get("severity") != "error":
                continue
            name = (((f.get("graphs") or [{}])[0].get("Krate")) or {}).get("name", "?")
            advisory = f.get("advisory") or {}
            if advisory.get("id"):
                advisories[advisory["id"]] = f"{name}: {advisory.get('title') or f.get('message')}"
            elif f.get("code") == "rejected":
                for label in f.get("labels") or []:
                    if (label.get("message") or "").startswith("rejected"):
                        lic = label.get("span", "")
                        (allowed.add(lic) if lic in PERMISSIVE else exceptions.setdefault(name, set()).add(lic))
            elif f.get("code") == "unlicensed":
                unlicensed.add(name)
    q = json.dumps
    out = [
        f"# cargo-deny baseline, written {date} by scripts/static-analysis/daily_findings.py --write-deny-toml",
        "# from every Cargo workspace with a Cargo.lock. It records the tree as it was: every license in use",
        "# and every advisory already known, so `cargo deny check licenses advisories` (cargo-deny.sh, the",
        "# daily static-analysis run) reports only what is new since. Report-only: no pull request check",
        "# reads this file. Fix a finding, or add it here with a reason.",
        "",
        "[graph]",
        "all-features = true",
        "",
        "[advisories]",
        "# A yanked version is a warning, never a finding: the lockfile pins it on purpose until someone moves it.",
        'yanked = "warn"',
        "ignore = [",
        *[f"  {{ id = {q(i)}, reason = {q('baseline ' + date + ': ' + why)} }}," for i, why in sorted(advisories.items())],
        "]",
        "",
        "[licenses]",
        "confidence-threshold = 0.8",
        "allow = [",
        *[f"  {q(lic)}," for lic in sorted(allowed)],
        "]",
        "exceptions = [",
        *[f"  {{ crate = {q(name)}, allow = [{', '.join(q(l) for l in sorted(lics))}] }},"
          for name, lics in sorted(exceptions.items())],
        "]",
        "",
        "[licenses.private]",
        "ignore = true",
    ]
    if unlicensed:
        out += ["", "# Crates with no license metadata today (cargo-deny reports them as unlicensed):",
                *[f"#   {n}" for n in sorted(unlicensed)]]
    return "\n".join(out) + "\n"


def read_baseline(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text().splitlines() if line.strip() and not line.startswith("#")}


def issue_body(f: Finding, run_url: str, sha: str, reopened_from: int | None) -> str:
    lines = [
        f"the daily static-analysis run found a new **{f.tool}** finding at {sha or 'the tip'}"
        + (f" ({run_url})" if run_url else "") + ".",
        "",
        *[f"- {d}" for d in f.details],
        "",
    ]
    if reopened_from:
        lines += [f"This finding was closed as completed in #{reopened_from} and is back.", ""]
    lines += [
        "Fix it, or close this issue as not planned: a finding whose issue is open or closed as not planned is never filed again.",
        "This is report-only; no pull request check reads it (scripts/static-analysis/README.md).",
        "",
        f"<!-- static-analysis-key: {f.key} -->",
    ]
    return "\n".join(lines)


class GitHub:
    def __init__(self, repo: str, token: str, api: str = "https://api.github.com"):
        self.repo, self.token, self.api = repo, token, api

    def call(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            f"{self.api}{path}", method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"null")

    def known_keys(self) -> dict[str, list[tuple[int, str, str]]]:
        """Every key our label's issues carry: key -> [(number, state, state_reason)]."""
        known: dict[str, list[tuple[int, str, str]]] = {}
        page = 1
        while True:
            q = urllib.parse.urlencode({"labels": LABEL, "state": "all", "per_page": 100, "page": page})
            batch = self.call("GET", f"/repos/{self.repo}/issues?{q}")
            for issue in batch:
                if issue.get("pull_request"):
                    continue
                for key in KEY_RE.findall(issue.get("body") or ""):
                    known.setdefault(key, []).append((issue["number"], issue["state"], issue.get("state_reason") or ""))
            if len(batch) < 100:
                return known
            page += 1

    def ensure_label(self) -> None:
        try:
            self.call("GET", f"/repos/{self.repo}/labels/{urllib.parse.quote(LABEL)}")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            self.call("POST", f"/repos/{self.repo}/labels", {
                "name": LABEL, "color": "c5def5",
                "description": "Filed by the daily static-analysis run (one issue per finding)"})

    def create(self, title: str, body: str) -> int:
        return self.call("POST", f"/repos/{self.repo}/issues", {"title": title, "body": body, "labels": ISSUE_LABELS})["number"]


def decide(key: str, known: dict[str, list[tuple[int, str, str]]]) -> tuple[bool, int | None]:
    """(file it?, the completed issue it came back from)."""
    issues = known.get(key, [])
    if any(state == "open" or reason != "completed" for _, state, reason in issues):
        return False, None
    return True, max((n for n, _, _ in issues), default=None)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--root", default=os.getcwd(), help="repo root, stripped from lockfile paths")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--write-baseline", type=Path)
    ap.add_argument("--baseline", type=Path)
    ap.add_argument("--file", action="store_true", help="file the issues (needs GITHUB_TOKEN)")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    ap.add_argument("--max-new", type=int, default=10, help="stop after filing this many issues in one run")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--sha", default="")
    ap.add_argument("--write-deny-toml", type=Path,
                    help="write a deny.toml baseline from a cargo-deny.sh run with SA_CARGO_DENY_CONFIG=deny-seed.toml")
    args = ap.parse_args(argv)

    if args.write_deny_toml:
        import datetime
        args.write_deny_toml.write_text(deny_toml(args.out_dir, datetime.date.today().isoformat()))
        print(f"wrote {args.write_deny_toml}")
        return 0
    findings = collect(args.out_dir, args.root)
    tools: dict[str, int] = {}
    for f in findings.values():
        tools[f.tool] = tools.get(f.tool, 0) + 1
    print("findings by tool (deduplicated keys): " + (", ".join(f"{t}={n}" for t, n in sorted(tools.items())) or "none"))

    if args.list:
        for key in sorted(findings):
            print(f"{key}\t{findings[key].title}")
        return 0
    if args.write_baseline:
        by_tool: dict[str, list[str]] = {}
        for f in findings.values():
            by_tool.setdefault(f.tool, []).append(f.key)
        out = ["# Daily static-analysis baseline: findings already in the tree when it was written.",
               "# daily_findings.py files an issue only for a key not listed here. Regenerate with",
               "# daily_findings.py OUT_DIR --write-baseline scripts/static-analysis/daily-baseline.txt"]
        for tool in sorted(by_tool):
            out.append(f"# {tool}: {len(by_tool[tool])}")
            out.extend(sorted(by_tool[tool]))
        args.write_baseline.write_text("\n".join(out) + "\n")
        print(f"wrote {len(findings)} keys to {args.write_baseline}")
        return 0

    baseline = read_baseline(args.baseline) if args.baseline else set()
    new = [findings[k] for k in sorted(findings) if k not in baseline]
    print(f"new since the baseline: {len(new)}")
    gh = None
    known: dict[str, list[tuple[int, str, str]]] = {}
    if args.file:
        token = os.environ.get("GITHUB_TOKEN")
        if not token:
            print("daily_findings.py: --file needs GITHUB_TOKEN", file=sys.stderr)
            return 2
        gh = GitHub(args.repo, token)
        known = gh.known_keys()  # fails closed: no list, no filing (a duplicate is worse than a day's delay)
        gh.ensure_label()
    filed = skipped = 0
    for f in new:
        ok, reopened_from = decide(f.key, known)
        if not ok:
            skipped += 1
            continue
        if filed >= args.max_new:
            print(f"stop: filed {filed} (--max-new); the rest are filed on the next runs")
            break
        title = f"static analysis: {f.title}"
        body = issue_body(f, args.run_url, args.sha, reopened_from)
        if gh:
            number = gh.create(title, body)
            print(f"filed #{number}: {f.key}")
        else:
            print(f"would file: {title}\n  key: {f.key}")
        filed += 1
    print(f"filed={filed} already_tracked={skipped} new={len(new)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
