#!/usr/bin/env python3
"""Disposable-macOS benchmark for preserving a checkout generation with DerivedData."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def run(argv, *, cwd=None, env=None, capture=False):
    print("+", " ".join(map(str, argv)), flush=True)
    return subprocess.run(
        [str(x) for x in argv],
        cwd=cwd,
        env=env,
        text=True,
        check=True,
        capture_output=capture,
    )


def output(*argv, cwd=None):
    return run(argv, cwd=cwd, capture=True).stdout.strip()


def wipe(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    for child in path.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def fetch_pair(workspace: Path, base: str, target: str) -> None:
    refs = [base] if base == target else [base, target]
    run(["git", "fetch", "--no-tags", "--force", "origin", *refs], cwd=workspace)


def normalize_tracked_mtimes(workspace: Path, metrics: Path | None = None) -> None:
    base_seconds = 978_307_200
    span_seconds = 15 * 365 * 24 * 60 * 60
    records = subprocess.check_output(
        ["git", "ls-files", "--recurse-submodules", "--stage", "-z"],
        cwd=workspace,
    ).split(b"\0")
    normalized = 0
    for record in records:
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_id, stage = metadata.split()
        if mode == b"160000" or stage != b"0":
            continue
        path = workspace / os.fsdecode(raw_path)
        if not os.path.lexists(path):
            continue
        digest = object_id.decode("ascii")
        seconds = base_seconds + int(digest[:12], 16) % span_seconds
        nanoseconds = int(digest[12:20], 16) % 1_000_000_000
        mtime_ns = seconds * 1_000_000_000 + nanoseconds
        os.utime(path, ns=(mtime_ns, mtime_ns), follow_symlinks=False)
        normalized += 1
    payload = {"workspace": str(workspace.resolve()), "normalized_files": normalized}
    if metrics:
        metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_MTIME_NORMALIZATION=" + json.dumps(payload, sort_keys=True), flush=True)


def source_fresh(workspace: Path, base: str, target: str, metrics: Path) -> None:
    started = time.monotonic()
    fetch_pair(workspace, base, target)
    run(["git", "reset", "--hard", target], cwd=workspace)
    run(["git", "clean", "-ffd"], cwd=workspace)
    run(["git", "submodule", "update", "--init", "--recursive"], cwd=workspace)
    record_source_metrics(
        workspace,
        base,
        target,
        "fresh-checkout",
        metrics,
        source_transition_seconds=time.monotonic() - started,
    )


def init_restored_repo(workspace: Path, repo_url: str, base: str, target: str) -> None:
    gitdir = workspace / ".git"
    if gitdir.exists() or gitdir.is_symlink():
        if gitdir.is_dir() and not gitdir.is_symlink():
            shutil.rmtree(gitdir)
        else:
            gitdir.unlink()
    run(["git", "init"], cwd=workspace)
    run(["git", "remote", "add", "origin", repo_url], cwd=workspace)
    run(["git", "fetch", "--no-tags", "--depth=8", "origin", base, target], cwd=workspace)
    # Bind HEAD/index to the archived source without rewriting working files.
    run(["git", "reset", "--mixed", base], cwd=workspace)
    run(["git", "submodule", "update", "--init", "--recursive"], cwd=workspace)
    status = output("git", "status", "--porcelain", "--untracked-files=all", cwd=workspace)
    if status:
        raise SystemExit("restored worktree differs from recorded seed before transition:\n" + status)


def source_restored(
    workspace: Path,
    archive: Path,
    repo_url: str,
    base: str,
    target: str,
    metrics: Path,
    synthetic_merge: bool,
) -> None:
    wipe(workspace)
    started = time.monotonic()
    run(["tar", "-xzf", archive, "-C", workspace])
    extract_seconds = time.monotonic() - started
    rebind_started = time.monotonic()
    init_restored_repo(workspace, repo_url, base, target)
    rebind_seconds = time.monotonic() - rebind_started

    sample = workspace / "Sources/AppDelegate.swift"
    edited = workspace / "Sources/Mobile/MobileTerminalByteTee.swift"
    before_sample = sample.stat().st_mtime_ns
    before_edited = edited.stat().st_mtime_ns

    transition_started = time.monotonic()
    if synthetic_merge:
        env = os.environ.copy()
        env.update({
            "GIT_AUTHOR_NAME": "cmux incremental canary",
            "GIT_AUTHOR_EMAIL": "canary@cmux.invalid",
            "GIT_COMMITTER_NAME": "cmux incremental canary",
            "GIT_COMMITTER_EMAIL": "canary@cmux.invalid",
            "GIT_AUTHOR_DATE": "2026-09-21T12:00:00Z",
            "GIT_COMMITTER_DATE": "2026-09-21T12:00:00Z",
        })
        run(["git", "checkout", "-B", "canary-merge-base", base], cwd=workspace)
        run(["git", "merge", "--no-ff", target, "-m", "synthetic PR merge for incremental canary"], cwd=workspace, env=env)
        resolved_target = output("git", "rev-parse", "HEAD", cwd=workspace)
        mode = "restored-generation-synthetic-merge"
    else:
        run(["git", "checkout", "--detach", target], cwd=workspace)
        resolved_target = target
        mode = "restored-generation"

    run(["git", "submodule", "update", "--init", "--recursive"], cwd=workspace)
    candidate_transition_seconds = time.monotonic() - transition_started
    status = output("git", "status", "--porcelain", "--untracked-files=all", cwd=workspace)
    if status:
        raise SystemExit("candidate worktree dirty after transition:\n" + status)

    payload = {
        "mode": mode,
        "base": base,
        "target": resolved_target,
        "workspace": str(workspace.resolve()),
        "worktree_extract_seconds": round(extract_seconds, 6),
        "git_rebind_seconds": round(rebind_seconds, 6),
        "candidate_transition_seconds": round(candidate_transition_seconds, 6),
        "source_transition_seconds": round(extract_seconds + rebind_seconds + candidate_transition_seconds, 6),
        "sample_unchanged_mtime_ns_before": before_sample,
        "sample_unchanged_mtime_ns_after": sample.stat().st_mtime_ns,
        "sample_unchanged_device": sample.stat().st_dev,
        "sample_unchanged_inode": sample.stat().st_ino,
        "edited_mtime_ns_before": before_edited,
        "edited_mtime_ns_after": edited.stat().st_mtime_ns,
        "edited_device": edited.stat().st_dev,
        "edited_inode": edited.stat().st_ino,
        "unchanged_mtime_preserved": before_sample == sample.stat().st_mtime_ns,
        "edited_mtime_changed": before_edited != edited.stat().st_mtime_ns,
        "head": output("git", "rev-parse", "HEAD", cwd=workspace),
        "tree": output("git", "rev-parse", "HEAD^{tree}", cwd=workspace),
    }
    metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_SOURCE=" + json.dumps(payload, sort_keys=True), flush=True)


def record_source_metrics(
    workspace: Path,
    base: str,
    target: str,
    mode: str,
    metrics: Path,
    source_transition_seconds: float | None = None,
) -> None:
    payload = {
        "mode": mode,
        "base": base,
        "target": target,
        "workspace": str(workspace.resolve()),
        "source_transition_seconds": (
            round(source_transition_seconds, 6) if source_transition_seconds is not None else None
        ),
        "head": output("git", "rev-parse", "HEAD", cwd=workspace),
        "tree": output("git", "rev-parse", "HEAD^{tree}", cwd=workspace),
    }
    metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_SOURCE=" + json.dumps(payload, sort_keys=True), flush=True)


def gzip_tar(source: Path, destination: Path, excludes=()) -> float:
    started = time.monotonic()
    tar = subprocess.Popen(
        ["tar", "-cf", "-", *sum((["--exclude", item] for item in excludes), []), "-C", str(source), "."],
        stdout=subprocess.PIPE,
    )
    assert tar.stdout is not None
    with destination.open("wb") as stream:
        gzip = subprocess.run(["gzip", "-1"], stdin=tar.stdout, stdout=stream, check=True)
    tar.stdout.close()
    code = tar.wait()
    if code:
        raise subprocess.CalledProcessError(code, tar.args)
    return time.monotonic() - started


def archive_generation(workspace: Path, derived: Path, outdir: Path, metrics: Path) -> None:
    status = output("git", "status", "--porcelain", "--untracked-files=all", cwd=workspace)
    if status:
        raise SystemExit("refusing to archive a dirty seed worktree:\n" + status)
    outdir.mkdir(parents=True, exist_ok=True)
    worktree_archive = outdir / "worktree.tar.gz"
    dd_archive = outdir / "derived-data.tar.gz"
    worktree_seconds = gzip_tar(
        workspace,
        worktree_archive,
        excludes=("./.git", "./ghostty", "./GhosttyKit.xcframework", "./.ci-source-packages"),
    )
    dd_seconds = gzip_tar(derived, dd_archive)

    def du_bytes(path: Path) -> int:
        blocks = int(output("du", "-sk", str(path)).split()[0])
        return blocks * 1024

    sample = (workspace / "Sources/AppDelegate.swift").stat()
    edited = (workspace / "Sources/Mobile/MobileTerminalByteTee.swift").stat()
    incremental_paths = {
        "intermediates": derived / "Build/Intermediates.noindex",
        "debug_products": derived / "Build/Products/Debug",
        "module_cache": derived / "ModuleCache.noindex",
        "sdk_stat_caches": derived / "SDKStatCaches.noindex",
    }
    incremental_sizes = {
        name: du_bytes(path) if path.exists() else 0
        for name, path in incremental_paths.items()
    }
    payload = {
        "workspace": str(workspace.resolve()),
        "derived_data": str(derived.resolve()),
        "sample_unchanged_mtime_ns": sample.st_mtime_ns,
        "sample_unchanged_device": sample.st_dev,
        "sample_unchanged_inode": sample.st_ino,
        "edited_seed_mtime_ns": edited.st_mtime_ns,
        "edited_seed_device": edited.st_dev,
        "edited_seed_inode": edited.st_ino,
        "worktree_archive_bytes": worktree_archive.stat().st_size,
        "derived_data_archive_bytes": dd_archive.stat().st_size,
        "generation_archive_bytes": worktree_archive.stat().st_size + dd_archive.stat().st_size,
        "worktree_compress_seconds": round(worktree_seconds, 6),
        "derived_data_compress_seconds": round(dd_seconds, 6),
        "generation_compress_seconds": round(worktree_seconds + dd_seconds, 6),
        "worktree_disk_bytes": du_bytes(workspace),
        "derived_data_disk_bytes": du_bytes(derived),
        "incremental_subset_disk_bytes": sum(incremental_sizes.values()),
        "incremental_subset_components_bytes": incremental_sizes,
    }
    metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_ARCHIVE=" + json.dumps(payload, sort_keys=True), flush=True)


def extract_derived(archive: Path, derived: Path, metrics: Path) -> None:
    wipe(derived)
    started = time.monotonic()
    run(["tar", "-xzf", archive, "-C", derived])
    seconds = time.monotonic() - started
    payload = {
        "derived_data": str(derived.resolve()),
        "derived_data_extract_seconds": round(seconds, 6),
        "archive_bytes": archive.stat().st_size,
    }
    metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_DD_RESTORE=" + json.dumps(payload, sort_keys=True), flush=True)


def make_xcodebuild_wrapper(root: Path) -> tuple[Path, dict[str, str]]:
    real = shutil.which("xcodebuild")
    if not real:
        raise SystemExit("xcodebuild is unavailable")
    bindir = root / "xcodebuild-wrapper"
    bindir.mkdir(parents=True, exist_ok=True)
    wrapper = bindir / "xcodebuild"
    wrapper.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        "for arg in \"$@\"; do\n"
        "  if [ \"$arg\" = build-for-testing ]; then\n"
        f"    exec {json.dumps(real)} \"$@\" -showBuildTimingSummary\n"
        "  fi\n"
        "done\n"
        f"exec {json.dumps(real)} \"$@\"\n"
    )
    wrapper.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
    return wrapper, env


def parse_build_log(path: Path) -> dict[str, object]:
    text = path.read_text(errors="replace") if path.is_file() else ""
    detail = text.split("Build Timing Summary", 1)[0]
    raw_compile_lines = 0
    source_compile_lines = 0
    source_compile_by_target: dict[str, int] = {}
    cas_hits = 0
    cas_misses = 0
    cas_hits_by_target: dict[str, int] = {}
    cas_misses_by_target: dict[str, int] = {}
    last_target = ""

    for line in detail.splitlines():
        target_match = re.search(r"\(in target '([^']+)' from project", line)
        if target_match:
            last_target = target_match.group(1)
        if line.startswith("SwiftCompile"):
            raw_compile_lines += 1
            if re.search(r"/[^\s]+\.swift(?:\s|$)", line):
                source_compile_lines += 1
                if last_target:
                    source_compile_by_target[last_target] = source_compile_by_target.get(last_target, 0) + 1
        if re.search(r"(?i)\bcache hit\b", line):
            cas_hits += 1
            if last_target:
                cas_hits_by_target[last_target] = cas_hits_by_target.get(last_target, 0) + 1
        if re.search(r"(?i)\bcache miss\b", line):
            cas_misses += 1
            if last_target:
                cas_misses_by_target[last_target] = cas_misses_by_target.get(last_target, 0) + 1

    def timing(name: str):
        matches = re.findall(
            rf"(?mi)^\s*{re.escape(name)}[^\n|]*\|\s*([0-9.]+)\s+seconds?",
            text,
        )
        return round(sum(float(x) for x in matches), 6) if matches else None

    def task_count(name: str):
        matches = re.findall(
            rf"(?mi)^\s*{re.escape(name)}\s+\(([0-9]+)\s+tasks?\)\s*\|",
            text,
        )
        return sum(int(x) for x in matches) if matches else None

    return {
        "swift_compile_log_lines": raw_compile_lines,
        "swift_compile_source_file_lines": source_compile_lines,
        "swift_compile_source_file_lines_by_target": source_compile_by_target,
        "swift_compile_task_count": task_count("SwiftCompile"),
        "swift_compile_timing_seconds": timing("SwiftCompile"),
        "emit_module_task_count": task_count("SwiftEmitModule"),
        "emit_module_seconds": timing("SwiftEmitModule"),
        "cas_hit_mentions": cas_hits,
        "cas_miss_mentions": cas_misses,
        "cas_hit_mentions_by_target": cas_hits_by_target,
        "cas_miss_mentions_by_target": cas_misses_by_target,
    }


def build(workspace: Path, derived: Path, source_packages: Path, cas: Path, label: str, source_metrics: Path | None, dd_metrics: Path | None, output_metrics: Path) -> None:
    workspace = workspace.resolve()
    derived = derived.resolve()
    source_packages = source_packages.resolve()
    cas = cas.resolve()
    derived.mkdir(parents=True, exist_ok=True)
    source_packages.mkdir(parents=True, exist_ok=True)
    cas.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["PATH"] = str(Path.home() / ".cargo/bin") + os.pathsep + env.get("PATH", "")
    env["CMUX_CI_MODULE_CACHE_PATH"] = str(derived / "ModuleCache.noindex")

    setup_started = time.monotonic()
    run([workspace / "scripts/install-rust-ci.sh"], cwd=workspace, env=env)
    run([workspace / "scripts/download-prebuilt-ghosttykit.sh"], cwd=workspace, env=env)
    setup_seconds = time.monotonic() - setup_started

    resolve_started = time.monotonic()
    run([
        workspace / "scripts/ci/compile-app-host-test-product.sh", "resolve",
        derived, source_packages,
    ], cwd=workspace, env=env)
    resolve_seconds = time.monotonic() - resolve_started

    wrapper, build_env = make_xcodebuild_wrapper(Path(os.environ.get("RUNNER_TEMP", "/tmp")))
    build_env.update(env)
    build_env["PATH"] = str(wrapper.parent) + os.pathsep + env.get("PATH", "")
    aggregate = derived / "canary-build-aggregate.log"
    started = time.monotonic()
    run([
        workspace / "scripts/ci/compile-app-host-test-product.sh", "build",
        derived, source_packages, cas, aggregate,
    ], cwd=workspace, env=build_env)
    wall = time.monotonic() - started

    cmux_log = derived / "cmux-build.log"
    parsed = parse_build_log(cmux_log)

    payload: dict[str, object] = {
        "label": label,
        "workspace": str(workspace),
        "derived_data": str(derived),
        "source_packages": str(source_packages),
        "cas_path": str(cas),
        "setup_seconds": round(setup_seconds, 6),
        "package_resolve_seconds": round(resolve_seconds, 6),
        "build_wall_seconds": round(wall, 6),
        "xcode": output("xcodebuild", "-version"),
        "sdk": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        **parsed,
    }
    if source_metrics and source_metrics.is_file():
        payload["source"] = json.loads(source_metrics.read_text())
    if dd_metrics and dd_metrics.is_file():
        payload["derived_restore"] = json.loads(dd_metrics.read_text())
    blocks = int(output("du", "-sk", str(derived)).split()[0])
    payload["derived_data_disk_bytes"] = blocks * 1024
    output_metrics.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    print("CMUX_CANARY_BUILD=" + json.dumps(payload, sort_keys=True), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("source-fresh")
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--metrics", type=Path, required=True)

    p = sub.add_parser("normalize-mtimes")
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--metrics", type=Path)

    p = sub.add_parser("source-restored")
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--archive", type=Path, required=True)
    p.add_argument("--repo-url", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--synthetic-merge", action="store_true")
    p.add_argument("--metrics", type=Path, required=True)

    p = sub.add_parser("archive")
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--derived", type=Path, required=True)
    p.add_argument("--outdir", type=Path, required=True)
    p.add_argument("--metrics", type=Path, required=True)

    p = sub.add_parser("extract-dd")
    p.add_argument("--archive", type=Path, required=True)
    p.add_argument("--derived", type=Path, required=True)
    p.add_argument("--metrics", type=Path, required=True)

    p = sub.add_parser("build")
    p.add_argument("--workspace", type=Path, required=True)
    p.add_argument("--derived", type=Path, required=True)
    p.add_argument("--source-packages", type=Path, required=True)
    p.add_argument("--cas", type=Path, required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--source-metrics", type=Path)
    p.add_argument("--dd-metrics", type=Path)
    p.add_argument("--metrics", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "source-fresh":
        source_fresh(args.workspace, args.base, args.target, args.metrics)
    elif args.command == "normalize-mtimes":
        normalize_tracked_mtimes(args.workspace, args.metrics)
    elif args.command == "source-restored":
        source_restored(args.workspace, args.archive, args.repo_url, args.base, args.target, args.metrics, args.synthetic_merge)
    elif args.command == "archive":
        archive_generation(args.workspace, args.derived, args.outdir, args.metrics)
    elif args.command == "extract-dd":
        extract_derived(args.archive, args.derived, args.metrics)
    elif args.command == "build":
        build(args.workspace, args.derived, args.source_packages, args.cas, args.label, args.source_metrics, args.dd_metrics, args.metrics)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
