#!/usr/bin/env python3
"""The bundle-size budget of one change: what it adds to the cmux NEXT app, against its base.

    bundle-size-pr.py check --base REF [--head REF] [--body-file FILE]
                            [--web-base DIR --web-head DIR] [--json OUT] [--repo DIR]

A pull request CI cannot build the macOS app, so this measures, on Linux, the
three inputs the app's size grows from (the `pull_request` rules in
scripts/cmux-next/bundle-size-budget.json):

  - files: the committed bytes under the paths the app ships (`tree_paths`),
    from git (no checkout of the base needed);
  - web: the built web bundles (`web_outputs`), when --web-base and --web-head
    name two `build-web-bundles.sh --out-root` folders of the base and the head;
  - rust: the crates each shipped Rust binary links (`rust`: a lockfile and
    its root packages), from Cargo.lock; a crate the base did not link is new.

It fails (exit 1) when the change grows files plus web by more than
`threshold_bytes`, or links a new crate into a shipped binary, unless the
change states why: a line `size: <reason>` in the pull request body
(--body-file), or a `Size:` trailer in a commit message of base..head.
It prints the table either way (Markdown, for the job summary). Exit 2 is a
broken check. The nightly measures the whole DMG (bundle-size.py summary);
cmuxterm-hq docs/perf/bundle-size.md is the attribution and the list of cuts.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUDGET = ROOT / "scripts/cmux-next/bundle-size-budget.json"
REASON_LINE = re.compile(r"^[ \t]*size[ \t]*:[ \t]*\S.*$", re.IGNORECASE | re.MULTILINE)


def git(repo: Path, *args: str, check: bool = True) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"bundle-size-pr: git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def tree_bytes(repo: Path, ref: str, patterns: list[str]) -> dict[str, int]:
    """Committed bytes at ref under each path pattern (fnmatch; `*` spans one folder)."""
    out = {p: 0 for p in patterns}
    listing = git(repo, "ls-tree", "-r", "-l", "--full-tree", ref)
    for line in listing.splitlines():
        meta, path = line.split("\t", 1)
        parts = meta.split()
        if len(parts) < 4 or parts[1] != "blob" or not parts[3].isdigit():
            continue
        for p in patterns:
            if path_under(path, p):
                out[p] += int(parts[3])
                break
    return out


def path_under(path: str, pattern: str) -> bool:
    """path is pattern itself or inside it; `*` in pattern matches one path segment."""
    segs, psegs = path.split("/"), pattern.split("/")
    return len(segs) >= len(psegs) and all(fnmatch.fnmatchcase(s, p) for s, p in zip(segs, psegs))


def dir_bytes(root: Path, rel: str) -> int:
    base = root / rel
    if base.is_file():
        return base.stat().st_size
    n = 0
    for dirpath, _dirs, files in os.walk(base):
        for f in files:
            p = Path(dirpath) / f
            if not p.is_symlink():
                n += p.stat().st_size
    return n


def show(repo: Path, ref: str, path: str) -> str | None:
    r = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def member_dev_deps(repo: Path, ref: str, lock_dir: str) -> dict[str, set[str]]:
    """Dev-dependency names of every path package under lock_dir: lock edges that never ship."""
    names = git(repo, "ls-tree", "-r", "--name-only", "--full-tree", ref, "--", lock_dir or ".").splitlines()
    out: dict[str, set[str]] = {}
    for path in names:
        if not path.endswith("Cargo.toml") or "/vendor/" in f"/{path}" or "/target/" in f"/{path}":
            continue
        text = show(repo, ref, path)
        if text is None:
            continue
        try:
            manifest = tomllib.loads(text)
        except tomllib.TOMLDecodeError:
            continue
        name = manifest.get("package", {}).get("name")
        if not name:
            continue
        dev = set(manifest.get("dev-dependencies", {}))
        for target in manifest.get("target", {}).values():
            dev |= set(target.get("dev-dependencies", {}))
        # A renamed dependency (`foo = { package = "bar" }`) is locked under its package name.
        for table in [manifest.get("dev-dependencies", {})] + [t.get("dev-dependencies", {}) for t in manifest.get("target", {}).values()]:
            for k, v in table.items():
                if isinstance(v, dict) and "package" in v:
                    dev.discard(k)
                    dev.add(v["package"])
        out[name] = dev
    return out


def shipped_crates(repo: Path, ref: str, lockfile: str, roots: list[str]) -> set[str] | None:
    """`name version` of every crate reachable from roots in the lockfile at ref (None: no lockfile)."""
    text = show(repo, ref, lockfile)
    if text is None:
        return None
    lock = tomllib.loads(text)
    packages = lock.get("package", [])
    by_name: dict[str, list[dict]] = {}
    for p in packages:
        by_name.setdefault(p["name"], []).append(p)
    lock_dir = str(Path(lockfile).parent)
    dev = member_dev_deps(repo, ref, "" if lock_dir == "." else lock_dir)

    def resolve(dep: str) -> dict | None:
        bits = dep.split(" ")
        cands = by_name.get(bits[0], [])
        if len(bits) > 1:
            cands = [c for c in cands if c["version"] == bits[1]] or cands
        return cands[0] if cands else None

    seen: set[str] = set()
    stack = [p for r in roots for p in by_name.get(r, []) if "source" not in p]
    while stack:
        p = stack.pop()
        key = f"{p['name']} {p['version']}"
        if key in seen:
            continue
        seen.add(key)
        skip = dev.get(p["name"], set()) if "source" not in p else set()
        for dep in p.get("dependencies", []):
            if dep.split(" ")[0] in skip:
                continue
            q = resolve(dep)
            if q is not None:
                stack.append(q)
    return seen


def commit_reasons(repo: Path, base: str, head: str) -> list[str]:
    log = git(repo, "log", "--format=%B%x00", f"{base}..{head}", check=False)
    return [m.group(0).strip() for m in REASON_LINE.finditer(log)]


def check(repo: Path, rules: dict, base: str, head: str, body: str | None,
          web_base: Path | None, web_head: Path | None) -> dict:
    rows = []
    tb, th = tree_bytes(repo, base, rules["tree_paths"]), tree_bytes(repo, head, rules["tree_paths"])
    for p in rules["tree_paths"]:
        rows.append({"kind": "files", "path": p, "base": tb[p], "head": th[p], "delta": th[p] - tb[p]})
    if web_base and web_head:
        for p in rules["web_outputs"]:
            b, h = dir_bytes(web_base, p), dir_bytes(web_head, p)
            rows.append({"kind": "web", "path": p, "base": b, "head": h, "delta": h - b})
    new_crates = []
    for entry in rules["rust"]:
        b = shipped_crates(repo, base, entry["lockfile"], entry["roots"]) or set()
        h = shipped_crates(repo, head, entry["lockfile"], entry["roots"]) or set()
        b_names = {k.split(" ")[0] for k in b}
        for key in sorted(h - b):
            name = key.split(" ")[0]
            # A version bump is not a new crate; a second version of one is.
            if name in b_names and sum(1 for k in h if k.split(" ")[0] == name) <= sum(1 for k in b if k.split(" ")[0] == name):
                continue
            new_crates.append({"lockfile": entry["lockfile"], "crate": key,
                               "second_version": name in b_names})
    growth = sum(r["delta"] for r in rows)
    reasons = ([m.group(0).strip() for m in REASON_LINE.finditer(body)] if body else []) + commit_reasons(repo, base, head)
    over = growth > rules["threshold_bytes"] or bool(new_crates)
    return {
        "base": base, "head": head, "threshold_bytes": rules["threshold_bytes"],
        "growth_bytes": growth, "rows": rows, "new_crates": new_crates,
        "web_measured": bool(web_base and web_head), "reasons": reasons,
        "over": over, "fails": over and not reasons,
    }


def markdown(r: dict) -> list[str]:
    def kb(n: int) -> str:
        return f"{n / 1024:+,.1f} KiB" if n else "0"

    verdict = ("over the budget, with a stated reason" if r["over"] and r["reasons"]
               else "over the budget: add a `size: <reason>` line to the pull request body, or cut it" if r["over"]
               else "within the budget")
    lines = [f"**Bundle size**: {kb(r['growth_bytes'])} against the base "
             f"(budget {r['threshold_bytes'] / 1024:,.1f} KiB), {len(r['new_crates'])} new crate(s) in shipped Rust binaries: {verdict}."]
    if not r["web_measured"]:
        lines.append("Web bundles were not built (no web source changed); files and Rust only.")
    changed = [x for x in r["rows"] if x["delta"]]
    if changed:
        lines += ["", "| What | Path | Base | Head | Change |", "|---|---|---:|---:|---:|"]
        for x in sorted(changed, key=lambda x: -abs(x["delta"])):
            lines.append(f"| {x['kind']} | `{x['path']}` | {x['base']:,} | {x['head']:,} | {kb(x['delta'])} |")
    if r["new_crates"]:
        lines += ["", "New crates linked into a shipped binary:"]
        lines += [f"- `{c['crate']}` ({c['lockfile']}{', a second version' if c['second_version'] else ''})" for c in r["new_crates"]]
    if r["reasons"]:
        lines += ["", "Stated reason:"] + [f"> {x}" for x in r["reasons"]]
    return lines


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--base", required=True)
    c.add_argument("--head", default="HEAD")
    c.add_argument("--body-file", type=Path)
    c.add_argument("--web-base", type=Path)
    c.add_argument("--web-head", type=Path)
    c.add_argument("--json", type=Path)
    c.add_argument("--repo", type=Path, default=ROOT)
    c.add_argument("--budget", type=Path, default=BUDGET)
    a = ap.parse_args(argv)
    if bool(a.web_base) != bool(a.web_head):
        print("bundle-size-pr: --web-base and --web-head go together", file=sys.stderr)
        return 2
    rules = json.loads(a.budget.read_text())["pull_request"]
    body = a.body_file.read_text() if a.body_file and a.body_file.exists() else None
    r = check(a.repo, rules, a.base, a.head, body, a.web_base, a.web_head)
    print("\n".join(markdown(r)))
    if a.json:
        a.json.write_text(json.dumps(r, indent=2) + "\n")
    return 1 if r["fails"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
