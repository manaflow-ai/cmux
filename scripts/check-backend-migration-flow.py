#!/usr/bin/env python3
"""Local gate: cmux-next backend migrations only travel through a PR.

Agents push straight to feat-cmux-next, but a migration for PlanetScale
`cmux-next` must be applied to staging and production before it lands, which
only the PR label flow does (skills/cmux-backend-migrations). This check fails
when the commits about to leave this checkout add or change files under
backend/db/migrations and the current branch has no open PR into
feat-cmux-next or main. It also refuses edits to existing migration files.

CI skips it (the trusted PR gate and the push guard cover CI).
Override for an intended PR branch whose PR is not open yet:
CMUX_BACKEND_MIGRATION_PR=1.
"""
import json
import os
import re
import subprocess
import sys

MIGRATIONS = "backend/db/migrations/"
TARGETS = ("feat-cmux-next", "main")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def in_ci():
    return any(os.environ.get(k, "").lower() not in ("", "0", "false", "no") for k in ("CI", "GITHUB_ACTIONS"))


def upstream_base():
    """The newest remote target this branch builds on: what is already shared."""
    for remote in ("origin", "upstream"):
        for target in TARGETS:
            ref = f"refs/remotes/{remote}/{target}"
            if git("rev-parse", "-q", "--verify", ref).returncode == 0:
                base = git("merge-base", ref, "HEAD")
                if base.returncode == 0:
                    yield ref, base.stdout.strip()


def changed_migrations(base):
    """Paths under backend/db/migrations changed since base (committed, staged, unstaged or
    untracked). "M" when the path already exists in base (an edit to a shared migration)."""
    paths = set()
    for args in (("diff", "--name-only", "--no-renames", base, "HEAD", "--", MIGRATIONS),
                 ("diff", "--name-only", "--no-renames", "HEAD", "--", MIGRATIONS),
                 ("diff", "--name-only", "--no-renames", "--cached", "--", MIGRATIONS),
                 ("ls-files", "--others", "--exclude-standard", "--", MIGRATIONS)):
        paths.update(p for p in git(*args).stdout.splitlines() if p)
    return {p: ("M" if git("cat-file", "-e", f"{base}:{p}").returncode == 0 else "A") for p in paths}


def open_pr_base():
    """Base branch of the open PR for the current branch, or None."""
    branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not branch or branch == "HEAD" or branch in TARGETS:
        return None
    try:
        out = subprocess.run(["gh", "pr", "view", branch, "--json", "state,baseRefName"],
                             capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    data = json.loads(out.stdout or "{}")
    return data.get("baseRefName") if data.get("state") == "OPEN" else None


def main():
    if in_ci():
        print("backend migration flow: skipped in CI (the trusted PR gate and the push guard run there)")
        return 0
    bases = list(upstream_base())
    if not bases:
        print("backend migration flow: no feat-cmux-next or main remote ref; skipped")
        return 0
    # Compare against the closest shared base (the one with the fewest commits ahead).
    ref, base = min(bases, key=lambda b: int(git("rev-list", "--count", f"{b[1]}..HEAD").stdout.strip() or 0))
    changes = changed_migrations(base)
    if not changes:
        print("backend migration flow: no migration changes")
        return 0
    errors = []
    for path, status in sorted(changes.items()):
        if status != "A":
            errors.append(f"{path}: existing migrations are append-only; add a new numbered file instead")
        elif not re.fullmatch(r"backend/db/migrations/\d{4}_[a-z0-9_]+\.sql", path):
            errors.append(f"{path}: name must be NNNN_lower_snake.sql")
    branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not errors and os.environ.get("CMUX_BACKEND_MIGRATION_PR") != "1":
        pr_base = open_pr_base()
        if pr_base not in TARGETS:
            where = "on this branch" if branch not in TARGETS else f"directly on {branch}"
            errors.append(
                f"new migration(s) {', '.join(sorted(changes))} {where} without an open PR into feat-cmux-next or main. "
                "Migrations reach staging and production only through a PR with the label backend:apply-migrations "
                "(skills/cmux-backend-migrations). Move them to a branch, open the PR, then push. "
                "If the PR is about to be opened from this branch, set CMUX_BACKEND_MIGRATION_PR=1.")
    if errors:
        for e in errors:
            print(f"backend migration flow: {e}", file=sys.stderr)
        return 1
    print(f"backend migration flow: {len(changes)} new migration(s) on a PR branch (base {ref})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
