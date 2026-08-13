#!/usr/bin/env python3
"""Hermetic behavior tests for scripts/cmux-workspace-handoff.py.

Cases:
  (1) exact staged/unstaged/untracked round trip, including deletions, modes,
      symlinks, nested files, and verify/status equality;
  (2) ignored files excluded by default and copied only with explicit consent;
  (3) non-tip submodule pinning and dirty-submodule refusal/override;
  (4) source status, refs, index, and stash hygiene;
  (5) non-empty destination and existing agent-session overwrite safety;
  (6) branch and detached-HEAD fidelity;
  (7) fake Claude/Codex session capture, placement, and cwd rewrite;
  (8) manifest schema, pins, and untracked-list sanity;
  (9) dangling symlink verification;
  (10) absent agent binary version handling.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "cmux-workspace-handoff.py"


def command(args, cwd=None, env=None, check=True):
    merged = os.environ.copy()
    merged["LC_ALL"] = "C"
    if env:
        merged.update(env)
    result = subprocess.run(args, cwd=cwd, env=merged, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise AssertionError(f"command failed: {args}\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


def git(repo, *args, check=True):
    return command(["git", *args], cwd=repo, check=check)


def write(path: pathlib.Path, value: str | bytes, mode: int | None = None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, bytes):
        path.write_bytes(value)
    else:
        path.write_text(value, encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


def init_repo(path: pathlib.Path, branch="main"):
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", "-b", branch)
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "user.name", "handoff tests")


def commit(repo: pathlib.Path, message="commit"):
    git(repo, "add", "-A")
    env = {"GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
           "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000"}
    command(["git", "commit", "-qm", message], cwd=repo, env=env)


def snapshot(repo, bundle, check=True, **options):
    skip_cli_version = options.pop("skip_cli_version", True)
    path_override = options.pop("path_override", None)
    args = [sys.executable, str(TOOL), "snapshot", "--workspace", str(repo), "--out", str(bundle), "--json"]
    for key, value in options.items():
        flag = "--" + key.replace("_", "-")
        if isinstance(value, bool):
            if value:
                args.append(flag)
        elif isinstance(value, list):
            for item in value:
                args.extend([flag, str(item)])
        elif value is not None:
            args.extend([flag, str(value)])
    env = {"SOURCE_DATE_EPOCH": "946684800"}
    if path_override is not None:
        env["PATH"] = path_override
    if skip_cli_version:
        env["CMUX_HANDOFF_SKIP_CLI_VERSION"] = "1"
    else:
        env["CMUX_HANDOFF_SKIP_CLI_VERSION"] = ""
    return command(args, check=check, env=env)


def restore(bundle, dest, **options):
    args = [sys.executable, str(TOOL), "restore", "--bundle", str(bundle), "--dest", str(dest), "--json"]
    for key, value in options.items():
        flag = "--" + key.replace("_", "-")
        if isinstance(value, bool):
            if value:
                args.append(flag)
        elif value is not None:
            args.extend([flag, str(value)])
    return command(args, check=False)


def verify(repo, restored):
    return command([sys.executable, str(TOOL), "verify", "--source", str(repo), "--restored", str(restored), "--json"], check=False)


def status_semantics(repo):
    lines = git(repo, "status", "--porcelain=v2", "-z").stdout.split("\0")
    return sorted(line for line in lines if line and not line.startswith("#"))


class WorkspaceHandoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.repo = self.root / "src"
        init_repo(self.repo)
        write(self.repo / ".gitignore", "ignored.txt\nignored-dir/\n")
        write(self.repo / "base.txt", "base\n")
        commit(self.repo, "base")

    def tearDown(self):
        self.tmp.cleanup()

    def test_round_trip_fidelity(self):
        write(self.repo / "same.txt", "one\n")
        write(self.repo / "staged-only.txt", "base staged-only\n")
        write(self.repo / "unstaged-only.txt", "base unstaged-only\n")
        write(self.repo / "delete-staged.txt", "gone\n")
        write(self.repo / "delete-unstaged.txt", "gone\n")
        write(self.repo / "exec.txt", "#!/bin/sh\nexit 0\n", 0o755)
        write(self.repo / "link-target", "target\n")
        os.symlink("link-target", self.repo / "link")
        commit(self.repo, "fixture")
        write(self.repo / "same.txt", "staged\n"); git(self.repo, "add", "same.txt")
        write(self.repo / "same.txt", "unstaged\n")
        write(self.repo / "staged-only.txt", "fully staged\n"); git(self.repo, "add", "staged-only.txt")
        write(self.repo / "unstaged-only.txt", "worktree only\n")
        write(self.repo / "staged-new.txt", "new\n"); git(self.repo, "add", "staged-new.txt")
        git(self.repo, "rm", "-q", "--cached", "delete-staged.txt")
        write(self.repo / "delete-staged.txt", "kept as untracked\n")
        (self.repo / "delete-unstaged.txt").unlink()
        write(self.repo / "nested" / "new.txt", "nested\n")
        bundle = self.root / "bundle"; restored = self.root / "restored"
        snapshot(self.repo, bundle)
        result = restore(bundle, restored, skip_agent_sessions=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(verify(self.repo, restored).returncode, 0)
        self.assertEqual(status_semantics(self.repo), status_semantics(restored))
        self.assertEqual(git(self.repo, "diff", "--cached", "--binary").stdout,
                         git(restored, "diff", "--cached", "--binary").stdout)
        self.assertEqual(git(self.repo, "diff", "--binary").stdout,
                         git(restored, "diff", "--binary").stdout)
        staged_paths = set(git(restored, "diff", "--cached", "--name-only").stdout.splitlines())
        worktree_paths = set(git(restored, "diff", "--name-only").stdout.splitlines())
        self.assertIn("staged-only.txt", staged_paths)
        self.assertNotIn("staged-only.txt", worktree_paths)
        self.assertNotIn("unstaged-only.txt", staged_paths)
        self.assertIn("unstaged-only.txt", worktree_paths)
        for path in ("delete-staged.txt", "nested/new.txt", "exec.txt", "link"):
            left = self.repo / path; right = restored / path
            self.assertEqual(left.is_symlink(), right.is_symlink(), path)
            if left.is_symlink(): self.assertEqual(os.readlink(left), os.readlink(right))
            else: self.assertEqual(left.read_bytes(), right.read_bytes(), path)
        self.assertEqual(stat.S_IMODE((self.repo / "exec.txt").stat().st_mode),
                         stat.S_IMODE((restored / "exec.txt").stat().st_mode))

    def test_ignored_file_exclusion_and_consent(self):
        write(self.repo / "ignored.txt", "secret\n", 0o640)
        default_bundle = self.root / "default-bundle"
        snapshot(self.repo, default_bundle)
        self.assertFalse((default_bundle / "ignored-files" / "ignored.txt").exists())
        default_dest = self.root / "default-dest"
        self.assertEqual(restore(default_bundle, default_dest, skip_agent_sessions=True).returncode, 0)
        self.assertFalse((default_dest / "ignored.txt").exists())
        consent_bundle = self.root / "consent-bundle"
        snapshot(self.repo, consent_bundle, include_ignored=["ignored.txt"])
        consent_dest = self.root / "consent-dest"
        self.assertEqual(restore(consent_bundle, consent_dest, skip_agent_sessions=True).returncode, 0)
        self.assertEqual((consent_dest / "ignored.txt").read_bytes(), b"secret\n")
        self.assertEqual(stat.S_IMODE((consent_dest / "ignored.txt").stat().st_mode), 0o640)

    def make_submodule(self):
        work = self.root / "subwork"; init_repo(work)
        write(work / "file", "one\n"); commit(work, "one"); pinned = git(work, "rev-parse", "HEAD").stdout.strip()
        write(work / "file", "two\n"); commit(work, "two")
        remote = self.root / "sub.git"; command(["git", "clone", "-q", "--bare", str(work), str(remote)])
        remote_url = "file://" + str(remote.resolve())
        git(self.repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_url, "vendor/sub")
        git(self.repo / "vendor/sub", "checkout", "-q", pinned)
        git(self.repo, "add", ".gitmodules", "vendor/sub"); commit(self.repo, "submodule")
        return pinned

    def test_submodule_pinning_and_dirty_refusal(self):
        pinned = self.make_submodule()
        bundle = self.root / "bundle"; snapshot(self.repo, bundle)
        restored = self.root / "restored"
        self.assertEqual(restore(bundle, restored, skip_agent_sessions=True).returncode, 0)
        self.assertEqual(git(restored / "vendor/sub", "rev-parse", "HEAD").stdout.strip(), pinned)
        write(self.repo / "vendor/sub" / "dirty", "dirty\n")
        refused = snapshot(self.repo, self.root / "dirty-bundle", check=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("vendor/sub", refused.stdout)
        allowed = snapshot(self.repo, self.root / "allowed-bundle", allow_dirty_submodules=True)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertIn("dirty submodule", allowed.stderr)

    def test_source_repo_hygiene(self):
        write(self.repo / "x", "x\n")
        git(self.repo, "add", "x")
        before_status = git(self.repo, "status", "--porcelain=v2").stdout
        before_refs = git(self.repo, "for-each-ref").stdout
        before_cached = git(self.repo, "diff", "--cached", "--binary").stdout
        stash_before = git(self.repo, "stash", "list").stdout
        snapshot(self.repo, self.root / "bundle")
        self.assertEqual(before_status, git(self.repo, "status", "--porcelain=v2").stdout)
        self.assertEqual(before_refs, git(self.repo, "for-each-ref").stdout)
        self.assertEqual(before_cached, git(self.repo, "diff", "--cached", "--binary").stdout)
        self.assertEqual(stash_before, git(self.repo, "stash", "list").stdout)

    def test_restore_safety_and_no_overwrite(self):
        bundle = self.root / "bundle"; snapshot(self.repo, bundle)
        nonempty = self.root / "nonempty"; nonempty.mkdir(); write(nonempty / "file", "x")
        refused = restore(bundle, nonempty, skip_agent_sessions=True)
        self.assertNotEqual(refused.returncode, 0); self.assertIn("must not exist", refused.stdout)
        home = self.root / "claude"; sid = "session-1"
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(self.repo.resolve()))
        write(home / "projects" / slug / f"{sid}.jsonl", "{}\n")
        session_bundle = self.root / "session-bundle"
        snapshot(self.repo, session_bundle, claude_session=sid, claude_home=home)
        target_home = self.root / "target-home"
        target_slug = re.sub(r"[^A-Za-z0-9]", "-", str((self.root / "dest").resolve()))
        write(target_home / "projects" / target_slug / f"{sid}.jsonl", "existing\n")
        refused = restore(session_bundle, self.root / "dest", claude_home=target_home)
        self.assertNotEqual(refused.returncode, 0); self.assertIn("overwrite", refused.stdout)

    def test_branch_and_detached_head_fidelity(self):
        git(self.repo, "checkout", "-q", "-b", "feature")
        branch = git(self.repo, "branch", "--show-current").stdout.strip(); head = git(self.repo, "rev-parse", "HEAD").stdout.strip()
        bundle = self.root / "branch-bundle"; snapshot(self.repo, bundle)
        restored = self.root / "branch-restored"; self.assertEqual(restore(bundle, restored, skip_agent_sessions=True).returncode, 0)
        self.assertEqual(git(restored, "branch", "--show-current").stdout.strip(), branch)
        self.assertEqual(git(restored, "rev-parse", "HEAD").stdout.strip(), head)
        git(self.repo, "checkout", "-q", "--detach", "HEAD")
        detached_bundle = self.root / "detached-bundle"; snapshot(self.repo, detached_bundle)
        detached = self.root / "detached"; self.assertEqual(restore(detached_bundle, detached, skip_agent_sessions=True).returncode, 0)
        self.assertEqual(git(detached, "symbolic-ref", "-q", "HEAD", check=False).returncode, 1)
        self.assertEqual(git(detached, "rev-parse", "HEAD").stdout.strip(), head)

    def test_agent_session_capture_and_rewrite(self):
        agent_repo = self.root / "src.dot_under"
        init_repo(agent_repo)
        write(agent_repo / "README.md", "agent\n")
        commit(agent_repo, "agent base")
        sid = "claude-test-id"; claude_home = self.root / "claude-home"
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(agent_repo.resolve()))
        lines = [json.dumps({"type": "user", "cwd": str(agent_repo.resolve()), "message": "hello"}) + "\n",
                 json.dumps({"type": "assistant", "working_directory": str(agent_repo.resolve()), "text": "ok"}) + "\n"]
        write(claude_home / "projects" / slug / f"{sid}.jsonl", "".join(lines))
        write(claude_home / "todos" / f"{sid}-todo.json", "{\"cwd\": \"%s\"}\n" % agent_repo)
        codex_home = self.root / "codex-home"; codex_id = "codex-test-id"
        codex_rel = pathlib.Path("sessions/2026/01/01") / f"rollout-2026-01-01T00-00-00-{codex_id}.jsonl"
        write(codex_home / codex_rel, json.dumps({"cwd": str(self.repo), "id": codex_id}) + "\n")
        bundle = self.root / "bundle"
        result = snapshot(agent_repo, bundle, claude_session=sid, claude_home=claude_home, codex_session=codex_id, codex_home=codex_home)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((bundle / "manifest.json").read_text())
        self.assertEqual({x["kind"] for x in manifest["agent_sessions"]}, {"claude", "codex"})
        dest = self.root / "different.path_under"; target_claude = self.root / "target-claude"; target_codex = self.root / "target-codex"
        restored = restore(bundle, dest, claude_home=target_claude, codex_home=target_codex, claude_cwd_mode="rewrite")
        self.assertEqual(restored.returncode, 0, restored.stderr)
        restored_lines = (target_claude / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(dest.resolve())) / f"{sid}.jsonl").read_text().splitlines()
        self.assertEqual(len(restored_lines), len(lines))
        self.assertNotIn(str(agent_repo.resolve()), "\n".join(restored_lines)); self.assertIn(str(dest.resolve()), "\n".join(restored_lines))
        self.assertTrue((target_claude / "todos" / f"{sid}-todo.json").exists())
        self.assertTrue((target_codex / codex_rel).exists())

    def test_dangling_symlink_round_trip_and_verify(self):
        os.symlink("missing-target", self.repo / "dangling-link")
        bundle = self.root / "bundle"; restored = self.root / "restored"
        snapshot(self.repo, bundle)
        self.assertEqual(restore(bundle, restored, skip_agent_sessions=True).returncode, 0)
        self.assertTrue((restored / "dangling-link").is_symlink())
        self.assertEqual(os.readlink(restored / "dangling-link"), "missing-target")
        self.assertEqual(verify(self.repo, restored).returncode, 0)

    def test_missing_agent_binary_version_is_null(self):
        sid = "missing-binary-session"
        claude_home = self.root / "claude-home"
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(self.repo.resolve()))
        write(claude_home / "projects" / slug / f"{sid}.jsonl", "{}\n")
        result = snapshot(
            self.repo,
            self.root / "bundle",
            claude_session=sid,
            claude_home=claude_home,
            skip_cli_version=False,
            path_override="/usr/bin:/bin",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.root / "bundle" / "manifest.json").read_text())
        self.assertIsNone(manifest["agent_sessions"][0]["cli_version"])

    def test_manifest_sanity(self):
        write(self.repo / "untracked", "u\n")
        git(self.repo, "remote", "add", "origin", "https://user:secret@example.com/repo.git?access_token=secret")
        bundle = self.root / "bundle"; snapshot(self.repo, bundle)
        manifest = json.loads((bundle / "manifest.json").read_text())
        self.assertEqual(manifest["bundle_schema_version"], 1)
        self.assertEqual(manifest["untracked_paths"], ["untracked"])
        self.assertIn("submodules", manifest)
        self.assertNotIn("secret", manifest["origin_url"])


if __name__ == "__main__":
    unittest.main()
