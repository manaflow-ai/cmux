#!/usr/bin/env python3
"""The oracle's seeded patch mutants: tests/oracle/mutants/<product>/<name>.patch (p15-oracle-026).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F "Mutation strength" and task 026. Twenty seeded
faults, ten in the app and ten in the daemon, kept as patch files. A job applies one in its own build worktree
before the build (`linux_run.sh build|run REF --mutant PATCH`, `linux_run.sh diff BASE HEAD --mutant PATCH` for
the head side; `scripts/measure/oracle.sh --mutant=PATCH` on the fleet, `fleet.py diff --head-mutant PATCH`).
Nothing is added to Sources or crates: no fault hooks, no `OracleFaults` switch. `selftest --mutants` (task 115)
runs each mutant against its base and counts the catches; `cargo mutants` (task 191) is the broad measure.

Stdlib only, Python 3.9+, safe under `python3 -I`:

    patch_mutants.py list [--product P] [--json]
    patch_mutants.py check [--ref REF] [--root DIR]     every patch is well formed and applies at REF (default HEAD)
    patch_mutants.py check --task [--ref REF]           the same for the task mutants, with no count
    patch_mutants.py validate PATCH [--product P] [--json]
                                                        one patch's header and scope; prints product/name (or
                                                        its parsed record, the one receipts store)

Patch format: `Key: value` header lines, a blank line, then `git diff` output. `git apply` skips the header.

    Mutant: daemon/workspace-move-lands-left     <product>/<file name without .patch>
    Suite: daemon-ops                            the suite expected to catch it (baselines.SUITE_CLASSES)
    Exercises: workspace.move                    the op, action or facet it breaks
    Fault: workspace.move puts the workspace one slot left of the asked index.

The check refuses: a missing or unknown header key, a Mutant line that does not match the path, an unknown suite,
a file outside the product's sources (app: Packages/macOS/CmuxNext/Sources/**.swift; daemon:
cmux-tui/crates/*/src/**.rs, never a test file), a new, deleted, renamed or binary file, a patch with more than
MAX_CHANGED_LINES changed lines, an added line that names the oracle (the fault reads as product code), two
patches with the same change, a patch that does not apply at REF, a product without EXPECTED_PER_PRODUCT patches,
and fault hooks in the sources at REF (`git grep OracleFaults -- Packages`, likewise in cmux-tui/crates).
Exit: 0 clean, 1 errors, 2 bad usage.

Task mutants (tests/oracle/task-mutants/<product>/<name>.patch, TASK_ROOT) have the same format and the same
checks but the count: each is the fault one task's test phase must catch (p15-oracle-206's double create), kept
out of the smoke set of ten per product that `selftest --mutants` scores. `linux_run.sh --mutant` applies them
the same way.

Chrome reference: a try bot applies the CL's patch to its own checkout before it compiles
(depot_tools recipes/recipe_modules/bot_update/resources/bot_update.py) and reruns failures "(without patch)"
(chromium/tools/build recipes/recipe_modules/chromium_tests/api.py); a mutant here is such a patch, applied in the
job worktree and never committed. Google's mutation testing keeps mutants out of the source the same way
(Petrovic and Ivankovic, "State of Mutation Testing at Google", ICSE-SEIP 2018).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import baselines  # noqa: E402  (SUITE_CLASSES: the suite names)

DEFAULT_ROOT = REPO / "tests" / "oracle" / "mutants"
TASK_ROOT = REPO / "tests" / "oracle" / "task-mutants"
PRODUCTS = ("app", "daemon")
EXPECTED_PER_PRODUCT = 10
# A seeded fault is one small change: an operator, a constant, a branch or one line removed.
MAX_CHANGED_LINES = 12
HEADER_KEYS = ("Mutant", "Suite", "Exercises", "Fault")
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
DIFF_HEADER = re.compile(r"^diff --git a/(\S+) b/(\S+)$")
# Fault hooks the spec dropped (draft tasks 022 and 045); none may come back in the sources.
FAULT_HOOK = r"OracleFaults?\b|oracle_faults?\b|ORACLE_FAULTS?\b"
HOOK_PATHS = ("Packages", "cmux-tui/crates")
# Added lines must read as product code: a mutant that names the oracle or itself is a hook in disguise.
ORACLE_WORDS = re.compile(r"oracle|mutant", re.IGNORECASE)
REFUSED_MARKS = ("new file mode", "deleted file mode", "rename from", "rename to", "copy from", "copy to",
                 "GIT binary patch", "Binary files ")


class UsageError(Exception):
    pass


@dataclass
class Mutant:
    product: str
    name: str
    path: Path
    suite: str
    exercises: str
    fault: str
    files: List[str] = field(default_factory=list)
    changed: int = 0
    body: str = ""

    @property
    def id(self) -> str:
        return f"{self.product}/{self.name}"

    def record(self) -> Dict[str, object]:
        return {"id": self.id, "product": self.product, "name": self.name, "path": str(self.path),
                "suite": self.suite, "exercises": self.exercises, "fault": self.fault, "files": self.files,
                "changedLines": self.changed}


def in_scope(product: str, path: str) -> bool:
    """Whether a mutant of `product` may change `path` (repo relative): product sources only, never tests."""
    parts = path.split("/")
    if ".." in parts or path.startswith("/"):
        return False
    if product == "app":
        return path.startswith("Packages/macOS/CmuxNext/Sources/") and path.endswith(".swift")
    if product == "daemon":
        name = parts[-1]
        return (len(parts) >= 5 and parts[:2] == ["cmux-tui", "crates"] and parts[3] == "src" and path.endswith(".rs")
                and "tests" not in parts[3:-1] and not name.endswith("_tests.rs") and name not in ("tests.rs", "test.rs"))
    return False


def parse(path: Path, product: Optional[str] = None) -> Tuple[Optional[Mutant], List[str]]:
    """One patch file: its header and diff. `product` defaults to the parent directory's name."""
    where = str(path)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return None, [f"{where}: unreadable: {error}"]
    product = product or path.parent.name
    errors: List[str] = []
    if product not in PRODUCTS:
        return None, [f"{where}: product {product!r} is not one of {', '.join(PRODUCTS)}"]
    name = path.name[: -len(".patch")] if path.name.endswith(".patch") else ""
    if not NAME.match(name):
        errors.append(f"{where}: the file name must be <lowercase-name>.patch")
    head, sep, body = text.partition("\n\n")
    if not sep:
        return None, errors + [f"{where}: no blank line between the header and the diff"]
    header: Dict[str, str] = {}
    for line in head.splitlines():
        key, colon, value = line.partition(":")
        if not colon or key not in HEADER_KEYS:
            errors.append(f"{where}: header line {line!r}: not one of {', '.join(HEADER_KEYS)}")
        elif key in header:
            errors.append(f"{where}: header {key} repeats")
        else:
            header[key] = value.strip()
    for key in HEADER_KEYS:
        if not header.get(key):
            errors.append(f"{where}: header {key} is missing or empty")
    if header.get("Mutant") and header["Mutant"] != f"{product}/{name}":
        errors.append(f"{where}: Mutant: {header['Mutant']} does not match its path {product}/{name}")
    suite = header.get("Suite", "")
    if suite and suite not in baselines.SUITE_CLASSES:
        errors.append(f"{where}: Suite: {suite} is not an oracle suite (baselines.SUITE_CLASSES)")
    files: List[str] = []
    changed = 0
    for line in body.splitlines():
        match = DIFF_HEADER.match(line)
        if match:
            a, b = match.groups()
            if a != b:
                errors.append(f"{where}: {a} -> {b}: a mutant edits a file in place")
            files.append(b)
            if not in_scope(product, b):
                errors.append(f"{where}: {b} is outside the {product}'s product sources")
        elif line.startswith(REFUSED_MARKS):
            errors.append(f"{where}: {line.strip()}: a mutant only edits existing text files")
        elif line.startswith(("+++", "---")):
            continue
        elif line.startswith(("+", "-")):
            changed += 1
            if line.startswith("+") and ORACLE_WORDS.search(line):
                errors.append(f"{where}: added line names the oracle: {line[1:].strip()!r}")
    if not files:
        errors.append(f"{where}: no `diff --git` section")
    if changed == 0 and files:
        errors.append(f"{where}: the diff changes no line")
    if changed > MAX_CHANGED_LINES:
        errors.append(f"{where}: {changed} changed lines; a seeded fault is at most {MAX_CHANGED_LINES}")
    mutant = Mutant(product, name, path, suite, header.get("Exercises", ""), header.get("Fault", ""), files,
                    changed, body)
    return mutant, errors


def load(root: Path = DEFAULT_ROOT) -> Tuple[List[Mutant], List[str]]:
    """Every `<product>/*.patch` under `root`, sorted by id, and the format errors."""
    mutants: List[Mutant] = []
    errors: List[str] = []
    if not root.is_dir():
        return [], [f"{root}: no mutants directory"]
    for entry in sorted(root.iterdir()):
        if entry.is_dir() and entry.name not in PRODUCTS:
            errors.append(f"{entry}: not a product directory ({', '.join(PRODUCTS)})")
    for product in PRODUCTS:
        for path in sorted((root / product).glob("*")):
            if path.suffix != ".patch":
                errors.append(f"{path}: only .patch files go in a product directory")
                continue
            mutant, found = parse(path, product)
            errors.extend(found)
            if mutant is not None:
                mutants.append(mutant)
    return mutants, errors


def git(args: Sequence[str], *, repo: Path, env: Optional[Dict[str, str]] = None,
        input_text: Optional[str] = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], input=input_text, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, check=False, env=env)


def resolve(ref: str, repo: Path = REPO) -> str:
    proc = git(["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], repo=repo)
    if proc.returncode != 0:
        raise UsageError(f"{ref}: not a commit in {repo}")
    return proc.stdout.strip()


def apply_errors(mutants: Sequence[Mutant], ref: str, repo: Path = REPO) -> List[str]:
    """`git apply --check` of each patch against REF's tree, through a scratch index: the work tree and the
    real index are not read or changed, so the answer is the same in a dirty checkout."""
    sha = resolve(ref, repo)
    errors: List[str] = []
    with tempfile.TemporaryDirectory(prefix="patch-mutants-") as tmp:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(tmp) / "index")}
        loaded = git(["read-tree", sha], repo=repo, env=env)
        if loaded.returncode != 0:
            return [f"git read-tree {sha}: {loaded.stderr.strip()}"]
        for mutant in mutants:
            proc = git(["apply", "--cached", "--check", "-"], repo=repo, env=env, input_text=mutant.body)
            if proc.returncode != 0:
                detail = " ".join(proc.stderr.split())
                errors.append(f"{mutant.path}: does not apply at {sha[:12]}: {detail}")
    return errors


def hook_errors(ref: str, repo: Path = REPO) -> List[str]:
    """Fault hooks in the sources at REF: `git grep` exits 1 when nothing matches."""
    sha = resolve(ref, repo)
    proc = git(["grep", "-n", "-I", "-E", FAULT_HOOK, sha, "--", *HOOK_PATHS], repo=repo)
    if proc.returncode == 1:
        return []
    if proc.returncode != 0:
        return [f"git grep at {sha[:12]}: {proc.stderr.strip()}"]
    return [f"fault hook in the sources: {line}" for line in proc.stdout.splitlines()]


def check(root: Path = DEFAULT_ROOT, ref: str = "HEAD", repo: Path = REPO,
          counted: bool = True) -> Tuple[List[Mutant], List[str]]:
    """Every patch under `root` at REF; `counted` (the smoke set) also holds each product at EXPECTED_PER_PRODUCT."""
    mutants, errors = load(root)
    for product in PRODUCTS:
        count = sum(m.product == product for m in mutants)
        if counted and count != EXPECTED_PER_PRODUCT:
            errors.append(f"{root / product}: {count} mutants; the smoke set has {EXPECTED_PER_PRODUCT} per product")
    seen: Dict[str, str] = {}
    for mutant in mutants:
        # The hunks with their file and place; the `index` line names blobs, not the change.
        change = "\n".join(line for line in mutant.body.splitlines() if not line.startswith("index "))
        if change in seen:
            errors.append(f"{mutant.path}: the same change as {seen[change]}")
        seen.setdefault(change, mutant.id)
    errors.extend(apply_errors(mutants, ref, repo))
    errors.extend(hook_errors(ref, repo))
    return mutants, errors


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="patch_mutants.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    listing = sub.add_parser("list", help="the mutants, one per line (or --json)")
    listing.add_argument("--product", choices=PRODUCTS)
    listing.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    listing.add_argument("--json", action="store_true")
    checking = sub.add_parser("check", help="every patch is well formed and applies at --ref")
    checking.add_argument("--ref", default="HEAD")
    checking.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    checking.add_argument("--task", action="store_true", help=f"check {TASK_ROOT} (no count) instead of --root")
    validating = sub.add_parser("validate", help="one patch's header and scope; prints product/name")
    validating.add_argument("patch", type=Path)
    validating.add_argument("--product", choices=PRODUCTS, help="the product the build is for")
    validating.add_argument("--json", action="store_true", help="print the parsed record instead of the id")
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            mutants, errors = load(args.root)
            mutants = [m for m in mutants if args.product in (None, m.product)]
            if args.json:
                print(json.dumps({"mutants": [m.record() for m in mutants], "errors": errors}, indent=1))
            else:
                for m in mutants:
                    print(f"{m.id}\t{m.suite}\t{m.exercises}")
                for error in errors:
                    print(f"error: {error}", file=sys.stderr)
            return 1 if errors else 0
        if args.command == "check":
            mutants, errors = check(TASK_ROOT, args.ref, counted=False) if args.task else check(args.root, args.ref)
            for error in errors:
                print(f"error: {error}", file=sys.stderr)
            counts = ", ".join(f"{sum(m.product == p for m in mutants)} {p}" for p in PRODUCTS)
            print(f"patch mutants: {counts}; {len(errors)} errors at {resolve(args.ref)[:12]}")
            return 1 if errors else 0
        path = args.patch.resolve()
        if not path.is_file():
            raise UsageError(f"{args.patch}: no such patch")
        product = args.product or path.parent.name
        if path.parent.name != product:
            raise UsageError(f"{args.patch}: its directory is {path.parent.name}; this build is the {product}")
        mutant, errors = parse(path, product)
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        if mutant is None or errors:
            return 1
        print(json.dumps(mutant.record(), sort_keys=True) if args.json else mutant.id)
        return 0
    except UsageError as error:
        print(f"patch_mutants: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
