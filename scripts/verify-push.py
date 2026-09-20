#!/usr/bin/env python3
"""Run the shared static recipe on the commit tips supplied by Git pre-push."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def clean_git_environment():
    # Git hooks can inherit index/worktree/object overrides. Never let those
    # redirect commands in the disposable snapshot back into the live checkout.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               PYTHONDONTWRITEBYTECODE="1")
    return env


def git(root, env, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], env=env, text=True, stderr=subprocess.PIPE
    ).strip()


def push_commits(root, env, lines):
    commits = {}
    for line in lines:
        fields = line.split()
        if len(fields) != 4:
            raise ValueError("malformed pre-push input; expected four fields per ref")
        local_ref, oid, _remote_ref, _remote_oid = fields
        if oid and set(oid) == {"0"}:
            continue  # Deleting a ref publishes no source.
        if len(oid) not in (40, 64) or any(c not in "0123456789abcdef" for c in oid):
            raise ValueError(f"invalid object ID for {local_ref}")
        try:
            commit = git(root, env, "rev-parse", "--verify", f"{oid}^{{commit}}")
        except subprocess.CalledProcessError as error:
            raise ValueError(f"{local_ref} does not point to a supported commit") from error
        commits.setdefault(commit, []).append(local_ref)
    return commits


def check_commit(root, env, objects, commit, refs, temporary_root):
    print(f"pre-push: checking {commit[:12]} ({', '.join(refs)})", flush=True)
    with tempfile.TemporaryDirectory(prefix="commit-", dir=temporary_root) as directory:
        snapshot = Path(directory)
        git(snapshot, env, "init", "--quiet", "--template=")
        # Share immutable objects, not the caller's index, refs, hooks or files.
        # No fetch, submodules, worktree registration or checkout switch occurs.
        alternate = snapshot / ".git/objects/info/alternates"
        alternate.write_text(json.dumps(str(objects), ensure_ascii=False) + "\n")
        git(snapshot, env, "config", "core.hooksPath", os.devnull)
        git(snapshot, env, "config", "core.autocrlf", "false")
        git(snapshot, env, "update-ref", "--no-deref", "HEAD", commit)
        git(snapshot, env, "read-tree", commit)
        git(snapshot, env, "checkout-index", "--all", "--force")
        runner = snapshot / "scripts/verify-local.py"
        if not runner.is_file() or not runner.resolve().is_relative_to(snapshot):
            raise ValueError(
                f"{commit[:12]} has no supported scripts/verify-local.py; "
                "update that branch to include the shared check recipe"
            )
        result = subprocess.run(
            [sys.executable, str(runner), "--repo", str(snapshot)], cwd=snapshot, env=env
        )
        if result.returncode:
            print(f"pre-push: rejected {commit[:12]}: static checks failed.\n"
                  "Fix that branch and rerun: python3 scripts/verify-local.py", file=sys.stderr)
            return 1
    return 0


def main():
    env = clean_git_environment()
    temporary_root = None
    try:
        root = Path(git(Path.cwd(), env, "rev-parse", "--show-toplevel"))
        commits = push_commits(root, env, sys.stdin)
        if not commits:
            print("pre-push: no commit tips to check (deletions or empty push)")
            return 0
        objects = Path(git(root, env, "rev-parse", "--git-path", "objects"))
        if not objects.is_absolute():
            objects = root / objects
        temporary_root = root / ".local/cmux-pre-push"
        temporary_root.mkdir(parents=True, exist_ok=True)
        for commit, refs in commits.items():
            if check_commit(root, env, objects.resolve(), commit, refs, temporary_root):
                return 1
        print(f"pre-push: {len(commits)} unique commit tip(s) passed static checks")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"pre-push: cannot verify pushed source: {detail}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("pre-push: interrupted; push was not verified", file=sys.stderr)
        return 130
    finally:
        if temporary_root is not None:
            try:
                temporary_root.rmdir()  # Only our now-empty directory, never another run.
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
