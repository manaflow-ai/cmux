#!/usr/bin/env python3
"""Run cmux compile admission through Glaeda's native Apple cache contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time


PROFILE = "ci-compile-admission"
BASE_GENERATION = "cmux-ci-v1"
QUARANTINE_RETAINED_STORES = 1
# Glaeda performs no automatic eviction of its own cache generations
# (docs/APPLE_NATIVE_BUILDS.md: "this prototype performs no automatic eviction
# or broad cache cleanup"). Each generation under
# .glaeda/apple-build/cache/<key>/ holds a full cmux DerivedData tree, so every
# Xcode or SDK bump strands a multi-GB directory on the owned Mac forever.
# Retain this run's generation plus the two most recently used others: enough
# to survive a toolchain bump and a rollback back onto the previous generation
# without a cold rebuild, while keeping disk bounded.
CACHE_RETAINED_GENERATIONS = 3
CACHE_GENERATION_KEY = re.compile(r"[a-f0-9]{64}")
STATE_RESET_REASONS = (
    "state belongs to another checkout",
    "existing Apple state is incomplete",
    "cache generation identity mismatch",
    "existing cache generation is unmarked",
    "checkout identity changed before state access",
)


class Refusal(RuntimeError):
    pass


def output(*argv: str, cwd: Path | None = None) -> str:
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False)
    if result.returncode:
        raise Refusal(f"command failed ({result.returncode}): {' '.join(argv)}\n{result.stderr.strip()}")
    return result.stdout.strip()


def json_command(argv: list[str]) -> tuple[dict[str, object], int]:
    result = subprocess.run(argv, text=True, capture_output=True, check=False)
    payload: dict[str, object] | None = None
    for raw in reversed(result.stdout.splitlines()):
        raw = raw.strip()
        if not raw:
            continue
        try:
            candidate = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            payload = candidate
            break
    if payload is None:
        reason = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise Refusal(reason)
    if result.stderr.strip():
        print(result.stderr.rstrip(), file=sys.stderr)
    return payload, result.returncode


def glaeda(
    executable: Path,
    action: str,
    project: Path,
    generation: str,
    *,
    expected_commit: str | None = None,
    expected_tree: str | None = None,
    require_clean: bool = False,
    run_id: str | None = None,
) -> tuple[dict[str, object], int]:
    argv = [
        str(executable),
        action,
        "--project",
        str(project),
        "--profile",
        PROFILE,
        "--generation",
        generation,
    ]
    if run_id is not None:
        argv.extend(["--run-id", run_id])
    if expected_commit is not None:
        argv.extend(["--expected-commit", expected_commit])
    if expected_tree is not None:
        argv.extend(["--expected-tree", expected_tree])
    if require_clean:
        argv.append("--require-clean-source")
    return json_command(argv)


def apple_state(project: Path) -> Path:
    return project / ".glaeda" / "apple-build"


def plan(executable: Path, project: Path) -> dict[str, object]:
    result, code = glaeda(executable, "plan", project, BASE_GENERATION)
    if code:
        raise Refusal(f"Glaeda plan exited {code}")
    return result


def prune_quarantine_stores(project: Path, keep: Path | None = None) -> None:
    parent = project / ".glaeda"
    if not parent.is_dir():
        return
    candidates: list[tuple[int, Path]] = []
    with os.scandir(parent) as entries:
        for entry in entries:
            if not entry.name.startswith("apple-build-quarantine-"):
                continue
            if not (entry.is_dir(follow_symlinks=False) or entry.is_symlink()):
                continue
            info = entry.stat(follow_symlinks=False)
            candidates.append((info.st_mtime_ns, Path(entry.path)))
    candidates.sort(reverse=True)
    retained: set[Path] = set()
    if keep is not None:
        retained.add(keep)
    for _, path in candidates:
        if path in retained:
            continue
        if len(retained) < QUARANTINE_RETAINED_STORES:
            retained.add(path)
            continue
        if path.parent != parent or not path.name.startswith("apple-build-quarantine-"):
            raise Refusal("refusing to prune a path outside the cmux Glaeda quarantine")
        if path.is_symlink():
            path.unlink()
        else:
            shutil.rmtree(path)
        print(f"Pruned obsolete Glaeda quarantine {path.name}")


def prune_cache_generations(project: Path, keep_key: str | None = None) -> list[str]:
    """Bound Glaeda cache growth, which Glaeda itself never bounds.

    Ordering is by directory mtime, which `main` stamps on the generation it
    used immediately before calling this. That makes the ordering an explicit
    least-recently-used record rather than an accident of what Xcode last wrote
    deep inside the tree: writes under `derived_data/` do not touch the
    generation directory's own mtime, so an unstamped warm generation could
    otherwise look older than a cold one.

    Only directories whose names are Glaeda cache keys are candidates, and the
    key this run used is never one. Deleting the wrong generation costs a cold
    rebuild, not correctness, so every ambiguous entry is left in place.
    """
    parent = project / ".glaeda" / "apple-build" / "cache"
    if not parent.is_dir():
        return []
    candidates: list[tuple[int, Path]] = []
    with os.scandir(parent) as entries:
        for entry in entries:
            if not CACHE_GENERATION_KEY.fullmatch(entry.name):
                continue
            if not (entry.is_dir(follow_symlinks=False) or entry.is_symlink()):
                continue
            info = entry.stat(follow_symlinks=False)
            candidates.append((info.st_mtime_ns, Path(entry.path)))
    candidates.sort(reverse=True)
    retained: set[str] = set()
    if keep_key is not None:
        retained.add(keep_key)
    pruned: list[str] = []
    for _, path in candidates:
        if path.name in retained:
            continue
        if len(retained) < CACHE_RETAINED_GENERATIONS:
            retained.add(path.name)
            continue
        if path.parent != parent or not CACHE_GENERATION_KEY.fullmatch(path.name):
            raise Refusal("refusing to prune a path outside the cmux Glaeda cache")
        if path.is_symlink():
            path.unlink()
        else:
            shutil.rmtree(path)
        pruned.append(path.name)
        print(f"Pruned obsolete Glaeda cache generation {path.name}")
    return pruned


def quarantine_state(project: Path, request_id: str) -> Path | None:
    state = apple_state(project)
    if not os.path.lexists(state):
        return None
    suffix = re.sub(r"[^a-zA-Z0-9_.-]+", "-", request_id).strip("-") or "run"
    destination = state.with_name(
        f"apple-build-quarantine-{suffix}-{time.time_ns()}"
    )
    state.rename(destination)
    print(f"Quarantined incompatible Glaeda state as {destination.name}")
    prune_quarantine_stores(project, keep=destination)
    return destination


def reset_to_cold(
    executable: Path,
    project: Path,
    request_id: str,
    reset_reasons: list[str],
    reason: str,
) -> dict[str, object]:
    reset_reasons.append(reason)
    quarantine_state(project, request_id)
    return plan(executable, project)


def plan_or_reset(
    executable: Path,
    project: Path,
    request_id: str,
    source_reset: bool,
) -> tuple[dict[str, object], str, list[str]]:
    reset_reasons: list[str] = []
    generation = BASE_GENERATION
    state_existed = apple_state(project).exists()
    try:
        current = plan(executable, project)
    except Refusal as error:
        reason = str(error)
        if "cache was interrupted" in reason:
            current = reset_to_cold(
                executable, project, request_id, reset_reasons, "quarantined_generation"
            )
        elif any(fragment in reason for fragment in STATE_RESET_REASONS):
            current = reset_to_cold(
                executable, project, request_id, reset_reasons, "state_ownership_reset"
            )
        else:
            raise

    active = current.get("active_run")
    if current.get("state") == "interrupted_or_running" and isinstance(active, str) and active:
        recovered, code = glaeda(
            executable, "recover", project, generation, run_id=active
        )
        if code:
            raise Refusal(
                f"Glaeda recovery exited {code}: {json.dumps(recovered, sort_keys=True)}"
            )
        current = reset_to_cold(
            executable,
            project,
            request_id,
            reset_reasons,
            "interrupted_generation_recovered",
        )

    if source_reset:
        reset_reasons.append("dirty_source_reset")
        if apple_state(project).exists():
            quarantine_state(project, request_id)
            current = plan(executable, project)
    elif current.get("state") == "cold" and state_existed and not reset_reasons:
        current = reset_to_cold(
            executable,
            project,
            request_id,
            reset_reasons,
            "incompatible_cache_reset",
        )

    prune_quarantine_stores(project)
    return current, generation, reset_reasons


def publish_native_log(project: Path, receipt: dict[str, object], label: str) -> None:
    run_id = receipt.get("run_id")
    if not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-f]{32}", run_id):
        return
    path = project / ".glaeda" / "apple-build" / f"run-{run_id}.log"
    if not path.is_file():
        return
    print(f"===== Glaeda {label} native log =====")
    with path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            print(line, end="")
    print(f"===== end Glaeda {label} native log =====")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def directory_sha256(root: Path) -> str:
    """Canonical byte/type/mode digest for a cached native input tree."""
    digest = hashlib.sha256()

    def visit(directory: Path) -> None:
        with os.scandir(directory) as stream:
            entries = sorted(stream, key=lambda entry: entry.name.encode())
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            info = entry.stat(follow_symlinks=False)
            digest.update(relative.encode() + b"\0")
            digest.update(f"{info.st_mode & 0o777:o}".encode() + b"\0")
            if stat.S_ISLNK(info.st_mode):
                digest.update(b"L\0" + os.readlink(path).encode() + b"\0")
            elif stat.S_ISDIR(info.st_mode):
                digest.update(b"D\0")
                visit(path)
            elif stat.S_ISREG(info.st_mode):
                digest.update(b"F\0")
                with path.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block)
                digest.update(b"\0")
            else:
                raise Refusal(f"unsupported cached GhosttyKit entry: {relative}")

    visit(root)
    return digest.hexdigest()


def ensure_ghostty(project: Path, cmux_state: Path) -> str:
    expected = output("git", "-C", str(project / "ghostty"), "rev-parse", "HEAD")
    marker = cmux_state / "ghosttykit-identity.json"
    framework = project / "GhosttyKit.xcframework"

    identity = None
    if marker.is_file():
        try:
            identity = json.loads(marker.read_text())
        except (OSError, ValueError):
            identity = None
    if (framework.is_dir() and not framework.is_symlink() and isinstance(identity, dict)
            and identity.get("schema_version") == 1
            and identity.get("ghostty_commit") == expected
            and isinstance(identity.get("tree_sha256"), str)
            and re.fullmatch(r"[a-f0-9]{64}", identity["tree_sha256"])
            and directory_sha256(framework) == identity["tree_sha256"]):
        return "reused"

    if framework.exists() or framework.is_symlink():
        if framework.is_dir() and not framework.is_symlink():
            shutil.rmtree(framework)
        else:
            framework.unlink()
    marker.unlink(missing_ok=True)
    subprocess.run([str(project / "scripts" / "download-prebuilt-ghosttykit.sh")], cwd=project, check=True)
    if not framework.is_dir() or framework.is_symlink():
        raise Refusal("GhosttyKit download completed without the expected framework")
    verified_identity = {
        "schema_version": 1,
        "ghostty_commit": expected,
        "tree_sha256": directory_sha256(framework),
    }
    temporary = marker.with_suffix(".tmp")
    temporary.write_text(json.dumps(verified_identity, sort_keys=True) + "\n")
    temporary.replace(marker)
    return "downloaded"


def require_exact_source(receipt: dict[str, object], commit: str, tree: str, label: str) -> None:
    if receipt.get("source_validation") != "exact_commit_tree_clean":
        raise Refusal(f"{label} receipt did not record exact source validation")
    for key in ("source_before", "source_after"):
        observed = receipt.get(key)
        if not isinstance(observed, dict):
            raise Refusal(f"{label} receipt omitted {key}")
        if observed.get("commit") != commit or observed.get("tree") != tree or observed.get("clean") is not True:
            raise Refusal(f"{label} receipt source identity drifted")


def write_output(name: str, value: object) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with Path(path).open("a", encoding="utf-8") as stream:
        stream.write(f"{name}={value}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--glaeda", type=Path, required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--expected-tree", required=True)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--source-preparation-seconds", type=float, required=True)
    parser.add_argument("--source-reset", choices=("true", "false"), required=True)
    parser.add_argument("--metrics", type=Path, required=True)
    args = parser.parse_args()

    project = Path.cwd().resolve()
    lockfile = project / "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if not lockfile.is_file():
        raise Refusal(f"missing Package.resolved: {lockfile.relative_to(project)}")
    initial_package_identity = sha256(lockfile)
    submodule_identity = hashlib.sha256(
        output("git", "-C", str(project), "submodule", "status", "--recursive").encode()
    ).hexdigest()

    plan, generation, reset_reasons = plan_or_reset(
        args.glaeda.resolve(), project, args.request_id, args.source_reset == "true"
    )
    initial_state = str(plan.get("state"))
    if initial_state not in {"cold", "prepared"}:
        raise Refusal(f"unexpected Glaeda cache state after admission: {initial_state}")

    cache_key = plan.get("cache_key")
    invocation_identity = plan.get("invocation_identity")
    cache_root = plan.get("cache_root")
    if (not isinstance(cache_key, str) or not re.fullmatch(r"[a-f0-9]{64}", cache_key)
            or not isinstance(invocation_identity, str) or not re.fullmatch(r"[a-f0-9]{64}", invocation_identity)):
        raise Refusal("Glaeda plan omitted valid cache lineage identities")
    expected_cache_root = f".glaeda/apple-build/cache/{cache_key}"
    if cache_root != expected_cache_root:
        raise Refusal("Glaeda plan returned an unexpected cache locator")

    cmux_state = project / ".glaeda" / "cmux-ci"
    cmux_state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(cmux_state, 0o700)

    package_marker = cmux_state / "package-resolved.json"
    package_identity = None
    if package_marker.is_file():
        try:
            package_identity = json.loads(package_marker.read_text())
        except (OSError, ValueError):
            package_identity = None
    package_cache_state = (
        "matched"
        if package_identity == {
            "schema_version": 1,
            "cache_key": cache_key,
            "package_resolved_sha256": initial_package_identity,
        }
        else "changed-or-unseeded"
    )

    build_marker = cmux_state / "last-successful-build.json"
    prior_build = None
    if build_marker.is_file():
        try:
            prior_build = json.loads(build_marker.read_text())
        except (OSError, ValueError):
            prior_build = None
    invocation_cache_state = (
        "matched"
        if prior_build == {
            "schema_version": 1,
            "cache_key": cache_key,
            "invocation_identity": invocation_identity,
        }
        else "changed-or-unseeded"
    )
    ghostty_state = ensure_ghostty(project, cmux_state)

    package_started = time.monotonic()
    dependency, dependency_code = glaeda(
        args.glaeda.resolve(),
        "dependencies",
        project,
        generation,
        expected_commit=args.expected_commit,
        expected_tree=args.expected_tree,
        require_clean=True,
    )
    package_seconds = time.monotonic() - package_started
    publish_native_log(project, dependency, "package readiness")
    require_exact_source(dependency, args.expected_commit, args.expected_tree, "dependency")
    if dependency_code or dependency.get("exit_code") != 0:
        raise Refusal(f"package readiness failed with exit {dependency.get('exit_code', dependency_code)}")

    final_package_identity = sha256(lockfile)
    if final_package_identity != initial_package_identity:
        raise Refusal("Package.resolved changed during package readiness")
    temporary_marker = package_marker.with_suffix(".tmp")
    temporary_marker.write_text(json.dumps({
        "schema_version": 1,
        "cache_key": cache_key,
        "package_resolved_sha256": final_package_identity,
    }, sort_keys=True) + "\n")
    temporary_marker.replace(package_marker)

    build_started = time.monotonic()
    build, build_code = glaeda(
        args.glaeda.resolve(),
        "run",
        project,
        generation,
        expected_commit=args.expected_commit,
        expected_tree=args.expected_tree,
        require_clean=True,
    )
    compile_seconds = time.monotonic() - build_started
    publish_native_log(project, build, "compile")
    require_exact_source(build, args.expected_commit, args.expected_tree, "build")
    if build_code or build.get("exit_code") != 0:
        raise Refusal(f"compile failed with exit {build.get('exit_code', build_code)}")

    cache_directory = project / expected_cache_root
    derived_data = cache_directory / "derived_data"
    if derived_data.is_symlink() or not derived_data.is_dir():
        raise Refusal("Glaeda native cache omitted a safe DerivedData directory")
    resolved_cache = cache_directory.resolve(strict=True)
    resolved_derived = derived_data.resolve(strict=True)
    if resolved_cache.parent != (project / ".glaeda/apple-build/cache").resolve(strict=True):
        raise Refusal("Glaeda cache locator escaped the project cache root")
    if resolved_derived.parent != resolved_cache:
        raise Refusal("Glaeda DerivedData escaped the admitted cache generation")
    derived_data = resolved_derived
    build_log = derived_data / "cmux-build.log"
    products = derived_data / "Build" / "Products" / "Debug"
    if not build_log.is_file() or not products.is_dir():
        raise Refusal("native compile completed without the admission log/products")

    # Stamp the generation this run used, then evict the least recently used
    # others. Pruning only after a verified-good compile means a failed run
    # never deletes a generation on the strength of an unvalidated plan.
    os.utime(resolved_cache)
    pruned_cache_generations = prune_cache_generations(project, keep_key=cache_key)

    classification = (
        "cold-reset"
        if reset_reasons or initial_state == "cold"
        else "hot"
        if (ghostty_state == "reused" and package_cache_state == "matched"
            and invocation_cache_state == "matched")
        else "partially-warm"
    )
    build_marker_tmp = build_marker.with_suffix(".tmp")
    build_marker_tmp.write_text(json.dumps({
        "schema_version": 1,
        "cache_key": cache_key,
        "invocation_identity": invocation_identity,
    }, sort_keys=True) + "\n")
    build_marker_tmp.replace(build_marker)
    toolchain = {
        "xcode": output("xcodebuild", "-version"),
        "sdk_version": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "developer_dir": os.environ.get("DEVELOPER_DIR", ""),
    }
    native_timings = build.get("timings_seconds")
    native_work = build.get("native_work")
    metrics = {
        "schema_version": 1,
        "classification": classification,
        "source": {"commit": args.expected_commit, "tree": args.expected_tree},
        "source_preparation_seconds": round(args.source_preparation_seconds, 6),
        "package_readiness_seconds": round(package_seconds, 6),
        "compile_duration_seconds": round(compile_seconds, 6),
        "package_resolved_sha256": final_package_identity,
        "submodule_identity_sha256": submodule_identity,
        "ghostty_state": ghostty_state,
        "package_cache_state": package_cache_state,
        "invocation_cache_state": invocation_cache_state,
        "glaeda": {
            "generation": generation,
            "initial_state": initial_state,
            "reset_reasons": reset_reasons,
            "cache_key": plan.get("cache_key"),
            "invocation_identity": plan.get("invocation_identity"),
            "pruned_cache_generations": pruned_cache_generations,
            "native_timings_seconds": native_timings if isinstance(native_timings, dict) else {},
            "native_work": native_work if isinstance(native_work, dict) else {},
        },
        "toolchain": toolchain,
    }
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, sort_keys=True, indent=2) + "\n")

    write_output("derived_data", derived_data)
    write_output("classification", classification)
    write_output("metrics", args.metrics)
    print(json.dumps(metrics, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Refusal, OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        print(f"persistent Mac compile refused: {error}", file=sys.stderr)
        raise SystemExit(1)
