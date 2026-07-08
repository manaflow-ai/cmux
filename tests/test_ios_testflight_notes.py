#!/usr/bin/env python3
"""Tests for ios/scripts/generate-testflight-notes.sh.

The generator turns the iOS-affecting commits in <base>..HEAD into the per-build
TestFlight "What to Test" notes (internal keeps PR numbers; external is a cleaned
draft). These tests build a throwaway git repo so the assertions are deterministic
and do not depend on the real history.
"""

import os
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "ios", "scripts", "generate-testflight-notes.sh")

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def _git(repo, *args, **kw):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True, **kw)


def _commit(repo, path, subject):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "a", encoding="utf-8") as f:
        f.write(subject + "\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", subject)


def _gen(repo, base, audience="internal"):
    env = dict(os.environ)
    out = subprocess.run(["bash", SCRIPT, base, "--audience", audience],
                         cwd=repo, capture_output=True, text=True, env=env)
    # The generator must always exit 0 (notes are non-fatal; a failure here would
    # abort the upload). Assert it, since callers only read stdout.
    _check(out.returncode == 0,
           f"generator exits 0 (base={base or 'EMPTY'}, {audience})")
    return out.stdout


def main():
    _check(os.access(SCRIPT, os.X_OK), "generator script is executable")

    with tempfile.TemporaryDirectory() as repo:
        _git(repo, "init", "-q", "-b", "main")
        _git(repo, "config", "user.email", "t@t.test")
        _git(repo, "config", "user.name", "Test")

        _commit(repo, "README.md", "root")
        base = _git(repo, "rev-parse", "HEAD").stdout.strip()

        # iOS-affecting commits (should appear), one per filtered path family.
        _commit(repo, "ios/cmux/App.swift", "ios: fix the thing (#101)")
        _commit(repo, "Packages/iOS/Foo/Bar.swift", "Mobile: add a feature (#102)")
        _commit(repo, "Packages/Shared/Baz/Qux.swift", "Shared: shared change (#103)")
        # Non-iOS commit (should NOT appear).
        _commit(repo, "web/app/page.tsx", "web: unrelated web change (#104)")
        # Noise commits (should NOT appear).
        _commit(repo, "ios/cmux/Chore.swift", "chore: bump deps (#105)")
        _commit(repo, "ios/cmux/Ci.swift", "ci: tweak workflow (#106)")

        # Subjects containing the literal '|' must not corrupt de-duplication
        # (regression: a '|'-delimited seen-set dropped distinct later subjects).
        _commit(repo, "ios/cmux/Pipe.swift", "ios: support A|B mode (#107)")
        _commit(repo, "ios/cmux/Pipe2.swift", "ios: support A (#108)")

        internal = _gen(repo, base, "internal")
        _check("fix the thing (#101)" in internal, "internal includes iOS PR title + number")
        _check("add a feature (#102)" in internal, "internal includes Packages/iOS commit")
        _check("shared change (#103)" in internal, "internal includes Packages/Shared commit")
        _check("unrelated web change" not in internal, "internal excludes non-iOS commit")
        _check("bump deps" not in internal and "tweak workflow" not in internal,
               "internal excludes chore/ci noise")
        _check("support A|B mode (#107)" in internal, "pipe-subject preserved")
        _check("support A (#108)" in internal,
               "distinct subject not dropped by a pipe-bearing earlier subject")

        external = _gen(repo, base, "external")
        _check("#101" not in external and "#102" not in external,
               "external strips PR numbers")
        _check("ios:" not in external, "external strips the conventional prefix")
        _check("fix the thing" in external.lower(), "external still carries the change text")

        # Empty range and a bogus base both fall back deterministically (exit 0).
        head = _git(repo, "rev-parse", "HEAD").stdout.strip()
        empty = _gen(repo, head, "internal")
        _check("no notable iOS changes" in empty, "empty range -> fallback line")
        bogus = _gen(repo, "deadbeefdeadbeef", "internal")
        _check("no notable iOS changes" in bogus, "unreachable base -> fallback line")

        # A base that is a real commit but NOT an ancestor of HEAD (e.g. a SHA from
        # an unrelated branch) must fail closed to the fallback, not emit notes for
        # a bogus range.
        _git(repo, "checkout", "-q", "-b", "side", base)
        _commit(repo, "ios/cmux/Side.swift", "ios: side-branch only change (#900)")
        side = _git(repo, "rev-parse", "HEAD").stdout.strip()
        _git(repo, "checkout", "-q", "main")
        non_ancestor = _gen(repo, side, "internal")
        _check("no notable iOS changes" in non_ancestor,
               "non-ancestor base -> fallback line")
        _check("side-branch only change" not in non_ancestor,
               "non-ancestor base does not leak unrelated commits")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios testflight notes generator tests passed")


if __name__ == "__main__":
    main()
