#!/usr/bin/env python3
import hashlib
import ipaddress
import json
import math
import os
import pathlib
import re
import sys

from startup_benchmark_contract import (
    PREFLIGHT_STATUS_UNVERIFIED,
    PREFLIGHT_STATUS_VERIFIED,
    validate_preflight_evidence,
)

FULL_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
FULL_SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
APP_CONTAINER_SID_PATTERN = re.compile(r"S-1(?:-\d+)+")
SKIPPED_REPORT_SCHEMA = 4
SKIPPED_PLATFORM = "windows-azure"
SKIPPED_BACKEND = "windows-restricted-token-job"
WINDOWS_BOOTSTRAP_IMPORT_SCHEMA = 1
APPROVED_WINDOWS_BOOTSTRAP_DEPENDENCIES = {
    "advapi32.dll",
    "bcrypt.dll",
    "kernel32.dll",
}
WINDOWS_API_SET_PATTERN = re.compile(
    r"(?i:(?:api|ext)-[a-z0-9-]+-l[0-9]+-[0-9]+-[0-9]+\.dll)"
)
WINDOWS_BOOTSTRAP_REPORT_FIELDS = (
    "infrastructure.windows_bootstrap_binary",
    "infrastructure.expected_windows_bootstrap_sha256",
    "infrastructure.windows_bootstrap_sha256",
    "infrastructure.windows_bootstrap_bytes",
)
APP_CONTAINER_UNAVAILABLE_SCHEMA_VERSION = 1
APP_CONTAINER_UNAVAILABLE_FIELDS = {
    "schema_version",
    "status",
    "backend",
    "nonce",
    "stage",
    "reason",
    "runner_staged_target_readable",
    "runner_staged_target_sha256",
    "expected_staged_target_sha256",
    "staging_creation_acl_applied",
    "fixture_creation_acl_applied",
    "staged_target_regular_file",
    "account_probe_impersonated",
    "account_probe_kind",
    "account_sid",
    "account_authentication_id",
    "account_process_target",
    "account_process_target_sha256",
    "account_process_probe_started",
    "account_staged_target_readable",
    "account_staged_target_error_code",
    "restricted_token_run_started",
    "profile_deleted",
    "account_profile_unloaded",
    "adjacent_sentinel_deleted",
    "staging_directory_deleted",
    "fixture_directory_deleted",
    "preexisting_parent_before_sha256",
    "preexisting_parent_after_sha256",
    "preexisting_parent_unchanged",
}


def require_full_sha(value, label):
    if not isinstance(value, str) or FULL_SHA_PATTERN.fullmatch(value) is None:
        raise SystemExit(f"{label} must be a lowercase 40-character SHA")


def require_exact_object(value, expected_fields, label):
    if not isinstance(value, dict) or set(value) != set(expected_fields):
        raise SystemExit(f"{label} has unknown or missing fields")


def require_true_fields(value, fields, label):
    if any(value[field] is not True for field in fields):
        raise SystemExit(f"{label} has a failed proof field")


ARTIFACT_MANIFEST_NAME = "startup-artifact-manifest.json"


def file_sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def load_json_object(path, label):
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"{label} is missing or is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is invalid: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be a JSON object")
    return value


def load_json_with_optional_bom(path, label):
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"{label} is missing or is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is invalid: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} must be a JSON object")
    return value


def validate_windows_bootstrap_attestation(
    artifact_root,
    preflight,
    *,
    expected_trusted_sha=None,
    expected_bootstrap_path=None,
):
    """Validate the trusted bootstrap binary and its audited imports.

    The skipped Windows path still carries the bootstrap identity in the
    preflight evidence. Requiring the immutable-input record and import audit
    here prevents an unavailable observation from becoming an unlinked claim.
    """
    integrity = load_json_object(
        artifact_root / "startup-integrity-before.json",
        "startup integrity record",
    )
    files = integrity.get("files")
    if not isinstance(files, dict):
        raise SystemExit("startup integrity record has no file map")
    if expected_trusted_sha is not None and integrity.get("trusted_sha") != expected_trusted_sha:
        raise SystemExit("startup integrity record has the wrong trusted SHA")
    record = files.get("trusted_windows_bootstrap")
    if not isinstance(record, dict) or set(record) != {"path", "sha256", "size_bytes"}:
        raise SystemExit("startup integrity record has no trusted Windows bootstrap")
    path_value = record["path"]
    expected_sha256 = record["sha256"]
    expected_size = record["size_bytes"]
    if (
        not isinstance(path_value, str)
        or not path_value
        or not pathlib.Path(path_value).is_absolute()
        or not isinstance(expected_sha256, str)
        or FULL_SHA256_PATTERN.fullmatch(expected_sha256) is None
        or not isinstance(expected_size, int)
        or isinstance(expected_size, bool)
        or expected_size <= 0
    ):
        raise SystemExit("trusted Windows bootstrap integrity metadata is invalid")
    bootstrap_path = pathlib.Path(path_value)
    if (
        expected_bootstrap_path is not None
        and (
            not isinstance(expected_bootstrap_path, str)
            or os.path.normcase(os.path.abspath(expected_bootstrap_path))
            != os.path.normcase(os.path.abspath(path_value))
        )
    ):
        raise SystemExit("startup report is not linked to the attested Windows bootstrap")
    if bootstrap_path.is_symlink() or not bootstrap_path.is_file():
        raise SystemExit("trusted Windows bootstrap binary is missing")
    actual_size = bootstrap_path.stat().st_size
    actual_sha256 = file_sha256(bootstrap_path)
    if actual_size != expected_size or actual_sha256 != expected_sha256:
        raise SystemExit("trusted Windows bootstrap changed after attestation")
    evidence_sha256 = preflight.get("windows_bootstrap_sha256")
    if evidence_sha256 != actual_sha256:
        raise SystemExit("preflight does not identify the attested Windows bootstrap")

    import_path = artifact_root / "windows-bootstrap-imports.json"
    import_record = files.get("trusted_windows_bootstrap_imports")
    if not isinstance(import_record, dict) or set(import_record) != {"path", "sha256", "size_bytes"}:
        raise SystemExit("startup integrity record has no bootstrap import audit")
    if (
        import_record["path"] != str(import_path.resolve())
        or import_path.is_symlink()
        or not import_path.is_file()
        or not isinstance(import_record["sha256"], str)
        or FULL_SHA256_PATTERN.fullmatch(import_record["sha256"]) is None
        or not isinstance(import_record["size_bytes"], int)
        or isinstance(import_record["size_bytes"], bool)
        or import_record["size_bytes"] <= 0
        or file_sha256(import_path) != import_record["sha256"]
        or import_path.stat().st_size != import_record["size_bytes"]
    ):
        raise SystemExit("trusted Windows bootstrap import audit changed after attestation")
    import_evidence = load_json_with_optional_bom(
        import_path,
        "trusted Windows bootstrap import evidence",
    )
    if set(import_evidence) != {"schema_version", "bootstrap_sha256", "dependencies"}:
        raise SystemExit("trusted Windows bootstrap import evidence has unknown fields")
    dependencies = import_evidence["dependencies"]
    if (
        import_evidence["schema_version"] != WINDOWS_BOOTSTRAP_IMPORT_SCHEMA
        or import_evidence["bootstrap_sha256"] != actual_sha256
        or not isinstance(dependencies, list)
        or not dependencies
        or any(
            not isinstance(dependency, str)
            or re.fullmatch(r"[A-Za-z0-9._-]+\.dll", dependency) is None
            for dependency in dependencies
        )
        or len(dependencies) != len({dependency.lower() for dependency in dependencies})
    ):
        raise SystemExit("trusted Windows bootstrap import evidence is invalid")
    if any(
        dependency.lower() not in APPROVED_WINDOWS_BOOTSTRAP_DEPENDENCIES
        and WINDOWS_API_SET_PATTERN.fullmatch(dependency) is None
        for dependency in dependencies
    ):
        raise SystemExit("trusted Windows bootstrap imports an unapproved DLL")


def validate_report_preflight(
    document,
    artifact_root,
    *,
    expected_supervisor_sha256,
    allow_unverified_windows,
    expected_bootstrap_path=None,
):
    """Run the one preflight contract for normal and skipped reports."""
    infrastructure = document.get("infrastructure")
    if not isinstance(infrastructure, dict):
        raise SystemExit("startup report has no infrastructure evidence")
    preflight_path = artifact_root / "sandbox-preflight.json"
    preflight = load_json_object(preflight_path, "sandbox preflight evidence")
    if (
        preflight.get("backend") != infrastructure.get("sandbox_backend")
        or preflight.get("policy") != infrastructure.get("sandbox_policy")
        or preflight.get("handshake") != infrastructure.get("sandbox_handshake")
        or preflight.get("cleanup") != infrastructure.get("sandbox_cleanup")
        or infrastructure.get("expected_supervisor_sha256")
        != expected_supervisor_sha256
        or infrastructure.get("expected_preflight_sha256")
        != infrastructure.get("preflight_sha256")
        or preflight.get("supervisor_sha256") != expected_supervisor_sha256
        or file_sha256(preflight_path) != infrastructure.get("preflight_sha256")
    ):
        raise SystemExit("startup report does not prove its sandbox preflight")
    try:
        status = validate_preflight_evidence(
            preflight,
            expected_supervisor_sha256=expected_supervisor_sha256,
            allow_unverified_windows=allow_unverified_windows,
        )
    except ValueError as error:
        raise SystemExit(f"startup report preflight is invalid: {error}") from error
    if preflight.get("backend") == SKIPPED_BACKEND:
        validate_windows_bootstrap_attestation(
            artifact_root,
            preflight,
            expected_trusted_sha=(
                document.get("trusted_sha")
                or infrastructure.get("trusted_sha")
            ),
            expected_bootstrap_path=expected_bootstrap_path,
        )
    return status


def require_nonempty_artifact(path, label):
    if path.is_symlink():
        raise SystemExit(f"{label} is a symlink: {path}")
    if path.is_file():
        if path.stat().st_size <= 0:
            raise SystemExit(f"{label} is empty: {path}")
        return
    if not path.is_dir():
        raise SystemExit(f"{label} is missing: {path}")
    files = []
    for entry in path.rglob("*"):
        if entry.is_symlink():
            raise SystemExit(f"{label} contains a symlink: {entry}")
        if entry.is_file() and entry.stat().st_size > 0:
            files.append(entry)
    if not files:
        raise SystemExit(f"{label} has no nonempty regular file: {path}")


def validate_raw_distributions(artifact_root):
    document = load_json_object(
        artifact_root / "startup-benchmark.json", "startup benchmark report"
    )
    if document.get("warmups") != 10 or document.get("paired_samples") != 50:
        raise SystemExit("startup report does not contain the fixed 10/50 pair counts")
    if document.get("order") != (
        "serial alternating baseline-first and candidate-first pairs"
    ):
        raise SystemExit("startup report does not prove serial alternating pairs")
    if document.get("infrastructure", {}).get("trusted_sha") != os.environ["TRUSTED_SHA"]:
        raise SystemExit("startup report has the wrong trusted SHA")
    if document.get("baseline", {}).get("observed_sha") != os.environ["BASELINE_SHA"]:
        raise SystemExit("startup report has the wrong baseline SHA")
    if document.get("candidate", {}).get("observed_sha") != os.environ["CANDIDATE_SHA"]:
        raise SystemExit("startup report has the wrong candidate SHA")
    scenarios = document.get("scenarios")
    expected_scenarios = ["cold", "warm", "headless", "restored", "incompatible"]
    if (
        not isinstance(scenarios, list)
        or len(scenarios) != len(expected_scenarios)
        or any(not isinstance(scenario, dict) for scenario in scenarios)
        or [scenario.get("scenario") for scenario in scenarios] != expected_scenarios
    ):
        raise SystemExit("startup report does not contain the five ordered scenarios")
    for scenario in scenarios:
        ordered = {}
        for target in ("baseline", "candidate"):
            sample_set = scenario.get(target)
            if not isinstance(sample_set, dict):
                raise SystemExit(f"{scenario['scenario']} has no {target} distribution")
            values = sample_set.get("ordered_ns")
            sorted_values = sample_set.get("sorted_ns")
            if (
                not isinstance(values, list)
                or len(values) != 50
                or any(
                    not isinstance(value, int) or isinstance(value, bool) or value <= 0
                    for value in values
                )
                or sorted_values != sorted(values)
            ):
                raise SystemExit(
                    f"{scenario['scenario']} has an invalid raw {target} distribution"
                )
            ordered[target] = values
        pairs = scenario.get("pairs")
        if not isinstance(pairs, list) or len(pairs) != 50:
            raise SystemExit(f"{scenario['scenario']} has no complete paired distribution")
        for index, pair in enumerate(pairs):
            baseline_ns = ordered["baseline"][index]
            candidate_ns = ordered["candidate"][index]
            expected = {
                "index": index,
                "first": "baseline" if index % 2 == 0 else "candidate",
                "baseline_ns": baseline_ns,
                "candidate_ns": candidate_ns,
                "candidate_minus_baseline_ns": candidate_ns - baseline_ns,
            }
            if pair != expected:
                raise SystemExit(
                    f"{scenario['scenario']} has an invalid serial pair at index {index}"
                )


def validate_skipped_report(document, artifact_root):
    require_exact_object(
        document,
        {
            "schema_version",
            "status",
            "skip_reason",
            "platform_label",
            "warmups",
            "paired_samples",
            "order",
            "trusted_sha",
            "baseline_sha",
            "candidate_sha",
            "infrastructure",
            "scenarios",
        },
        "skipped startup benchmark report",
    )
    reason = document["skip_reason"]
    if (
        document["schema_version"] != SKIPPED_REPORT_SCHEMA
        or document["status"] != "skipped"
        or document["platform_label"] != SKIPPED_PLATFORM
        or document["warmups"] != 10
        or document["paired_samples"] != 50
        or document["order"] != "serial alternating baseline-first and candidate-first pairs"
        or not isinstance(reason, str)
        or not reason.strip()
        or len(reason.encode("utf-8")) > 4096
        or document["scenarios"] != []
    ):
        raise SystemExit("skipped startup benchmark report has invalid status or identity")
    for key in ("trusted_sha", "baseline_sha", "candidate_sha"):
        require_full_sha(document[key], f"skipped report {key}")
    if document["trusted_sha"] != document["baseline_sha"]:
        raise SystemExit("skipped report trusted and baseline SHAs differ")
    if document["candidate_sha"] == document["baseline_sha"]:
        raise SystemExit("skipped report baseline and candidate SHAs must differ")
    infrastructure = document["infrastructure"]
    require_exact_object(
        infrastructure,
        {
            "trusted_sha",
            "sandbox_backend",
            "sandbox_policy",
            "sandbox_handshake",
            "sandbox_cleanup",
            "sandbox_claim_status",
            "sandbox_claim_reason",
            "expected_supervisor_sha256",
            "supervisor_sha256",
            "expected_preflight_sha256",
            "preflight_sha256",
        },
        "skipped startup infrastructure",
    )
    if (
        infrastructure["trusted_sha"] != document["trusted_sha"]
        or infrastructure["sandbox_backend"] != SKIPPED_BACKEND
        or infrastructure["sandbox_policy"] != "fixture-root-only-write"
        or infrastructure["sandbox_handshake"] != "nonce-bound-ready-arm-with-pre-exec-t0"
        or infrastructure["sandbox_cleanup"] != "descendant-channel-eof-after-process-tree-empty"
        or infrastructure["sandbox_claim_status"] != PREFLIGHT_STATUS_UNVERIFIED
        or infrastructure["sandbox_claim_reason"] != reason
        or not isinstance(infrastructure["expected_supervisor_sha256"], str)
        or FULL_SHA256_PATTERN.fullmatch(infrastructure["expected_supervisor_sha256"]) is None
        or infrastructure["supervisor_sha256"]
        != infrastructure["expected_supervisor_sha256"]
        or not isinstance(infrastructure["expected_preflight_sha256"], str)
        or FULL_SHA256_PATTERN.fullmatch(infrastructure["expected_preflight_sha256"]) is None
        or infrastructure["preflight_sha256"] != infrastructure["expected_preflight_sha256"]
    ):
        raise SystemExit("skipped startup infrastructure has invalid claim metadata")

    expected_platform = os.environ.get("PLATFORM_LABEL")
    if expected_platform is not None and expected_platform != document["platform_label"]:
        raise SystemExit("skipped report has the wrong platform label")
    for environment_name, field in (
        ("TRUSTED_SHA", "trusted_sha"),
        ("BASELINE_SHA", "baseline_sha"),
        ("CANDIDATE_SHA", "candidate_sha"),
    ):
        expected = os.environ.get(environment_name)
        if expected is not None and expected != document[field]:
            raise SystemExit(f"skipped report has the wrong {field}")
    for environment_name, field in (
        ("SUPERVISOR_BINARY_SHA256", "expected_supervisor_sha256"),
        ("SANDBOX_PREFLIGHT_SHA256", "expected_preflight_sha256"),
    ):
        expected = os.environ.get(environment_name)
        if expected is not None and expected != infrastructure[field]:
            raise SystemExit(f"skipped report has the wrong {field}")
    if os.environ.get("RUNNER_OS") not in (None, "Windows"):
        raise SystemExit("skipped startup report is only valid on Windows")

    appcontainer_status = validate_appcontainer_feasibility(
        artifact_root / "windows-appcontainer-feasibility.json",
        allow_unavailable=True,
    )
    if appcontainer_status != "unavailable":
        raise SystemExit("skipped report must contain unavailable AppContainer evidence")

    claim_status = validate_report_preflight(
        document,
        artifact_root,
        expected_supervisor_sha256=infrastructure["supervisor_sha256"],
        allow_unverified_windows=True,
    )
    if claim_status == PREFLIGHT_STATUS_VERIFIED:
        if not reason.startswith(
            "Windows AppContainer staging-readability capability was unavailable"
        ):
            raise SystemExit(
                "a skipped report with verified common preflight needs an AppContainer skip reason"
            )
    elif claim_status != PREFLIGHT_STATUS_UNVERIFIED:
        raise SystemExit("skipped report must contain unavailable Windows observations")

    markdown_path = artifact_root / "startup-benchmark.md"
    markdown = markdown_path.read_text(encoding="utf-8")
    if "Status: skipped (unverified)" not in markdown or reason not in markdown:
        raise SystemExit("skipped startup markdown does not state the claim reason")

    lifecycle = load_json_object(artifact_root / "startup-lifecycle.json", "startup lifecycle")
    require_exact_object(
        lifecycle,
        {
            "schema_version",
            "status",
            "reason",
            "fixture_parent_name",
            "report_written_before_reclamation",
            "deferred_roots",
            "pairs",
            "fixtures",
            "profiles",
        },
        "skipped startup lifecycle",
    )
    if (
        lifecycle["schema_version"] != 1
        or lifecycle["status"] != "skipped"
        or lifecycle["reason"] != reason
        or not isinstance(lifecycle["fixture_parent_name"], str)
        or not lifecycle["fixture_parent_name"]
        or lifecycle["report_written_before_reclamation"] is not True
        or lifecycle["deferred_roots"] != []
        or lifecycle["pairs"] != []
        or lifecycle["fixtures"] != []
        or lifecycle["profiles"] != []
    ):
        raise SystemExit("skipped startup lifecycle is invalid")

    attribution = load_json_object(
        artifact_root / "profile-attribution.json", "profile attribution"
    )
    require_exact_object(
        attribution,
        {"schema_version", "purpose", "status", "reason", "targets"},
        "skipped profile attribution",
    )
    if (
        attribution["schema_version"] != 1
        or attribution["purpose"] != "offline attribution of native cmux-tui startup profiles"
        or attribution["status"] != "skipped"
        or attribution["reason"] != reason
        or attribution["targets"] != {}
    ):
        raise SystemExit("skipped profile attribution is invalid")


def validate_harness_test_evidence(artifact_root):
    evidence = load_json_object(
        artifact_root / "harness-tests.json", "harness test evidence"
    )
    require_exact_object(
        evidence,
        {
            "schema_version",
            "target",
            "platform_label",
            "trusted_sha",
            "selected_count",
            "names",
        },
        "harness test evidence",
    )
    names = evidence["names"]
    count = evidence["selected_count"]
    if (
        evidence["schema_version"] != 1
        or evidence["target"] != "cmux-tui example startup_benchmark"
        or evidence["platform_label"] != os.environ["PLATFORM_LABEL"]
        or evidence["trusted_sha"] != os.environ["TRUSTED_SHA"]
        or not isinstance(count, int)
        or isinstance(count, bool)
        or count <= 0
        or not isinstance(names, list)
        or count != len(names)
        or any(not isinstance(name, str) or not name for name in names)
        or len(names) != len(set(names))
    ):
        raise SystemExit("harness test evidence has an invalid named test count")


def validate_profile_report(profile_root, target):
    report = load_json_object(
        profile_root / f"startup-profile-{target}-cold.json",
        f"{target} native profile report",
    )
    binary = report.get("binary")
    infrastructure = report.get("infrastructure")
    expected_sha = os.environ["BASELINE_SHA" if target == "baseline" else "CANDIDATE_SHA"]
    if (
        report.get("schema_version") != 3
        or report.get("platform_label") != os.environ["PLATFORM_LABEL"]
        or report.get("target") != target
        or report.get("scenario") != "cold"
        or not isinstance(report.get("duration_ns"), int)
        or isinstance(report.get("duration_ns"), bool)
        or report["duration_ns"] <= 0
        or not isinstance(binary, dict)
        or binary.get("kind") != target
        or binary.get("requested_sha") != expected_sha
        or binary.get("observed_sha") != expected_sha
        or not isinstance(infrastructure, dict)
        or infrastructure.get("trusted_sha") != os.environ["TRUSTED_SHA"]
    ):
        raise SystemExit(f"{target} native profile report has the wrong identity")
    require_full_sha(binary.get("requested_sha"), f"{target} profile requested SHA")
    require_full_sha(binary.get("observed_sha"), f"{target} profile observed SHA")
    require_full_sha(binary.get("ghostty_sha"), f"{target} profile Ghostty SHA")
    require_full_sha(
        infrastructure.get("trusted_sha"), f"{target} profile trusted SHA"
    )


def validate_required_native_profiles(artifact_root):
    runner_os = os.environ["RUNNER_OS"]
    if runner_os == "macOS":
        profile_root = artifact_root / "profiles" / "time-profiler"
        for target in ("baseline", "candidate"):
            validate_profile_report(profile_root, target)
            require_nonempty_artifact(
                profile_root / f"{target}.trace", f"{target} macOS Time Profiler trace"
            )
    elif runner_os == "Linux":
        profile_root = artifact_root / "profiles" / "strace"
        for target in ("baseline", "candidate"):
            validate_profile_report(profile_root, target)
            require_nonempty_artifact(
                profile_root / f"{target}-summary.txt", f"{target} Linux strace summary"
            )
    elif runner_os == "Windows":
        profile_root = artifact_root / "profiles" / "wpr"
        for target in ("baseline", "candidate"):
            validate_profile_report(profile_root, target)
            require_nonempty_artifact(
                profile_root / f"{target}.etl", f"{target} Windows WPR trace"
            )
    else:
        raise SystemExit(f"unsupported profile runner OS: {runner_os!r}")


def collect_artifact_records(artifact_root):
    records = {}
    for path in sorted(artifact_root.rglob("*")):
        relative = path.relative_to(artifact_root).as_posix()
        if path.is_symlink():
            raise SystemExit(f"startup artifact contains a symlink: {relative}")
        if path.is_file():
            if relative == ARTIFACT_MANIFEST_NAME:
                continue
            records[relative] = {
                "path": relative,
                "sha256": file_sha256(path),
                "size_bytes": path.stat().st_size,
            }
        elif not path.is_dir():
            raise SystemExit(f"startup artifact contains an unsafe entry: {relative}")
    if not records or len(records) > 100_000:
        raise SystemExit(f"startup artifact has an invalid file count: {len(records)}")
    return records


def validate_artifact_manifest(artifact_root):
    manifest = load_json_object(
        artifact_root / ARTIFACT_MANIFEST_NAME, "startup artifact manifest"
    )
    require_exact_object(
        manifest,
        {
            "schema_version",
            "purpose",
            "platform_label",
            "trusted_sha",
            "baseline_sha",
            "candidate_sha",
            "files",
        },
        "startup artifact manifest",
    )
    for key in ("trusted_sha", "baseline_sha", "candidate_sha"):
        require_full_sha(manifest[key], f"artifact manifest {key}")
        if manifest[key] != os.environ[key.upper()]:
            raise SystemExit(f"startup artifact manifest has the wrong {key}")
    if manifest["trusted_sha"] != manifest["baseline_sha"]:
        raise SystemExit("artifact manifest trusted and baseline SHAs differ")
    files = manifest["files"]
    if (
        manifest["schema_version"] != 1
        or manifest["purpose"] != "closed cmux-tui startup benchmark evidence"
        or manifest["platform_label"] != os.environ["PLATFORM_LABEL"]
        or not isinstance(files, list)
    ):
        raise SystemExit("startup artifact manifest metadata is invalid")
    listed = {}
    for record in files:
        if not isinstance(record, dict) or set(record) != {"path", "sha256", "size_bytes"}:
            raise SystemExit(f"startup artifact manifest has an invalid record: {record!r}")
        record_path = record["path"]
        if not isinstance(record_path, str):
            raise SystemExit(f"startup artifact manifest path is invalid: {record!r}")
        relative = pathlib.PurePosixPath(record_path)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() != record_path
            or record_path == ARTIFACT_MANIFEST_NAME
            or record_path in listed
            or not isinstance(record["sha256"], str)
            or re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is None
            or not isinstance(record["size_bytes"], int)
            or isinstance(record["size_bytes"], bool)
            or record["size_bytes"] < 0
        ):
            raise SystemExit(f"startup artifact manifest record is unsafe: {record!r}")
        listed[record_path] = record
    actual = collect_artifact_records(artifact_root)
    if listed != actual:
        missing = sorted(set(listed) - set(actual))
        extra = sorted(set(actual) - set(listed))
        changed = sorted(
            name for name in set(listed) & set(actual) if listed[name] != actual[name]
        )
        raise SystemExit(
            f"startup artifact is not closed: missing={missing}, extra={extra}, changed={changed}"
        )


def close_artifact(artifact_root):
    if artifact_root.is_symlink() or not artifact_root.is_dir():
        raise SystemExit(f"artifact root is not a regular directory: {artifact_root}")
    for identity in ("TRUSTED_SHA", "BASELINE_SHA", "CANDIDATE_SHA"):
        require_full_sha(os.environ[identity], identity)
    if os.environ["TRUSTED_SHA"] != os.environ["BASELINE_SHA"]:
        raise SystemExit("trusted_sha and baseline_sha must be identical")
    for required in (
        "startup-benchmark.md",
        "startup-lifecycle.json",
        "candidate-product-manifest.json",
        "candidate-product-validation.json",
        "profile-attribution.json",
        "sandbox-preflight.json",
        "startup-integrity-before.json",
        "startup-integrity-final.json",
        "runner-context.txt",
        "runner-hardware.json",
        "runner-os.txt",
    ):
        require_nonempty_artifact(artifact_root / required, required)
    report = load_json_object(artifact_root / "startup-benchmark.json", "startup benchmark report")
    skipped = report.get("status") == "skipped"
    if skipped:
        validate_skipped_report(report, artifact_root)
    else:
        validate_raw_distributions(artifact_root)
        infrastructure = report.get("infrastructure")
        if not isinstance(infrastructure, dict):
            raise SystemExit("startup report has no infrastructure evidence")
        status = validate_report_preflight(
            report,
            artifact_root,
            expected_supervisor_sha256=infrastructure.get("supervisor_sha256"),
            allow_unverified_windows=False,
            expected_bootstrap_path=(
                infrastructure.get("windows_bootstrap_binary")
                if os.environ.get("RUNNER_OS") == "Windows"
                else None
            ),
        )
        if status != PREFLIGHT_STATUS_VERIFIED:
            raise SystemExit("normal startup report cannot be unverified")
    validate_harness_test_evidence(artifact_root)
    if not skipped:
        validate_required_native_profiles(artifact_root)
    records = collect_artifact_records(artifact_root)
    manifest = {
        "schema_version": 1,
        "purpose": "closed cmux-tui startup benchmark evidence",
        "platform_label": os.environ["PLATFORM_LABEL"],
        "trusted_sha": os.environ["TRUSTED_SHA"],
        "baseline_sha": os.environ["BASELINE_SHA"],
        "candidate_sha": os.environ["CANDIDATE_SHA"],
        "files": [records[name] for name in sorted(records)],
    }
    output = artifact_root / ARTIFACT_MANIFEST_NAME
    with output.open("x", encoding="utf-8") as destination:
        json.dump(manifest, destination, indent=2, sort_keys=True)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())
    validate_artifact_manifest(artifact_root)


def validate_appcontainer_feasibility_unavailable(evidence):
    require_exact_object(
        evidence,
        APP_CONTAINER_UNAVAILABLE_FIELDS,
        "AppContainer unavailable evidence",
    )
    nonce = evidence["nonce"]
    reason = evidence["reason"]
    if (
        evidence["schema_version"] != APP_CONTAINER_UNAVAILABLE_SCHEMA_VERSION
        or evidence["status"] != "unavailable"
        or evidence["backend"] != "windows-appcontainer-feasibility"
        or not isinstance(nonce, str)
        or re.fullmatch(r"[0-9a-f]{64}", nonce) is None
        or evidence["stage"] != "staging-readability"
        or not isinstance(reason, str)
        or not reason.startswith(
            "dedicated Windows account could not read the nonce-bound staged target before the restricted-token broker started"
        )
        or len(reason.encode("utf-8")) > 4096
    ):
        raise SystemExit("AppContainer unavailable identity is invalid")
    for field in (
        "runner_staged_target_sha256",
        "expected_staged_target_sha256",
        "preexisting_parent_before_sha256",
        "preexisting_parent_after_sha256",
    ):
        if (
            not isinstance(evidence[field], str)
            or FULL_SHA256_PATTERN.fullmatch(evidence[field]) is None
        ):
            raise SystemExit(f"AppContainer unavailable {field} is invalid")
    if (
        evidence["runner_staged_target_sha256"]
        != evidence["expected_staged_target_sha256"]
        or evidence["preexisting_parent_before_sha256"]
        != evidence["preexisting_parent_after_sha256"]
    ):
        raise SystemExit("AppContainer unavailable hashes do not match")
    for field in (
        "runner_staged_target_readable",
        "staging_creation_acl_applied",
        "fixture_creation_acl_applied",
        "staged_target_regular_file",
        "account_probe_impersonated",
        "profile_deleted",
        "account_profile_unloaded",
        "adjacent_sentinel_deleted",
        "staging_directory_deleted",
        "fixture_directory_deleted",
        "preexisting_parent_unchanged",
    ):
        if evidence[field] is not True:
            raise SystemExit(f"AppContainer unavailable proof is false: {field}")
    if evidence["account_probe_kind"] not in {
        "impersonated-account",
        "account-process",
    }:
        raise SystemExit("AppContainer unavailable probe kind is invalid")
    if (
        not isinstance(evidence["account_sid"], str)
        or APP_CONTAINER_SID_PATTERN.fullmatch(evidence["account_sid"]) is None
        or not isinstance(evidence["account_authentication_id"], str)
        or re.fullmatch(r"[0-9a-f]{16}", evidence["account_authentication_id"]) is None
    ):
        raise SystemExit("AppContainer unavailable account identity is invalid")
    process_target = evidence["account_process_target"]
    process_hash = evidence["account_process_target_sha256"]
    process_started = evidence["account_process_probe_started"]
    if evidence["account_probe_kind"] == "account-process":
        normalized_target = process_target.replace("/", "\\") if isinstance(process_target, str) else ""
        target_parts = [part for part in normalized_target.split("\\") if part]
        expected_stage = f"appcontainer-stage-{nonce[:16]}"
        if (
            not isinstance(process_target, str)
            or not process_target.endswith(
                "startup-benchmark-appcontainer-probe.exe"
            )
            or len(target_parts) < 2
            or target_parts[-2] != expected_stage
            or not isinstance(process_hash, str)
            or FULL_SHA256_PATTERN.fullmatch(process_hash) is None
            or process_hash != evidence["runner_staged_target_sha256"]
            or process_started is not True
        ):
            raise SystemExit("AppContainer unavailable account-process proof is invalid")
    elif process_target != "" or process_hash != "" or process_started is not False:
        raise SystemExit("AppContainer unavailable impersonation proof is invalid")
    if (
        evidence["account_staged_target_readable"] is not False
        or evidence["restricted_token_run_started"] is not False
        or not isinstance(evidence["account_staged_target_error_code"], int)
        or isinstance(evidence["account_staged_target_error_code"], bool)
        or evidence["account_staged_target_error_code"] != 5
    ):
        raise SystemExit("AppContainer unavailable account probe is not an exact access denial")


def validate_appcontainer_feasibility(path, *, allow_unavailable=False):
    evidence = load_json_object(path, "AppContainer feasibility evidence")
    if evidence.get("status") == "unavailable":
        if not allow_unavailable:
            raise SystemExit("AppContainer unavailable evidence is not valid for a verified claim")
        validate_appcontainer_feasibility_unavailable(evidence)
        return "unavailable"
    require_exact_object(
        evidence,
        {
            "schema_version",
            "backend",
            "nonce",
            "profile_name",
            "appcontainer_sid",
            "account_sid",
            "profile_user_sid_matches_account",
            "no_capabilities",
            "broker",
            "profile_folder_owned_state",
            "registry_owned_state",
            "profile_delete_succeeded",
            "sid_derived_after_delete_matches",
            "profile_folder_absent_after_delete",
            "registry_store_delete_contract",
            "network_isolation_entry_absent_after_delete",
            "staged_probe_sha256",
            "staging_creation_acl_applied",
            "fixture_creation_acl_applied",
            "staging_directory_deleted",
            "fixture_directory_deleted",
            "preexisting_parent_path",
            "preexisting_parent_before_sha256",
            "preexisting_parent_after_sha256",
            "preexisting_parent_unchanged",
        },
        "AppContainer feasibility evidence",
    )
    nonce = evidence["nonce"]
    if (
        evidence["schema_version"] != 4
        or evidence["backend"] != "windows-appcontainer-feasibility"
        or not isinstance(nonce, str)
        or re.fullmatch(r"[0-9a-f]{64}", nonce) is None
        or evidence["profile_name"] != f"cmux.bench.ac.{nonce[:32]}"
    ):
        raise SystemExit("AppContainer feasibility identity is invalid")
    sid_pattern = re.compile(r"S-1(?:-\d+)+")
    appcontainer_sid = evidence["appcontainer_sid"]
    account_sid = evidence["account_sid"]
    if (
        not isinstance(appcontainer_sid, str)
        or sid_pattern.fullmatch(appcontainer_sid) is None
        or not isinstance(account_sid, str)
        or sid_pattern.fullmatch(account_sid) is None
        or appcontainer_sid == account_sid
    ):
        raise SystemExit("AppContainer feasibility SIDs are invalid")
    require_true_fields(
        evidence,
        {
            "profile_user_sid_matches_account",
            "no_capabilities",
            "profile_folder_owned_state",
            "registry_owned_state",
            "profile_delete_succeeded",
            "sid_derived_after_delete_matches",
            "profile_folder_absent_after_delete",
            "registry_store_delete_contract",
            "network_isolation_entry_absent_after_delete",
            "staging_creation_acl_applied",
            "fixture_creation_acl_applied",
            "staging_directory_deleted",
            "fixture_directory_deleted",
            "preexisting_parent_unchanged",
        },
        "AppContainer feasibility cleanup",
    )

    broker = evidence["broker"]
    require_exact_object(
        broker,
        {
            "schema_version",
            "nonce",
            "appcontainer_sid",
            "pre_launch_token",
            "suspended_product_token",
            "product",
            "launch_api",
            "create_process_w_succeeded",
            "broker_staging_write_denied",
            "broker_staged_probe_write_denied",
            "explicit_three_handle_list",
            "security_capabilities_applied",
            "product_exact_job_before_resume",
            "product_resume_previous_count",
            "product_process_id",
            "product_primary_thread_id",
            "descendant_observed_in_job",
            "active_process_zero",
        },
        "AppContainer broker evidence",
    )
    if (
        broker["schema_version"] != 4
        or broker["nonce"] != nonce
        or broker["appcontainer_sid"] != appcontainer_sid
        or broker["launch_api"] != "CreateProcessW+SECURITY_CAPABILITIES"
        or broker["product_resume_previous_count"] != 1
        or not isinstance(broker["product_process_id"], int)
        or isinstance(broker["product_process_id"], bool)
        or broker["product_process_id"] <= 0
        or not isinstance(broker["product_primary_thread_id"], int)
        or isinstance(broker["product_primary_thread_id"], bool)
        or broker["product_primary_thread_id"] <= 0
    ):
        raise SystemExit("AppContainer broker identity is invalid")
    require_true_fields(
        broker,
        {
            "create_process_w_succeeded",
            "broker_staging_write_denied",
            "broker_staged_probe_write_denied",
            "explicit_three_handle_list",
            "security_capabilities_applied",
            "product_exact_job_before_resume",
            "descendant_observed_in_job",
            "active_process_zero",
        },
        "AppContainer broker containment",
    )

    pre_launch_token = broker["pre_launch_token"]
    require_exact_object(
        pre_launch_token,
        {
            "non_appcontainer",
            "restricting_sid_count_zero",
            "enabled_privilege_count",
            "se_change_notify_enabled",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer pre-launch token evidence",
    )
    if (
        not isinstance(pre_launch_token["enabled_privilege_count"], int)
        or isinstance(pre_launch_token["enabled_privilege_count"], bool)
        or pre_launch_token["enabled_privilege_count"] != 1
    ):
        raise SystemExit("AppContainer pre-launch token privilege count is invalid")
    require_true_fields(
        pre_launch_token,
        {
            "non_appcontainer",
            "restricting_sid_count_zero",
            "se_change_notify_enabled",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer pre-launch token isolation",
    )

    suspended_product_token = broker["suspended_product_token"]
    require_exact_object(
        suspended_product_token,
        {
            "token_is_appcontainer",
            "appcontainer_sid_match",
            "restricting_sid_count_zero",
            "capability_count_zero",
            "low_integrity",
            "enabled_privilege_count",
            "se_change_notify_enabled",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer suspended-product token evidence",
    )
    if (
        not isinstance(suspended_product_token["enabled_privilege_count"], int)
        or isinstance(suspended_product_token["enabled_privilege_count"], bool)
        or suspended_product_token["enabled_privilege_count"] != 1
    ):
        raise SystemExit("AppContainer suspended-product token privilege count is invalid")
    require_true_fields(
        suspended_product_token,
        {
            "token_is_appcontainer",
            "appcontainer_sid_match",
            "restricting_sid_count_zero",
            "capability_count_zero",
            "low_integrity",
            "se_change_notify_enabled",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer suspended-product token isolation",
    )

    product = broker["product"]
    require_exact_object(
        product,
        {
            "schema_version",
            "nonce",
            "entry_reached",
            "fixture_write",
            "staging_write_denied",
            "staged_probe_write_denied",
            "adjacent_write_denied",
            "profile_owned_write",
            "registry_owned_write",
            "outbound_network_denied",
            "inbound_network_denied",
            "inbound_bound_address",
            "descendant_ready",
            "token_is_appcontainer",
            "appcontainer_sid_match",
            "restricting_sid_count_zero",
            "capability_count_zero",
            "low_integrity",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer product evidence",
    )
    if product["schema_version"] != 4 or product["nonce"] != nonce:
        raise SystemExit("AppContainer product identity is invalid")
    require_true_fields(
        product,
        {
            "entry_reached",
            "fixture_write",
            "staging_write_denied",
            "staged_probe_write_denied",
            "adjacent_write_denied",
            "profile_owned_write",
            "registry_owned_write",
            "outbound_network_denied",
            "inbound_network_denied",
            "descendant_ready",
            "token_is_appcontainer",
            "appcontainer_sid_match",
            "restricting_sid_count_zero",
            "capability_count_zero",
            "low_integrity",
            "traverse_privilege_only",
            "account_authentication_match",
        },
        "AppContainer product isolation",
    )
    inbound_address = product["inbound_bound_address"]
    if inbound_address is not None:
        if not isinstance(inbound_address, str):
            raise SystemExit("AppContainer inbound address is not a string")
        match = re.fullmatch(r"(?:\[([^]]+)\]|([^:]+)):(\d{1,5})", inbound_address)
        if match is None:
            raise SystemExit("AppContainer inbound address is malformed")
        address = ipaddress.ip_address(match.group(1) or match.group(2))
        port = int(match.group(3))
        if (
            not 1 <= port <= 65535
            or address.is_loopback
            or address.is_unspecified
            or address.is_multicast
        ):
            raise SystemExit("AppContainer inbound address is not a private probe endpoint")

    staged_probe_sha256 = evidence["staged_probe_sha256"]
    parent_path = evidence["preexisting_parent_path"]
    parent_before = evidence["preexisting_parent_before_sha256"]
    parent_after = evidence["preexisting_parent_after_sha256"]
    if (
        not isinstance(staged_probe_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", staged_probe_sha256) is None
        or not isinstance(parent_path, str)
        or not parent_path
        or f"appcontainer-stage-{nonce[:16]}" in parent_path
        or f"appcontainer-fixture-{nonce[:16]}" in parent_path
        or not isinstance(parent_before, str)
        or re.fullmatch(r"[0-9a-f]{64}", parent_before) is None
        or parent_after != parent_before
    ):
        raise SystemExit("AppContainer nonce-owned path cleanup evidence is invalid")
    return "verified"


def validate_appcontainer_feasibility_failure(path):
    evidence = json.loads(path.read_text(encoding="utf-8"))
    require_exact_object(
        evidence,
        {
            "schema_version",
            "nonce",
            "stage",
            "error",
            "account_sid",
            "account_authentication_id",
            "target",
            "target_sha256",
            "restricted_token_run_started",
        },
        "AppContainer feasibility failure evidence",
    )
    nonce = evidence["nonce"]
    error = evidence["error"]
    if (
        evidence["schema_version"] != 4
        or not isinstance(nonce, str)
        or re.fullmatch(r"[0-9a-f]{64}", nonce) is None
        or evidence["stage"]
        not in {
            "config-receive",
            "staging-readability",
            "config-validate",
            "product-launch",
            "success-evidence-encode",
            "success-evidence-write",
        }
        or not isinstance(error, str)
        or not error
        or len(error.encode("utf-8")) > 4096
    ):
        raise SystemExit("AppContainer feasibility failure evidence is invalid")
    process_fields = (
        evidence["account_sid"],
        evidence["account_authentication_id"],
        evidence["target"],
        evidence["target_sha256"],
        evidence["restricted_token_run_started"],
    )
    if evidence["stage"] == "staging-readability":
        account_sid, authentication_id, target, target_sha256, restricted_started = process_fields
        if (
            not isinstance(account_sid, str)
            or APP_CONTAINER_SID_PATTERN.fullmatch(account_sid) is None
            or not isinstance(authentication_id, str)
            or re.fullmatch(r"[0-9a-f]{16}", authentication_id) is None
            or not isinstance(target, str)
            or not target.endswith("startup-benchmark-appcontainer-probe.exe")
            or not isinstance(target_sha256, str)
            or FULL_SHA256_PATTERN.fullmatch(target_sha256) is None
            or restricted_started is not False
        ):
            raise SystemExit("AppContainer staging-readability identity is invalid")
    elif any(value is not None for value in process_fields):
        raise SystemExit("AppContainer feasibility failure has unexpected process fields")


if len(sys.argv) == 3 and sys.argv[1] == "--appcontainer-feasibility":
    validate_appcontainer_feasibility(pathlib.Path(sys.argv[2]), allow_unavailable=True)
    raise SystemExit(0)
if len(sys.argv) == 3 and sys.argv[1] == "--appcontainer-feasibility-failure":
    validate_appcontainer_feasibility_failure(pathlib.Path(sys.argv[2]))
    raise SystemExit(0)
if len(sys.argv) == 3 and sys.argv[1] == "--close-artifact":
    close_artifact(pathlib.Path(sys.argv[2]))
    raise SystemExit(0)
if len(sys.argv) == 3 and sys.argv[1] == "--verify-artifact-manifest":
    validate_artifact_manifest(pathlib.Path(sys.argv[2]))
    raise SystemExit(0)
if len(sys.argv) != 2:
    raise SystemExit(
        "usage: verify-startup-benchmark.py "
        "[--appcontainer-feasibility|--appcontainer-feasibility-failure|"
        "--close-artifact|--verify-artifact-manifest] <path>"
    )

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
if isinstance(document, dict) and document.get("status") == "skipped":
    validate_skipped_report(document, path.parent)
    raise SystemExit(0)
expected_warmups = int(os.environ["WARMUPS"])
expected_samples = int(os.environ["SAMPLES"])
if expected_warmups != 10 or expected_samples != 50:
    raise SystemExit(
        "startup evidence requires exactly 10 warmup pairs and 50 measured pairs"
    )
for identity in ("TRUSTED_SHA", "BASELINE_SHA", "CANDIDATE_SHA"):
    require_full_sha(os.environ[identity], identity)
if os.environ["TRUSTED_SHA"] != os.environ["BASELINE_SHA"]:
    raise SystemExit("trusted_sha and baseline_sha must be identical")

required = {
    "infrastructure.trusted_sha": str,
    "infrastructure.sandbox_backend": str,
    "infrastructure.sandbox_policy": str,
    "infrastructure.sandbox_handshake": str,
    "infrastructure.sandbox_cleanup": str,
    "infrastructure.expected_supervisor_sha256": str,
    "infrastructure.supervisor_sha256": str,
    "infrastructure.expected_preflight_sha256": str,
    "infrastructure.preflight_sha256": str,
    "host.cpu": str,
    "host.logical_processors": int,
    "host.physical_cores": int,
    "host.memory_bytes": int,
    "host.kernel": str,
    "host.rustc": str,
    "host.cargo": str,
    "host.zig": str,
    "baseline.observed_sha": str,
    "baseline.requested_sha": str,
    "baseline.ghostty_sha": str,
    "baseline.zig_version": str,
    "baseline.rust_toolchain": str,
    "baseline.expected_binary_sha256": str,
    "baseline.binary_sha256": str,
    "candidate.observed_sha": str,
    "candidate.requested_sha": str,
    "candidate.ghostty_sha": str,
    "candidate.zig_version": str,
    "candidate.rust_toolchain": str,
    "candidate.expected_binary_sha256": str,
    "candidate.binary_sha256": str,
}

def get(dotted):
    value = document
    for component in dotted.split("."):
        if not isinstance(value, dict) or component not in value:
            raise SystemExit(f"benchmark evidence is missing {dotted}")
        value = value[component]
    return value

for dotted, expected_type in required.items():
    value = get(dotted)
    if not isinstance(value, expected_type) or isinstance(value, bool) or value == 0:
        raise SystemExit(f"benchmark evidence has invalid {dotted}: {value!r}")
    if isinstance(value, str) and value.strip().lower() in {
        "",
        "n/a",
        "none",
        "null",
        "unavailable",
        "unknown",
    }:
        raise SystemExit(f"benchmark evidence has sentinel {dotted}: {value!r}")

expected = {
    "infrastructure.trusted_sha": os.environ["TRUSTED_SHA"],
    "infrastructure.sandbox_backend": os.environ["SANDBOX_BACKEND"],
    "infrastructure.expected_supervisor_sha256": os.environ[
        "SUPERVISOR_BINARY_SHA256"
    ],
    "infrastructure.expected_preflight_sha256": os.environ[
        "SANDBOX_PREFLIGHT_SHA256"
    ],
    "baseline.requested_sha": os.environ["BASELINE_SHA"],
    "baseline.observed_sha": os.environ["BASELINE_SHA"],
    "candidate.requested_sha": os.environ["CANDIDATE_SHA"],
    "candidate.observed_sha": os.environ["CANDIDATE_SHA"],
    "baseline.ghostty_sha": os.environ["EXPECTED_BASELINE_GHOSTTY"],
    "candidate.ghostty_sha": os.environ["EXPECTED_CANDIDATE_GHOSTTY"],
    "baseline.zig_version": os.environ["BASELINE_ZIG_VERSION"],
    "candidate.zig_version": os.environ["CANDIDATE_ZIG_VERSION"],
    "baseline.rust_toolchain": os.environ["BASELINE_RUST_TOOLCHAIN"],
    "candidate.rust_toolchain": os.environ["CANDIDATE_RUST_TOOLCHAIN"],
    "baseline.expected_binary_sha256": os.environ["BASELINE_BINARY_SHA256"],
    "candidate.expected_binary_sha256": os.environ["CANDIDATE_BINARY_SHA256"],
}
for dotted, expected_value in expected.items():
    actual = get(dotted)
    if actual != expected_value:
        raise SystemExit(
            f"benchmark evidence {dotted} is {actual!r}, expected {expected_value!r}"
        )
for dotted in (
    "infrastructure.trusted_sha",
    "baseline.requested_sha",
    "baseline.observed_sha",
    "baseline.ghostty_sha",
    "candidate.requested_sha",
    "candidate.observed_sha",
    "candidate.ghostty_sha",
):
    require_full_sha(get(dotted), dotted)
for dotted in (
    "infrastructure.expected_supervisor_sha256",
    "infrastructure.supervisor_sha256",
    "infrastructure.expected_preflight_sha256",
    "infrastructure.preflight_sha256",
    "baseline.expected_binary_sha256",
    "baseline.binary_sha256",
    "candidate.expected_binary_sha256",
    "candidate.binary_sha256",
):
    value = get(dotted)
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise SystemExit(f"benchmark evidence has invalid {dotted}: {value!r}")
for target in ("baseline", "candidate"):
    if get(f"{target}.binary_sha256") != get(f"{target}.expected_binary_sha256"):
        raise SystemExit(f"{target} binary changed after exact build attestation")
if get("infrastructure.supervisor_sha256") != get(
    "infrastructure.expected_supervisor_sha256"
):
    raise SystemExit("trusted supervisor changed after exact build attestation")
if get("infrastructure.preflight_sha256") != get(
    "infrastructure.expected_preflight_sha256"
):
    raise SystemExit("sandbox preflight evidence changed after attestation")
appcontainer_feasibility_path = path.parent / "windows-appcontainer-feasibility.json"
if os.environ["RUNNER_OS"] == "Windows":
    validate_appcontainer_feasibility(appcontainer_feasibility_path)
elif appcontainer_feasibility_path.exists():
    raise SystemExit("non-Windows evidence contains an AppContainer feasibility record")
expected_bootstrap_path = (
    get(WINDOWS_BOOTSTRAP_REPORT_FIELDS[0])
    if os.environ["RUNNER_OS"] == "Windows"
    else None
)
preflight_status = validate_report_preflight(
    document,
    path.parent,
    expected_supervisor_sha256=get("infrastructure.supervisor_sha256"),
    allow_unverified_windows=False,
    expected_bootstrap_path=expected_bootstrap_path,
)
if preflight_status != PREFLIGHT_STATUS_VERIFIED:
    raise SystemExit("normal startup evidence cannot be unverified")
if os.environ["RUNNER_OS"] == "Windows":
    bootstrap_binary = get(WINDOWS_BOOTSTRAP_REPORT_FIELDS[0])
    expected_bootstrap_sha256 = get(WINDOWS_BOOTSTRAP_REPORT_FIELDS[1])
    bootstrap_sha256 = get(WINDOWS_BOOTSTRAP_REPORT_FIELDS[2])
    bootstrap_bytes = get(WINDOWS_BOOTSTRAP_REPORT_FIELDS[3])
    if (
        not isinstance(bootstrap_binary, str)
        or not bootstrap_binary
        or not isinstance(expected_bootstrap_sha256, str)
        or FULL_SHA256_PATTERN.fullmatch(expected_bootstrap_sha256) is None
        or expected_bootstrap_sha256 != os.environ["WINDOWS_BOOTSTRAP_SHA256"]
        or bootstrap_sha256 != expected_bootstrap_sha256
        or not isinstance(bootstrap_bytes, int)
        or isinstance(bootstrap_bytes, bool)
        or bootstrap_bytes <= 0
    ):
        raise SystemExit("benchmark evidence has invalid Windows bootstrap identity")
    preflight = load_json_object(path.parent / "sandbox-preflight.json", "sandbox preflight evidence")
    if preflight.get("windows_bootstrap_sha256") != bootstrap_sha256:
        raise SystemExit("sandbox preflight and report identify different bootstraps")
    validate_windows_bootstrap_attestation(path.parent, preflight)
else:
    for dotted in WINDOWS_BOOTSTRAP_REPORT_FIELDS:
        if get(dotted) is not None:
            raise SystemExit("non-Windows evidence contains Windows bootstrap identity")
expected_sandbox_contract = {
    "infrastructure.sandbox_policy": "fixture-root-only-write",
    "infrastructure.sandbox_handshake": "nonce-bound-ready-arm-with-pre-exec-t0",
    "infrastructure.sandbox_cleanup": "descendant-channel-eof-after-process-tree-empty",
}
for dotted, expected_value in expected_sandbox_contract.items():
    if get(dotted) != expected_value:
        raise SystemExit(f"wrong sandbox contract for {dotted}: {get(dotted)!r}")
if not isinstance(get("baseline.embedded_identity_verified"), bool):
    raise SystemExit("baseline embedded identity result is not a boolean")
if get("candidate.embedded_identity_verified") is not True:
    raise SystemExit("candidate embedded source identity was not verified")

if document.get("schema_version") != 3:
    raise SystemExit(f"unsupported benchmark schema: {document.get('schema_version')!r}")
if document.get("platform_label") != os.environ["PLATFORM_LABEL"]:
    raise SystemExit(f"wrong platform label: {document.get('platform_label')!r}")
if document.get("warmups") != expected_warmups:
    raise SystemExit(f"wrong warmup count: {document.get('warmups')!r}")
if document.get("paired_samples") != expected_samples:
    raise SystemExit(f"wrong paired sample count: {document.get('paired_samples')!r}")
if document.get("order") != "serial alternating baseline-first and candidate-first pairs":
    raise SystemExit(f"wrong pairing order: {document.get('order')!r}")

expected_ci = {
    "CMUX_BENCHMARK_RUN_ID": os.environ["GITHUB_RUN_ID"],
    "CMUX_BENCHMARK_RUN_ATTEMPT": os.environ["GITHUB_RUN_ATTEMPT"],
    "CMUX_BENCHMARK_RUNNER_NAME": os.environ["RUNNER_NAME"],
    "CMUX_BENCHMARK_RUNNER_OS": os.environ["RUNNER_OS"],
    "CMUX_BENCHMARK_RUNNER_ARCH": os.environ["RUNNER_ARCH"],
    "CMUX_BENCHMARK_IMAGE_OS": os.environ.get("ImageOS", ""),
    "CMUX_BENCHMARK_IMAGE_VERSION": os.environ.get("ImageVersion", ""),
    "CMUX_BENCHMARK_WORKFLOW_REF": os.environ["GITHUB_WORKFLOW_REF"],
}
if get("host.ci") != expected_ci:
    raise SystemExit(
        f"wrong normalized runner metadata: {get('host.ci')!r}, expected {expected_ci!r}"
    )

for target in ("baseline", "candidate"):
    binary = pathlib.Path(get(f"{target}.binary"))
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    if digest != get(f"{target}.binary_sha256"):
        raise SystemExit(f"{target} binary hash does not match the measured binary")

artifact_root = path.parent
attribution_path = artifact_root / "profile-attribution.json"
attribution = json.loads(attribution_path.read_text(encoding="utf-8"))
if attribution.get("schema_version") != 1:
    raise SystemExit(
        f"unsupported profile attribution schema: {attribution.get('schema_version')!r}"
    )
if attribution.get("purpose") != "offline attribution of native cmux-tui startup profiles":
    raise SystemExit("profile attribution manifest has the wrong purpose")
attribution_targets = attribution.get("targets")
if not isinstance(attribution_targets, dict) or set(attribution_targets) != {
    "baseline",
    "candidate",
}:
    raise SystemExit("profile attribution manifest has the wrong targets")

listed_artifacts = set()

def validate_artifact(entry, context):
    if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "size_bytes"}:
        raise SystemExit(f"{context} has an invalid artifact record: {entry!r}")
    if (
        not isinstance(entry["path"], str)
        or not isinstance(entry["sha256"], str)
        or len(entry["sha256"]) != 64
        or any(character not in "0123456789abcdef" for character in entry["sha256"])
        or not isinstance(entry["size_bytes"], int)
        or isinstance(entry["size_bytes"], bool)
        or entry["size_bytes"] <= 0
    ):
        raise SystemExit(f"{context} has invalid artifact metadata: {entry!r}")
    relative = pathlib.PurePosixPath(entry["path"])
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise SystemExit(f"{context} has an unsafe artifact path: {entry['path']!r}")
    if relative.as_posix() in listed_artifacts:
        raise SystemExit(f"{context} duplicates artifact path: {entry['path']!r}")
    artifact = artifact_root.joinpath(*relative.parts)
    if artifact.is_symlink() or not artifact.is_file():
        raise SystemExit(f"{context} artifact is missing or is a symlink: {artifact}")
    if entry["size_bytes"] != artifact.stat().st_size:
        raise SystemExit(f"{context} artifact size does not match: {artifact}")
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if entry["sha256"] != digest:
        raise SystemExit(f"{context} artifact hash does not match: {artifact}")
    listed_artifacts.add(relative.as_posix())
    return entry

for target in ("baseline", "candidate"):
    target_manifest = attribution_targets[target]
    if not isinstance(target_manifest, dict) or set(target_manifest) != {
        "binary",
        "symbols",
    }:
        raise SystemExit(f"{target} has an invalid profile attribution record")
    binary_entry = validate_artifact(target_manifest["binary"], f"{target} binary")
    expected_binary_path = f"binaries/{target}/cmux-tui{os.environ['BINARY_SUFFIX']}"
    if binary_entry["path"] != expected_binary_path:
        raise SystemExit(
            f"{target} packaged binary path is {binary_entry['path']!r}, "
            f"expected {expected_binary_path!r}"
        )
    if binary_entry["sha256"] != get(f"{target}.binary_sha256"):
        raise SystemExit(f"{target} packaged binary is not the measured binary")
    symbols = target_manifest["symbols"]
    if not isinstance(symbols, list):
        raise SystemExit(f"{target} symbols are not a list")
    for index, symbol in enumerate(symbols):
        validate_artifact(symbol, f"{target} symbol {index}")

packaged_files = {
    artifact.relative_to(artifact_root).as_posix()
    for artifact in (artifact_root / "binaries").rglob("*")
    if artifact.is_file()
}
if packaged_files != listed_artifacts:
    raise SystemExit(
        "profile attribution manifest does not list every packaged file: "
        f"listed={sorted(listed_artifacts)!r} packaged={sorted(packaged_files)!r}"
    )

lifecycle_path = artifact_root / "startup-lifecycle.json"
lifecycle = json.loads(lifecycle_path.read_text(encoding="utf-8"))
if lifecycle.get("schema_version") != 1:
    raise SystemExit(f"unsupported lifecycle schema: {lifecycle.get('schema_version')!r}")
expected_fixture_parent_name = pathlib.Path(os.environ["FIXTURE_PARENT"]).name
if lifecycle.get("fixture_parent_name") != expected_fixture_parent_name:
    raise SystemExit(
        f"wrong fixture parent name: {lifecycle.get('fixture_parent_name')!r}"
    )
if lifecycle.get("report_written_before_reclamation") is not True:
    raise SystemExit("lifecycle evidence was published before the benchmark report")

deferred_roots = lifecycle.get("deferred_roots")
expected_root_count = 2 * (2 * (expected_warmups + expected_samples) + 3)
if not isinstance(deferred_roots, list) or len(deferred_roots) != expected_root_count:
    actual_root_count = len(deferred_roots) if isinstance(deferred_roots, list) else deferred_roots
    raise SystemExit(f"wrong deferred root count: {actual_root_count!r}")
if len(set(deferred_roots)) != len(deferred_roots) or any(
    not isinstance(root, str) or re.fullmatch(r"r-[0-9]{10}-[0-9]{20}", root) is None
    for root in deferred_roots
):
    raise SystemExit("deferred fixture roots are not unique fixed-width root names")

lifecycle_pairs = lifecycle.get("pairs")
expected_pair_count = 5 * (expected_warmups + expected_samples)
if not isinstance(lifecycle_pairs, list) or len(lifecycle_pairs) != expected_pair_count:
    raise SystemExit("lifecycle evidence has an incomplete pair set")
checkpoint_files = sorted((artifact_root / "lifecycle-checkpoints").glob("*.json"))
if len(checkpoint_files) != expected_pair_count:
    raise SystemExit("lifecycle evidence has an incomplete durable checkpoint set")
checkpoints = [json.loads(checkpoint.read_text(encoding="utf-8")) for checkpoint in checkpoint_files]
if sorted(checkpoints, key=lambda value: json.dumps(value, sort_keys=True)) != sorted(
    lifecycle_pairs, key=lambda value: json.dumps(value, sort_keys=True)
):
    raise SystemExit("durable lifecycle checkpoints do not match final lifecycle evidence")

persistent = {"warm", "restored", "incompatible"}
validation = {"cold": 1, "warm": 0, "headless": 1, "restored": 1, "incompatible": 1}
observed_pair_keys = set()
for pair in lifecycle_pairs:
    scenario = pair.get("scenario")
    kind = pair.get("kind")
    index = pair.get("index")
    first = pair.get("first")
    if scenario not in {"cold", "warm", "headless", "restored", "incompatible"}:
        raise SystemExit(f"unknown lifecycle scenario: {scenario!r}")
    limit = expected_warmups if kind == "warmup" else expected_samples if kind == "measured" else -1
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < limit:
        raise SystemExit(f"invalid lifecycle pair index: {pair!r}")
    expected_first = "baseline" if index % 2 == 0 else "candidate"
    if first != expected_first:
        raise SystemExit(f"wrong lifecycle pair order: {pair!r}")
    key = (scenario, kind, index)
    if key in observed_pair_keys:
        raise SystemExit(f"duplicate lifecycle pair: {key!r}")
    observed_pair_keys.add(key)
    for target in ("baseline", "candidate"):
        target_record = pair.get(target)
        if not isinstance(target_record, dict) or target_record.get("target") != target:
            raise SystemExit(f"wrong lifecycle target record: {target_record!r}")
        phases = target_record.get("phases")
        expected_counts = {
            "prepare": 0 if scenario in persistent else 1,
            "measured_event": 1,
            "validation": validation[scenario],
            "process_exit": 1,
            "thread_join": 0 if scenario == "incompatible" else 1,
            "fixture_cleanup": 0 if scenario in persistent else 1,
            "root_deferral": 0 if scenario in persistent else 1,
            "final_reclaim": 0,
        }
        if not isinstance(phases, dict) or set(phases) != set(expected_counts):
            raise SystemExit(f"incomplete lifecycle phases: {phases!r}")
        for phase, count in expected_counts.items():
            metric = phases[phase]
            if (
                not isinstance(metric, dict)
                or metric.get("count") != count
                or not isinstance(metric.get("wall_ns"), int)
                or isinstance(metric.get("wall_ns"), bool)
                or metric["wall_ns"] < 0
                or (count == 0 and metric["wall_ns"] != 0)
            ):
                raise SystemExit(
                    f"invalid lifecycle metric for {scenario} {target} {phase}: {metric!r}"
                )

fixture_records = lifecycle.get("fixtures")
if not isinstance(fixture_records, list) or len(fixture_records) != 12:
    raise SystemExit("persistent fixture lifecycle evidence is incomplete")
if lifecycle.get("profiles") != []:
    raise SystemExit("comparison lifecycle evidence unexpectedly contains profiles")

event_names = {
    "cold": "PTY process spawn to unique session marker followed by a frame-end cursor control",
    "warm": "attach PTY process spawn to unique session marker followed by a frame-end cursor control",
    "headless": "process spawn to readiness line and successful session ping RPC",
    "restored": "process spawn to readiness line and topology RPC containing the saved terminal",
    "incompatible": "process spawn to nonzero exit with the exact public incompatible-state error",
}
summary_fields = {
    "count",
    "min",
    "mean",
    "stddev_population",
    "mad",
    "p50",
    "p90",
    "p95",
    "p99",
    "max",
}

def validate_summary(summary, count, label):
    if not isinstance(summary, dict) or set(summary) != summary_fields:
        raise SystemExit(f"{label} has incomplete summary fields: {summary!r}")
    if summary["count"] != count or isinstance(summary["count"], bool):
        raise SystemExit(f"{label} has the wrong summary count")
    for field in summary_fields - {"count"}:
        value = summary[field]
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
        ):
            raise SystemExit(f"{label} has invalid summary {field}: {value!r}")
    if summary["stddev_population"] < 0 or summary["mad"] < 0:
        raise SystemExit(f"{label} has a negative spread")
    percentile_order = [
        summary["min"],
        summary["p50"],
        summary["p90"],
        summary["p95"],
        summary["p99"],
        summary["max"],
    ]
    if percentile_order != sorted(percentile_order):
        raise SystemExit(f"{label} has non-monotonic percentiles")

scenarios = document.get("scenarios")
if not isinstance(scenarios, list) or len(scenarios) != len(event_names):
    raise SystemExit(f"benchmark evidence has invalid scenarios: {scenarios!r}")
if [scenario.get("scenario") for scenario in scenarios] != list(event_names):
    raise SystemExit("benchmark scenarios are missing or out of order")

total_runs = expected_warmups + expected_samples
for scenario in scenarios:
    name = scenario["scenario"]
    if scenario.get("event") != event_names[name]:
        raise SystemExit(f"{name} has the wrong measured event")
    ordered = {}
    for target in ("baseline", "candidate"):
        sample_set = scenario.get(target)
        if not isinstance(sample_set, dict):
            raise SystemExit(f"{name} is missing the {target} sample set")
        values = sample_set.get("ordered_ns")
        sorted_values = sample_set.get("sorted_ns")
        if (
            not isinstance(values, list)
            or len(values) != expected_samples
            or any(not isinstance(value, int) or value <= 0 for value in values)
        ):
            raise SystemExit(f"{name} has invalid {target} ordered samples")
        if sorted_values != sorted(values):
            raise SystemExit(f"{name} has invalid {target} sorted samples")
        summary = sample_set.get("summary_ns")
        validate_summary(summary, expected_samples, f"{name} {target}")
        if summary.get("min") != sorted_values[0] or summary.get("max") != sorted_values[-1]:
            raise SystemExit(f"{name} has inconsistent {target} summary bounds")
        evidence = sample_set.get("evidence")
        if not isinstance(evidence, dict):
            raise SystemExit(f"{name} is missing {target} event evidence")
        if evidence.get("warmups_completed") != expected_warmups:
            raise SystemExit(f"{name} has an incomplete {target} warmup count")
        if evidence.get("samples_completed") != expected_samples:
            raise SystemExit(f"{name} has an incomplete {target} sample count")
        interactive_probe_minimum = (
            2 if os.environ["PLATFORM_LABEL"] == "windows-azure" else 4
        ) * total_runs
        required_events = {
            "cold": {"render_markers": total_runs, "frame_completions": total_runs, "terminal_probe_responses": interactive_probe_minimum, "process_exits": total_runs},
            "warm": {"render_markers": total_runs, "frame_completions": total_runs, "terminal_probe_responses": interactive_probe_minimum, "readiness_lines": 1, "socket_rpcs": 2},
            "headless": {"readiness_lines": total_runs, "socket_rpcs": 2 * total_runs},
            "restored": {"readiness_lines": total_runs, "socket_rpcs": 2 * total_runs, "restored_topologies": total_runs},
            "incompatible": {"schema_rejections": total_runs, "process_exits": total_runs},
        }[name]
        for field in (
            "supervisor_ready_events",
            "supervisor_t0_records",
            "containment_cleanups",
        ):
            if evidence.get(field) != total_runs:
                raise SystemExit(
                    f"{name} {target} has {evidence.get(field)!r} {field}, "
                    f"expected exactly {total_runs}"
                )
        for field, minimum in required_events.items():
            if evidence.get(field, 0) < minimum:
                raise SystemExit(
                    f"{name} {target} has {evidence.get(field, 0)} {field}, expected at least {minimum}"
                )
        if name in {"cold", "warm"}:
            if evidence["render_markers"] != total_runs:
                raise SystemExit(f"{name} {target} has duplicate render markers")
            if evidence["frame_completions"] != total_runs:
                raise SystemExit(f"{name} {target} has duplicate frame completions")
            cursor_completions = (
                evidence.get("frame_cursor_shows", 0)
                + evidence.get("frame_cursor_hides", 0)
                + evidence.get("frame_cursor_positions", 0)
            )
            if cursor_completions != evidence["frame_completions"]:
                raise SystemExit(f"{name} {target} has inconsistent cursor completion evidence")
            probe_kind_fields = (
                "terminal_cpr_responses",
                "terminal_foreground_color_responses",
                "terminal_background_color_responses",
                "terminal_window_pixel_responses",
                "terminal_kitty_responses",
                "terminal_da1_responses",
                "terminal_keyboard_responses",
            )
            probe_kind_counts = []
            for field in probe_kind_fields:
                count = evidence.get(field)
                if not isinstance(count, int) or not 0 <= count <= total_runs:
                    raise SystemExit(
                        f"{name} {target} has invalid one-shot {field}: {count!r}"
                    )
                probe_kind_counts.append(count)
            if sum(probe_kind_counts) != evidence["terminal_probe_responses"]:
                raise SystemExit(
                    f"{name} {target} probe-kind counts do not match total responses"
                )
            if (
                os.environ["PLATFORM_LABEL"] == "windows-azure"
                and evidence["terminal_cpr_responses"] != total_runs
            ):
                raise SystemExit(
                    f"{name} {target} did not answer one CPR query per launch"
                )
        ordered[target] = values

    pairs = scenario.get("pairs")
    if not isinstance(pairs, list) or len(pairs) != expected_samples:
        raise SystemExit(f"{name} has an incomplete paired distribution")
    deltas = []
    for index, pair in enumerate(pairs):
        expected_first = "baseline" if index % 2 == 0 else "candidate"
        delta = ordered["candidate"][index] - ordered["baseline"][index]
        if pair != {
            "index": index,
            "first": expected_first,
            "baseline_ns": ordered["baseline"][index],
            "candidate_ns": ordered["candidate"][index],
            "candidate_minus_baseline_ns": delta,
        }:
            raise SystemExit(f"{name} has an invalid pair at index {index}: {pair!r}")
        deltas.append(delta)
    delta_summary = scenario.get("paired_delta_summary_ns")
    validate_summary(delta_summary, expected_samples, f"{name} paired delta")
    if delta_summary.get("min") != min(deltas) or delta_summary.get("max") != max(deltas):
        raise SystemExit(f"{name} has inconsistent paired delta bounds")
