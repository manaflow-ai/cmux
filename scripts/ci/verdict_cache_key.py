#!/usr/bin/env python3
"""The input key of a base-revision pull request check's verdict, so a run with the same inputs replays it.

Leo, 2026-11-21: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall time and
lower machine time while maintaining a partial semblance of checks." A check whose verdict is a function of its
inputs needs to decide once per input set; every later run with the same key replays the stored verdict (same
check name, same conclusion, same annotations) and skips the work.

For a pull_request_target check that runs the base's code on the pull request's head (language-boundaries.yml):

  key = sha256 of {v, check, head, inputs: {path: git blob id of the base's copy}, python: X.Y.Z}

  head    the pull request's head commit (the event's head.sha). The check reads the change the head makes to the
          base tip (a merge ref's diff); a newer base tip can only drop a path the base already made identical,
          never add one, so the head stands for the change. It is the one input the event names without a fetch,
          which is what makes a hit cheap: the hit skips the merge-ref fetch that is most of the job.
  inputs  the check's own code and data from the base checkout (its script, manifest and workflow), as git blob
          ids computed from the bytes (no git call). A path absent from the checkout keys as null, so adding it
          changes the key.
  python  the interpreter that runs the check (the toolchain).

No key (empty output) when one of --approval-labels is on the pull request: then the verdict also reads the
pull request's events and comments, which the key does not cover, so the check runs in full every time.

    verdict_cache_key.py --check NAME --head SHA --inputs PATH... [--labels-json JSON]
                         [--approval-labels a,b] [--output FILE]

Prints key=<hex or empty>, and appends it to --output (GITHUB_OUTPUT). Never fails the job: any error prints an
empty key, and the check runs. Prior art for the key shape: scripts/ci/receipt_input_key.py (tree-keyed receipts
of push-recorded checks); this one is for checks whose verdict is per pull request, recorded by the pull request's
own base-code run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import sys
from pathlib import Path

KEY_VERSION = 1
SHA = re.compile(r"^[0-9a-f]{40}$")


def blob_id(data: bytes) -> str:
    """git hash-object: the id git gives a file with these bytes."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def input_ids(root: Path, paths: list[str]) -> dict[str, str | None]:
    out: dict[str, str | None] = {}
    for rel in paths:
        path = root / rel
        out[rel] = blob_id(path.read_bytes()) if path.is_file() else None
    return out


def verdict_key(check: str, head: str, inputs: dict[str, str | None], python: str) -> str:
    if not SHA.match(head):
        raise ValueError(f"head must be a 40-hex commit id, not {head!r}")
    material = {"v": KEY_VERSION, "check": check, "head": head, "inputs": inputs, "python": python}
    return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def main(argv: list[str] | None = None, root: Path = Path.cwd()) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--inputs", nargs="+", required=True)
    parser.add_argument("--labels-json", default="[]")
    parser.add_argument("--approval-labels", default="")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    key, why = "", ""
    try:
        labels = {str(name) for name in json.loads(args.labels_json or "[]")}
        approvals = sorted(labels & {name for name in args.approval_labels.split(",") if name})
        if approvals:
            why = f"approval label on the pull request ({', '.join(approvals)}): not keyed, the check runs"
        else:
            key = verdict_key(args.check, args.head, input_ids(root, args.inputs), platform.python_version())
    except Exception as err:  # noqa: BLE001 - any failure means no key, and the check runs
        why = f"no key: {type(err).__name__}: {err}"
    if why:
        print(why, file=sys.stderr)
    print(f"key={key}")
    if args.output:
        with args.output.open("a", encoding="utf-8") as handle:
            handle.write(f"key={key}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
