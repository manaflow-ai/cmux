#!/usr/bin/env python3
"""Portable workspace handoff utility.

The invariant is that a snapshot captures the exact staged/unstaged/untracked
split of a Git workspace without mutating the source repository, and restore
reconstructs that split (plus explicitly selected agent-session files).

Tests may set CMUX_HANDOFF_SKIP_CLI_VERSION=1 to avoid probing agent binaries.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from typing import Any, Iterable


TOOL_VERSION = "cmux-workspace-handoff 1.0"
BUNDLE_SCHEMA_VERSION = 1
FIXED_IDENTITY = {
    "GIT_AUTHOR_NAME": "cmux handoff",
    "GIT_AUTHOR_EMAIL": "handoff@cmux.invalid",
    "GIT_COMMITTER_NAME": "cmux handoff",
    "GIT_COMMITTER_EMAIL": "handoff@cmux.invalid",
    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
    "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
}
REWRITE_KEYS = {
    "cwd",
    "current_cwd",
    "current_working_directory",
    "working_directory",
    "project_path",
    "projectPath",
}


class HandoffError(RuntimeError):
    """A user-actionable invariant or input failure."""


def die(message: str) -> None:
    raise HandoffError(message)


def run_git(repo: pathlib.Path, *args: str, env: dict[str, str] | None = None,
            check: bool = True, capture: bool = True) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    result = subprocess.run(
        ["git", *args], cwd=repo, env=merged, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip()
        die(f"git {' '.join(args)} failed: {detail}")
    return result


def run_git_bytes(repo: pathlib.Path, *args: str, env: dict[str, str] | None = None,
                  check: bool = True) -> bytes:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    result = subprocess.run(
        ["git", *args], cwd=repo, env=merged,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and result.returncode:
        die(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def git_env(index: pathlib.Path) -> dict[str, str]:
    return {"GIT_INDEX_FILE": str(index)}


def repo_root(path: pathlib.Path) -> pathlib.Path:
    result = run_git(path, "rev-parse", "--show-toplevel")
    return pathlib.Path(result.stdout.strip()).resolve()


def relpath_checked(root: pathlib.Path, value: str) -> pathlib.Path:
    candidate = pathlib.Path(value)
    if candidate.is_absolute():
        die(f"path must be relative to workspace: {value}")
    resolved = (root / candidate).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        die(f"path escapes workspace: {value}")
    return candidate


def source_epoch() -> str:
    raw = os.environ.get("SOURCE_DATE_EPOCH")
    if raw is not None:
        try:
            return _datetime.datetime.fromtimestamp(int(raw), _datetime.timezone.utc).isoformat()
        except ValueError:
            die("SOURCE_DATE_EPOCH must be an integer")
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat()


def claude_slug(path: pathlib.Path) -> str:
    """Claude Code's project directory encoding observed by the lab.

    Claude replaces every empirically tested non-alphanumeric character with a
    hyphen. The lab confirmed this for path separators, dots, and underscores.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", str(path.resolve()))


def copy_index(real_index: pathlib.Path, target: pathlib.Path) -> None:
    if real_index.exists():
        shutil.copy2(real_index, target)
    else:
        run_git(real_index.parent.parent, "read-tree", "--empty", env=git_env(target))


def write_tree(repo: pathlib.Path, index: pathlib.Path, *command: str) -> str:
    run_git(repo, *command, env=git_env(index))
    return run_git(repo, "write-tree", env=git_env(index)).stdout.strip()


def commit_tree_with_message(repo: pathlib.Path, tree: str, parent: str | None, message: str) -> str:
    env = os.environ.copy()
    env.update(FIXED_IDENTITY)
    args = ["git", "commit-tree", tree]
    if parent:
        args.extend(["-p", parent])
    result = subprocess.run(args, cwd=repo, env=env, input=message + "\n", text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        die(f"git commit-tree failed: {result.stderr.strip()}")
    return result.stdout.strip()


def parse_submodules(repo: pathlib.Path) -> list[dict[str, Any]]:
    entries = run_git(repo, "ls-files", "-s", "-z").stdout.split("\0")
    submodules: list[dict[str, Any]] = []
    for entry in entries:
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        mode, sha, stage = meta.split()
        if mode != "160000":
            continue
        sub_path = pathlib.Path(path)
        current_sha = None
        subdir = repo / sub_path
        if subdir.is_dir():
            probe = run_git(subdir, "rev-parse", "HEAD", check=False)
            if probe.returncode == 0:
                current_sha = probe.stdout.strip()
        dirty = current_sha != sha
        if subdir.is_dir():
            status = run_git(subdir, "status", "--porcelain=v1", check=False)
            dirty = dirty or bool(status.stdout)
        url = run_git(repo, "config", "-f", ".gitmodules", "--get", f"submodule.{path}.url", check=False).stdout.strip()
        item: dict[str, Any] = {"path": path, "url": url, "pinned_sha": sha, "dirty": dirty}
        if dirty:
            item["worktree_sha"] = current_sha
        submodules.append(item)
    return submodules


def copy_ignored(root: pathlib.Path, out: pathlib.Path, values: Iterable[str]) -> list[dict[str, Any]]:
    captured: list[dict[str, Any]] = []
    target_root = out / "ignored-files"
    for value in values:
        rel = relpath_checked(root, value)
        source = root / rel
        if not source.exists() or source.is_dir():
            die(f"--include-ignored requires an existing file: {value}")
        ignored = run_git(root, "check-ignore", "-q", "--", str(rel), check=False)
        if ignored.returncode != 0:
            die(f"path is not ignored by Git: {value}")
        destination = target_root / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        mode = stat.S_IMODE(source.stat().st_mode)
        os.chmod(destination, mode)
        captured.append({"path": str(rel), "mode": mode})
    return captured


def find_claude_session(home: pathlib.Path, workspace: pathlib.Path, session_id: str) -> tuple[pathlib.Path, str]:
    slug = claude_slug(workspace)
    path = home / "projects" / slug / f"{session_id}.jsonl"
    if not path.is_file():
        die(f"Claude session {session_id} not found at {path}")
    return path, str(path.relative_to(home))


def find_codex_session(home: pathlib.Path, session_id: str) -> tuple[pathlib.Path, str]:
    matches = sorted(home.glob(f"sessions/**/rollout-*{session_id}*.jsonl"))
    if not matches:
        die(f"Codex session {session_id} not found under {home / 'sessions'}")
    if len(matches) > 1:
        die(f"Codex session {session_id} is ambiguous ({len(matches)} rollout files)")
    return matches[0], str(matches[0].relative_to(home))


def capture_sessions(args: argparse.Namespace, root: pathlib.Path, out: pathlib.Path) -> list[dict[str, Any]]:
    descriptors: list[dict[str, Any]] = []
    if args.claude_session:
        home = pathlib.Path(args.claude_home).expanduser().resolve()
        source, rel = find_claude_session(home, root, args.claude_session)
        destination = out / "agent-sessions" / "claude" / pathlib.Path(rel).name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        todos = sorted((home / "todos").glob(f"{args.claude_session}*.json"))
        todo_rels: list[str] = []
        for todo in todos:
            todo_dest = out / "agent-sessions" / "claude" / "todos" / todo.name
            todo_dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(todo, todo_dest)
            todo_rels.append(str(todo.relative_to(home)))
        descriptors.append({
            "kind": "claude", "session_id": args.claude_session,
            "original_cwd": str(root), "relpaths": [rel, *todo_rels],
            "bundle_paths": [str(destination.relative_to(out)), *[str((out / "agent-sessions" / "claude" / "todos" / pathlib.Path(x).name).relative_to(out)) for x in todo_rels]],
            "cli_version": None if os.environ.get("CMUX_HANDOFF_SKIP_CLI_VERSION") else cli_version("claude"),
        })
    if args.codex_session:
        home = pathlib.Path(args.codex_home).expanduser().resolve()
        source, rel = find_codex_session(home, args.codex_session)
        destination = out / "agent-sessions" / "codex" / pathlib.Path(rel)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        descriptors.append({
            "kind": "codex", "session_id": args.codex_session,
            "original_cwd": str(root), "relpaths": [rel],
            "bundle_paths": [str(destination.relative_to(out))],
            "cli_version": None if os.environ.get("CMUX_HANDOFF_SKIP_CLI_VERSION") else cli_version("codex"),
        })
    return descriptors


def cli_version(binary: str) -> str | None:
    try:
        result = subprocess.run([binary, "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError:
        return None
    except OSError:
        return None
    if result.returncode:
        return None
    return (result.stdout or result.stderr).strip().splitlines()[0] if (result.stdout or result.stderr) else None


def safe_origin_url(value: str | None) -> str | None:
    """Keep repository provenance without copying embedded credentials."""
    if not value:
        return None
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return None
    if parsed.scheme and (parsed.username or parsed.password or parsed.query):
        return f"{parsed.scheme}://{parsed.hostname or ''}{parsed.path}"
    return value


def snapshot(args: argparse.Namespace) -> dict[str, Any]:
    root = repo_root(pathlib.Path(args.workspace).expanduser().resolve())
    out = pathlib.Path(args.out).expanduser().resolve()
    try:
        out.relative_to(root)
    except ValueError:
        pass
    else:
        die("output bundle must be outside the source workspace to preserve source hygiene")
    if out.exists() and any(out.iterdir()):
        die(f"output bundle must be absent or empty: {out}")
    out.mkdir(parents=True, exist_ok=True)
    real_index = pathlib.Path(run_git(root, "rev-parse", "--git-path", "index").stdout.strip())
    if not real_index.is_absolute():
        real_index = (root / real_index).resolve()
    branch_result = run_git(root, "symbolic-ref", "--short", "-q", "HEAD", check=False)
    branch = branch_result.stdout.strip() if branch_result.returncode == 0 else None
    head = run_git(root, "rev-parse", "HEAD").stdout.strip()
    submodules = parse_submodules(root)
    dirty = [item["path"] for item in submodules if item["dirty"]]
    if dirty and not args.allow_dirty_submodules:
        die("dirty submodule(s): " + ", ".join(dirty) + "; use --allow-dirty-submodules to record lossy state")
    with tempfile.TemporaryDirectory(prefix="cmux-handoff-index-") as tmp:
        tmpdir = pathlib.Path(tmp)
        staged_index = tmpdir / "staged.index"
        worktree_index = tmpdir / "worktree.index"
        untracked_index = tmpdir / "untracked.index"
        copy_index(real_index, staged_index)
        staged_tree = run_git(root, "write-tree", env=git_env(staged_index)).stdout.strip()
        copy_index(real_index, worktree_index)
        run_git(root, "add", "-u", "--", env=git_env(worktree_index))
        worktree_tree = run_git(root, "write-tree", env=git_env(worktree_index)).stdout.strip()
        run_git(root, "read-tree", "--empty", env=git_env(untracked_index))
        raw_untracked = run_git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z")
        untracked = [item.decode() for item in raw_untracked.split(b"\0") if item]
        if untracked:
            run_git(root, "add", "--", *untracked, env=git_env(untracked_index))
        untracked_tree = run_git(root, "write-tree", env=git_env(untracked_index)).stdout.strip()
        staged_commit = commit_tree_with_message(root, staged_tree, head, "cmux handoff staged tree")
        worktree_commit = commit_tree_with_message(root, worktree_tree, staged_commit, "cmux handoff worktree tree")
        untracked_commit = commit_tree_with_message(root, untracked_tree, worktree_commit, "cmux handoff untracked tree")
        ref = f"refs/cmux/handoff-tmp/{uuid.uuid4().hex}"
        run_git(root, "update-ref", ref, untracked_commit)
        try:
            run_git(root, "bundle", "create", str(out / "repo.bundle"), ref)
        finally:
            run_git(root, "update-ref", "-d", ref, check=False)
            ref_probe = run_git(root, "show-ref", "--verify", "--quiet", ref, check=False)
            if ref_probe.returncode == 0:
                die(f"temporary handoff ref was not deleted: {ref}")
            if ref_probe.returncode != 1:
                die(f"could not verify temporary handoff ref deletion: {ref}")
    ignored = copy_ignored(root, out, args.include_ignored or [])
    sessions = capture_sessions(args, root, out)
    origin = safe_origin_url(run_git(root, "config", "--get", "remote.origin.url", check=False).stdout.strip() or None)
    manifest = {
        "bundle_schema_version": BUNDLE_SCHEMA_VERSION,
        "tool_version": TOOL_VERSION,
        "workspace_basename": root.name,
        "original_abspath": str(root),
        "branch": branch,
        "detached": branch is None,
        "head_sha": head,
        "staged_tree": staged_tree,
        "worktree_tree": worktree_tree,
        "untracked_tree": untracked_tree,
        "staged_commit": staged_commit,
        "worktree_commit": worktree_commit,
        "untracked_commit": untracked_commit,
        "ref": ref,
        "origin_url": origin,
        "submodules": submodules,
        "untracked_paths": sorted(untracked),
        "ignored_allowlist": ignored,
        "agent_sessions": sessions,
        "created_at": source_epoch(),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {
        "bundle": str(out), "branch": branch, "head_sha": head,
        "counts": {"untracked": len(untracked), "ignored": len(ignored), "agent_sessions": len(sessions), "submodules": len(submodules)},
        "manifest": manifest,
        "warnings": [f"dirty submodule: {path}; content is not portable" for path in dirty],
    }


def rewrite_json_value(value: Any, old: str, new: str, key: str | None = None) -> Any:
    if isinstance(value, dict):
        return {k: rewrite_json_value(v, old, new, k) for k, v in value.items()}
    if isinstance(value, list):
        return [rewrite_json_value(v, old, new, key) for v in value]
    if isinstance(value, str) and key in REWRITE_KEYS:
        if value == old:
            return new
        if value.startswith(old + os.sep):
            return new + value[len(old):]
    return value


def rewrite_jsonl(path: pathlib.Path, old: str, new: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    rewritten: list[str] = []
    for line in lines:
        ending = "\n" if line.endswith("\n") else ""
        body = line[:-1] if ending else line
        try:
            value = json.loads(body)
        except json.JSONDecodeError:
            rewritten.append(line.replace(old, new))
            continue
        rewritten.append(json.dumps(rewrite_json_value(value, old, new), separators=(",", ":")) + ending)
    path.write_text("".join(rewritten), encoding="utf-8")


def ensure_no_overwrite(path: pathlib.Path) -> None:
    if path.exists():
        die(f"refusing to overwrite existing agent session file: {path}")


def restore_sessions(manifest: dict[str, Any], bundle: pathlib.Path, dest: pathlib.Path, args: argparse.Namespace) -> list[str]:
    placements: list[str] = []
    for descriptor in manifest.get("agent_sessions", []):
        kind = descriptor["kind"]
        home_arg = args.claude_home if kind == "claude" else args.codex_home
        home = pathlib.Path(home_arg).expanduser().resolve()
        bundle_paths = descriptor.get("bundle_paths", [])
        if kind == "claude":
            old_cwd = descriptor["original_cwd"]
            target_slug = claude_slug(dest)
            primary = bundle / bundle_paths[0]
            target = home / "projects" / target_slug / f"{descriptor['session_id']}.jsonl"
            todo_targets = [home / "todos" / (bundle / rel_bundle).name for rel_bundle in bundle_paths[1:]]
            ensure_no_overwrite(target)
            for todo_target in todo_targets:
                ensure_no_overwrite(todo_target)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(primary, target)
            if args.claude_cwd_mode == "rewrite":
                rewrite_jsonl(target, old_cwd, str(dest))
            placements.append(str(target))
            for rel_bundle, todo_target in zip(bundle_paths[1:], todo_targets):
                source = bundle / rel_bundle
                todo_target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, todo_target)
                placements.append(str(todo_target))
        elif kind == "codex":
            for rel_bundle, rel_original in zip(bundle_paths, descriptor.get("relpaths", [])):
                target = home / rel_original
                ensure_no_overwrite(target)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(bundle / rel_bundle, target)
                placements.append(str(target))
        else:
            die(f"unsupported agent session kind: {kind}")
    return placements


def restore(args: argparse.Namespace) -> dict[str, Any]:
    bundle = pathlib.Path(args.bundle).expanduser().resolve()
    manifest_path = bundle / "manifest.json"
    if not manifest_path.is_file() or not (bundle / "repo.bundle").is_file():
        die(f"invalid bundle (manifest.json and repo.bundle required): {bundle}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("bundle_schema_version") != BUNDLE_SCHEMA_VERSION:
        die(f"unsupported bundle_schema_version: {manifest.get('bundle_schema_version')}")
    dest = pathlib.Path(args.dest).expanduser().resolve()
    if dest.exists() and any(dest.iterdir()):
        die(f"destination must not exist or must be empty: {dest}")
    dest.mkdir(parents=True, exist_ok=True)
    run_git(dest, "init", "-q")
    run_git(dest, "fetch", str(bundle / "repo.bundle"), manifest["ref"] + ":refs/cmux/handoff/restored")
    branch = manifest.get("branch")
    if branch:
        run_git(dest, "checkout", "-q", "-b", branch, manifest["head_sha"])
    else:
        run_git(dest, "checkout", "-q", "--detach", manifest["head_sha"])
    with tempfile.TemporaryDirectory(prefix="cmux-handoff-restore-index-") as tmp:
        tmpdir = pathlib.Path(tmp)
        work_index = tmpdir / "worktree.index"
        run_git(dest, "read-tree", manifest["worktree_tree"], env=git_env(work_index))
        run_git(dest, "checkout-index", "-a", "-f", env=git_env(work_index))
        deletions = run_git(dest, "diff-tree", "-r", "--name-only", "--diff-filter=D", manifest["head_sha"], manifest["worktree_tree"]).stdout.splitlines()
        for path in deletions:
            target = dest / path
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
        run_git(dest, "read-tree", manifest["staged_tree"])
        untracked_index = tmpdir / "untracked.index"
        run_git(dest, "read-tree", manifest["untracked_tree"], env=git_env(untracked_index))
        run_git(dest, "checkout-index", "-a", "-f", env=git_env(untracked_index))
        run_git(dest, "update-index", "--refresh", check=False)
    if manifest.get("submodules"):
        run_git(dest, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive")
        for item in manifest["submodules"]:
            actual = run_git(dest / item["path"], "rev-parse", "HEAD").stdout.strip()
            if actual != item["pinned_sha"]:
                die(f"submodule {item['path']} restored at {actual}, expected {item['pinned_sha']}")
    for item in manifest.get("ignored_allowlist", []):
        source = bundle / "ignored-files" / item["path"]
        target = dest / item["path"]
        if not source.is_file():
            die(f"ignored-file payload missing: {item['path']}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        os.chmod(target, int(item["mode"]))
    placements: list[str] = []
    if not args.skip_agent_sessions:
        placements = restore_sessions(manifest, bundle, dest, args)
    result = {
        "bundle": str(bundle), "destination": str(dest), "branch": branch,
        "detached": branch is None, "head_sha": manifest["head_sha"],
        "counts": {"untracked": len(manifest.get("untracked_paths", [])), "ignored": len(manifest.get("ignored_allowlist", [])), "agent_sessions": len(manifest.get("agent_sessions", []))},
        "agent_placements": placements,
        "resume_commands": [f"cd {dest} && claude --resume {x['session_id']}" if x["kind"] == "claude" else f"cd {dest} && codex exec resume {x['session_id']}" for x in manifest.get("agent_sessions", [])],
    }
    return result


def untracked_hashes(repo: pathlib.Path) -> dict[str, str]:
    paths = run_git_bytes(repo, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    result: dict[str, str] = {}
    for raw in paths:
        if raw:
            path = raw.decode()
            candidate = repo / path
            if candidate.is_symlink():
                result[path] = "symlink:" + os.readlink(candidate)
            else:
                result[path] = run_git(repo, "hash-object", "--", path).stdout.strip()
    return result


def submodule_shas(repo: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in parse_submodules(repo):
        result[item["path"]] = item["pinned_sha"]
    return result


def verify(args: argparse.Namespace) -> dict[str, Any]:
    source = repo_root(pathlib.Path(args.source).expanduser().resolve())
    restored = repo_root(pathlib.Path(args.restored).expanduser().resolve())
    mismatches: dict[str, Any] = {}
    source_branch = run_git(source, "symbolic-ref", "--short", "-q", "HEAD", check=False).stdout.strip() or None
    restored_branch = run_git(restored, "symbolic-ref", "--short", "-q", "HEAD", check=False).stdout.strip() or None
    if source_branch != restored_branch:
        mismatches["branch"] = {"source": source_branch, "restored": restored_branch}
    for label, args2 in (("head", ("rev-parse", "HEAD")),):
        left = run_git(source, *args2).stdout.strip(); right = run_git(restored, *args2).stdout.strip()
        if left != right: mismatches[label] = {"source": left, "restored": right}
    for label, args2 in (("staged_raw", ("diff", "--cached", "--raw", "-z")), ("worktree_raw", ("diff", "--raw", "-z"))):
        left = run_git_bytes(source, *args2); right = run_git_bytes(restored, *args2)
        if left != right: mismatches[label] = {"source_sha256": hashlib.sha256(left).hexdigest(), "restored_sha256": hashlib.sha256(right).hexdigest()}
    left_untracked = untracked_hashes(source); right_untracked = untracked_hashes(restored)
    if left_untracked != right_untracked: mismatches["untracked"] = {"source": left_untracked, "restored": right_untracked}
    left_sub = submodule_shas(source); right_sub = submodule_shas(restored)
    if left_sub != right_sub: mismatches["submodules"] = {"source": left_sub, "restored": right_sub}
    return {"ok": not mismatches, "source": str(source), "restored": str(restored), "mismatches": mismatches}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--workspace", required=True); snap.add_argument("--out", required=True)
    snap.add_argument("--claude-session"); snap.add_argument("--codex-session")
    snap.add_argument("--claude-home", default="~/.claude"); snap.add_argument("--codex-home", default="~/.codex")
    snap.add_argument("--include-ignored", action="append", default=[]); snap.add_argument("--allow-dirty-submodules", action="store_true"); snap.add_argument("--json", action="store_true")
    restore_p = sub.add_parser("restore")
    restore_p.add_argument("--bundle", required=True); restore_p.add_argument("--dest", required=True)
    restore_p.add_argument("--claude-home", default="~/.claude"); restore_p.add_argument("--codex-home", default="~/.codex")
    restore_p.add_argument("--claude-cwd-mode", choices=("verbatim", "rewrite"), default="verbatim"); restore_p.add_argument("--skip-agent-sessions", action="store_true"); restore_p.add_argument("--json", action="store_true")
    ver = sub.add_parser("verify")
    ver.add_argument("--source", required=True); ver.add_argument("--restored", required=True); ver.add_argument("--json", action="store_true")
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        result = snapshot(args) if args.command == "snapshot" else restore(args) if args.command == "restore" else verify(args)
        if args.command == "verify" and not result["ok"]:
            if args.json: print(json.dumps(result, indent=2, sort_keys=True))
            else: print("VERIFY FAIL", json.dumps(result["mismatches"], indent=2, sort_keys=True), file=sys.stderr)
            return 1
        if args.json: print(json.dumps(result, indent=2, sort_keys=True))
        else:
            if args.command == "snapshot":
                print(f"snapshot: {result['bundle']} ({result['head_sha']})")
            elif args.command == "restore":
                print(f"restore: {result['destination']} ({result['head_sha']})")
                for command in result["resume_commands"]: print(f"resume: {command}")
            else: print("VERIFY PASS")
        if args.command == "snapshot":
            for warning in result.get("warnings", []):
                print(f"warning: {warning}", file=sys.stderr)
        return 0
    except HandoffError as exc:
        if getattr(args, "json", False): print(json.dumps({"ok": False, "error": str(exc)}))
        else: print(f"error: {exc}", file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as exc:
        if getattr(args, "json", False): print(json.dumps({"ok": False, "error": str(exc)}))
        else: print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
