#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that the Zig packages of the libghostty-vt that bin/cmux links are
covered by the shipped Ghostty license notices.

  check_ghostty_vt_notices.py [--repo DIR] [--rev REV] [--vt-git-dir DIR]
                              (--license-manifest SOURCE-MANIFEST.json ... | --print-source)
                              [--link-graph vt-link-graph.json]

bin/cmux (cmux-tui) links libghostty-vt, which ghostty-vt-sys's build.rs
builds with zig from a Ghostty submodule of the cmux tree: `ghostty` at older
cmux-tui pins, `ghostty-next` since 8aac5e8f3cb. The Ghostty license tree
(collect-ghostty-licenses.py) is collected from the `ghostty` submodule, so a
different source or commit can link Zig packages that no notice covers.

The check reads, from the cmux tree at REV (default HEAD), never from a
constant: the submodule that build.rs's default source names
(`manifest_dir.join("../../../<submodule>")`) and that submodule's gitlink
commit. It prints `libghostty-vt source: <submodule> <commit>` (cmux-browser
G2 matches this line), then reads the declared Zig package closure of that
commit without zig: build.zig.zon and every `.path` package it reaches, each
`.hash` dependency (lazy ones too). A declared closure is a superset of what
the libghostty-vt build links; the zig link-graph mode (plan only) narrows it.
Every declared package must appear in one of the --license-manifest files (a
collected tree's SOURCE-MANIFEST.json: a `license_files` package or a
`zig_packages` key). The vendored pkg/ and vendor/ directories of that commit
must pass ghostty_vendored.py too. Exit 1 names every uncovered package.

--link-graph FILE (vt_link_graph.py's output, made on a Testbox from the
DWARF of libghostty-vt.a built with -Dstrip=false) adds the linked set: the
graph must be for the resolved source and commit, no DWARF path may be
unattributed, and every linked package must be declared and covered. The
output names the linked and the declared-but-not-linked packages.

CMUX_GHOSTTY_SRC overrides build.rs's source for out-of-tree builds; the
cmux-tui workflows set it empty, so the gitlink is what ships.

Product override: a product that builds cmux-tui with its own Ghostty pin
(cmux-browser: cmux-tui-ghostty-revision.txt) passes --ghostty-revision SHA or
--ghostty-revision-file FILE. It wins over the gitlink, must exist in the vt
repository, and the output says `commit source: product override (...)`.
Without it the commit is the gitlink of REV (`commit source: gitlink of REV`),
the rule for cmux-next.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import posixpath
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BUILD_RS = "cmux-tui/crates/ghostty-vt-sys/build.rs"
SOURCE = re.compile(r'manifest_dir\.join\(\s*"\.\./\.\./\.\./([A-Za-z0-9._-]+)"\s*\)')
sys.path.insert(0, str(ROOT / "cmux-tui/build-support/notices/ghostty"))
import ghostty_vendored  # noqa: E402

ZON_HASH = re.compile(r'\.hash\s*=\s*"([^"\\]+)"')
ZON_PATH = re.compile(r'\.path\s*=\s*"([^"\\]+)"')
ZON_LAZY = re.compile(r"\.lazy\s*=\s*true")


class CheckError(RuntimeError):
    pass


@dataclass(frozen=True)
class Package:
    name: str
    package_hash: str
    declared_in: str
    lazy: bool


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise CheckError(f"git -C {repo} {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def resolve_vt_source(repo: Path, rev: str) -> tuple[str, str]:
    """(submodule path, gitlink commit) that bin/cmux's libghostty-vt comes from."""
    build_rs = git(repo, "show", f"{rev}:{BUILD_RS}")
    sources = set(SOURCE.findall(build_rs))
    if len(sources) != 1:
        raise CheckError(f"{BUILD_RS} at {rev} names {sorted(sources) or 'no'} default Ghostty sources; expected one")
    path = sources.pop()
    entry = git(repo, "ls-tree", rev, "--", path).split()
    if len(entry) < 4 or entry[0] != "160000" or entry[1] != "commit":
        raise CheckError(f"{path} at {rev} is not a submodule gitlink")
    return path, entry[2]


def declared_packages(vt_git_dir: Path, commit: str) -> list[Package]:
    """Every `.hash` dependency in build.zig.zon and the `.path` packages it reaches."""
    found: dict[str, Package] = {}
    seen: set[str] = set()
    pending = ["build.zig.zon"]
    while pending:
        zon = pending.pop()
        if zon in seen:
            continue
        seen.add(zon)
        try:
            text = git(vt_git_dir, "show", f"{commit}:{zon}")
        except CheckError:
            if zon == "build.zig.zon":
                raise
            continue
        for raw, body in ghostty_vendored.ZON_DEPENDENCY.findall(ghostty_vendored.strip_zon_comments(text)):
            name = raw[2:-1] if raw.startswith('@"') else raw
            package_hash, path = ZON_HASH.search(body), ZON_PATH.search(body)
            if package_hash:
                found.setdefault(package_hash[1], Package(name, package_hash[1], zon, bool(ZON_LAZY.search(body))))
            elif path:
                pending.append(posixpath.normpath(posixpath.join(posixpath.dirname(zon), path[1], "build.zig.zon")))
    return sorted(found.values(), key=lambda package: (package.name, package.package_hash))


def covered_packages(manifests: list[Path]) -> set[str]:
    covered: set[str] = set()
    for path in manifests:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        covered.update(str(entry["package"]) for entry in manifest.get("license_files", []))
        covered.update(manifest.get("zig_packages", {}))
    return covered


def link_graph_problems(graph: dict, path: str, commit: str, declared: list[Package], covered: set[str]) -> tuple[list[str], list[str]]:
    """(problems, report lines) for a vt_link_graph.py result."""
    if graph.get("source") != path or graph.get("commit") != commit:
        return [
            f"link graph is for {graph.get('source')} {graph.get('commit')}, not {path} {commit}; "
            "regenerate it on a Testbox with scripts/cmux-next/notices/vt_link_graph.py generate"
        ], []
    problems: list[str] = []
    by_hash = {package.package_hash: package for package in declared}
    linked: dict[str, list[str]] = {}
    for target, entry in sorted(graph.get("targets", {}).items()):
        for source_path in entry.get("unattributed", []):
            problems.append(f"link graph {target}: DWARF source path {source_path} belongs to no package, Zig lib or the Ghostty tree")
        for package_hash in entry.get("packages", []):
            linked.setdefault(package_hash, []).append(target)
    if not graph.get("targets"):
        problems.append("link graph has no targets")
    for package_hash, targets in sorted(linked.items()):
        if package_hash not in by_hash:
            problems.append(f"link graph: {package_hash} is linked ({', '.join(targets)}) but not declared in build.zig.zon")
        elif package_hash not in covered:
            problems.append(f"link graph: linked Zig package {by_hash[package_hash].name} {package_hash} is in no license manifest")
    names = lambda hashes: ", ".join(f"{by_hash[h].name if h in by_hash else '?'} {h}" for h in hashes) or "none"
    not_linked = sorted((p.package_hash for p in declared if p.package_hash not in linked), key=lambda h: (by_hash[h].name, h))
    report = [
        f"link graph ({', '.join(sorted(graph['targets']))}): linked {len(linked)} of {len(declared)} declared Zig packages",
        f"linked: {names(sorted(linked, key=lambda h: (by_hash[h].name if h in by_hash else h, h)))}",
        f"declared, not linked: {names(not_linked)}",
    ]
    vendored = sorted({v for entry in graph["targets"].values() for v in entry.get("vendored", {})})
    report.append(f"vendored Ghostty directories linked: {', '.join(vendored) or 'none'}")
    return problems, report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=ROOT, help="the cmux repository")
    parser.add_argument("--rev", default="HEAD", help="the cmux commit whose bin/cmux is checked (e.g. the cmux-tui pin)")
    parser.add_argument("--vt-git-dir", type=Path, help="the Ghostty repository that holds the gitlink commit (default: the submodule in --repo)")
    parser.add_argument("--license-manifest", type=Path, action="append", default=[], help="a collected SOURCE-MANIFEST.json (repeatable)")
    parser.add_argument("--print-source", action="store_true", help="print the resolved source and commit only")
    parser.add_argument("--link-graph", type=Path, help="vt_link_graph.py output: also check the packages the archive links")
    override = parser.add_mutually_exclusive_group()
    override.add_argument("--ghostty-revision", help="product override: the Ghostty commit the product builds cmux-tui with")
    override.add_argument("--ghostty-revision-file", type=Path, help="product override: a pin file whose first line is that commit")
    args = parser.parse_args(argv)
    try:
        path, commit = resolve_vt_source(args.repo, args.rev)
        vt_git_dir = args.vt_git_dir or args.repo / path
        origin = f"gitlink of {args.rev}"
        if args.ghostty_revision_file is not None:
            args.ghostty_revision = args.ghostty_revision_file.read_text(encoding="utf-8").split()[0]
            origin = f"product override ({args.ghostty_revision_file})"
        elif args.ghostty_revision is not None:
            origin = "product override (--ghostty-revision)"
        if args.ghostty_revision is not None:
            if not re.fullmatch(r"[0-9a-f]{40}", args.ghostty_revision):
                raise CheckError(f"override {args.ghostty_revision!r} is not a 40-hex commit")
            try:
                git(vt_git_dir, "cat-file", "-e", f"{args.ghostty_revision}^{{commit}}")
            except CheckError:
                raise CheckError(f"override commit {args.ghostty_revision} does not exist in {vt_git_dir}") from None
            commit = args.ghostty_revision
        print(f"libghostty-vt source: {path} {commit}")
        print(f"commit source: {origin}")
        if args.print_source:
            return 0
        if not args.license_manifest:
            parser.error("pass --license-manifest (or --print-source)")
        packages = declared_packages(vt_git_dir, commit)
        vendored_problems, _ = ghostty_vendored.check_tree(
            ghostty_vendored.Tree.from_git(vt_git_dir, commit),
            ghostty_vendored.load_manifest(
                ROOT / "cmux-tui/build-support/notices/ghostty/pinned-licenses/MANIFEST.json"
            )[1],
        )
    except CheckError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    covered = covered_packages(args.license_manifest)
    missing = [package for package in packages if package.package_hash not in covered]
    graph_problems: list[str] = []
    if args.link_graph is not None:
        graph_problems, report = link_graph_problems(
            json.loads(args.link_graph.read_text(encoding="utf-8")), path, commit, packages, covered
        )
        for line in report:
            print(line)
        for problem in graph_problems:
            print(f"error: {problem}", file=sys.stderr)
    for package in missing:
        print(
            f"error: libghostty-vt Zig package {package.name} {package.package_hash} "
            f"({package.declared_in}{', lazy' if package.lazy else ''}) is in no license manifest",
            file=sys.stderr,
        )
    for problem in vendored_problems:
        print(f"error: {path}@{commit[:11]}: {problem}", file=sys.stderr)
    if missing or vendored_problems or graph_problems:
        print(
            f"check_ghostty_vt_notices: {len(missing)} uncovered Zig package(s), "
            f"{len(vendored_problems)} vendored problem(s), {len(graph_problems)} link graph problem(s) in {path} {commit}",
            file=sys.stderr,
        )
        return 1
    print(f"check_ghostty_vt_notices: all {len(packages)} declared Zig packages of {path} {commit[:11]} are covered")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
