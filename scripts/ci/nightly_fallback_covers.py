#!/usr/bin/env python3
"""Does an older cmux-tui client serve every daemon capability the app at the build commit needs?

nightly.yml's resolve step (scripts/ci/nightly-steps/resolve-tree-pending.sh) picks a fallback
client: the newest published cmux-tui tree, used when the build commit's own tree is still
publishing after the compile. A daemon capability added since that tree (a PR that adds it to the
daemon and to plans/cmux-next/daemon-capabilities.json together) is missing from the fallback, and
"Bundle the cmux-tui client" fails at check-daemon-capabilities.sh --static-only after the whole
build: run 44975559258 (2026-11-22) bundled client 602f51e1, 24 commits behind, and failed 20 min in
on `language-packs-v1` (#45928).

This answers at resolve time from git alone, with no binary: the capability strings the daemon
source defines (check-app-capability-references.py's rust_capabilities: cmux-tui-core and the crates
it depends on) at the build commit and at the client's source commit. A capability the app lists
(required or optional) that the build commit's daemon defines and the client's does not is one the
client cannot serve. Comparing two reads of the same parser keeps it exact: a capability the parser
cannot see is missed on both sides, so it never refuses a client on its own.

Usage: nightly_fallback_covers.py --app-commit SHA --client-commit SHA [--repo DIR]
Prints `missing=<comma list>` (empty when it covers). Exit 0: covers; 1: it lacks one or more;
2: could not tell (a commit's objects are not here, or a source read failed).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CAPABILITIES = "plans/cmux-next/daemon-capabilities.json"


def checker():
    spec = importlib.util.spec_from_file_location(
        "check_app_capability_references", HERE.parent / "cmux-next" / "check-app-capability-references.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its @dataclass looks its module up
    spec.loader.exec_module(module)
    return module


def git(repo: Path, *args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], input=data, capture_output=True, check=True).stdout


def daemon_capabilities(repo: Path, commit: str, refs) -> set[str]:
    """The capability strings the daemon source of `commit` defines, read from git into a scratch tree."""
    names = git(repo, "ls-tree", "-r", "-z", "--name-only", commit, "--", "cmux-tui/Cargo.toml", "cmux-tui/crates")
    wanted = [n for n in names.decode().split("\0") if n.endswith(".rs") or n.endswith("Cargo.toml")]
    if not wanted:
        raise RuntimeError(f"{commit} has no cmux-tui sources")
    blobs = git(repo, "cat-file", "--batch", data="".join(f"{commit}:{n}\n" for n in wanted).encode())
    with tempfile.TemporaryDirectory(prefix="fallback-caps.") as scratch:
        root, at = Path(scratch), 0
        for name in wanted:
            header_end = blobs.index(b"\n", at)
            header = blobs[at:header_end].split()
            if len(header) < 3 or header[1] != b"blob":
                raise RuntimeError(f"{commit}:{name} is not a blob")
            size = int(header[2])
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(blobs[header_end + 1:header_end + 1 + size])
            at = header_end + 1 + size + 1
        return set(refs.rust_capabilities(root))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app-commit", required=True)
    parser.add_argument("--client-commit", required=True)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        refs = checker()
        app = json.loads(git(args.repo, "show", f"{args.app_commit}:{CAPABILITIES}"))
        needed = set(app.get("required", [])) | set(app.get("optional", []))
        at_app = daemon_capabilities(args.repo, args.app_commit, refs)
        at_client = daemon_capabilities(args.repo, args.client_commit, refs)
    # Any read failure (rust_capabilities exits when it finds none) is "could not tell", never "lacks".
    except (Exception, SystemExit) as error:
        detail = error.stderr.decode(errors="replace").strip() if isinstance(error, subprocess.CalledProcessError) else error
        print(f"nightly_fallback_covers: could not read the sources: {detail}", file=sys.stderr)
        print("missing=")
        return 2
    missing = sorted((needed & at_app) - at_client)
    print("missing=" + ",".join(missing))
    if missing:
        print(f"nightly_fallback_covers: the client at {args.client_commit[:12]} does not define "
              f"{', '.join(missing)}, which the app at {args.app_commit[:12]} needs", file=sys.stderr)
        return 1
    print(f"nightly_fallback_covers: the client at {args.client_commit[:12]} defines every one of the "
          f"{len(needed & at_app)} listed capabilities the app's daemon source defines", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
