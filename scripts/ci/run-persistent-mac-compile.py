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


def semantic_stage_seconds(result: dict[str, object], stage: str) -> float:
    timings = result.get("stage_timings")
    if not isinstance(timings, list):
        raise Refusal("canonical workload result omitted stage timings")
    matched = []
    for item in timings:
        if not isinstance(item, dict):
            raise Refusal("canonical workload stage timing is invalid")
        name = item.get("stage")
        seconds = item.get("seconds")
        if not isinstance(name, str) or type(seconds) not in (int, float) or seconds < 0:
            raise Refusal("canonical workload stage timing is invalid")
        if name == stage:
            matched.append(float(seconds))
    if len(matched) != 1:
        raise Refusal(f"canonical workload result must report one {stage} stage")
    return matched[0]


def validate_semantic_result(
    result: object, expected_commit: str, expected_tree: str
) -> dict[str, object]:
    if not isinstance(result, dict):
        raise Refusal("canonical workload result is not an object")
    if result.get("document_type") != "cmux-workload-result" or result.get("schema_version") != 1:
        raise Refusal("canonical workload result identity is invalid")
    if result.get("result") != "passed":
        raise Refusal("canonical compile-admission workload did not pass")
    if result.get("source") != {
        "repository": "manaflow-ai/cmux",
        "commit": expected_commit,
        "tree": expected_tree,
    }:
        raise Refusal("canonical workload source identity mismatch")
    if result.get("profile") != {
        "id": "cmux.macos.compile-admission",
        "generation": 1,
    }:
        raise Refusal("canonical workload profile identity mismatch")
    if result.get("semantic_validator") != "cmux.compile-admission/v1":
        raise Refusal("canonical workload semantic validator mismatch")

    validation = result.get("validation")
    if (
        not isinstance(validation, dict)
        or validation.get("missing_required_artifact_classes") != []
    ):
        raise Refusal("canonical workload artifact validation is incomplete")
    cleanup = result.get("cleanup")
    if (
        not isinstance(cleanup, dict)
        or cleanup.get("state") != "complete"
        or cleanup.get("process_group_settled") is not True
    ):
        raise Refusal("canonical workload cleanup is incomplete")

    benchmark = result.get("benchmark")
    if not isinstance(benchmark, dict):
        raise Refusal("canonical workload benchmark identity is missing")
    state_class = benchmark.get("state_class")
    if state_class not in {"cold", "compiler-warm"}:
        raise Refusal("canonical workload used an unexpected benchmark state class")
    for key in ("semantic_comparison_key", "comparison_context_key"):
        value = benchmark.get(key)
        if not isinstance(value, str) or re.fullmatch(r"sha256:[a-f0-9]{64}", value) is None:
            raise Refusal(f"canonical workload {key} is invalid")

    toolchain = result.get("toolchain")
    if not isinstance(toolchain, dict):
        raise Refusal("canonical workload toolchain identity is missing")
    identity = toolchain.get("identity")
    observations = toolchain.get("observations")
    if (
        not isinstance(identity, str)
        or re.fullmatch(r"sha256:[a-f0-9]{64}", identity) is None
        or not isinstance(observations, dict)
    ):
        raise Refusal("canonical workload toolchain identity is invalid")

    semantic_stage_seconds(result, "setup")
    semantic_stage_seconds(result, "dependency_preparation")
    semantic_stage_seconds(result, "compile")
    semantic_stage_seconds(result, "validation")
    return result


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
    semantic_runner = project / "scripts/ci/cmux_workload_profile.py"
    semantic_registry = project / "scripts/ci/cmux-workload-profiles.json"
    semantic_entrypoint = project / "scripts/ci/persistent-mac-semantic-entrypoint.sh"
    if not semantic_runner.is_file() or not semantic_registry.is_file():
        raise Refusal(
            "canonical cmux.macos.compile-admission@1 is unavailable; "
            "persistent routing remains disabled until #13411 is on the exact source"
        )
    if not semantic_entrypoint.is_file() or not os.access(semantic_entrypoint, os.X_OK):
        raise Refusal("persistent semantic entrypoint is unavailable or not executable")

    lockfile = project / "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if not lockfile.is_file():
        raise Refusal(f"missing Package.resolved: {lockfile.relative_to(project)}")
    initial_package_identity = sha256(lockfile)
    initial_submodules = output(
        "git", "-C", str(project), "submodule", "status", "--recursive"
    )
    submodule_identity = hashlib.sha256(initial_submodules.encode()).hexdigest()

    plan_receipt, generation, reset_reasons = plan_or_reset(
        args.glaeda.resolve(), project, args.request_id, args.source_reset == "true"
    )
    initial_state = str(plan_receipt.get("state"))
    if initial_state not in {"cold", "prepared"}:
        raise Refusal(f"unexpected Glaeda cache state after admission: {initial_state}")

    cache_key = plan_receipt.get("cache_key")
    invocation_identity = plan_receipt.get("invocation_identity")
    cache_root = plan_receipt.get("cache_root")
    if (
        not isinstance(cache_key, str)
        or re.fullmatch(r"[a-f0-9]{64}", cache_key) is None
        or not isinstance(invocation_identity, str)
        or re.fullmatch(r"[a-f0-9]{64}", invocation_identity) is None
    ):
        raise Refusal("Glaeda plan omitted valid cache lineage identities")
    expected_cache_root = f".glaeda/apple-build/cache/{cache_key}"
    if cache_root != expected_cache_root:
        raise Refusal("Glaeda plan returned an unexpected cache locator")

    cmux_state = project / ".glaeda" / "cmux-ci"
    cmux_state.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(cmux_state, 0o700)
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

    native_started = time.monotonic()
    native, native_code = glaeda(
        args.glaeda.resolve(),
        "run",
        project,
        generation,
        expected_commit=args.expected_commit,
        expected_tree=args.expected_tree,
        require_clean=True,
    )
    outer_native_seconds = time.monotonic() - native_started
    publish_native_log(project, native, "canonical compile admission")
    require_exact_source(native, args.expected_commit, args.expected_tree, "build")
    if native_code or native.get("exit_code") != 0:
        quarantine_state(project, args.request_id + "-semantic-failed")
        raise Refusal(
            "canonical compile admission failed with exit "
            f"{native.get('exit_code', native_code)}"
        )

    cache_directory = project / expected_cache_root
    if cache_directory.is_symlink() or not cache_directory.is_dir():
        raise Refusal("Glaeda native cache omitted a safe cache directory")
    canonical_cache_parent = (project / ".glaeda/apple-build/cache").resolve(strict=True)
    resolved_cache = cache_directory.resolve(strict=True)
    if resolved_cache.parent != canonical_cache_parent:
        raise Refusal("Glaeda cache locator escaped the project cache root")

    products_root = cache_directory / "products"
    semantic_state = products_root / "semantic-state"
    semantic_result_path = products_root / "semantic-result.json"
    derived_data = semantic_state / "derived-data"
    for label, path in (
        ("products", products_root),
        ("semantic state", semantic_state),
        ("DerivedData", derived_data),
    ):
        if path.is_symlink() or not path.is_dir():
            raise Refusal(f"Glaeda native cache omitted a safe {label} directory")
        resolved = path.resolve(strict=True)
        if resolved_cache not in resolved.parents:
            raise Refusal(f"{label} escaped the admitted Glaeda cache generation")
    if semantic_result_path.is_symlink() or not semantic_result_path.is_file():
        raise Refusal("canonical workload result is missing or unsafe")

    try:
        raw_semantic = json.loads(semantic_result_path.read_text())
    except (OSError, ValueError) as error:
        raise Refusal("canonical workload result cannot be read") from error
    semantic = validate_semantic_result(
        raw_semantic, args.expected_commit, args.expected_tree
    )

    final_package_identity = sha256(lockfile)
    if final_package_identity != initial_package_identity:
        quarantine_state(project, args.request_id + "-package-drift")
        raise Refusal("Package.resolved changed during canonical compile admission")
    final_submodules = output(
        "git", "-C", str(project), "submodule", "status", "--recursive"
    )
    if final_submodules != initial_submodules:
        quarantine_state(project, args.request_id + "-submodule-drift")
        raise Refusal("submodule identity changed during canonical compile admission")

    build_log = derived_data / "cmux-build.log"
    debug_products = derived_data / "Build" / "Products" / "Debug"
    if not build_log.is_file() or not debug_products.is_dir():
        raise Refusal("canonical compile completed without admission log/products")
    semantic_copy = derived_data / "cmux-workload-result.json"
    shutil.copy2(semantic_result_path, semantic_copy)

    semantic_state_class = semantic["benchmark"]["state_class"]
    classification = (
        "cold-reset"
        if reset_reasons or initial_state == "cold" or semantic_state_class == "cold"
        else "hot"
        if semantic_state_class == "compiler-warm" and invocation_cache_state == "matched"
        else "partially-warm"
    )
    build_marker_tmp = build_marker.with_suffix(".tmp")
    build_marker_tmp.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "cache_key": cache_key,
                "invocation_identity": invocation_identity,
            },
            sort_keys=True,
        )
        + "\n"
    )
    build_marker_tmp.replace(build_marker)

    toolchain = {
        "xcode": output("xcodebuild", "-version"),
        "sdk_version": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "developer_dir": os.environ.get("DEVELOPER_DIR", ""),
    }
    semantic_toolchain = semantic.get("toolchain", {})
    observations = semantic_toolchain.get("observations", {})
    if isinstance(observations, dict):
        if observations.get("xcode") not in (None, toolchain["xcode"]):
            raise Refusal("canonical workload Xcode observation differs after execution")
        if observations.get("macos_sdk") not in (None, toolchain["sdk_version"]):
            raise Refusal("canonical workload SDK observation differs after execution")

    native_timings = native.get("timings_seconds")
    native_work = native.get("native_work")
    package_seconds = semantic_stage_seconds(semantic, "dependency_preparation")
    compile_seconds = semantic_stage_seconds(semantic, "compile")
    semantic_validation_seconds = semantic_stage_seconds(semantic, "validation")
    setup_seconds = semantic_stage_seconds(semantic, "setup")

    metrics = {
        "schema_version": 1,
        "classification": classification,
        "source": {"commit": args.expected_commit, "tree": args.expected_tree},
        "source_preparation_seconds": round(args.source_preparation_seconds, 6),
        "setup_seconds": setup_seconds,
        "package_readiness_seconds": package_seconds,
        "compile_duration_seconds": compile_seconds,
        "semantic_validation_seconds": semantic_validation_seconds,
        "outer_native_seconds": round(outer_native_seconds, 6),
        "package_resolved_sha256": final_package_identity,
        "submodule_identity_sha256": submodule_identity,
        "invocation_cache_state": invocation_cache_state,
        "semantic": semantic,
        "glaeda": {
            "generation": generation,
            "initial_state": initial_state,
            "reset_reasons": reset_reasons,
            "cache_key": cache_key,
            "invocation_identity": invocation_identity,
            "native_timings_seconds": (
                native_timings if isinstance(native_timings, dict) else {}
            ),
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
    except (
        Refusal,
        OSError,
        subprocess.SubprocessError,
        ValueError,
        KeyError,
        TypeError,
    ) as error:
        print(f"persistent Mac compile refused: {error}", file=sys.stderr)
        raise SystemExit(1)
