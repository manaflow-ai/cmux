#!/usr/bin/env python3
"""The bundle-size budget of one change: what it adds to the cmux NEXT app, against its base.

    bundle-size-pr.py check --base REF [--head REF] [--body-file FILE]
                            [--web-base DIR|JSON --web-head DIR|JSON] [--json OUT] [--repo DIR]
    bundle-size-pr.py web-bytes OUT_ROOT     (one build's bytes per web output, as JSON)

A pull request CI cannot build the macOS app, so this measures, on Linux, the
three inputs the app's size grows from (the `pull_request` rules in
scripts/cmux-next/bundle-size-budget.json):

  - files: the committed bytes under the paths the app ships (`tree_paths`),
    from git (no checkout of the base needed). Assets.xcassets is the source
    actool compiles into Resources/Assets.car: its growth stands in for the
    car's; the nightly's whole-app check measures the car itself;
  - web: the built web bundles (`web_outputs`), when --web-base and --web-head
    name two `build-web-bundles.sh --out-root` folders of the base and the head,
    or the `web-bytes` JSON of each (CI builds each in its own job);
  - rust: the crates each shipped Rust binary links (`rust`: a lockfile and
    its root packages). A registry or git crate that a shipped path package
    now depends on unconditionally for aarch64-apple-darwin (its manifests:
    normal and build dependencies, `[target.cfg(...)]` tables evaluated for
    macOS, workspace inheritance), and that the base's lockfile graph did not
    reach, or reached at fewer versions, is new. Optional and transitive
    crates new to the lockfile graph are listed, not counted: Cargo.lock
    records neither targets nor features.

It fails (exit 1) when the change grows files plus web by more than
`threshold_bytes`, or adds a new crate to a shipped binary, unless the
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
import posixpath
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


def web_bytes(source: Path, rules: dict) -> dict[str, int]:
    """Bytes of each web output: a `build-web-bundles.sh --out-root` folder, or the JSON that
    `web-bytes` wrote from one in another job."""
    if source.is_file():
        try:
            data = json.loads(source.read_text())
        except json.JSONDecodeError:
            data = None
        if not isinstance(data, dict) or not all(isinstance(data.get(p), int) for p in rules["web_outputs"]):
            print(f"bundle-size-pr: {source} lacks a byte count for a web output", file=sys.stderr)
            raise SystemExit(2)
        return {p: data[p] for p in rules["web_outputs"]}
    # A build that wrote no folder for an output is broken, not a cut: counting it as 0 would
    # let an incomplete head build pass as a shrink.
    missing = [p for p in rules["web_outputs"] if not (source / p).exists()]
    if missing:
        print(f"bundle-size-pr: {source} has no web output {', '.join(missing)}: the build did not finish",
              file=sys.stderr)
        raise SystemExit(2)
    return {p: dir_bytes(source, p) for p in rules["web_outputs"]}


def show(repo: Path, ref: str, path: str) -> str | None:
    r = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


# The target every shipped binary is built for: aarch64-apple-darwin.
MAC_CFG = {"target_os": "macos", "target_family": "unix", "target_vendor": "apple", "target_arch": "aarch64",
           "target_pointer_width": "64", "target_endian": "little", "target_env": "", "target_abi": "",
           "panic": "unwind"}
MAC_FLAGS = {"unix"}
MAC_TRIPLES = {"aarch64-apple-darwin"}


def on_mac(spec: str) -> bool:
    """Whether a `[target.SPEC]` table applies to aarch64-apple-darwin (unparseable: yes)."""
    spec = spec.strip()
    if not (spec.startswith("cfg(") and spec.endswith(")")):
        return spec in MAC_TRIPLES
    tokens = re.findall(r'"[^"]*"|[A-Za-z_][A-Za-z0-9_]*|[(),=]', spec[4:-1])
    pos = 0

    def expr() -> bool:
        nonlocal pos
        name = tokens[pos]
        pos += 1
        if name in ("all", "any", "not") and tokens[pos] == "(":
            pos += 1
            vals = []
            while tokens[pos] != ")":
                vals.append(expr())
                if tokens[pos] == ",":
                    pos += 1
            pos += 1
            return all(vals) if name == "all" else any(vals) if name == "any" else not vals[0]
        if pos < len(tokens) and tokens[pos] == "=":
            value = tokens[pos + 1].strip('"')
            pos += 2
            return MAC_CFG.get(name) == value
        return name in MAC_FLAGS

    try:
        return expr()
    except IndexError:
        return True


def manifest_at(repo: Path, ref: str, path: str) -> dict | None:
    text = show(repo, ref, path)
    if text is None:
        return None
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return None


def mac_deps(manifest: dict, manifest_dir: str, workspace: dict, workspace_dir: str,
             any_target: bool = False) -> list[tuple[str, bool, str | None]]:
    """(locked name, optional, path) of each normal and build dependency that applies on macOS
    (any_target: on any target)."""
    tables = [manifest.get("dependencies", {}), manifest.get("build-dependencies", {})]
    for spec, t in manifest.get("target", {}).items():
        if any_target or on_mac(spec):
            tables += [t.get("dependencies", {}), t.get("build-dependencies", {})]
    out = []
    for table in tables:
        for key, v in table.items():
            v = v if isinstance(v, dict) else {"version": v}
            where = manifest_dir
            if v.get("workspace"):
                w = workspace.get(key, {})
                w = w if isinstance(w, dict) else {"version": w}
                v = {**w, "optional": v.get("optional", False)}
                where = workspace_dir
            path = posixpath.normpath(posixpath.join(where, v["path"])) if "path" in v else None
            out.append((v.get("package", key), bool(v.get("optional", False)), path))
    return out


def shipped_deps(repo: Path, ref: str, lockfile: str, roots: list[str]) -> dict | None:
    """What the roots in the lockfile at ref link (None: no lockfile).

    direct: each registry or git crate a shipped path package depends on for macOS, by locked
    name, mapped to whether every such use is optional (a feature may leave it out);
    linked: every crate the lockfile reaches from the roots, name to versions. The lockfile has
    no targets or features, so `linked` over-counts (Windows and Linux crates, optional ones);
    only `direct` is read from the manifests."""
    text = show(repo, ref, lockfile)
    if text is None:
        return None
    packages = tomllib.loads(text).get("package", [])
    by_name: dict[str, list[dict]] = {}
    for p in packages:
        by_name.setdefault(p["name"], []).append(p)
    lock_dir = posixpath.dirname(lockfile)
    ws_root = manifest_at(repo, ref, posixpath.join(lock_dir, "Cargo.toml")) or {}
    workspace = ws_root.get("workspace", {}).get("dependencies", {})
    names = git(repo, "ls-tree", "-r", "--name-only", "--full-tree", ref, "--", lock_dir or ".").splitlines()
    manifests: dict[str, str] = {}  # path package name -> its folder
    for path in names:
        if not path.endswith("Cargo.toml") or "/vendor/" in f"/{path}" or "/target/" in f"/{path}":
            continue
        m = manifest_at(repo, ref, path)
        name = (m or {}).get("package", {}).get("name")
        if name:
            manifests.setdefault(name, posixpath.dirname(path))

    direct: dict[str, bool] = {}
    shipping_edges: dict[str, set[str]] = {}  # path package -> its non-dev dependencies, any target
    seen: set[tuple[str, bool]] = set()
    stack = [(manifests[r], False) for r in roots if r in manifests]
    while stack:
        folder, optional = stack.pop()
        if (folder, optional) in seen or (folder, False) in seen:
            continue
        seen.add((folder, optional))
        m = manifest_at(repo, ref, posixpath.join(folder, "Cargo.toml")) or {}
        if m.get("package", {}).get("name"):
            shipping_edges[m["package"]["name"]] = {d[0] for d in mac_deps(m, folder, workspace, lock_dir, any_target=True)}
        for name, opt, path in mac_deps(m, folder, workspace, lock_dir):
            if path is not None:
                stack.append((path, optional or opt))
            else:
                direct[name] = direct.get(name, True) and (optional or opt)

    def resolve(dep: str) -> dict | None:
        bits = dep.split(" ")
        cands = by_name.get(bits[0], [])
        if len(bits) > 1:
            cands = [c for c in cands if c["version"] == bits[1]] or cands
        return cands[0] if cands else None

    linked: dict[str, set[str]] = {}
    done: set[str] = set()
    walk = [p for r in roots for p in by_name.get(r, []) if "source" not in p]
    while walk:
        p = walk.pop()
        key = f"{p['name']} {p['version']}"
        if key in done:
            continue
        done.add(key)
        if "source" in p:
            linked.setdefault(p["name"], set()).add(p["version"])
        edges = shipping_edges.get(p["name"]) if "source" not in p else None
        for dep in p.get("dependencies", []):
            if edges is not None and dep.split(" ")[0] not in edges:
                continue  # a dev-dependency of a path package
            q = resolve(dep)
            if q is not None:
                walk.append(q)
    return {"direct": direct, "linked": linked}


def crate_changes(lockfile: str, b: dict, h: dict) -> tuple[list[dict], list[dict]]:
    """(fails, notes), one entry per crate name. Fails: a crate a shipped package now depends on
    for macOS, unconditionally, that the base did not link, or did link at fewer versions.
    Notes: the rest the lockfile newly reaches (optional, transitive, maybe another target's)."""
    fails, notes = [], []
    for name in sorted(set(h["linked"]) | set(h["direct"])):
        hv, bv = h["linked"].get(name, set()), b["linked"].get(name, set())
        new = not bv and (bool(hv) or name not in b["direct"])
        more = bool(bv) and len(hv) > len(bv)
        if not (new or more):
            continue
        entry = {"lockfile": lockfile, "crate": name, "versions": sorted(hv), "second_version": more}
        if h["direct"].get(name) is False:
            fails.append(entry)
        else:
            notes.append({**entry, "why": "optional" if name in h["direct"] else "transitive"})
    return fails, notes


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
        wb, wh = web_bytes(web_base, rules), web_bytes(web_head, rules)
        for p in rules["web_outputs"]:
            b, h = wb[p], wh[p]
            rows.append({"kind": "web", "path": p, "base": b, "head": h, "delta": h - b})
    new_crates, crate_notes = [], []
    for entry in rules["rust"]:
        empty = {"direct": {}, "linked": {}}
        b = shipped_deps(repo, base, entry["lockfile"], entry["roots"]) or empty
        h = shipped_deps(repo, head, entry["lockfile"], entry["roots"]) or empty
        fails, notes = crate_changes(entry["lockfile"], b, h)
        new_crates += fails
        crate_notes += notes
    growth = sum(r["delta"] for r in rows)
    reasons = ([m.group(0).strip() for m in REASON_LINE.finditer(body)] if body else []) + commit_reasons(repo, base, head)
    over = growth > rules["threshold_bytes"] or bool(new_crates)
    return {
        "base": base, "head": head, "threshold_bytes": rules["threshold_bytes"],
        "growth_bytes": growth, "rows": rows, "new_crates": new_crates, "crate_notes": crate_notes,
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
        lines += [f"- `{c['crate']} {', '.join(c['versions'])}` ({c['lockfile']}{', a second version' if c['second_version'] else ''})"
                  for c in r["new_crates"]]
    if r["crate_notes"]:
        lines += ["", "Also new in a shipped binary's lockfile graph, not counted (optional, or only transitive: "
                  "the lockfile does not say whether macOS links it):"]
        lines += [f"- `{c['crate']} {', '.join(c['versions'])}` ({c['lockfile']}, {c['why']})" for c in r["crate_notes"]]
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
    w = sub.add_parser("web-bytes", help="write the bytes of each web output of one build as JSON")
    w.add_argument("out_root", type=Path)
    w.add_argument("--budget", type=Path, default=BUDGET)
    a = ap.parse_args(argv)
    if a.cmd == "web-bytes":
        rules = json.loads(a.budget.read_text())["pull_request"]
        print(json.dumps(web_bytes(a.out_root, rules), sort_keys=True))
        return 0
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
