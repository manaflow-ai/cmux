#!/usr/bin/env python3
"""Generated files never conflict for a person: each one merges through a driver, then is rebuilt.

Leo, 2026-11-16: "generated schema files those shouldve been handled automatically right why did you
even notice the conflict it shouldve just been done".

Which files are generated comes from the generated-files check (scripts/ci/generated_files_guard.py):
the "committed" generators in scripts/ci/generated-files.json, the exports in
scripts/cmux-next/generated_outputs.py OUTPUTS, the tracked files in
scripts/ci/generated-files-baseline.txt, and the files its naming conventions mark. A file inside a
directory with an SDK `.cmux-sdk-manifest.json` is generated only when that manifest lists it (the
Java and Go raw packages mix hand-written files into generated ones).

Each of those files belongs to a family (its generator id, its OUTPUTS row's first pattern, or its
own path for a baseline file), and REGENERATE says how the family is rebuilt after a merge:

  here      the commands run on any host with python3 and bun (Linux CI included), from the repo
            root. The file merges with `cmux-generated-v1` (scripts/merge-insertions.py
            --generated: the three-way merge when it is clean, else this branch's copy, said on
            stderr), and `regenerate` rebuilds it from the merged inputs.
  autofix   only the base autofix can rebuild it (a Mac runs the Swift tests that export it), so
            it never keeps one side: `cmux-export-v1` (scripts/merge-insertions.py) merges it
            three-way, both sides' rows kept, or stops the merge on a real conflict naming the
            file. It kept this branch's copy until 2026-11-22, which dropped every settings row
            the base added since the branch last merged (cmux#45928, cmux#47525), and nothing
            rebuilt them.
  line      no merge host can rebuild it (a vendored upstream snapshot, a release build's
            output). It merges by line, or by the semantic driver named, never by keeping one
            side, which would drop the other side's change with nothing to restore it.

  generated_merge.py audit [--repo DIR]
      The detector (tests/test_generated_merge.py runs it on this tree). Exit 1, naming each file,
      when a generated file's family has no REGENERATE entry, when its merge attribute is not the
      one its entry names, when a `cmux-generated-v1` file is not generated at all (keeping one
      side would drop a hand edit), or when a REGENERATE key names no family any more.
  generated_merge.py regenerate [--repo DIR] (--merge | --all | --paths-from FILE | --families A,B) [--web] [--stage]
      Runs the `here` commands of every family a merge touched: the generated paths still
      unmerged, plus those both sides of the merge changed (a clean line merge of two builds is
      no build either). --merge reads MERGE_HEAD, or HEAD^2 after the merge commit. --stage adds
      the rebuilt files to the index. Prints what it ran and what the base autofix still owns.
      Exit 1, naming the file, when a family has no REGENERATE entry, or (--merge) when a
      generated file no command here rebuilt lacks a line either side added: a merge that kept
      one side (an older clone whose cmux-generated-v1 driver is still `true`).
  generated_merge.py paths [--repo DIR]
      Every generated path with its family and expected driver, one per line (tab-separated).
"""
from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GUARD = "scripts/ci/generated_files_guard.py"
SDK_MANIFEST = ".cmux-sdk-manifest.json"
# Written beside the manifest by the same SDK run (sync-resource-api.py), never listed in it.
SDK_SIDECARS = {SDK_MANIFEST, ".cmux-resource-api.json"}
GENERATED_DRIVER = "cmux-generated-v1"
# The Mac-only exports (`autofix`): a three-way merge or a conflict, never one side.
EXPORT_DRIVER = "cmux-export-v1"
# The semantic drivers a `line` family may name instead of git's line merge (.gitattributes).
LINE_DRIVERS = {"unspecified", "cmux-insertions-v1", "cmux-baseline-v1", "cmux-capabilities-v1"}


@dataclass(frozen=True)
class Regen:
    where: str  # "here", "autofix" or "line"
    commands: tuple[tuple[str, ...], ...] = ()  # each run from the repo root, in order (`here` only)
    driver: str = GENERATED_DRIVER  # the merge attribute every output must have
    why: str = ""

    def __post_init__(self) -> None:
        if self.where not in {"here", "autofix", "line"}:
            raise ValueError(f"where must be here, autofix or line, not {self.where!r}")
        if (self.where == "here") != bool(self.commands):
            raise ValueError("a `here` family has commands; no other family does")
        if self.where == "line" and (self.driver not in LINE_DRIVERS or not self.why):
            raise ValueError(f"a `line` family names a line or semantic driver and why ({self.driver!r})")
        if self.where == "autofix" and self.driver == GENERATED_DRIVER:
            raise ValueError(f"an `autofix` family has no rebuild on a merge host, so it may not keep one side "
                             f"({GENERATED_DRIVER}); use {EXPORT_DRIVER} or a semantic driver")


def here(*commands: tuple[str, ...]) -> Regen:
    return Regen("here", tuple(commands))


def autofix(how: str, driver: str = EXPORT_DRIVER) -> Regen:
    return Regen("autofix", driver=driver, why=how)


def line(why: str, driver: str = "unspecified") -> Regen:
    return Regen("line", driver=driver, why=why)


def in_dir(directory: str, *command: str) -> tuple[str, ...]:
    """A command run from DIRECTORY (relative to the repo root)."""
    return ("sh", "-c", 'cd "$1" && shift && exec "$@"', "sh", directory, *command)


PY = "python3"
SDK = (
    (PY, "cmux-tui/bindings/codegen/generate.py", "--write"),
    (PY, "cmux-tui/bindings/rust/scripts/sync-resource-api.py"),
)
CLOUD = (in_dir("backend/packages/protocol", "bun", "scripts/export-client.ts"),
         in_dir("backend/packages/protocol", "bun", "scripts/export-rust-client.ts"))
NEXT_DOCS = here(("bun", "web/scripts/export-next-docs.ts"))
PANE_GO = "cmux-tui/bindings/codegen/pane/generate.py"

# Family -> how it is rebuilt. Keys: a generated-files.json generator id, a generated_outputs.py
# OUTPUTS row's first pattern, or a baseline path. The audit fails on a family missing here.
REGENERATE: dict[str, Regen] = {
    # generated-files.json "committed" generators.
    "settings-sources": here((PY, "scripts/cmux-next/gen-settings-sources.py")),
    "motion-scale": here((PY, "scripts/cmux-next/gen-motion-scale.py")),
    "type-scale": here((PY, "scripts/cmux-next/gen-type-scale.py")),
    "status-glyphs": here((PY, "scripts/cmux-next/gen-status-glyphs.py")),
    "phone-lane-fields": here((PY, "scripts/cmux-next/gen-phone-lane-fields.py")),
    "protected-folders": here((PY, "scripts/cmux-next/gen-protected-folders.py")),
    "chrome-styles": here((PY, "scripts/cmux-next/gen-chrome-styles.py")),
    "agent-icons": here((PY, "scripts/agent-icons/generate.py")),
    "icon-pack": here((PY, "scripts/icons/build_pack.py")),
    "pane-protocol-go": here(
        (PY, PANE_GO, "--write", "--ir", "cmux-tui/crates/cmux-pane-protocol/spec/pane-protocol.json",
         "--out", "cmux-tui/bindings/go-pane/examples/hello/hellopane", "--package", "hellopane",
         "--provider-ns", "com.example.hello"),
        (PY, PANE_GO, "--write", "--ir", "cmux-tui/bindings/go-pane/testdata/pane-protocol.rich.json",
         "--out", "cmux-tui/bindings/go-pane/internal/richpane", "--package", "richpane",
         "--provider-ns", "com.example.rich")),
    "iroh-v2-contracts": here(in_dir("workers/iroh-v2", "bun", "install", "--frozen-lockfile"),
                              in_dir("workers/iroh-v2", "bun", "scripts/generate-contracts.ts")),
    "control-plane-types": here(("bash", "scripts/gen-control-plane-types.sh")),
    "managed-relay-catalog": here(in_dir("web", "bun", "tools/generate-managed-iroh-relay-catalog.ts")),
    "app-pack": line("built by `cmux app pack`, which needs a cmux CLI build; no merge host has one"),
    # generated_outputs.py OUTPUTS rows.
    "Packages/macOS/CmuxNext/ci-target-graph.json": autofix("scripts/cmux-next/ci-target-graph.py"),
    "plans/cmux-next/daemon-capabilities.json": autofix(
        "check-daemon-capabilities-fresh.py --write; merges per list as a set", "cmux-capabilities-v1"),
    "plans/cmux-next/action-surfaces.json": autofix("scripts/cmux-next/regenerate-action-exports.sh (Swift)"),
    "docs/mdm/com.manaflow.cmux.json": autofix("scripts/cmux-next/regenerate-settings-exports.sh (Swift)"),
    "schemas/defaults/cmux-next.json": here((PY, "scripts/ci/defaults_guard.py", "snapshot")),
    "web/data/cmux-shortcuts.generated.json": here(("bun", "web/scripts/export-docs-shortcuts.ts")),
    "cmux-tui/crates/cmux-app-host/generated/*": here(("bun", "cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts")),
    "cmux-tui/bindings/*/.cmux-resource-api.json": here(*SDK),
    "clients/ts/cloud/src/generated.ts": here(*CLOUD),
    "scripts/ghosttykit-checksums.txt": autofix("the base autofix's GhosttyKit pin"),
    "scripts/lint-namespace-types-ratchet.txt": autofix("base-autofix.sh's namespace ratchet step; merges entry by entry",
                                                        "cmux-baseline-v1"),
    # generated-files-baseline.txt: generated files no "committed" generator owns.
    "web/data/next-docs/cli-reference.generated.json": NEXT_DOCS,
    "web/data/next-docs/palette-reference.generated.json": NEXT_DOCS,
    "web/data/next-docs/settings-reference.generated.json": NEXT_DOCS,
    "plans/cmux-next/coordination/INDEX.md": here((PY, "scripts/cmux-next/generate-coordination-index.py", "--write")),
    "agent-chat/adapters/claude-environment-policy.generated.ts": here(
        (PY, "scripts/generate-claude-launch-environment-policy.py", "--write")),
    "webviews/src/pages/shared/generated/pageRouter.ts": here((PY, "cmux-tui/bindings/codegen/page_router.py", "--write")),
    "clients/ts/cloud/src/automation-cmux.ts": here(*CLOUD),
    "web/services/vms/hygiene/script.generated.ts": here(in_dir("web", "bun", "scripts/generate-machine-hygiene-script.ts")),
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt.swift": here(
        (PY, "scripts/cmux-next/art/generate_backdrop_art.py")),
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/BackdropArt+Entries.swift": here(
        (PY, "scripts/cmux-next/art/generate_backdrop_art.py")),
    "Resources/markdown-viewer/ondine.min.js": line("a vendored upstream release (vendor-ondine.mjs)"),
    "THIRD_PARTY_LICENSES.md": line("written by the release build's license collector"),
    "cmux-tui/build-support/notices/REVIEW.md": line("written by pin-cmux-tui.sh when the cmux-tui pin moves"),
    "cmux-tui/build-support/notices/browser-host/THIRD_PARTY_LICENSES.linux.md": line(
        "written by browser-host-release.py's release packaging"),
    "cmux-tui/crates/acpmux/rules/secrets/gitleaks.toml": line("a vendored upstream rule set"),
    "cmux-tui/crates/cmux-app-host/js/dist/cmux-app-runtime.js": line(
        "an esbuild bundle (js/build.ts); rebuilt with the app host, not on a merge host"),
    "cmux-tui/crates/cmux-tasks-core/catalog/mux-task.d.ts": line(
        "emitted by a cargo build of cmux-tasks-core", "cmux-insertions-v1"),
    "first-party-apps/codemirror/THIRD_PARTY_NOTICES": line("written by the codemirror app's release build"),
    "first-party-apps/codemirror/web/THIRD_PARTY_NOTICES.txt": line("written by the codemirror app's release build"),
    "mux/packages/brain/conformance/chief-cases.json": line("written by the brain conformance generator (mux workspace)"),
    "backend/apps/api/src/domains/public-suffix-data.ts": line(
        "a vendored snapshot of the public suffix list", "cmux-insertions-v1"),
    "webviews/src/diff/generated/protocol.ts": line("emitted by ts-rs during a cargo test", "cmux-insertions-v1"),
    "webviews/src/icon-picker/generated/LICENSES.md": line("written with emoji-data.json by gen-emoji-data.mjs, which downloads"),
    "webviews/src/icon-picker/generated/emoji-data.json": line("gen-emoji-data.mjs downloads its upstream data"),
    "workers/cmux-vm/cli/crates/cmux-vm-client/src/generated.rs": line(
        "cmux-vm-codegen (workers/cmux-vm/cli/scripts/regenerate.sh), a cargo build"),
    "workers/cmux-vm/cli/crates/cmux-vm-client/src/generated_raw.rs": line(
        "cmux-vm-codegen (workers/cmux-vm/cli/scripts/regenerate.sh), a cargo build"),
}

# Generated files the generated-files check knows only by name (its conventions), mapped to the
# family that writes them. The manifest cannot list them: a pull request may not widen a committed
# generator's outputs.
CONVENTION_FAMILIES: dict[str, str] = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Tree/ProtectedFolderEntry.generated.swift": "protected-folders",
}


def _load_guard(repo: Path):
    spec = importlib.util.spec_from_file_location("generated_files_guard_for_merge", repo / GUARD)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module  # dataclasses look their module up while the class is made
    spec.loader.exec_module(module)
    return module


class Catalog:
    """The generated-files check's rules at REPO's working tree, read the way the check reads them."""

    def __init__(self, repo: Path):
        self.repo = repo
        guard = _load_guard(repo)
        self.guard = guard
        exports = guard.load_exports((repo / guard.OUTPUTS).read_text(encoding="utf-8"),
                                     (repo / guard.SETTINGS_EXPORTS).read_text(encoding="utf-8"))
        self.rules = guard.parse_rules((repo / guard.MANIFEST).read_text(encoding="utf-8"),
                                       (repo / guard.BASELINE).read_text(encoding="utf-8"), exports)
        self._manifests: dict[str, set[str] | None] = {}

    def sdk_listed(self, path: str) -> bool:
        """False only for a file beside an SDK manifest that does not list it (a hand-written file)."""
        directory, _, name = path.rpartition("/")
        if directory not in self._manifests:
            manifest = self.repo / directory / SDK_MANIFEST
            try:
                listed = {entry["path"] for entry in json.loads(manifest.read_text(encoding="utf-8"))["files"]}
            except (OSError, ValueError, KeyError, TypeError):
                listed = None
            self._manifests[directory] = listed
        listed = self._manifests[directory]
        return listed is None or name in SDK_SIDECARS or name in listed

    def family(self, path: str) -> str | None:
        """The family of a generated path, or None when the generated-files check does not call it generated."""
        if self.rules.committed_by_design(path) or not self.sdk_listed(path):
            return None
        found = self.rules.generator_of(path)
        if found is not None:
            return found.id if found.status == "committed" else None
        for patterns, _ in self.rules.exports:
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns):
                return patterns[0]
        if path in self.rules.baseline:
            return path
        if self.guard.matches(path, self.rules.conventions):
            return CONVENTION_FAMILIES.get(path, f"(convention) {path}")
        return None

    def families(self) -> set[str]:
        """Every family key the rules define: committed generators, OUTPUTS rows, baseline files."""
        keys = {g.id for g in self.rules.generators if g.status == "committed"}
        keys |= {patterns[0] for patterns, _ in self.rules.exports}
        return keys | self.rules.baseline


def git(repo: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False,
                          env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
    if check and done.returncode != 0:
        raise SystemExit(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def tracked(repo: Path) -> list[str]:
    return [path for path in git(repo, "ls-files", "-z").split("\0") if path]


def merge_attributes(repo: Path, paths: list[str]) -> dict[str, str]:
    """{path: merge attribute} through one `git check-attr` (paths from a file: a pipe write can block)."""
    if not paths:
        return {}
    import tempfile
    with tempfile.TemporaryFile() as handle:
        handle.write("\0".join(paths).encode())
        handle.seek(0)
        out = subprocess.run(["git", "-C", str(repo), "check-attr", "--stdin", "-z", "merge"], stdin=handle,
                             capture_output=True, check=True,
                             env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}).stdout.decode()
    fields = out.split("\0")
    return {fields[i]: fields[i + 2] for i in range(0, len(fields) - 2, 3)}


def audit(repo: Path) -> list[str]:
    catalog = Catalog(repo)
    files = tracked(repo)
    attributes = merge_attributes(repo, files)
    problems = []
    used = set()
    for path in files:
        family = catalog.family(path)
        attribute = attributes.get(path, "unspecified")
        if family is None:
            if attribute == GENERATED_DRIVER:
                problems.append(f"{path}: merges with {GENERATED_DRIVER}, which keeps one side, but the generated-files "
                                "check does not call it generated: a hand edit on the other side would be dropped. "
                                "Narrow its .gitattributes line (or `!merge` it after that line).")
            continue
        used.add(family)
        entry = REGENERATE.get(family)
        if entry is None:
            problems.append(f"{path}: generated (family {family!r}) but scripts/cmux-next/generated_merge.py REGENERATE "
                            "has no entry saying how a merge rebuilds it. Add one (here, autofix or line) and route it "
                            "in .gitattributes.")
            continue
        if attribute != entry.driver:
            problems.append(f"{path}: generated (family {family!r}, {entry.where}) must merge with "
                            f"merge={entry.driver} in .gitattributes, not {attribute}")
    stale = sorted(set(REGENERATE) - catalog.families() - used)
    problems += [f"REGENERATE[{key!r}]: no generated file has this family any more; remove the entry" for key in stale]
    return problems


def merge_sides(repo: Path) -> tuple[str, str, str | None]:
    """(ours, theirs, merge base or None) of a merge in progress (MERGE_HEAD) or just committed (HEAD^2)."""
    in_progress = git(repo, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).strip()
    ours, theirs = ("HEAD", in_progress) if in_progress else ("HEAD^1", "HEAD^2")
    if not git(repo, "rev-parse", "-q", "--verify", theirs + "^{commit}", check=False).strip():
        raise SystemExit("no merge to regenerate after: no MERGE_HEAD and HEAD is not a merge commit")
    bases = git(repo, "merge-base", "--all", ours, theirs).split()
    return ours, theirs, (bases[0] if bases else None)


def both_changed(repo: Path) -> list[str]:
    """The paths both sides of the merge changed since their merge base."""
    ours, theirs, base = merge_sides(repo)
    if base is None:
        return []
    mine = set(git(repo, "diff", "--name-only", "-z", "--no-renames", base, ours).split("\0"))
    other = set(git(repo, "diff", "--name-only", "-z", "--no-renames", base, theirs).split("\0"))
    return sorted(path for path in mine & other if path)


def merge_paths(repo: Path) -> list[str]:
    """The paths a merge in progress (MERGE_HEAD) or just committed (HEAD^2) needs rebuilt from."""
    merge_sides(repo)
    paths = set(git(repo, "diff", "--name-only", "-z", "--diff-filter=U").split("\0"))
    paths |= set(both_changed(repo))
    return sorted(path for path in paths if path)


def blob_lines(repo: Path, rev: str, path: str) -> list[bytes] | None:
    done = subprocess.run(["git", "-C", str(repo), "show", f"{rev}:{path}"], capture_output=True, check=False,
                          env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
    return done.stdout.splitlines() if done.returncode == 0 else None


def dropped(repo: Path, catalog: Catalog, rebuilt: set[str]) -> list[str]:
    """Generated files both sides changed, that no command here rebuilt, whose merged copy lacks a line one
    side added: the merge kept the other side (cmux#47525's settings rows). Unmerged paths are left to git."""
    from collections import Counter
    ours, theirs, base = merge_sides(repo)
    if base is None:
        return []
    unmerged = set(git(repo, "diff", "--name-only", "-z", "--diff-filter=U").split("\0"))
    problems = []
    for path in both_changed(repo):
        family = catalog.family(path)
        if family is None or family in rebuilt or path in unmerged or not (repo / path).is_file():
            continue
        result = Counter((repo / path).read_bytes().splitlines())
        before = Counter(blob_lines(repo, base, path) or [])
        for side, label in ((ours, "this branch"), (theirs, "the merged-in side")):
            lines = blob_lines(repo, side, path)
            if lines is None:
                continue
            counts = Counter(lines)
            lost = [line for line, count in counts.items() if count > before[line] and result[line] < count]
            if lost:
                sample = lost[0].decode("utf-8", "replace").strip()[:120]
                problems.append(f"{path}: the merge dropped {len(lost)} line(s) {label} added (first: {sample!r}); "
                                f"family {family!r} has no rebuild here, so it must merge three-way "
                                f"(`git merge-file` of both sides over {base[:12]}), never keep one side. "
                                "Rerun scripts/install-git-hooks.sh if this clone's merge drivers are old.")
    return problems




def families_of(catalog: Catalog, paths: list[str]) -> list[str]:
    """The families PATHS belong to, in first-seen order."""
    found: list[str] = []
    for path in paths:
        family = catalog.family(path)
        if family is not None and family not in found:
            found.append(family)
    return found


def web_kept(repo: Path, catalog: Catalog, paths: list[str]) -> bool:
    """Whether PATHS hold a kept web build output (a former bundle, a strings table): those are
    regenerate-web-bundles.sh's, the generator this step ran alone before the other families."""
    attributes = merge_attributes(repo, paths)
    return any(attributes.get(path) == GENERATED_DRIVER and catalog.family(path) is None for path in paths)


def plan(families: list[str]) -> tuple[list[tuple[str, ...]], list[str]]:
    """(the commands to run, deduplicated and in order; notes on what no command here rebuilds). A note that
    starts with "error:" fails the run: a family nobody knows how to rebuild is never silently kept."""
    commands: list[tuple[str, ...]] = []
    notes: list[str] = []
    for family in families:
        entry = REGENERATE.get(family)
        if entry is None:
            notes.append(f"error: {family}: generated, but REGENERATE has no entry saying how a merge rebuilds it; "
                         "its merged copy may be one side's (run `generated_merge.py audit`)")
        elif entry.where == "here":
            commands += [command for command in entry.commands if command not in commands]
        elif entry.where == "autofix":
            notes.append(f"{family}: merged three-way by {entry.driver}; the base autofix rebuilds it after "
                         f"landing ({entry.why})")
        else:
            notes.append(f"{family}: merged by {entry.driver}; no merge host rebuilds it ({entry.why})")
    return commands, notes


def regenerate(repo: Path, families: list[str], *, web: bool = False, stage: bool = False) -> int:
    """Run FAMILIES' commands (regenerate-web-bundles.sh first with WEB). Returns 1 when one failed."""
    commands, notes = plan(families)
    before = dirty(repo) if stage else set()
    if web:
        commands.insert(0, ("sh", "scripts/cmux-next/regenerate-web-bundles.sh"))
    failed = 0
    for command in commands:
        print(f"regenerating: {' '.join(command)}", flush=True)
        done = subprocess.run(command, cwd=repo, check=False)
        if done.returncode != 0:
            print(f"error: `{' '.join(command)}` exited {done.returncode}", file=sys.stderr)
            failed = 1
    for note in notes:
        if note.startswith("error:"):
            print(note, file=sys.stderr)
            failed = 1
        else:
            print(note)
    if stage and not failed:
        # What the generators wrote: tracked files they changed and new files they added (a new protocol type),
        # never a change that was in the work tree before they ran.
        changed = sorted(dirty(repo) - before)
        if changed:
            subprocess.run(["git", "-C", str(repo), "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"],
                           input="\0".join(changed).encode(), check=True)
            print(f"staged {len(changed)} regenerated file(s)")
    return failed


def dirty(repo: Path) -> set[str]:
    """Paths whose work-tree content differs from the index, untracked files included (not ignored ones)."""
    out = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
    return {record[3:] for record in out.split("\0") if len(record) > 3 and record[1] != " "}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("audit", "regenerate", "paths"))
    parser.add_argument("--repo", type=Path, default=ROOT)
    which = parser.add_mutually_exclusive_group()
    which.add_argument("--merge", action="store_true", help="the paths the current merge touched")
    which.add_argument("--all", action="store_true", help="every family a merge host rebuilds")
    which.add_argument("--paths-from", type=Path, help="a file of paths, one per line")
    which.add_argument("--families", help="family keys, comma-separated (`paths` prints them)")
    parser.add_argument("--web", action="store_true",
                        help="run regenerate-web-bundles.sh first, whatever the paths (the catch-up does)")
    parser.add_argument("--stage", action="store_true", help="git add the regenerated files")
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    if args.command == "audit":
        problems = audit(repo)
        for problem in problems:
            print(problem)
        if problems:
            print(f"{len(problems)} generated-file merge problem(s); see scripts/cmux-next/generated_merge.py")
        return 1 if problems else 0
    catalog = Catalog(repo)
    if args.command == "paths":
        for path in tracked(repo):
            family = catalog.family(path)
            if family is not None:
                entry = REGENERATE.get(family)
                print(f"{path}\t{family}\t{entry.where if entry else '?'}\t{entry.driver if entry else '?'}")
        return 0
    web = args.web
    if args.families is not None:
        families = [family for family in args.families.split(",") if family]
    elif args.all:
        families = sorted(REGENERATE)
    else:
        if args.merge:
            paths = merge_paths(repo)
        elif args.paths_from:
            paths = [line.strip() for line in args.paths_from.read_text(encoding="utf-8").splitlines() if line.strip()]
        else:
            parser.error("regenerate needs --merge, --all, --paths-from or --families")
        families = families_of(catalog, paths)
        web = web or web_kept(repo, catalog, paths)
    failed = regenerate(repo, families, web=web, stage=args.stage)
    if args.merge:
        rebuilt = {family for family in families if family in REGENERATE and REGENERATE[family].where == "here"}
        for problem in dropped(repo, catalog, rebuilt):
            print(f"error: {problem}", file=sys.stderr)
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
