#!/usr/bin/env python3
"""A sparse checkout that runs cargo on the cmux-tui workspace carries every package that workspace loads.

cargo loads every workspace member and every path dependency, path [patch] and `workspace.dependencies` path before it
builds even one package (`cargo build -p cmux-cas` too), and a member whose folder is missing fails the whole command:
`failed to read workers/cmux-vm/cli/crates/cmux-vm/Cargo.toml: No such file or directory`. cmux-tui's manifests point
outside `cmux-tui/` (cmux-tui's bin crate links `workers/cmux-vm/cli` in process), so a list that names only
`/cmux-tui/` breaks the day a manifest adds such a path, with no change to the workflow. That happened to
cmux-next-web-bundle-publish.yml's cas/1 job: every new web key from then on published its pointer without `cas`
(RFD 0166's web update on cas/1 reached nobody), and the job is continue-on-error, so nothing went red.

For every job (and composite action) that runs `cargo` and checks out `cmux-tui/Cargo.toml` with a `sparse-checkout`
list, this test computes the workspace's package closure from the manifests (members, and the path sources of
dependencies, dev-, build- and target dependencies, `[workspace.dependencies]` and `[patch]`, transitively) and asks
git which of each package's files the list leaves out: it builds a throwaway repo with each package's Cargo.toml and
one file under its src/, runs `git sparse-checkout set` with the list verbatim (`--no-cone` when the step says
`sparse-checkout-cone-mode: false`, else `--cone`, actions/checkout's default), and reads `git ls-files -t`.
A job that runs cargo only through a script it calls is not seen. There is no allowlist.

Run: python3 tests/test_ci_sparse_cargo_path_deps.py
"""
from __future__ import annotations

import bisect
import functools
import glob
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tomllib
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = "cmux-tui/Cargo.toml"
CARGO = re.compile(r"(^|[\s;&|(`])cargo\s+(\+\S+\s+)?(build|check|clippy|test|nextest|run|doc|bench|metadata)\b")


@functools.cache
def tracked_files() -> tuple[str, ...]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return tuple(sorted(out.split("\0")))


def tracked(folder: str) -> list[str]:
    """The tracked files under FOLDER, from one ls-files of the whole repo."""
    files, prefix = tracked_files(), folder.rstrip("/") + "/"
    i = bisect.bisect_left(files, prefix)
    out = []
    while i < len(files) and files[i].startswith(prefix):
        out.append(files[i])
        i += 1
    return out


def path_sources(manifest: dict) -> list[str]:
    """Every `path = ...` a manifest's dependency tables and [patch] name."""
    tables: list[dict] = []

    def deps(t: dict) -> None:
        for key in ("dependencies", "dev-dependencies", "build-dependencies"):
            tables.append(t.get(key) or {})
        for target in (t.get("target") or {}).values():
            deps(target)

    deps(manifest)
    tables.append((manifest.get("workspace") or {}).get("dependencies") or {})
    tables.extend((manifest.get("patch") or {}).values())
    return [spec["path"] for table in tables for spec in table.values() if isinstance(spec, dict) and "path" in spec]


def workspace_packages() -> list[str]:
    """The folders of every package cargo loads for the cmux-tui workspace, repo-relative."""
    root = tomllib.loads((ROOT / WORKSPACE).read_text())
    ws = root.get("workspace") or {}
    excluded = {os.path.normpath(os.path.join("cmux-tui", e)) for e in ws.get("exclude") or []}
    todo = []
    for member in ws.get("members") or []:
        for hit in sorted(glob.glob(str(ROOT / "cmux-tui" / member / "Cargo.toml"))):
            rel = os.path.relpath(os.path.dirname(hit), ROOT)
            if rel not in excluded:
                todo.append(rel)
    todo += [os.path.normpath(os.path.join("cmux-tui", p)) for p in path_sources(root)]
    seen: set[str] = set()
    while todo:
        pkg = todo.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        manifest = ROOT / pkg / "Cargo.toml"
        if not manifest.is_file():
            continue
        todo += [os.path.normpath(os.path.join(pkg, p)) for p in path_sources(tomllib.loads(manifest.read_text()))]
    return sorted(seen | {"cmux-tui"})


def needed_files(packages: list[str]) -> list[str]:
    """Each package's Cargo.toml and one tracked file under its src/ (cargo infers targets from it)."""
    files = []
    for pkg in packages:
        files.append(f"{pkg}/Cargo.toml")
        src = tracked(f"{pkg}/src")
        if src:
            files.append(src[0])
    return files


def checkouts() -> list[tuple[str, str, list[str], bool]]:
    """(file, job, sparse patterns, cone) for each sparse actions/checkout in a job that runs cargo."""
    found = []
    docs = sorted(ROOT.glob(".github/workflows/*.yml")) + sorted(ROOT.glob(".github/actions/*/action.yml"))
    for doc in docs:
        data = yaml.safe_load(doc.read_text()) or {}
        jobs = dict(data.get("jobs") or {})
        if isinstance(data.get("runs"), dict):
            jobs["(composite)"] = data["runs"]
        for name, job in jobs.items():
            steps = (job or {}).get("steps") or []
            if not any(CARGO.search(str(s.get("run") or "")) for s in steps if isinstance(s, dict)):
                continue
            for step in steps:
                if not isinstance(step, dict) or not str(step.get("uses") or "").startswith("actions/checkout@"):
                    continue
                w = step.get("with") or {}
                sparse = w.get("sparse-checkout")
                if not sparse or "${{" in str(sparse):
                    continue
                patterns = [line.strip() for line in str(sparse).splitlines()
                            if line.strip() and not line.strip().startswith("#")]
                cone = str(w.get("sparse-checkout-cone-mode", True)).lower() != "false"
                found.append((str(doc.relative_to(ROOT)), name, patterns, cone))
    return found


def left_out(patterns: list[str], cone: bool, files: list[str]) -> tuple[bool, list[str]]:
    """(whether the list checks out the workspace manifest, the needed files it leaves out), as git decides."""
    with tempfile.TemporaryDirectory(prefix="sparse-cargo-") as tmp:
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        env.pop("BASH_ENV", None)

        def git(*args: str) -> str:
            return subprocess.run(["git", *args], cwd=tmp, env=env, capture_output=True, text=True,
                                  check=True).stdout

        git("init", "-q")
        for f in files:
            p = Path(tmp) / f
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x\n")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fixture")
        subprocess.run(["git", "sparse-checkout", "set", "--cone" if cone else "--no-cone", "--stdin"], cwd=tmp,
                       env=env, input="\n".join(patterns) + "\n", capture_output=True, text=True, check=True)
        skipped = {line[2:] for line in git("ls-files", "-t").splitlines() if line.startswith("S ")}
        return WORKSPACE not in skipped, sorted(f for f in files if f in skipped)


class SparseCargoPathDepsTest(unittest.TestCase):
    def test_workspace_reaches_outside_cmux_tui(self):
        # The closure walk itself: cmux-tui's bin crate links workers/cmux-vm/cli by path.
        self.assertIn("workers/cmux-vm/cli/crates/cmux-vm", workspace_packages())

    def test_every_cargo_sparse_checkout_carries_the_workspace(self):
        files = needed_files(workspace_packages())
        misses, judged = [], {}
        for doc, job, patterns, cone in checkouts():
            key = (tuple(patterns), cone)
            if key not in judged:
                judged[key] = left_out(patterns, cone, files)
            builds, missing = judged[key]
            if builds and missing:
                dirs = sorted({os.path.dirname(m).removesuffix("/src") for m in missing})
                misses.append(f"{doc} job {job}: its sparse-checkout leaves out {', '.join(dirs)}")
        self.assertEqual(misses, [], "cargo loads every package of the cmux-tui workspace; add these folders:\n"
                         + "\n".join(misses))


if __name__ == "__main__":
    unittest.main()
