#!/usr/bin/env python3
"""Every non-cone sparse checkout lists .gitmodules, so actions/checkout never fetches it lazily.

A sparse-checkout list gets a blobless (filter=blob:none) clone. In non-cone mode the root's
files are not part of it, so .gitmodules (blob a8e13d8d) stays unfetched. actions/checkout's
"Removing auth" then runs `git submodule foreach --recursive`, which reads .gitmodules and makes
git fetch that one blob from github.com with the credentials already gone. On 2026-11-25 that
fetch stalled ("Operation too slow. Less than 1 bytes/sec ... could not fetch a8e13d8d... from
promisor remote") and failed a checkout that had already succeeded, twice in 20 minutes:

- nightly.yml publish-release-notes, job 139440509186 (run 45679817194): build 4567042650501's
  signed notes never reached the feed;
- cmux-next-media.yml "Pick the tour runner", job 139452750869 (run 45680711758): the nightly
  media tour recorded no What's New clip.

Listing .gitmodules fetches it with the checkout's other blobs, while the token is still set, so
the foreach reads a local file. Cone mode, and a list with "/*", always include the root's files
and need no entry.
"""

import glob
import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = sorted(
    glob.glob(os.path.join(ROOT, ".github", "workflows", "*.y*ml"))
    + glob.glob(os.path.join(ROOT, ".github", "actions", "**", "*.y*ml"), recursive=True)
)
# A pull request that changes the language-boundaries workflow fails unless Leo labels it
# (.github/language-boundaries.toml, SELF_PATHS in scripts/ci/language_boundaries.py), so its
# list gains the entry in a PR of its own; until then it is the one checkout allowed without it.
LEO_LABELED_ONLY = {os.path.join(".github", "workflows", "language-boundaries.yml")}


def _checkouts(node):
    if isinstance(node, dict):
        uses = node.get("uses")
        if isinstance(uses, str) and uses.startswith("actions/checkout@"):
            yield node
        for v in node.values():
            yield from _checkouts(v)
    elif isinstance(node, list):
        for v in node:
            yield from _checkouts(v)


def _non_cone_without_gitmodules(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    bad = []
    for step in _checkouts(doc):
        w = step.get("with") or {}
        sparse = w.get("sparse-checkout")
        if not isinstance(sparse, str) or not sparse.strip():
            continue
        if str(w.get("sparse-checkout-cone-mode", True)).lower() != "false":
            continue
        patterns = {line.strip() for line in sparse.splitlines()}
        # "/*" (or "*") already takes every root file, .gitmodules with them.
        if not patterns & {".gitmodules", "/.gitmodules", "/*", "*"}:
            bad.append(step.get("name") or sparse.split()[0])
    return bad


class SparseCheckoutKeepsGitmodulesTest(unittest.TestCase):
    def test_every_non_cone_sparse_checkout_lists_gitmodules(self):
        self.assertTrue(FILES)
        missing = {}
        for path in FILES:
            bad = _non_cone_without_gitmodules(path)
            if bad and os.path.relpath(path, ROOT) not in LEO_LABELED_ONLY:
                missing[os.path.relpath(path, ROOT)] = bad
        self.assertEqual(missing, {}, "add .gitmodules to these sparse-checkout lists")

    def test_the_check_sees_a_missing_entry(self):
        import tempfile

        wf = {
            "jobs": {
                "a": {
                    "steps": [
                        {
                            "uses": "actions/checkout@x",
                            "with": {"sparse-checkout": "scripts/ci/a.sh\n", "sparse-checkout-cone-mode": False},
                        },
                        {
                            "uses": "actions/checkout@x",
                            "with": {"sparse-checkout": "scripts\n"},
                        },
                        {
                            "uses": "actions/checkout@x",
                            "with": {"sparse-checkout": "/*\n!/*/\n/scripts/\n", "sparse-checkout-cone-mode": False},
                        },
                        {
                            "name": "kept",
                            "uses": "actions/checkout@x",
                            "with": {"sparse-checkout": "/scripts/\n/.gitmodules\n", "sparse-checkout-cone-mode": False},
                        },
                    ]
                }
            }
        }
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as f:
            yaml.safe_dump(wf, f)
        try:
            self.assertEqual(_non_cone_without_gitmodules(f.name), ["scripts/ci/a.sh"])
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
