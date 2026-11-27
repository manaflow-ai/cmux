#!/usr/bin/env python3
"""The SDK descriptors and schema hashes each have one source; this fails when a hand copy appears.

1. The resource operation catalog, cmux-tui/spec/resource-operations-v2.json.
   Each of the seven high-level SDKs used to carry a `.cmux-resource-api.json`
   descriptor: the catalog's protocol, its SHA-256 and every operation's class,
   copied by a sync script. Nothing read them at run time, yet every catalog
   change rewrote all seven, and a catalog change that left the pasted hash
   stale turned the base red (#23191, #34498). Fails on:
     - any tracked file named `.cmux-resource-api.json`;
     - any tracked file other than the catalog with the catalog's exact bytes;
     - any tracked file that pastes the catalog's SHA-256 (of its bytes, or of
       its canonical JSON, the form the descriptors used).

2. The SDK schema, cmux-tui/spec/sdk-schema.json, and its IR SHA-256. The
   codegen (cmux-tui/bindings/codegen/generate.py) writes it into each
   language's metadata constant and its `.cmux-sdk-manifest.json`, and
   `generate.py --check` keeps those current. It used to be pasted into every
   generated file's header too, so any schema change rewrote 27 files. Fails
   on any tracked file outside the generator's own outputs (the manifests and
   the files they list) that names the IR SHA-256, and on manifests that
   disagree about it.

3. The list of high-level SDK packages. `sync-resource-api.py` and
   `check-resource-api-boundary.py` each typed it ("keep in step with"), and
   their test typed it a third time. Fails when more than one tracked file
   types the seven package names as one quoted list; a script that needs the
   list imports it from the file that keeps it.

Exit 0 when every fact has its one source, 1 naming each copy otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path, PurePosixPath


CATALOG = "cmux-tui/spec/resource-operations-v2.json"
RETIRED_DESCRIPTOR = ".cmux-resource-api.json"
SDK_MANIFEST = ".cmux-sdk-manifest.json"
BINDINGS = "cmux-tui/bindings/"
# The high-level SDK packages, in the order a sorted list types them. A file that
# types all seven as one quoted list holds a copy of the list; one such file may
# be the list's home, a second is a copy.
SDK_PACKAGES = ("cpp", "go", "java", "python", "rust", "typescript", "zig")
SDK_PACKAGE_LIST_RE = r"[[:space:]]*,[[:space:]]*".join(
    f"[\"']{name}[\"']" for name in SDK_PACKAGES
)


def catalog_digests(raw: bytes) -> tuple[str, str]:
    """The SHA-256 of the catalog's bytes and of its canonical JSON."""
    canonical = json.dumps(
        json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return hashlib.sha256(raw).hexdigest(), hashlib.sha256(canonical).hexdigest()


def _git(root: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, check=False)


def _tracked(root: Path) -> list[tuple[str, str]] | str:
    """(path, blob id) of every tracked file, or git's error."""
    listed = _git(root, "ls-files", "-z", "-s")
    if listed.returncode != 0:
        return f"git ls-files failed: {listed.stderr.decode(errors='replace').strip()}"
    entries = []
    for entry in listed.stdout.split(b"\0"):
        if entry:
            meta, _, path = entry.partition(b"\t")
            entries.append((path.decode(errors="replace"), meta.split()[1].decode()))
    return entries


def _files_naming(root: Path, *needles: str, regex: bool = False) -> list[str] | str:
    arguments = ["grep", "-l", "-z", "-E" if regex else "-F"]
    for needle in needles:
        arguments += ["-e", needle]
    found = _git(root, *arguments)
    if found.returncode not in (0, 1):
        return f"git grep failed: {found.stderr.decode(errors='replace').strip()}"
    return [path for path in found.stdout.decode(errors="replace").split("\0") if path]


def catalog_copies(root: Path, tracked: list[tuple[str, str]]) -> list[str]:
    catalog = root / CATALOG
    if not catalog.is_file():
        return [f"{CATALOG} is missing"]
    problems: list[str] = []
    catalog_blob = _git(root, "hash-object", "--", CATALOG).stdout.decode().strip()
    for path, blob in tracked:
        if PurePosixPath(path).name == RETIRED_DESCRIPTOR:
            problems.append(f"{path}: a copy of the catalog's descriptor; read {CATALOG} instead")
        elif path != CATALOG and blob == catalog_blob:
            problems.append(f"{path}: a byte copy of {CATALOG}; read the catalog instead")
    hits = _files_naming(root, *catalog_digests(catalog.read_bytes()))
    if isinstance(hits, str):
        return [*problems, hits]
    for path in hits:
        if PurePosixPath(path).name != RETIRED_DESCRIPTOR:  # already named above
            problems.append(
                f"{path}: pastes the SHA-256 of {CATALOG}; compute it from the catalog instead"
            )
    return problems


def ir_hash_copies(root: Path, tracked: list[tuple[str, str]]) -> list[str]:
    problems: list[str] = []
    generated: set[str] = set()
    digests: dict[str, list[str]] = {}
    for path, _ in tracked:
        if not path.startswith(BINDINGS) or PurePosixPath(path).name != SDK_MANIFEST:
            continue
        try:
            document = json.loads((root / path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            problems.append(f"{path}: unreadable SDK manifest ({error})")
            continue
        generated.add(path)
        directory = PurePosixPath(path).parent
        for entry in document.get("files", ()):
            if isinstance(entry, dict) and isinstance(entry.get("path"), str):
                generated.add((directory / entry["path"]).as_posix())
        digest = document.get("ir_sha256")
        if isinstance(digest, str):
            digests.setdefault(digest, []).append(path)
    if len(digests) > 1:
        problems.append(
            "the SDK manifests disagree about ir_sha256 ("
            + "; ".join(f"{digest[:12]}: {', '.join(paths)}" for digest, paths in sorted(digests.items()))
            + "); run python3 cmux-tui/bindings/codegen/generate.py --write"
        )
    for digest in sorted(digests):
        hits = _files_naming(root, digest)
        if isinstance(hits, str):
            problems.append(hits)
            continue
        for path in hits:
            if path not in generated:
                problems.append(
                    f"{path}: pastes the SDK IR SHA-256; read the generated constant "
                    "(SDK_IR_SHA256 and its peers) instead"
                )
    return problems


def package_list_copies(root: Path) -> list[str]:
    hits = _files_naming(root, SDK_PACKAGE_LIST_RE, regex=True)
    if isinstance(hits, str):
        return [hits]
    if len(hits) < 2:
        return []
    return [
        f"{path}: types the SDK package list, as {len(hits) - 1} other file(s) do "
        f"({', '.join(other for other in hits if other != path)}); keep one and import it"
        for path in hits
    ]


def copies(root: Path) -> list[str]:
    """Every problem, one line each; empty when each fact has its one source."""
    tracked = _tracked(root)
    if isinstance(tracked, str):
        return [tracked]
    return sorted(
        catalog_copies(root, tracked) + ir_hash_copies(root, tracked) + package_list_copies(root)
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="the repository root (a git checkout)",
    )
    arguments = parser.parse_args(argv)
    problems = copies(arguments.root)
    for problem in problems:
        print(f"check-sdk-single-source: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
