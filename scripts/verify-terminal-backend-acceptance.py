#!/usr/bin/env python3
"""Create and verify commit-bound terminal-backend acceptance manifests."""

from __future__ import annotations

import argparse
import collections
import ctypes
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import platform
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib
from typing import Any, Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC_PATH = REPO_ROOT / "tests/terminal-backend/acceptance/spec.json"
SCHEMA_PATH = REPO_ROOT / "tests/terminal-backend/acceptance/manifest.schema.json"
IDENTITY_TOOL = REPO_ROOT / "scripts/terminal-backend-identity.py"
SCHEMA_VERSION = 1
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")

LINKAGE_AUDIT_SCHEMA = "cmux-terminal-linkage-fixed-roots-v1"
LINKAGE_AUDIT_SOURCE_ROOTS = (
    "Sources",
    "Packages/macOS/CmuxTerminal/Sources",
    "Packages/macOS/CmuxTerminalRenderer/Sources",
    "Packages/macOS/CmuxBrowser/Sources",
)
LINKAGE_AUDIT_SOURCE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".hpp",
    ".js",
    ".jsx",
    ".m",
    ".mm",
    ".rs",
    ".swift",
    ".ts",
    ".tsx",
    ".zig",
}
LINKAGE_AUDIT_METRIC_BY_CATEGORY = {
    "backend_mode_local_terminal_constructor": (
        "backend_mode_local_terminal_constructor_callsite_count"
    ),
    "backend_mode_canonical_parser_constructor": (
        "backend_mode_canonical_parser_constructor_callsite_count"
    ),
    "backend_mode_pty_constructor": "backend_mode_pty_constructor_callsite_count",
    "renderer_raw_pty_consumer": "renderer_raw_pty_consumer_callsite_count",
    "browser_raw_pty_consumer": "browser_raw_pty_consumer_callsite_count",
    "browser_canonical_parser_constructor": (
        "browser_canonical_parser_constructor_callsite_count"
    ),
}
LINKAGE_AUDIT_RULES: dict[str, dict[str, tuple[Any, ...]]] = {
    "backend_mode_local_terminal_constructor": {
        "roots": ("Sources",),
        "patterns": (
            (
                "EmbeddedTerminalPanelFactory.init",
                r"\bEmbeddedTerminalPanelFactory\b",
            ),
            (
                "TerminalClientComposition.embedded",
                r"\bTerminalClientComposition\s*\.\s*embedded\s*\(",
            ),
            ("legacyDirect terminal origin", r"\borigin\s*:\s*\.legacyDirect\b"),
        ),
    },
    "backend_mode_canonical_parser_constructor": {
        "roots": (
            "Sources",
            "Packages/macOS/CmuxTerminal/Sources",
        ),
        "patterns": (
            ("ghostty_app_new", r"\bghostty_app_new\b"),
            (
                "ghostty_surface_new",
                r"\bghostty_surface_new(?:_[A-Za-z0-9_]+)?\b",
            ),
        ),
    },
    "backend_mode_pty_constructor": {
        "roots": (
            "Sources",
            "Packages/macOS/CmuxTerminal/Sources",
        ),
        "patterns": (
            (
                "Ghostty PTY-backed surface constructor",
                r"\bghostty_surface_new(?:_[A-Za-z0-9_]+)?\b",
            ),
            (
                "direct PTY constructor",
                r"\b(?:forkpty|openpty|posix_openpt|grantpt|unlockpt)\b",
            ),
        ),
    },
    "renderer_raw_pty_consumer": {
        "roots": ("Packages/macOS/CmuxTerminalRenderer/Sources",),
        "patterns": (
            (
                "Ghostty runtime or surface constructor",
                r"\bghostty_(?:app|surface)_new(?:_[A-Za-z0-9_]+)?\b",
            ),
            (
                "direct PTY API",
                r"\b(?:forkpty|openpty|posix_openpt|grantpt|unlockpt)\b",
            ),
            ("raw VT byte write", r"\bvt_write\b"),
            ("daemon byte attach stream", r"\b(?:AttachFrame|AttachStream)\b"),
        ),
    },
    "browser_raw_pty_consumer": {
        "roots": ("Packages/macOS/CmuxBrowser/Sources",),
        "patterns": (
            (
                "Ghostty runtime or surface constructor",
                r"\bghostty_(?:app|surface)_new(?:_[A-Za-z0-9_]+)?\b",
            ),
            (
                "direct PTY API",
                r"\b(?:forkpty|openpty|posix_openpt|grantpt|unlockpt)\b",
            ),
            ("raw VT byte write", r"\bvt_write\b"),
            ("daemon byte attach stream", r"\b(?:AttachFrame|AttachStream)\b"),
        ),
    },
    "browser_canonical_parser_constructor": {
        "roots": ("Packages/macOS/CmuxBrowser/Sources",),
        "patterns": (
            (
                "Ghostty canonical parser constructor",
                r"\bghostty_(?:app|surface|terminal)_new(?:_[A-Za-z0-9_]+)?\b",
            ),
            ("VTParser.init", r"\bVTParser\b"),
            ("ghostty-vt Terminal.new", r"\bTerminal\s*::\s*new\b"),
            (
                "terminal parser module import",
                r"\bimport\s+(?:GhosttyKit|GhosttyVT|XTerm)\b",
            ),
        ),
    },
}

# Every manifest artifact is a small, machine-readable receipt. The receipt
# binds the claimed result to the exact source commit, command, live PIDs, and
# one or more hashed payloads. This prevents a passing manifest from being
# assembled from arbitrary files whose names merely match the requested kinds.
ARTIFACT_REQUIRED_METRICS: dict[str, set[str]] = {
    "accessibility-tree": {
        "node_count",
        "terminal_utf16_length",
        "cursor_utf16_offset",
        "link_count",
    },
    "allocation-trace": {
        "swift_ghostty_runtime_app_creation_attempts",
        "swift_canonical_ghostty_allocations",
        "swift_pty_master_allocations",
    },
    "ax-query": {"query_count", "failure_count"},
    "baseline": {
        "workload_id",
        "sample_count",
        "p95_ms",
        "p99_ms",
        "max_ms",
        "source_commit",
        "current_main_commit",
        "hardware_model",
        "host_identity_sha256",
        "os_build",
        "display_configuration_sha256",
        "workload_sha256",
        "workload_seed",
        "duration_seconds",
    },
    "conformance-test": {
        "test_count",
        "failure_count",
        "selected_test_count",
        "runner_name",
        "runner_version",
        "runner_sha256",
        "binary_sha256",
        "binary_source_commit",
        "exit_code",
        "stdout_sha256",
        "junit_sha256",
        "command_sha256",
        "selected_tests_sha256",
    },
    "frame-counters": {
        "received_frames",
        "admitted_frames",
        "submitted_blits",
        "rejected_frames",
        "coalesced_frames",
        "drawable_unavailable_events",
        "provenance_records",
        "provenance_dropped_records",
    },
    "golden-image": {
        "fixture_count",
        "width",
        "height",
        "build_sha256",
        "executable_sha256",
        "process_pid",
        "process_started_at",
        "font_sha256",
        "config_sha256",
        "geometry_sha256",
        "source_commit",
    },
    "image-diff": {
        "different_pixel_count",
        "maximum_channel_delta",
        "mean_absolute_error",
        "expected_build_sha256",
        "expected_executable_sha256",
        "expected_process_pid",
        "expected_process_started_at",
        "expected_font_sha256",
        "expected_config_sha256",
        "expected_geometry_sha256",
        "expected_source_commit",
        "actual_build_sha256",
        "actual_executable_sha256",
        "actual_process_pid",
        "actual_process_started_at",
        "actual_font_sha256",
        "actual_config_sha256",
        "actual_geometry_sha256",
        "actual_source_commit",
    },
    "input-transcript": {
        "group_count",
        "duplicate_count",
        "lost_count",
        "split_group_count",
        "global_sequence_count",
        "global_sequence_gap_count",
        "source_coverage_count",
        "event_type_coverage_count",
        "pty_bytes_event_count",
        "pty_bytes_mismatch_count",
    },
    "integration-test": {
        "test_count",
        "failure_count",
        "selected_test_count",
        "runner_name",
        "runner_version",
        "runner_sha256",
        "binary_sha256",
        "binary_source_commit",
        "exit_code",
        "stdout_sha256",
        "junit_sha256",
        "command_sha256",
        "selected_tests_sha256",
    },
    "latency-distribution": {
        "sample_count",
        "p50_ms",
        "p95_ms",
        "p99_ms",
        "max_ms",
        "source_commit",
        "current_main_commit",
        "hardware_model",
        "host_identity_sha256",
        "os_build",
        "display_configuration_sha256",
        "workload_id",
        "workload_sha256",
        "workload_seed",
        "duration_seconds",
        "workspace_count",
        "continuous_output_terminal_count",
    },
    "lease-transcript": {
        "input_lease_count",
        "geometry_lease_count",
        "unauthorized_attempt_count",
        "unauthorized_rejected_count",
        "unauthorized_state_change_count",
    },
    "linkage-audit": {
        "backend_mode_local_terminal_constructor_callsite_count",
        "backend_mode_canonical_parser_constructor_callsite_count",
        "backend_mode_pty_constructor_callsite_count",
        "renderer_raw_pty_consumer_callsite_count",
        "browser_raw_pty_consumer_callsite_count",
        "browser_canonical_parser_constructor_callsite_count",
    },
    "memory-report": {"swift_rss_bytes", "backend_rss_bytes", "renderer_rss_bytes"},
    "metal-system-trace": {
        "swift_terminal_draw_count",
        "swift_full_surface_blit_count",
        "renderer_terminal_draw_count",
    },
    "negative-test": {"case_count", "rejected_count", "state_mutation_count"},
    "process-census": {
        "swift_pid",
        "backend_pid",
        "renderer_pid_count",
        "swift_pty_master_count",
        "backend_pty_master_count",
        "renderer_pty_master_count",
    },
    "protocol": {"request_count", "response_count", "error_count"},
    "pty-size-samples": {
        "sample_count",
        "attempted_resize_count",
        "distinct_canonical_sizes",
        "unauthorized_resize_attempt_count",
        "unauthorized_resize_change_count",
    },
    "queue-metrics": {
        "maximum_retained_bytes",
        "overflow_count",
        "resnapshot_count",
        "blocked_parser_count",
    },
    "restart-transcript": {
        "shell_pid_before",
        "shell_pid_after",
        "terminal_id_equal",
        "tty_equal",
        "cwd_equal",
        "topology_equal",
        "reader_uuid_equal",
        "scrollback_sentinel_preserved",
        "unread_preserved",
    },
    "runtime-assertion": {"assertion_count", "failure_count"},
    "saturation-test": {
        "client_count",
        "blocked_parser_count",
        "blocked_topology_count",
        "other_client_failure_count",
    },
    "screen-capture": {"duration_ms", "frame_count"},
    "screenshot": {"width", "height"},
    "state-hash": {"before_sha256", "after_sha256", "equal"},
    "structured-log": {"accepted_frame_records", "missing_provenance_records"},
    "time-profiler": {
        "swift_terminal_shaping_samples",
        "swift_terminal_render_encoding_samples",
        "renderer_terminal_render_samples",
        "swift_main_thread_sample_count",
        "swift_main_thread_p50_ms",
        "swift_main_thread_p95_ms",
        "swift_main_thread_p99_ms",
        "swift_main_thread_max_ms",
    },
    "version-matrix": {
        "case_count",
        "read_write_success_count",
        "read_only_success_count",
        "state_mutation_count",
    },
    "video": {"duration_ms", "frame_count"},
}

TRACE_ARTIFACT_KINDS = {"allocation-trace", "metal-system-trace", "time-profiler"}
PNG_ARTIFACT_KINDS = {"screenshot"}
GOLDEN_ARTIFACT_KINDS = {"golden-image", "image-diff"}
VIDEO_ARTIFACT_KINDS = {"screen-capture", "video"}
FIDELITY_CORPUS_CASES = {
    "ascii",
    "ligatures",
    "emoji",
    "cjk",
    "combining",
    "wide-cells",
    "styles",
    "cursor",
    "palette",
    "osc-colors",
}
FIDELITY_PROVENANCE_FIELDS = {
    "build_sha256",
    "executable_sha256",
    "process_pid",
    "process_started_at",
    "font_sha256",
    "config_sha256",
    "geometry",
    "source_commit",
}
FID2_MACHINE_SUBCASES = {
    "link-targets",
    "link-activation",
    "selection-drag-autoscroll",
    "search-highlights",
    "kitty-static-images",
    "kitty-animated-images",
    "custom-shaders",
    "synchronized-output-hold",
    "synchronized-output-timeout",
    "ime-marked-text-selection",
    "ime-caret-attributes",
}
MULTI2_INPUT_SOURCES = {"gui", "tui", "automation"}
MULTI2_EVENT_TYPES = {"key-down", "key-up", "mouse", "paste"}
PERF_RUN_BINDING_FIELDS = {
    "hardware_model",
    "host_identity_sha256",
    "os_build",
    "display_configuration_sha256",
    "workload_id",
    "workload_sha256",
    "workload_seed",
    "duration_seconds",
    "current_main_commit",
}

TRACE_TEMPLATE_BY_KIND = {
    "allocation-trace": "Allocations",
    "metal-system-trace": "Metal System Trace",
    "time-profiler": "Time Profiler",
}
SIDEBAR_SIGNPOST_SUBSYSTEM = "com.cmux.sidebar"
SIDEBAR_SELECTION_SIGNPOST = "sidebar-selection-event-to-visible-state"
GHOSTTY_CENSUS_SIGNPOST_SUBSYSTEM = "com.cmux.ghostty.process-census"
GHOSTTY_CENSUS_SNAPSHOT = "ghostty-process-census-snapshot"
GHOSTTY_CENSUS_SCHEMA = "ghostty-process-census-schema-v2"
GHOSTTY_CENSUS_OVERFLOW = "ghostty-process-census-snapshot-overflow"
GHOSTTY_CENSUS_UNIT_NAMES = {
    "ghostty-snapshot-runtime-app-constructor": "runtime_app",
    "ghostty-snapshot-canonical-surface-constructor": "canonical",
    "ghostty-snapshot-manual-io-surface-constructor": "manual",
    "ghostty-snapshot-embedded-pty-surface-constructor": "embedded",
    "ghostty-snapshot-pty-master-open-attempt": "pty_attempt",
    "ghostty-snapshot-pty-master-allocation": "pty_allocation",
}
GHOSTTY_CENSUS_LIVE_EVENT_NAMES = {
    "ghostty-runtime-app-constructor": "runtime_app",
    "ghostty-canonical-surface-constructor": "canonical",
    "ghostty-manual-io-surface-constructor": "manual",
    "ghostty-embedded-pty-surface-constructor": "embedded",
    "ghostty-pty-master-open-attempt": "pty_attempt",
    "ghostty-pty-master-allocated": "pty_allocation",
}
HOST_METAL_COMMAND_BUFFER_LABEL = "cmux host compositor: one IOSurface blit"
HOST_METAL_BLIT_ENCODER_LABEL = "cmux host compositor: no Ghostty rendering"
RENDERER_METAL_COMMAND_BUFFER_LABEL = "cmux Ghostty worker semantic-scene render"
RENDERER_METAL_ENCODER_LABEL = "Ghostty terminal glyph render pass"

# These fragments intentionally identify Ghostty's terminal-specific stack,
# rather than generic CoreText/Metal work that the Swift shell may legitimately
# perform for its own UI. They are applied only to commit-bound process PIDs.
TERMINAL_SHAPING_SYMBOL_FRAGMENTS = (
    "font.shape",
    "font::shape",
    "font_shaper",
    "harfbuzz",
    "hb_shape",
)
TERMINAL_RENDER_SYMBOL_FRAGMENTS = (
    "ghostty",
    "renderer.generic",
    "renderer::generic",
    "renderpass",
    "render pass",
)

CRITERION_REQUIRED_METRICS: dict[tuple[str, str], set[str]] = {
    # The latency artifact contains only branch-run measurements. Baseline p95
    # and improvement are derived across both independently hashed artifacts.
    ("PERF-1", "latency-distribution"): set(),
    ("PERF-2", "process-census"): {
        "dormant_workspace_count",
        "dormant_worker_count",
        "visible_workspace_count",
        "visible_worker_count",
        "shared_workspace_presentation_count",
        "shared_workspace_worker_count",
        "retired_worker_count",
        "collector_pid",
        "collector_executable_sha256",
        "collector_source_commit",
        "collector_command_sha256",
        "collector_sample_count",
        "phase_provenance_count",
        "observed_pid_set_sha256",
    },
    ("FLOW-1", "queue-metrics"): {"retained_byte_budget"},
}

ZERO_ON_PASS_METRICS = {
    "swift_ghostty_runtime_app_creation_attempts",
    "swift_canonical_ghostty_allocations",
    "swift_pty_master_allocations",
    "failure_count",
    "duplicate_count",
    "lost_count",
    "split_group_count",
    "global_sequence_gap_count",
    "pty_bytes_mismatch_count",
    "unauthorized_state_change_count",
    "unauthorized_resize_change_count",
    "exit_code",
    "backend_mode_local_terminal_constructor_callsite_count",
    "backend_mode_canonical_parser_constructor_callsite_count",
    "backend_mode_pty_constructor_callsite_count",
    "renderer_raw_pty_consumer_callsite_count",
    "browser_raw_pty_consumer_callsite_count",
    "browser_canonical_parser_constructor_callsite_count",
    "swift_terminal_draw_count",
    "state_mutation_count",
    "swift_pty_master_count",
    "renderer_pty_master_count",
    "blocked_parser_count",
    "blocked_topology_count",
    "other_client_failure_count",
    "missing_provenance_records",
    "swift_terminal_shaping_samples",
    "swift_terminal_render_encoding_samples",
    "provenance_dropped_records",
    "dormant_worker_count",
    "retired_worker_count",
}

POSITIVE_ON_PASS_METRICS = {
    "node_count",
    "terminal_utf16_length",
    "link_count",
    "query_count",
    "workload_id",
    "sample_count",
    "test_count",
    "received_frames",
    "admitted_frames",
    "submitted_blits",
    "provenance_records",
    "fixture_count",
    "width",
    "height",
    "group_count",
    "global_sequence_count",
    "source_coverage_count",
    "event_type_coverage_count",
    "pty_bytes_event_count",
    "input_lease_count",
    "geometry_lease_count",
    "unauthorized_attempt_count",
    "unauthorized_rejected_count",
    "swift_rss_bytes",
    "backend_rss_bytes",
    "renderer_rss_bytes",
    "swift_full_surface_blit_count",
    "renderer_terminal_draw_count",
    "case_count",
    "rejected_count",
    "swift_pid",
    "backend_pid",
    "renderer_pid_count",
    "request_count",
    "response_count",
    "distinct_canonical_sizes",
    "attempted_resize_count",
    "unauthorized_resize_attempt_count",
    "assertion_count",
    "client_count",
    "duration_ms",
    "frame_count",
    "accepted_frame_records",
    "renderer_terminal_render_samples",
    "swift_main_thread_sample_count",
    "swift_main_thread_p50_ms",
    "swift_main_thread_p95_ms",
    "swift_main_thread_p99_ms",
    "swift_main_thread_max_ms",
    "read_write_success_count",
    "read_only_success_count",
    "duration_seconds",
    "workspace_count",
    "continuous_output_terminal_count",
    "dormant_workspace_count",
    "visible_workspace_count",
    "visible_worker_count",
    "shared_workspace_presentation_count",
    "shared_workspace_worker_count",
    "retained_byte_budget",
    "collector_pid",
    "collector_sample_count",
    "phase_provenance_count",
}


class AcceptanceError(RuntimeError):
    pass


def run(arguments: Sequence[str], *, cwd: pathlib.Path = REPO_ROOT) -> str:
    completed = subprocess.run(
        list(arguments),
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise AcceptanceError(f"command failed ({completed.returncode}): {arguments!r}: {detail}")
    return completed.stdout.strip()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_path(path: pathlib.Path) -> str:
    """Hash one file or a directory tree without following symbolic links."""
    if path.is_symlink():
        raise AcceptanceError(f"evidence payload must not be a symbolic link: {path}")
    if path.is_file():
        return sha256_file(path)
    if not path.is_dir():
        raise AcceptanceError(f"evidence payload is missing: {path}")
    digest = hashlib.sha256()
    entries = sorted(path.rglob("*"))
    symbolic_links = [candidate for candidate in entries if candidate.is_symlink()]
    if symbolic_links:
        raise AcceptanceError(
            f"evidence directory contains a symbolic link: {symbolic_links[0]}"
        )
    files = [candidate for candidate in entries if candidate.is_file()]
    if not files:
        raise AcceptanceError(f"evidence directory is empty: {path}")
    for candidate in files:
        relative = candidate.relative_to(path).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        file_hash = bytes.fromhex(sha256_file(candidate))
        digest.update(len(file_hash).to_bytes(8, "big"))
        digest.update(file_hash)
    return digest.hexdigest()


def resolve_evidence_path(run_root: pathlib.Path, relative: str) -> pathlib.Path:
    path = (run_root / relative).resolve()
    try:
        path.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError(f"evidence payload escapes the evidence directory: {relative}") from error
    if not path.exists():
        raise AcceptanceError(f"evidence payload is missing: {path}")
    if path.is_symlink():
        raise AcceptanceError(f"evidence payload must not be a symbolic link: {path}")
    return path


def expect_scalar(value: Any, label: str) -> None:
    if isinstance(value, bool) or isinstance(value, int):
        return
    if isinstance(value, float):
        if value != value or value in {float("inf"), float("-inf")}:
            raise AcceptanceError(f"{label} must be finite")
        return
    if isinstance(value, str) and value:
        return
    raise AcceptanceError(f"{label} must be a non-empty scalar")


def numeric_metric(metrics: dict[str, Any], name: str, label: str) -> float:
    value = metrics.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AcceptanceError(f"{label} metric {name} must be numeric")
    converted = float(value)
    if converted != converted or converted in {float("inf"), float("-inf")}:
        raise AcceptanceError(f"{label} metric {name} must be finite")
    return converted


def boolean_metric(metrics: dict[str, Any], name: str, label: str) -> bool:
    value = metrics.get(name)
    if not isinstance(value, bool):
        raise AcceptanceError(f"{label} metric {name} must be boolean")
    return value


def string_metric(metrics: dict[str, Any], name: str, label: str) -> str:
    value = metrics.get(name)
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} metric {name} must be a non-empty string")
    return value


def sha256_json(value: Any) -> str:
    """Hash one JSON value using a stable, whitespace-free representation."""
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _linkage_git_source_files(
    repo_root: pathlib.Path,
    source_commit: str,
) -> dict[str, bytes]:
    """Read the fixed linkage roots from one immutable Git commit."""
    expect_commit(source_commit, "linkage audit source commit")
    listed = subprocess.run(
        [
            "git",
            "ls-tree",
            "-r",
            "-z",
            "--full-tree",
            source_commit,
            "--",
            *LINKAGE_AUDIT_SOURCE_ROOTS,
        ],
        cwd=repo_root,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if listed.returncode != 0:
        detail = listed.stderr.decode("utf-8", errors="replace").strip()
        raise AcceptanceError(
            f"linkage audit could not read commit {source_commit}: {detail}"
        )
    identities: list[tuple[str, str]] = []
    for raw_entry in listed.stdout.split(b"\0"):
        if not raw_entry:
            continue
        try:
            metadata, raw_path = raw_entry.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split()
            relative = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise AcceptanceError("linkage audit could not parse committed source tree") from error
        if object_type != "blob" or mode == "120000":
            continue
        if pathlib.PurePosixPath(relative).suffix not in LINKAGE_AUDIT_SOURCE_SUFFIXES:
            continue
        identities.append((relative, object_id))
    identities.sort()
    if not identities:
        raise AcceptanceError("linkage audit fixed roots contain no committed source files")

    batch = subprocess.run(
        ["git", "cat-file", "--batch"],
        cwd=repo_root,
        check=False,
        input="".join(f"{object_id}\n" for _, object_id in identities).encode("ascii"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if batch.returncode != 0:
        detail = batch.stderr.decode("utf-8", errors="replace").strip()
        raise AcceptanceError(f"linkage audit could not read committed blobs: {detail}")
    result: dict[str, bytes] = {}
    cursor = 0
    for relative, expected_object_id in identities:
        header_end = batch.stdout.find(b"\n", cursor)
        if header_end < 0:
            raise AcceptanceError("linkage audit Git blob batch is truncated")
        try:
            object_id, object_type, raw_size = batch.stdout[cursor:header_end].decode(
                "ascii"
            ).split()
            size = int(raw_size)
        except (ValueError, UnicodeDecodeError) as error:
            raise AcceptanceError("linkage audit Git blob header is invalid") from error
        if object_id != expected_object_id or object_type != "blob" or size < 0:
            raise AcceptanceError("linkage audit Git blob identity is invalid")
        payload_start = header_end + 1
        payload_end = payload_start + size
        if payload_end >= len(batch.stdout) or batch.stdout[payload_end : payload_end + 1] != b"\n":
            raise AcceptanceError("linkage audit Git blob payload is truncated")
        result[relative] = batch.stdout[payload_start:payload_end]
        cursor = payload_end + 1
    if cursor != len(batch.stdout):
        raise AcceptanceError("linkage audit Git blob batch has trailing data")
    return result


def _linkage_source_digest(files: dict[str, bytes]) -> str:
    return sha256_json(
        [
            {"path": relative, "sha256": hashlib.sha256(payload).hexdigest()}
            for relative, payload in sorted(files.items())
        ]
    )


def _linkage_source_without_comments_and_literals(source: str) -> str:
    """Blank comments and literals while preserving source offsets and lines."""
    output = list(source)
    index = 0
    block_depth = 0
    delimiter: str | None = None
    while index < len(source):
        if block_depth:
            if source.startswith("/*", index):
                output[index : index + 2] = "  "
                block_depth += 1
                index += 2
            elif source.startswith("*/", index):
                output[index : index + 2] = "  "
                block_depth -= 1
                index += 2
            else:
                if source[index] != "\n":
                    output[index] = " "
                index += 1
            continue
        if delimiter is not None:
            if source.startswith(delimiter, index):
                output[index : index + len(delimiter)] = " " * len(delimiter)
                index += len(delimiter)
                delimiter = None
            elif source[index] == "\\" and len(delimiter) == 1 and index + 1 < len(source):
                output[index : index + 2] = "  "
                index += 2
            else:
                if source[index] != "\n":
                    output[index] = " "
                index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
            output[index:end] = " " * (end - index)
            index = end
            continue
        if source.startswith("/*", index):
            output[index : index + 2] = "  "
            block_depth = 1
            index += 2
            continue
        if source.startswith('"""', index) or source.startswith("'''", index):
            delimiter = source[index : index + 3]
            output[index : index + 3] = "   "
            index += 3
            continue
        if source[index] in {'"', "'"}:
            delimiter = source[index]
            output[index] = " "
            index += 1
            continue
        index += 1
    return "".join(output)


def _linkage_files_for_roots(
    files: dict[str, bytes],
    roots: tuple[str, ...],
) -> dict[str, bytes]:
    return {
        relative: payload
        for relative, payload in files.items()
        if any(relative == root or relative.startswith(f"{root}/") for root in roots)
    }


def build_linkage_audit_artifact(
    repo_root: pathlib.Path,
    source_commit: str,
) -> dict[str, Any]:
    """Build the only accepted linkage artifact from fixed roots at one commit."""
    files = _linkage_git_source_files(repo_root, source_commit)
    decoded: dict[str, str] = {}
    for relative, payload in files.items():
        try:
            decoded[relative] = payload.decode("utf-8")
        except UnicodeDecodeError as error:
            raise AcceptanceError(
                f"linkage audit committed source is not UTF-8: {relative}"
            ) from error

    records: list[dict[str, Any]] = []
    for category in LINKAGE_AUDIT_METRIC_BY_CATEGORY:
        rule = LINKAGE_AUDIT_RULES[category]
        roots = tuple(str(root) for root in rule["roots"])
        category_files = _linkage_files_for_roots(files, roots)
        if not category_files:
            raise AcceptanceError(
                f"linkage audit category {category} fixed roots contain no source files"
            )
        findings: list[dict[str, Any]] = []
        for relative in sorted(category_files):
            source = decoded[relative]
            searchable = _linkage_source_without_comments_and_literals(source)
            for symbol, pattern in rule["patterns"]:
                for match in re.finditer(str(pattern), searchable, flags=re.MULTILINE):
                    line = searchable.count("\n", 0, match.start()) + 1
                    line_start = searchable.rfind("\n", 0, match.start()) + 1
                    findings.append({
                        "path": relative,
                        "line": line,
                        "column": match.start() - line_start + 1,
                        "symbol": str(symbol),
                    })
        findings.sort(
            key=lambda finding: (
                finding["path"],
                finding["line"],
                finding["column"],
                finding["symbol"],
            )
        )
        records.append({
            "category": category,
            "roots": list(roots),
            "scanned_file_count": len(category_files),
            "scanned_source_sha256": _linkage_source_digest(category_files),
            "findings": findings,
        })

    rule_contract = {
        category: {
            "roots": list(rule["roots"]),
            "patterns": [list(pattern) for pattern in rule["patterns"]],
        }
        for category, rule in LINKAGE_AUDIT_RULES.items()
    }
    return {
        "schema_version": 1,
        "artifact_kind": "linkage-audit",
        "context": {
            "scanner_schema": LINKAGE_AUDIT_SCHEMA,
            "source_commit": source_commit,
            "fixed_roots": list(LINKAGE_AUDIT_SOURCE_ROOTS),
            "scanner_rules_sha256": sha256_json(rule_contract),
            "scanned_source_sha256": _linkage_source_digest(files),
        },
        "records": records,
    }


def validate_metric_invariants(
    criterion_id: str,
    artifact_kind: str,
    metrics: dict[str, Any],
    label: str,
) -> None:
    for name in ZERO_ON_PASS_METRICS.intersection(metrics):
        if numeric_metric(metrics, name, label) != 0:
            raise AcceptanceError(f"{label} metric {name} must be zero for passing evidence")
    for name in POSITIVE_ON_PASS_METRICS.intersection(metrics):
        value = metrics[name]
        if isinstance(value, str):
            if not value:
                raise AcceptanceError(f"{label} metric {name} must be non-empty")
        elif numeric_metric(metrics, name, label) <= 0:
            raise AcceptanceError(f"{label} metric {name} must be positive")

    if artifact_kind == "frame-counters":
        received = numeric_metric(metrics, "received_frames", label)
        admitted = numeric_metric(metrics, "admitted_frames", label)
        submitted = numeric_metric(metrics, "submitted_blits", label)
        provenance = numeric_metric(metrics, "provenance_records", label)
        if provenance != received:
            raise AcceptanceError(f"{label} must record exactly one provenance row per frame")
        if admitted > received or submitted > admitted:
            raise AcceptanceError(f"{label} frame counters violate receive/admit/submit ordering")
    elif artifact_kind == "image-diff":
        if numeric_metric(metrics, "maximum_channel_delta", label) > 2:
            raise AcceptanceError(f"{label} exceeds the maximum channel-delta budget")
        if numeric_metric(metrics, "mean_absolute_error", label) > 0.25:
            raise AcceptanceError(f"{label} exceeds the mean-absolute-error budget")
    elif artifact_kind == "negative-test":
        if numeric_metric(metrics, "rejected_count", label) != numeric_metric(
            metrics, "case_count", label
        ):
            raise AcceptanceError(f"{label} did not reject every negative case")
    elif artifact_kind == "restart-transcript":
        if numeric_metric(metrics, "shell_pid_before", label) != numeric_metric(
            metrics, "shell_pid_after", label
        ):
            raise AcceptanceError(f"{label} shell PID changed across Swift restart")
        for name in (
            "terminal_id_equal",
            "tty_equal",
            "cwd_equal",
            "topology_equal",
            "reader_uuid_equal",
            "scrollback_sentinel_preserved",
            "unread_preserved",
        ):
            if not boolean_metric(metrics, name, label):
                raise AcceptanceError(f"{label} metric {name} must be true")
    elif artifact_kind == "state-hash":
        before = string_metric(metrics, "before_sha256", label)
        after = string_metric(metrics, "after_sha256", label)
        expect_sha256(before, f"{label} before_sha256")
        expect_sha256(after, f"{label} after_sha256")
        if before != after or not boolean_metric(metrics, "equal", label):
            raise AcceptanceError(f"{label} state digest changed")
    elif artifact_kind == "version-matrix":
        cases = numeric_metric(metrics, "case_count", label)
        covered = numeric_metric(metrics, "read_write_success_count", label) + numeric_metric(
            metrics, "read_only_success_count", label
        )
        if cases != covered:
            raise AcceptanceError(f"{label} version matrix does not account for every case")
    elif artifact_kind in {"conformance-test", "integration-test"}:
        if numeric_metric(metrics, "selected_test_count", label) != numeric_metric(
            metrics, "test_count", label
        ):
            raise AcceptanceError(f"{label} selected and JUnit test counts differ")
        if numeric_metric(metrics, "exit_code", label) != 0:
            raise AcceptanceError(f"{label} runner exit code must be zero")
    elif artifact_kind == "lease-transcript":
        attempted = numeric_metric(metrics, "unauthorized_attempt_count", label)
        rejected = numeric_metric(metrics, "unauthorized_rejected_count", label)
        changed = numeric_metric(metrics, "unauthorized_state_change_count", label)
        if attempted < 1 or rejected != attempted:
            raise AcceptanceError(f"{label} must reject at least one unauthorized attempt")
        if changed != 0:
            raise AcceptanceError(f"{label} unauthorized attempt changed lease state")
    elif artifact_kind == "pty-size-samples":
        attempted = numeric_metric(metrics, "unauthorized_resize_attempt_count", label)
        if attempted < 1:
            raise AcceptanceError(f"{label} must include an unauthorized resize attempt")
        if numeric_metric(metrics, "unauthorized_resize_change_count", label) != 0:
            raise AcceptanceError(f"{label} unauthorized resize changed canonical geometry")
    elif artifact_kind == "input-transcript":
        if numeric_metric(metrics, "source_coverage_count", label) != len(
            MULTI2_INPUT_SOURCES
        ):
            raise AcceptanceError(f"{label} does not cover GUI, TUI, and automation sources")
        if numeric_metric(metrics, "event_type_coverage_count", label) != len(
            MULTI2_EVENT_TYPES
        ):
            raise AcceptanceError(f"{label} does not cover every required input event type")

    if criterion_id == "PERF-1" and artifact_kind == "latency-distribution":
        if numeric_metric(metrics, "duration_seconds", label) < 60:
            raise AcceptanceError(f"{label} profiling duration is shorter than 60 seconds")
        if numeric_metric(metrics, "workspace_count", label) != 100:
            raise AcceptanceError(f"{label} workload must contain 100 workspaces")
        if numeric_metric(metrics, "continuous_output_terminal_count", label) != 8:
            raise AcceptanceError(f"{label} workload must contain eight output terminals")
        if numeric_metric(metrics, "p95_ms", label) > 16.7:
            raise AcceptanceError(f"{label} exceeds the p95 latency budget")
        if numeric_metric(metrics, "p99_ms", label) > 33.4:
            raise AcceptanceError(f"{label} exceeds the p99 latency budget")
        if numeric_metric(metrics, "max_ms", label) > 50:
            raise AcceptanceError(f"{label} exceeds the maximum latency budget")
    elif criterion_id == "PERF-2" and artifact_kind == "process-census":
        exact = {
            "dormant_workspace_count": 1_000,
            "dormant_worker_count": 0,
            "visible_workspace_count": 100,
            "visible_worker_count": 100,
            "shared_workspace_worker_count": 1,
            "retired_worker_count": 0,
        }
        for name, expected in exact.items():
            if numeric_metric(metrics, name, label) != expected:
                raise AcceptanceError(f"{label} metric {name} must equal {expected}")
        if numeric_metric(metrics, "shared_workspace_presentation_count", label) < 2:
            raise AcceptanceError(f"{label} needs multiple same-workspace presentations")
        if numeric_metric(metrics, "collector_sample_count", label) != 4:
            raise AcceptanceError(f"{label} must contain four live collector samples")
        if numeric_metric(metrics, "phase_provenance_count", label) != 4:
            raise AcceptanceError(f"{label} lacks per-phase live collector provenance")
    elif criterion_id == "PROC-1" and artifact_kind == "process-census":
        if numeric_metric(metrics, "backend_pty_master_count", label) < 1:
            raise AcceptanceError(f"{label} backend must own at least one live PTY master")
    elif criterion_id == "FLOW-1" and artifact_kind == "queue-metrics":
        if numeric_metric(metrics, "maximum_retained_bytes", label) > numeric_metric(
            metrics, "retained_byte_budget", label
        ):
            raise AcceptanceError(f"{label} exceeded its retained-byte budget")
        if numeric_metric(metrics, "overflow_count", label) < 1:
            raise AcceptanceError(f"{label} did not exercise overflow")
        if numeric_metric(metrics, "resnapshot_count", label) < 1:
            raise AcceptanceError(f"{label} did not prove resnapshot recovery")


def validate_cross_artifact_invariants(
    criterion_id: str,
    metrics_by_kind: dict[str, dict[str, Any]],
    label: str,
    *,
    source_commit: str | None = None,
    environment: dict[str, Any] | None = None,
) -> None:
    if criterion_id == "PERF-1":
        baseline = metrics_by_kind.get("baseline")
        latency = metrics_by_kind.get("latency-distribution")
        if baseline is None or latency is None:
            return
        mismatched = sorted(
            field
            for field in PERF_RUN_BINDING_FIELDS
            if baseline.get(field) != latency.get(field)
        )
        if mismatched:
            raise AcceptanceError(
                f"{label} baseline and branch runs differ in: {mismatched}"
            )
        baseline_commit = string_metric(baseline, "source_commit", label)
        current_main = string_metric(baseline, "current_main_commit", label)
        branch_commit = string_metric(latency, "source_commit", label)
        for name, value in (
            ("baseline source_commit", baseline_commit),
            ("current_main_commit", current_main),
            ("branch source_commit", branch_commit),
        ):
            expect_commit(value, f"{label} {name}")
        if baseline_commit != current_main:
            raise AcceptanceError(f"{label} baseline was not captured from current-main")
        if source_commit is None or branch_commit != source_commit:
            raise AcceptanceError(f"{label} branch latency is not bound to the manifest commit")
        if branch_commit == baseline_commit:
            raise AcceptanceError(f"{label} baseline and branch commits must differ")
        baseline_p95 = numeric_metric(baseline, "p95_ms", label)
        branch_p95 = numeric_metric(latency, "p95_ms", label)
        if baseline_p95 <= 0:
            raise AcceptanceError(f"{label} baseline p95 must be positive")
        improvement = (baseline_p95 - branch_p95) * 100 / baseline_p95
        if improvement < 25:
            raise AcceptanceError(
                f"{label} derived p95 improvement is {improvement:.3f} percent, below 25"
            )
        if environment is not None:
            for manifest_key, metric_key in (
                ("hardware_model", "hardware_model"),
                ("os_build", "os_build"),
            ):
                if environment.get(manifest_key) != latency.get(metric_key):
                    raise AcceptanceError(
                        f"{label} {metric_key} differs from the manifest environment"
                    )
        return
    if criterion_id == "FID-1":
        golden = metrics_by_kind.get("golden-image")
        image_diff = metrics_by_kind.get("image-diff")
        if golden is None or image_diff is None:
            return
        for field in (
            "build_sha256",
            "executable_sha256",
            "process_pid",
            "process_started_at",
            "font_sha256",
            "config_sha256",
            "geometry_sha256",
            "source_commit",
        ):
            if golden.get(field) != image_diff.get(f"expected_{field}"):
                raise AcceptanceError(
                    f"{label} golden corpus does not match expected {field} provenance"
                )
        if source_commit is None or golden.get("source_commit") != source_commit:
            raise AcceptanceError(f"{label} fidelity evidence is not bound to the manifest commit")
        return
    if criterion_id == "MULTI-1":
        leases = metrics_by_kind.get("lease-transcript")
        sizes = metrics_by_kind.get("pty-size-samples")
        if leases is None or sizes is None:
            return
        if numeric_metric(leases, "unauthorized_attempt_count", label) != numeric_metric(
            sizes, "unauthorized_resize_attempt_count", label
        ):
            raise AcceptanceError(
                f"{label} lease and PTY transcripts disagree on unauthorized attempts"
            )
        if numeric_metric(leases, "unauthorized_state_change_count", label) != numeric_metric(
            sizes, "unauthorized_resize_change_count", label
        ):
            raise AcceptanceError(
                f"{label} lease and PTY transcripts disagree on unauthorized changes"
            )
        return
    if criterion_id != "PROC-2":
        return
    metal = metrics_by_kind.get("metal-system-trace")
    frames = metrics_by_kind.get("frame-counters")
    if metal is None or frames is None:
        return
    blits = numeric_metric(metal, "swift_full_surface_blit_count", label)
    admitted = numeric_metric(frames, "admitted_frames", label)
    if blits > admitted:
        raise AcceptanceError(f"{label} Swift blits exceed raw admitted frames")


class PNGPayload(tuple):
    """Decoded, non-interlaced 8-bit PNG metadata and channel bytes."""

    __slots__ = ()

    @property
    def width(self) -> int:
        return self[0]

    @property
    def height(self) -> int:
        return self[1]

    @property
    def channels(self) -> int:
        return self[2]

    @property
    def pixels(self) -> bytes:
        return self[3]


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def decode_png(path: pathlib.Path, label: str) -> PNGPayload:
    """Validate the complete PNG stream, inflate it, and return raw pixels.

    Acceptance screenshots are intentionally restricted to non-interlaced,
    8-bit grayscale/RGB/gray-alpha/RGBA PNGs. That keeps verification in the
    Python standard library while still decoding every pixel used by image
    tolerance calculations. A filename plus IHDR is never accepted.
    """
    if not path.is_file():
        raise AcceptanceError(f"{label} must be a PNG file")
    payload = path.read_bytes()
    if len(payload) < 57 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise AcceptanceError(f"{label} is not a complete PNG file")

    offset = 8
    chunks: list[tuple[bytes, bytes]] = []
    saw_iend = False
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise AcceptanceError(f"{label} has a truncated PNG chunk")
        length = struct.unpack_from(">I", payload, offset)[0]
        chunk_type = payload[offset + 4 : offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        crc_end = data_end + 4
        if crc_end > len(payload):
            raise AcceptanceError(f"{label} has a truncated PNG chunk payload")
        chunk_payload = payload[data_start:data_end]
        expected_crc = struct.unpack_from(">I", payload, data_end)[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(chunk_payload, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise AcceptanceError(f"{label} has a PNG CRC mismatch")
        chunks.append((chunk_type, chunk_payload))
        offset = crc_end
        if chunk_type == b"IEND":
            if length != 0:
                raise AcceptanceError(f"{label} has an invalid IEND chunk")
            saw_iend = True
            break
    if not saw_iend or offset != len(payload):
        raise AcceptanceError(f"{label} lacks a terminal IEND chunk or has trailing bytes")
    if not chunks or chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
        raise AcceptanceError(f"{label} lacks a valid leading IHDR chunk")
    if sum(chunk_type == b"IHDR" for chunk_type, _ in chunks) != 1:
        raise AcceptanceError(f"{label} contains multiple IHDR chunks")
    if sum(chunk_type == b"IEND" for chunk_type, _ in chunks) != 1:
        raise AcceptanceError(f"{label} contains multiple IEND chunks")

    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", chunks[0][1]
    )
    if width <= 0 or height <= 0 or width * height > 200_000_000:
        raise AcceptanceError(f"{label} has invalid or excessive PNG dimensions")
    channels_by_color_type = {0: 1, 2: 3, 4: 2, 6: 4}
    channels = channels_by_color_type.get(color_type)
    if bit_depth != 8 or channels is None:
        raise AcceptanceError(
            f"{label} must use non-paletted 8-bit grayscale, RGB, gray-alpha, or RGBA pixels"
        )
    if compression != 0 or filtering != 0 or interlace != 0:
        raise AcceptanceError(f"{label} uses an unsupported PNG encoding")
    compressed = b"".join(data for chunk_type, data in chunks if chunk_type == b"IDAT")
    if not compressed:
        raise AcceptanceError(f"{label} lacks IDAT pixel data")
    try:
        inflated = zlib.decompress(compressed)
    except zlib.error as error:
        raise AcceptanceError(f"{label} has invalid compressed PNG pixels: {error}") from error
    row_bytes = width * channels
    expected_size = height * (row_bytes + 1)
    if len(inflated) != expected_size:
        raise AcceptanceError(
            f"{label} inflated PNG size is {len(inflated)}, expected {expected_size}"
        )

    decoded = bytearray(height * row_bytes)
    previous = bytearray(row_bytes)
    source_offset = 0
    destination_offset = 0
    for _ in range(height):
        filter_type = inflated[source_offset]
        source_offset += 1
        if filter_type > 4:
            raise AcceptanceError(f"{label} has an invalid PNG row filter")
        encoded_row = inflated[source_offset : source_offset + row_bytes]
        source_offset += row_bytes
        row = bytearray(row_bytes)
        for index, encoded in enumerate(encoded_row):
            left = row[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = _paeth(left, above, upper_left)
            row[index] = (encoded + predictor) & 0xFF
        decoded[destination_offset : destination_offset + row_bytes] = row
        destination_offset += row_bytes
        previous = row
    return PNGPayload((width, height, channels, bytes(decoded)))


def _raw_reference(raw_path: pathlib.Path, value: Any, label: str) -> pathlib.Path:
    relative = _raw_string(value, label)
    pure = pathlib.PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts:
        raise AcceptanceError(f"{label} must stay under the raw artifact directory")
    path = (raw_path.parent / pure).resolve()
    try:
        path.relative_to(raw_path.parent.resolve())
    except ValueError as error:
        raise AcceptanceError(f"{label} escapes the raw artifact directory") from error
    if not path.is_file() or path.is_symlink():
        raise AcceptanceError(f"{label} does not identify a regular evidence file")
    return path


def _fidelity_provenance(value: Any, label: str) -> dict[str, Any]:
    provenance = _raw_dict(value, label)
    if set(provenance) != FIDELITY_PROVENANCE_FIELDS:
        raise AcceptanceError(f"{label} fidelity provenance keys differ from repository schema")
    result: dict[str, Any] = {}
    for field in ("build_sha256", "executable_sha256", "font_sha256", "config_sha256"):
        field_value = _raw_string(provenance.get(field), f"{label} {field}")
        expect_sha256(field_value, f"{label} {field}")
        result[field] = field_value
    result["process_pid"] = _raw_int(
        provenance.get("process_pid"), f"{label} process_pid", minimum=1
    )
    result["process_started_at"] = _raw_string(
        provenance.get("process_started_at"), f"{label} process_started_at"
    )
    parse_timestamp(result["process_started_at"], f"{label} process_started_at")
    source_commit = _raw_string(provenance.get("source_commit"), f"{label} source_commit")
    expect_commit(source_commit, f"{label} source_commit")
    result["source_commit"] = source_commit
    geometry = _raw_dict(provenance.get("geometry"), f"{label} geometry")
    if set(geometry) != {"width", "height", "scale"}:
        raise AcceptanceError(f"{label} geometry needs width, height, and scale")
    normalized_geometry = {
        "width": _raw_int(geometry.get("width"), f"{label} width", minimum=1),
        "height": _raw_int(geometry.get("height"), f"{label} height", minimum=1),
        "scale": _raw_number(geometry.get("scale"), f"{label} scale", minimum=0.000001),
    }
    result["geometry_sha256"] = sha256_json(normalized_geometry)
    result["geometry_width"] = normalized_geometry["width"]
    result["geometry_height"] = normalized_geometry["height"]
    return result


def derive_fidelity_metrics(kind: str, path: pathlib.Path, label: str) -> dict[str, Any]:
    context, records = load_raw_artifact(path, kind, label)
    if kind == "golden-image":
        if set(context) != {"provenance"}:
            raise AcceptanceError(f"{label} golden context needs one provenance object")
        provenance = _fidelity_provenance(context.get("provenance"), f"{label} golden")
        expected_provenance = provenance
        actual_provenance = None
    else:
        if set(context) != {"expected_provenance", "actual_provenance"}:
            raise AcceptanceError(
                f"{label} image-diff context needs expected and actual provenance"
            )
        expected_provenance = _fidelity_provenance(
            context.get("expected_provenance"), f"{label} expected"
        )
        actual_provenance = _fidelity_provenance(
            context.get("actual_provenance"), f"{label} actual"
        )
        for field in ("font_sha256", "config_sha256", "geometry_sha256", "source_commit"):
            if expected_provenance[field] != actual_provenance[field]:
                raise AcceptanceError(
                    f"{label} expected and actual {field} differ, so parity is uncontrolled"
                )
        if expected_provenance["build_sha256"] == actual_provenance["build_sha256"]:
            raise AcceptanceError(f"{label} expected and actual build identities must differ")
        if expected_provenance["executable_sha256"] == actual_provenance["executable_sha256"]:
            raise AcceptanceError(f"{label} expected and actual executable identities must differ")
        if (
            expected_provenance["process_pid"],
            expected_provenance["process_started_at"],
        ) == (
            actual_provenance["process_pid"],
            actual_provenance["process_started_at"],
        ):
            raise AcceptanceError(f"{label} expected and actual process identities must differ")
    names: set[str] = set()
    fixture_dimensions: tuple[int, int] | None = None
    different_pixels = 0
    maximum_delta = 0
    channel_total = 0
    channel_count = 0
    for index, raw_record in enumerate(records):
        record = _raw_dict(raw_record, f"{label} fixture {index}")
        name = _raw_string(record.get("name"), f"{label} fixture name")
        if name in names:
            raise AcceptanceError(f"{label} repeats fidelity fixture {name!r}")
        names.add(name)
        if kind == "golden-image":
            image = decode_png(
                _raw_reference(path, record.get("path"), f"{label} fixture path"),
                f"{label} fixture {name}",
            )
            dimensions = (image.width, image.height)
        else:
            expected_path = _raw_reference(
                path, record.get("expected_path"), f"{label} expected path"
            )
            actual_path = _raw_reference(
                path, record.get("actual_path"), f"{label} actual path"
            )
            if expected_path == actual_path:
                raise AcceptanceError(f"{label} fixture {name} reuses one image path")
            if sha256_file(expected_path) == sha256_file(actual_path):
                raise AcceptanceError(f"{label} fixture {name} reuses one image hash")
            expected = decode_png(
                expected_path,
                f"{label} expected fixture {name}",
            )
            actual = decode_png(
                actual_path,
                f"{label} actual fixture {name}",
            )
            if (
                expected.width,
                expected.height,
                expected.channels,
            ) != (actual.width, actual.height, actual.channels):
                raise AcceptanceError(f"{label} fixture {name} has a geometry or channel mismatch")
            dimensions = (expected.width, expected.height)
            assert actual_provenance is not None
            if dimensions != (
                expected_provenance["geometry_width"],
                expected_provenance["geometry_height"],
            ):
                raise AcceptanceError(f"{label} fixture geometry differs from its provenance")
            for pixel_offset in range(0, len(expected.pixels), expected.channels):
                expected_pixel = expected.pixels[
                    pixel_offset : pixel_offset + expected.channels
                ]
                actual_pixel = actual.pixels[pixel_offset : pixel_offset + actual.channels]
                deltas = [
                    abs(expected_channel - actual_channel)
                    for expected_channel, actual_channel in zip(
                        expected_pixel, actual_pixel, strict=True
                    )
                ]
                different_pixels += int(any(deltas))
                maximum_delta = max(maximum_delta, max(deltas))
                channel_total += sum(deltas)
                channel_count += len(deltas)
        if fixture_dimensions is None:
            fixture_dimensions = dimensions
        elif fixture_dimensions != dimensions:
            raise AcceptanceError(f"{label} corpus fixtures do not share one geometry")
    missing = FIDELITY_CORPUS_CASES - names
    if missing:
        raise AcceptanceError(f"{label} fidelity corpus lacks cases: {sorted(missing)}")
    assert fixture_dimensions is not None
    if kind == "golden-image":
        if fixture_dimensions != (
            expected_provenance["geometry_width"],
            expected_provenance["geometry_height"],
        ):
            raise AcceptanceError(f"{label} golden geometry differs from its provenance")
        return {
            "fixture_count": len(records),
            "width": fixture_dimensions[0],
            "height": fixture_dimensions[1],
            **{
                field: expected_provenance[field]
                for field in (
                    "build_sha256",
                    "executable_sha256",
                    "process_pid",
                    "process_started_at",
                    "font_sha256",
                    "config_sha256",
                    "geometry_sha256",
                    "source_commit",
                )
            },
        }
    assert actual_provenance is not None
    provenance_metrics: dict[str, Any] = {}
    for prefix, value in (
        ("expected", expected_provenance),
        ("actual", actual_provenance),
    ):
        for field in (
            "build_sha256",
            "executable_sha256",
            "process_pid",
            "process_started_at",
            "font_sha256",
            "config_sha256",
            "geometry_sha256",
            "source_commit",
        ):
            provenance_metrics[f"{prefix}_{field}"] = value[field]
    return {
        "different_pixel_count": different_pixels,
        "maximum_channel_delta": maximum_delta,
        "mean_absolute_error": channel_total / channel_count,
        **provenance_metrics,
    }


def _bmff_boxes(payload: bytes, start: int, end: int, label: str) -> list[tuple[bytes, int, int]]:
    boxes: list[tuple[bytes, int, int]] = []
    offset = start
    while offset < end:
        if end - offset < 8:
            raise AcceptanceError(f"{label} has a truncated ISO BMFF box header")
        box_size = struct.unpack_from(">I", payload, offset)[0]
        box_type = payload[offset + 4 : offset + 8]
        header_size = 8
        if box_size == 1:
            if end - offset < 16:
                raise AcceptanceError(f"{label} has a truncated extended ISO BMFF box")
            box_size = struct.unpack_from(">Q", payload, offset + 8)[0]
            header_size = 16
        elif box_size == 0:
            box_size = end - offset
        if box_size < header_size or offset + box_size > end:
            raise AcceptanceError(f"{label} has an invalid ISO BMFF box size")
        boxes.append((box_type, offset + header_size, offset + box_size))
        offset += box_size
    if offset != end:
        raise AcceptanceError(f"{label} has misaligned ISO BMFF boxes")
    return boxes


def _first_box(
    boxes: list[tuple[bytes, int, int]], box_type: bytes
) -> tuple[bytes, int, int] | None:
    return next((box for box in boxes if box[0] == box_type), None)


def validate_video(path: pathlib.Path, label: str) -> tuple[int, int]:
    """Validate a self-contained MOV/MP4 and derive duration and frame count."""
    if not path.is_file():
        raise AcceptanceError(f"{label} must be a MOV or MP4 file")
    payload = path.read_bytes()
    if len(payload) < 128:
        raise AcceptanceError(f"{label} is too small to contain a video track")
    top_level = _bmff_boxes(payload, 0, len(payload), label)
    ftyp = _first_box(top_level, b"ftyp")
    moov = _first_box(top_level, b"moov")
    mdats = [box for box in top_level if box[0] == b"mdat"]
    if ftyp is None or moov is None or not mdats:
        raise AcceptanceError(f"{label} lacks ftyp, moov, or mdat boxes")
    if ftyp[2] - ftyp[1] < 8 or not any(end > start for _, start, end in mdats):
        raise AcceptanceError(f"{label} has empty file-type or media data")

    moov_children = _bmff_boxes(payload, moov[1], moov[2], label)
    mvhd = _first_box(moov_children, b"mvhd")
    if mvhd is None or mvhd[2] - mvhd[1] < 20:
        raise AcceptanceError(f"{label} lacks a valid movie header")
    mvhd_payload = payload[mvhd[1] : mvhd[2]]
    version = mvhd_payload[0]
    if version == 0 and len(mvhd_payload) >= 20:
        timescale = struct.unpack_from(">I", mvhd_payload, 12)[0]
        duration = struct.unpack_from(">I", mvhd_payload, 16)[0]
    elif version == 1 and len(mvhd_payload) >= 32:
        timescale = struct.unpack_from(">I", mvhd_payload, 20)[0]
        duration = struct.unpack_from(">Q", mvhd_payload, 24)[0]
    else:
        raise AcceptanceError(f"{label} has an unsupported movie-header version")
    if timescale <= 0 or duration <= 0:
        raise AcceptanceError(f"{label} has zero movie duration")

    video_frame_count = 0
    for trak in [box for box in moov_children if box[0] == b"trak"]:
        trak_children = _bmff_boxes(payload, trak[1], trak[2], label)
        mdia = _first_box(trak_children, b"mdia")
        if mdia is None:
            continue
        mdia_children = _bmff_boxes(payload, mdia[1], mdia[2], label)
        hdlr = _first_box(mdia_children, b"hdlr")
        minf = _first_box(mdia_children, b"minf")
        if hdlr is None or hdlr[2] - hdlr[1] < 12:
            continue
        if payload[hdlr[1] + 8 : hdlr[1] + 12] != b"vide":
            continue
        if minf is None:
            raise AcceptanceError(f"{label} video track lacks media information")
        minf_children = _bmff_boxes(payload, minf[1], minf[2], label)
        stbl = _first_box(minf_children, b"stbl")
        if stbl is None:
            raise AcceptanceError(f"{label} video track lacks a sample table")
        sample_boxes = _bmff_boxes(payload, stbl[1], stbl[2], label)
        stts = _first_box(sample_boxes, b"stts")
        stsz = _first_box(sample_boxes, b"stsz")
        stco = _first_box(sample_boxes, b"stco") or _first_box(sample_boxes, b"co64")
        stsd = _first_box(sample_boxes, b"stsd")
        if None in (stts, stsz, stco, stsd):
            raise AcceptanceError(f"{label} video track has an incomplete sample table")
        assert stts is not None and stsz is not None
        stts_payload = payload[stts[1] : stts[2]]
        if len(stts_payload) < 8:
            raise AcceptanceError(f"{label} has a truncated time-to-sample table")
        entry_count = struct.unpack_from(">I", stts_payload, 4)[0]
        if len(stts_payload) != 8 + entry_count * 8:
            raise AcceptanceError(f"{label} has a malformed time-to-sample table")
        frame_count = sum(
            struct.unpack_from(">I", stts_payload, 8 + index * 8)[0]
            for index in range(entry_count)
        )
        stsz_payload = payload[stsz[1] : stsz[2]]
        if len(stsz_payload) < 12:
            raise AcceptanceError(f"{label} has a truncated sample-size table")
        sample_count = struct.unpack_from(">I", stsz_payload, 8)[0]
        if frame_count <= 0 or sample_count != frame_count:
            raise AcceptanceError(f"{label} video sample counts disagree or are zero")
        video_frame_count += frame_count
    if video_frame_count <= 0:
        raise AcceptanceError(f"{label} contains no complete video track")
    return (math.ceil(duration * 1000 / timescale), video_frame_count)


def xctrace_export_xml(
    path: pathlib.Path,
    label: str,
    *,
    xpath: str | None = None,
) -> ET.Element:
    """Export and parse an Instruments TOC or one schema selection."""
    if not path.is_dir() or path.suffix != ".trace":
        raise AcceptanceError(f"{label} must be an Instruments .trace directory")
    command = ["xcrun", "xctrace", "export", "--quiet", "--input", str(path)]
    if xpath is None:
        command.append("--toc")
    else:
        command.extend(["--xpath", xpath])
    try:
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AcceptanceError(f"{label} could not be parsed by xctrace: {error}") from error
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise AcceptanceError(f"{label} is not a readable Instruments trace: {detail}")
    try:
        root = ET.fromstring(completed.stdout)
    except ET.ParseError as error:
        raise AcceptanceError(f"{label} xctrace export is not valid XML") from error
    return root


def validate_trace(path: pathlib.Path, label: str) -> ET.Element:
    """Require a real Instruments bundle and return its exported TOC."""
    sha256_path(path)
    root = xctrace_export_xml(path, label)
    if not any(element.tag.rsplit("}", 1)[-1] == "run" for element in root.iter()):
        raise AcceptanceError(f"{label} xctrace TOC contains no captured run")
    return root


def _xml_tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def _xctrace_id_map(root: ET.Element) -> dict[str, ET.Element]:
    result: dict[str, ET.Element] = {}
    for element in root.iter():
        identifier = element.get("id")
        if identifier is not None:
            if identifier in result:
                raise AcceptanceError(f"xctrace export repeats object id {identifier}")
            result[identifier] = element
    return result


def _xctrace_resolve(element: ET.Element, identifiers: dict[str, ET.Element]) -> ET.Element:
    seen: set[str] = set()
    while (reference := element.get("ref")) is not None:
        if reference in seen or reference not in identifiers:
            raise AcceptanceError(f"xctrace export has an invalid object reference {reference}")
        seen.add(reference)
        element = identifiers[reference]
    return element


def xctrace_table_rows(
    root: ET.Element,
    schema_name: str,
    *,
    required_columns: set[str],
) -> list[tuple[dict[str, ET.Element], dict[str, ET.Element]]]:
    """Return mnemonic-addressable rows from an `xctrace export --xpath` XML fixture."""
    result: list[tuple[dict[str, ET.Element], dict[str, ET.Element]]] = []
    matched_schema = False
    for node in (element for element in root.iter() if _xml_tag(element) == "node"):
        schema = next(
            (child for child in node if _xml_tag(child) == "schema"),
            None,
        )
        if schema is None or schema.get("name") != schema_name:
            continue
        matched_schema = True
        # xctrace object IDs are scoped to one exported table node. Multiple
        # os-signpost table instances may reuse the same numeric IDs.
        identifiers = _xctrace_id_map(node)
        columns: list[str] = []
        for column in (child for child in schema if _xml_tag(child) == "col"):
            mnemonic = next(
                (child for child in column if _xml_tag(child) == "mnemonic"),
                None,
            )
            if mnemonic is None or not mnemonic.text:
                raise AcceptanceError(f"xctrace {schema_name} has a column without a mnemonic")
            columns.append(mnemonic.text)
        missing = required_columns - set(columns)
        if missing:
            raise AcceptanceError(
                f"xctrace {schema_name} lacks required columns: {sorted(missing)}"
            )
        for row in (child for child in node if _xml_tag(child) == "row"):
            cells = list(row)
            if len(cells) != len(columns):
                raise AcceptanceError(
                    f"xctrace {schema_name} row has {len(cells)} cells for {len(columns)} columns"
                )
            result.append((dict(zip(columns, cells, strict=True)), identifiers))
    if not matched_schema:
        raise AcceptanceError(f"xctrace export contains no {schema_name} schema")
    return result


def _xctrace_text(element: ET.Element, identifiers: dict[str, ET.Element]) -> str:
    resolved = _xctrace_resolve(element, identifiers)
    if _xml_tag(resolved) == "sentinel":
        return ""
    text = (resolved.text or "").strip()
    if text:
        return text
    return (resolved.get("fmt") or "").strip()


def _xctrace_integer(element: ET.Element, identifiers: dict[str, ET.Element], label: str) -> int:
    text = _xctrace_text(element, identifiers).replace(",", "")
    try:
        return int(text, 0)
    except ValueError as error:
        raise AcceptanceError(f"xctrace {label} is not an integer: {text!r}") from error


def _xctrace_pid(element: ET.Element, identifiers: dict[str, ET.Element], label: str) -> int:
    resolved = _xctrace_resolve(element, identifiers)
    for candidate in resolved.iter():
        candidate = _xctrace_resolve(candidate, identifiers)
        if _xml_tag(candidate) == "pid":
            return _xctrace_integer(candidate, identifiers, label)
    raise AcceptanceError(f"xctrace {label} contains no PID")


def _xctrace_frame_names(
    element: ET.Element,
    identifiers: dict[str, ET.Element],
) -> list[str]:
    resolved = _xctrace_resolve(element, identifiers)
    result: list[str] = []
    for candidate in resolved.iter():
        candidate = _xctrace_resolve(candidate, identifiers)
        if _xml_tag(candidate) == "frame" and candidate.get("name"):
            result.append(candidate.get("name", ""))
    return result


def _trace_role_pids(process_roles: dict[int, str], role: str, label: str) -> set[int]:
    result = {pid for pid, candidate in process_roles.items() if candidate == role}
    minimum = 1
    maximum = 1 if role in {"swift-host", "terminal-backend"} else None
    if len(result) < minimum or (maximum is not None and len(result) > maximum):
        raise AcceptanceError(f"{label} needs bound PID roles for {role}")
    return result


def _is_terminal_shaping_sample(frames: list[str]) -> bool:
    stack = "\n".join(frames).casefold()
    has_shaping_symbol = any(
        fragment in stack for fragment in TERMINAL_SHAPING_SYMBOL_FRAGMENTS
    )
    has_terminal_context = any(
        fragment in stack
        for fragment in ("ghostty", "renderer.generic", "renderer::generic", "harfbuzz", "hb_shape")
    )
    return has_shaping_symbol and has_terminal_context


def _is_terminal_render_sample(frames: list[str]) -> bool:
    stack = "\n".join(frames).casefold()
    return "render" in stack and any(
        fragment in stack for fragment in TERMINAL_RENDER_SYMBOL_FRAGMENTS
    )


def derive_sidebar_signpost_latencies_ms(
    root: ET.Element,
    *,
    swift_pid: int,
    label: str,
) -> list[float]:
    rows = xctrace_table_rows(
        root,
        "os-signpost",
        required_columns={
            "time",
            "thread",
            "process",
            "event-type",
            "identifier",
            "name",
            "subsystem",
        },
    )
    events: list[tuple[int, str, str]] = []
    for cells, identifiers in rows:
        if _xctrace_pid(cells["process"], identifiers, "signpost process") != swift_pid:
            continue
        if _xctrace_text(cells["subsystem"], identifiers) != SIDEBAR_SIGNPOST_SUBSYSTEM:
            continue
        if _xctrace_text(cells["name"], identifiers) != SIDEBAR_SELECTION_SIGNPOST:
            continue
        thread = _xctrace_resolve(cells["thread"], identifiers)
        if not (thread.get("fmt") or "").startswith("Main Thread"):
            raise AcceptanceError(f"{label} sidebar selection signpost is not on the main thread")
        event_type = _xctrace_text(cells["event-type"], identifiers).casefold()
        if "begin" in event_type:
            disposition = "begin"
        elif "end" in event_type:
            disposition = "end"
        else:
            raise AcceptanceError(f"{label} has an unknown signpost event type {event_type!r}")
        events.append((
            _xctrace_integer(cells["time"], identifiers, "signpost timestamp"),
            _xctrace_text(cells["identifier"], identifiers),
            disposition,
        ))
    if not events:
        raise AcceptanceError(
            f"{label} contains no {SIDEBAR_SIGNPOST_SUBSYSTEM}/"
            f"{SIDEBAR_SELECTION_SIGNPOST} intervals"
        )
    starts: dict[str, int] = {}
    durations: list[float] = []
    for timestamp, identifier, disposition in sorted(events):
        if not identifier:
            raise AcceptanceError(f"{label} sidebar signpost has no interval identifier")
        if disposition == "begin":
            if identifier in starts:
                raise AcceptanceError(f"{label} repeats an open sidebar signpost interval")
            starts[identifier] = timestamp
            continue
        start = starts.pop(identifier, None)
        if start is None or timestamp <= start:
            raise AcceptanceError(f"{label} has an unmatched or non-positive sidebar interval")
        durations.append((timestamp - start) / 1_000_000)
    if starts or not durations:
        raise AcceptanceError(f"{label} has incomplete sidebar selection intervals")
    return durations


def _source_function_body(source: str, name: str, label: str) -> str:
    """Return one brace-balanced Zig function body for a static linkage audit."""
    matches = list(re.finditer(rf"\bfn\s+{re.escape(name)}\s*\(", source))
    if len(matches) != 1:
        raise AcceptanceError(f"{label} needs exactly one {name} function")
    opening = source.find("{", matches[0].end())
    if opening < 0:
        raise AcceptanceError(f"{label} {name} has no function body")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AcceptanceError(f"{label} {name} has an unterminated function body")


def audit_ghostty_process_census_linkage(repo_root: pathlib.Path = REPO_ROOT) -> None:
    """Fail closed if a Ghostty constructor can bypass process census accounting."""
    ghostty = repo_root / "ghostty"
    try:
        embedded = (ghostty / "src/apprt/embedded.zig").read_text(encoding="utf-8")
        pty = (ghostty / "src/pty.zig").read_text(encoding="utf-8")
        census = (ghostty / "src/process_census.zig").read_text(encoding="utf-8")
        header = (ghostty / "include/ghostty.h").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise AcceptanceError(f"Ghostty process census linkage audit could not read source: {error}") from error

    exported_surface_constructors = set(re.findall(
        r"export\s+fn\s+(ghostty_surface_new(?:_with_scrollback_limit)?)\s*\(",
        embedded,
    ))
    expected_surface_constructors = {
        "ghostty_surface_new",
        "ghostty_surface_new_with_scrollback_limit",
    }
    if exported_surface_constructors != expected_surface_constructors:
        raise AcceptanceError(
            "Ghostty surface constructor set bypasses the census audit: "
            f"{sorted(exported_surface_constructors)}"
        )
    for name in sorted(expected_surface_constructors):
        body = _source_function_body(embedded, name, "Ghostty embedded C API")
        if body.count("surface_new_(") != 1:
            raise AcceptanceError(f"Ghostty {name} does not use the censused constructor seam")

    shared_constructor = _source_function_body(embedded, "surface_new_", "Ghostty embedded C API")
    if shared_constructor.count(
        "process_census.recordSurfaceConstructor(opts.io_mode == .manual);"
    ) != 1 or shared_constructor.count("app.newSurface(") != 1:
        raise AcceptanceError("Ghostty shared surface constructor is not census-instrumented")

    app_constructor = _source_function_body(embedded, "ghostty_app_new", "Ghostty embedded C API")
    if app_constructor.count("process_census.recordRuntimeAppConstructor();") != 1:
        raise AcceptanceError("Ghostty runtime app constructor is not census-instrumented")

    snapshot_body = _source_function_body(
        embedded,
        "ghostty_process_census_emit_signpost_snapshot",
        "Ghostty embedded C API",
    )
    if snapshot_body.count("process_census.emitSignpostSnapshot()") != 1:
        raise AcceptanceError("Ghostty C API does not emit its own process census snapshot")

    posix_start = pty.find("const PosixPty = struct")
    posix_end = pty.find("const WindowsPty = struct")
    if posix_start < 0 or posix_end <= posix_start:
        raise AcceptanceError("Ghostty POSIX PTY constructor could not be isolated")
    posix_source = pty[posix_start:posix_end]
    pty_open = _source_function_body(posix_source, "open", "Ghostty POSIX PTY")
    attempt = pty_open.find("process_census.recordPtyMasterOpenAttempt();")
    allocation = pty_open.find("process_census.recordPtyMasterAllocation();")
    openpty = pty_open.find("c.openpty(")
    if not (0 <= attempt < openpty < allocation):
        raise AcceptanceError("Ghostty PTY accounting does not bracket the actual openpty allocation")

    required_header_symbols = {
        "ghostty_process_census_s",
        "ghostty_process_census_snapshot",
        "ghostty_process_census_emit_signpost_snapshot",
        "runtime_app_constructor_attempts",
    }
    missing_header_symbols = {
        symbol for symbol in required_header_symbols if header.count(symbol) < 1
    }
    if missing_header_symbols:
        raise AcceptanceError(
            f"Ghostty process census C ABI is incomplete: {sorted(missing_header_symbols)}"
        )

    required_census_fragments = {
        GHOSTTY_CENSUS_SCHEMA,
        "ghostty-process-census-snapshot-overflow",
        *GHOSTTY_CENSUS_UNIT_NAMES,
        *GHOSTTY_CENSUS_LIVE_EVENT_NAMES,
    }
    missing_census_fragments = {
        fragment for fragment in required_census_fragments if census.count(fragment) < 1
    }
    if missing_census_fragments:
        raise AcceptanceError(
            "Ghostty process census signpost coverage is incomplete: "
            f"{sorted(missing_census_fragments)}"
        )


def derive_ghostty_process_census_metrics(
    root: ET.Element,
    *,
    process_roles: dict[int, str],
    label: str,
) -> dict[str, Any]:
    """Derive lifetime Swift ownership only from Ghostty-emitted signposts."""
    audit_ghostty_process_census_linkage()
    swift_pid = next(iter(_trace_role_pids(process_roles, "swift-host", label)))
    rows = xctrace_table_rows(
        root,
        "os-signpost",
        required_columns={"time", "process", "event-type", "identifier", "name", "subsystem"},
    )
    snapshots: dict[str, dict[str, Any]] = {}
    live_events: list[tuple[tuple[int, int], str]] = []
    allowed_names = {
        GHOSTTY_CENSUS_SNAPSHOT,
        GHOSTTY_CENSUS_SCHEMA,
        GHOSTTY_CENSUS_OVERFLOW,
        *GHOSTTY_CENSUS_UNIT_NAMES,
        *GHOSTTY_CENSUS_LIVE_EVENT_NAMES,
    }
    for row_index, (cells, identifiers) in enumerate(rows):
        pid = _xctrace_pid(cells["process"], identifiers, "Ghostty census process")
        if pid != swift_pid:
            continue
        subsystem = _xctrace_text(cells["subsystem"], identifiers)
        if subsystem != GHOSTTY_CENSUS_SIGNPOST_SUBSYSTEM:
            continue
        name = _xctrace_text(cells["name"], identifiers)
        if name not in allowed_names:
            raise AcceptanceError(f"{label} has an unknown Ghostty census event {name!r}")
        timestamp = _xctrace_integer(cells["time"], identifiers, "Ghostty census timestamp")
        identifier = _xctrace_text(cells["identifier"], identifiers)
        if not identifier:
            raise AcceptanceError(f"{label} Ghostty census event has no identifier")
        event_type = _xctrace_text(cells["event-type"], identifiers).casefold()
        ordering_key = (timestamp, row_index)

        if name in GHOSTTY_CENSUS_LIVE_EVENT_NAMES:
            if "begin" in event_type or "end" in event_type:
                raise AcceptanceError(f"{label} Ghostty constructor marker is not an event")
            live_events.append((ordering_key, GHOSTTY_CENSUS_LIVE_EVENT_NAMES[name]))
            continue

        snapshot = snapshots.setdefault(identifier, {
            "begin": [],
            "end": [],
            "events": [],
            "schema": 0,
            "overflow": 0,
            "counts": collections.Counter(),
        })
        if name == GHOSTTY_CENSUS_SNAPSHOT:
            if "begin" in event_type:
                snapshot["begin"].append(ordering_key)
            elif "end" in event_type:
                snapshot["end"].append(ordering_key)
            else:
                raise AcceptanceError(f"{label} Ghostty census snapshot marker is not an interval")
        else:
            if "begin" in event_type or "end" in event_type:
                raise AcceptanceError(f"{label} Ghostty census unit marker is not an event")
            snapshot["events"].append(ordering_key)
            if name == GHOSTTY_CENSUS_SCHEMA:
                snapshot["schema"] += 1
            elif name == GHOSTTY_CENSUS_OVERFLOW:
                snapshot["overflow"] += 1
            else:
                snapshot["counts"][GHOSTTY_CENSUS_UNIT_NAMES[name]] += 1

    complete: list[tuple[tuple[int, int], dict[str, int]]] = []
    for identifier, snapshot in snapshots.items():
        if len(snapshot["begin"]) != 1 or len(snapshot["end"]) != 1:
            raise AcceptanceError(f"{label} has an incomplete Ghostty census snapshot {identifier}")
        begin = snapshot["begin"][0]
        end = snapshot["end"][0]
        if end <= begin or snapshot["schema"] != 1:
            raise AcceptanceError(f"{label} has an invalid Ghostty census snapshot {identifier}")
        if any(not (begin < event < end) for event in snapshot["events"]):
            raise AcceptanceError(f"{label} has a Ghostty census marker outside its interval")
        if snapshot["overflow"]:
            raise AcceptanceError(f"{label} Ghostty census snapshot overflowed")
        counts = {
            key: int(snapshot["counts"][key])
            for key in (
                "runtime_app",
                "canonical",
                "manual",
                "embedded",
                "pty_attempt",
                "pty_allocation",
            )
        }
        if counts["canonical"] != counts["manual"] + counts["embedded"]:
            raise AcceptanceError(f"{label} Ghostty surface census subtype counts disagree")
        if counts["pty_allocation"] > counts["pty_attempt"]:
            raise AcceptanceError(f"{label} Ghostty PTY allocations exceed open attempts")
        complete.append((end, counts))
    if not complete:
        raise AcceptanceError(
            f"{label} contains no {GHOSTTY_CENSUS_SIGNPOST_SUBSYSTEM}/"
            f"{GHOSTTY_CENSUS_SNAPSHOT} interval for bound Swift PID {swift_pid}"
        )
    complete.sort(key=lambda item: item[0])
    prior = {key: 0 for key in complete[0][1]}
    for _, counts in complete:
        for key, value in counts.items():
            if value < prior[key]:
                raise AcceptanceError(f"{label} Ghostty census counter {key} decreased")
        prior = counts
    latest_end, latest = complete[-1]
    if any(ordering_key > latest_end for ordering_key, _ in live_events):
        raise AcceptanceError(f"{label} has Ghostty constructor activity after its final snapshot")

    live_counts = collections.Counter(kind for _, kind in live_events)
    if live_counts["canonical"] != live_counts["manual"] + live_counts["embedded"]:
        raise AcceptanceError(f"{label} captured a partial Ghostty surface constructor event pair")
    if live_counts["pty_allocation"] > live_counts["pty_attempt"]:
        raise AcceptanceError(f"{label} captured a PTY allocation without its open attempt")
    for key in live_counts:
        if live_counts[key] > latest[key]:
            raise AcceptanceError(f"{label} Ghostty live event count exceeds its lifetime snapshot")

    return {
        "swift_ghostty_runtime_app_creation_attempts": latest["runtime_app"],
        "swift_canonical_ghostty_allocations": latest["canonical"],
        "swift_pty_master_allocations": latest["pty_allocation"],
    }


def derive_time_profiler_metrics_from_exports(
    time_profile_root: ET.Element,
    signpost_root: ET.Element,
    *,
    process_roles: dict[int, str],
    label: str,
) -> dict[str, Any]:
    swift_pid = next(iter(_trace_role_pids(process_roles, "swift-host", label)))
    renderer_pids = _trace_role_pids(process_roles, "renderer-worker", label)
    shaping = 0
    swift_render = 0
    renderer_render = 0
    rows = xctrace_table_rows(
        time_profile_root,
        "time-profile",
        required_columns={"process", "stack"},
    )
    for cells, identifiers in rows:
        pid = _xctrace_pid(cells["process"], identifiers, "Time Profiler process")
        if pid != swift_pid and pid not in renderer_pids:
            continue
        frames = _xctrace_frame_names(cells["stack"], identifiers)
        if pid == swift_pid:
            shaping += int(_is_terminal_shaping_sample(frames))
            swift_render += int(_is_terminal_render_sample(frames))
        else:
            renderer_render += int(_is_terminal_render_sample(frames))
    latencies = derive_sidebar_signpost_latencies_ms(
        signpost_root,
        swift_pid=swift_pid,
        label=label,
    )
    return {
        "swift_terminal_shaping_samples": shaping,
        "swift_terminal_render_encoding_samples": swift_render,
        "renderer_terminal_render_samples": renderer_render,
        "swift_main_thread_sample_count": len(latencies),
        "swift_main_thread_p50_ms": _percentile(latencies, 0.50),
        "swift_main_thread_p95_ms": _percentile(latencies, 0.95),
        "swift_main_thread_p99_ms": _percentile(latencies, 0.99),
        "swift_main_thread_max_ms": max(latencies),
    }


def derive_metal_metrics_from_export(
    root: ET.Element,
    *,
    process_roles: dict[int, str],
    label: str,
) -> dict[str, Any]:
    swift_pid = next(iter(_trace_role_pids(process_roles, "swift-host", label)))
    renderer_pids = _trace_role_pids(process_roles, "renderer-worker", label)
    swift_draws = 0
    swift_blits = 0
    renderer_draws = 0
    rows = xctrace_table_rows(
        root,
        "metal-application-encoders-list",
        required_columns={"process", "cmdbuffer-label", "encoder-label"},
    )
    for cells, identifiers in rows:
        pid = _xctrace_pid(cells["process"], identifiers, "Metal process")
        command_buffer = _xctrace_text(cells["cmdbuffer-label"], identifiers)
        encoder = _xctrace_text(cells["encoder-label"], identifiers)
        is_host_blit = (
            command_buffer == HOST_METAL_COMMAND_BUFFER_LABEL
            and encoder == HOST_METAL_BLIT_ENCODER_LABEL
        )
        is_terminal_draw = (
            command_buffer == RENDERER_METAL_COMMAND_BUFFER_LABEL
            and encoder == RENDERER_METAL_ENCODER_LABEL
        )
        if pid == swift_pid:
            swift_blits += int(is_host_blit)
            swift_draws += int(is_terminal_draw)
        elif pid in renderer_pids:
            renderer_draws += int(is_terminal_draw)
            if is_host_blit:
                raise AcceptanceError(f"{label} renderer PID submitted a host compositor blit")
        elif is_host_blit or is_terminal_draw:
            raise AcceptanceError(f"{label} terminal Metal label belongs to an unbound PID {pid}")
    return {
        "swift_terminal_draw_count": swift_draws,
        "swift_full_surface_blit_count": swift_blits,
        "renderer_terminal_draw_count": renderer_draws,
    }


def derive_trace_metrics(
    kind: str,
    path: pathlib.Path,
    label: str,
    *,
    process_roles: dict[int, str],
) -> dict[str, Any] | None:
    toc = validate_trace(path, label)
    template_names = {
        (element.text or "").strip()
        for element in toc.iter()
        if _xml_tag(element) == "template-name" and (element.text or "").strip()
    }
    expected_template = TRACE_TEMPLATE_BY_KIND[kind]
    if template_names != {expected_template}:
        raise AcceptanceError(
            f"{label} must use the {expected_template!r} template, got {sorted(template_names)}"
        )
    if kind == "allocation-trace":
        signposts = xctrace_export_xml(
            path,
            label,
            xpath="/trace-toc/run/data/table[@schema='os-signpost']",
        )
        return derive_ghostty_process_census_metrics(
            signposts,
            process_roles=process_roles,
            label=label,
        )
    if kind == "time-profiler":
        profile = xctrace_export_xml(
            path,
            label,
            xpath="/trace-toc/run/data/table[@schema='time-profile']",
        )
        signposts = xctrace_export_xml(
            path,
            label,
            xpath="/trace-toc/run/data/table[@schema='os-signpost']",
        )
        return derive_time_profiler_metrics_from_exports(
            profile,
            signposts,
            process_roles=process_roles,
            label=label,
        )
    encoders = xctrace_export_xml(
        path,
        label,
        xpath="/trace-toc/run/data/table[@schema='metal-application-encoders-list']",
    )
    return derive_metal_metrics_from_export(
        encoders,
        process_roles=process_roles,
        label=label,
    )


def load_raw_artifact(path: pathlib.Path, kind: str, label: str) -> tuple[dict[str, Any], list[Any]]:
    if not path.is_file() or path.suffix.lower() != ".json":
        raise AcceptanceError(f"{label} must be a raw JSON artifact")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"{label} contains invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError(f"{label} raw artifact must be an object")
    expected_keys = {"schema_version", "artifact_kind", "context", "records"}
    if set(value) != expected_keys:
        raise AcceptanceError(
            f"{label} raw artifact keys differ from repository schema: {sorted(value)}"
        )
    if value["schema_version"] != 1 or value["artifact_kind"] != kind:
        raise AcceptanceError(f"{label} raw artifact identity does not match {kind}")
    context = value["context"]
    records = value["records"]
    if not isinstance(context, dict) or not isinstance(records, list):
        raise AcceptanceError(f"{label} raw artifact needs object context and array records")
    return context, records


def _raw_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AcceptanceError(f"{label} must be an object")
    return value


def _raw_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty string")
    return value


def _raw_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise AcceptanceError(f"{label} must be boolean")
    return value


def _raw_int(value: Any, label: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise AcceptanceError(f"{label} must be an integer at least {minimum}")
    return value


def _raw_number(value: Any, label: str, *, minimum: float = 0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AcceptanceError(f"{label} must be numeric")
    converted = float(value)
    if not math.isfinite(converted) or converted < minimum:
        raise AcceptanceError(f"{label} must be finite and at least {minimum}")
    return converted


def _percentile(samples: list[float], percentile: float) -> float:
    if not samples:
        raise AcceptanceError("latency artifact contains no samples")
    ordered = sorted(samples)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def _verified_raw_file(
    raw_path: pathlib.Path,
    value: Any,
    label: str,
) -> tuple[pathlib.Path, str]:
    descriptor = _raw_dict(value, label)
    if set(descriptor) != {"path", "sha256"}:
        raise AcceptanceError(f"{label} keys must be path and sha256")
    path = _raw_reference(raw_path, descriptor.get("path"), f"{label} path")
    expected = _raw_string(descriptor.get("sha256"), f"{label} sha256")
    expect_sha256(expected, f"{label} sha256")
    if sha256_file(path) != expected:
        raise AcceptanceError(f"{label} file hash changed")
    return path, expected


def _junit_results(path: pathlib.Path, label: str) -> list[tuple[str, bool]]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise AcceptanceError(f"{label} is not valid JUnit XML: {error}") from error
    if _xml_tag(root) not in {"testsuite", "testsuites"}:
        raise AcceptanceError(f"{label} root must be testsuite or testsuites")
    results: list[tuple[str, bool]] = []
    names: set[str] = set()
    for testcase in (element for element in root.iter() if _xml_tag(element) == "testcase"):
        name = testcase.get("name")
        if not isinstance(name, str) or not name or name in names:
            raise AcceptanceError(f"{label} needs unique non-empty testcase names")
        names.add(name)
        child_tags = {_xml_tag(child) for child in testcase}
        passed = not bool(child_tags & {"failure", "error", "skipped"})
        results.append((name, passed))
    if not results:
        raise AcceptanceError(f"{label} contains no testcases")
    return results


def _test_metrics(
    criterion_id: str,
    context: dict[str, Any],
    records: list[Any],
    raw_path: pathlib.Path,
    label: str,
) -> dict[str, Any]:
    expected_context_keys = {
        "runner",
        "binary",
        "command",
        "selected_tests",
        "exit_code",
        "stdout",
        "junit",
    }
    if set(context) != expected_context_keys:
        raise AcceptanceError(
            f"{label} test context keys differ from repository schema: {sorted(context)}"
        )
    runner = _raw_dict(context.get("runner"), f"{label} runner")
    if set(runner) != {"name", "version", "file"}:
        raise AcceptanceError(f"{label} runner needs name, version, and file identity")
    runner_name = _raw_string(runner.get("name"), f"{label} runner name")
    runner_version = _raw_string(runner.get("version"), f"{label} runner version")
    _, runner_sha256 = _verified_raw_file(
        raw_path, runner.get("file"), f"{label} runner file"
    )

    binary = _raw_dict(context.get("binary"), f"{label} binary")
    if set(binary) != {"file", "source_commit"}:
        raise AcceptanceError(f"{label} binary needs file identity and source_commit")
    _, binary_sha256 = _verified_raw_file(
        raw_path, binary.get("file"), f"{label} test binary"
    )
    binary_source_commit = _raw_string(
        binary.get("source_commit"), f"{label} binary source commit"
    )
    expect_commit(binary_source_commit, f"{label} binary source commit")

    command = context.get("command")
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(item, str) or not item for item in command)
    ):
        raise AcceptanceError(f"{label} command must be a non-empty string array")
    selected_tests = context.get("selected_tests")
    if (
        not isinstance(selected_tests, list)
        or not selected_tests
        or any(not isinstance(item, str) or not item for item in selected_tests)
        or len(set(selected_tests)) != len(selected_tests)
    ):
        raise AcceptanceError(f"{label} selected_tests must be unique non-empty strings")
    if criterion_id == "FID-2" and set(selected_tests) != FID2_MACHINE_SUBCASES:
        missing = sorted(FID2_MACHINE_SUBCASES - set(selected_tests))
        extra = sorted(set(selected_tests) - FID2_MACHINE_SUBCASES)
        raise AcceptanceError(
            f"{label} FID-2 named subcases differ, missing={missing}, extra={extra}"
        )
    exit_code = _raw_int(context.get("exit_code"), f"{label} exit code")
    _, stdout_sha256 = _verified_raw_file(
        raw_path, context.get("stdout"), f"{label} stdout"
    )
    junit_path, junit_sha256 = _verified_raw_file(
        raw_path, context.get("junit"), f"{label} JUnit"
    )
    junit_results = _junit_results(junit_path, f"{label} JUnit")
    junit_names = [name for name, _ in junit_results]
    if junit_names != selected_tests:
        raise AcceptanceError(f"{label} exact selected test list differs from JUnit output")

    record_names: list[str] = []
    for index, raw_record in enumerate(records):
        record = _raw_dict(raw_record, f"{label} record {index}")
        if set(record) != {"name"}:
            raise AcceptanceError(f"{label} test records may contain only the exact test name")
        record_names.append(_raw_string(record.get("name"), f"{label} record name"))
    if record_names != selected_tests:
        raise AcceptanceError(f"{label} raw records differ from the selected test list")

    return {
        "test_count": len(junit_results),
        "failure_count": sum(not passed for _, passed in junit_results),
        "selected_test_count": len(selected_tests),
        "runner_name": runner_name,
        "runner_version": runner_version,
        "runner_sha256": runner_sha256,
        "binary_sha256": binary_sha256,
        "binary_source_commit": binary_source_commit,
        "exit_code": exit_code,
        "stdout_sha256": stdout_sha256,
        "junit_sha256": junit_sha256,
        "command_sha256": sha256_json(command),
        "selected_tests_sha256": sha256_json(selected_tests),
    }


def _performance_binding_metrics(context: dict[str, Any], label: str) -> dict[str, Any]:
    expected = PERF_RUN_BINDING_FIELDS | {"source_commit"}
    missing = expected - set(context)
    if missing:
        raise AcceptanceError(f"{label} lacks performance provenance: {sorted(missing)}")
    result: dict[str, Any] = {}
    for field in (
        "source_commit",
        "current_main_commit",
        "hardware_model",
        "os_build",
        "workload_id",
    ):
        result[field] = _raw_string(context.get(field), f"{label} {field}")
    for field in (
        "source_commit",
        "current_main_commit",
    ):
        expect_commit(result[field], f"{label} {field}")
    for field in (
        "host_identity_sha256",
        "display_configuration_sha256",
        "workload_sha256",
    ):
        value = _raw_string(context.get(field), f"{label} {field}")
        expect_sha256(value, f"{label} {field}")
        result[field] = value
    result["workload_seed"] = _raw_int(context.get("workload_seed"), f"{label} seed")
    result["duration_seconds"] = _raw_number(
        context.get("duration_seconds"), f"{label} duration", minimum=0.000001
    )
    return result


def _provenance_is_complete(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    required = {
        "worker_audit_identity",
        "renderer_epoch",
        "presentation_generation",
        "frame_sequence",
    }
    return required.issubset(value) and all(value[name] not in (None, "") for name in required)


def derive_structured_metrics(
    criterion_id: str,
    kind: str,
    path: pathlib.Path,
    label: str,
    *,
    source_commit: str | None = None,
    repo_root: pathlib.Path = REPO_ROOT,
) -> dict[str, Any]:
    context, records = load_raw_artifact(path, kind, label)
    if kind == "accessibility-tree":
        text = context.get("text")
        if not isinstance(text, str):
            raise AcceptanceError(f"{label} context text must be a string")
        cursor = _raw_int(context.get("cursor_utf16_offset"), f"{label} cursor offset")
        length = len(text.encode("utf-16-le")) // 2
        if cursor > length:
            raise AcceptanceError(f"{label} cursor lies beyond terminal text")
        links = sum(
            _raw_dict(record, f"{label} node {index}").get("role") == "link"
            for index, record in enumerate(records)
        )
        return {
            "node_count": len(records),
            "terminal_utf16_length": length,
            "cursor_utf16_offset": cursor,
            "link_count": links,
        }
    if kind == "ax-query":
        passed = [
            _raw_bool(_raw_dict(record, f"{label} query {index}").get("passed"), f"{label} query passed")
            for index, record in enumerate(records)
        ]
        return {"query_count": len(passed), "failure_count": passed.count(False)}
    if kind == "baseline":
        binding = _performance_binding_metrics(context, label)
        allowed_context = PERF_RUN_BINDING_FIELDS | {"source_commit"}
        if set(context) != allowed_context:
            raise AcceptanceError(
                f"{label} baseline context keys differ from repository schema: {sorted(context)}"
            )
        samples = [
            _raw_number(
                _raw_dict(record, f"{label} sample {index}").get("latency_ms"),
                f"{label} latency_ms",
            )
            for index, record in enumerate(records)
        ]
        return binding | {
            "sample_count": len(samples),
            "p95_ms": _percentile(samples, 0.95),
            "p99_ms": _percentile(samples, 0.99),
            "max_ms": max(samples),
        }
    if kind in {"conformance-test", "integration-test"}:
        return _test_metrics(criterion_id, context, records, path, label)
    if kind == "frame-counters":
        dispositions: list[str] = []
        admitted = 0
        provenance = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} frame {index}")
            disposition = _raw_string(record.get("disposition"), f"{label} disposition")
            if disposition not in {"submitted", "rejected", "coalesced", "drawable_unavailable"}:
                raise AcceptanceError(f"{label} has unknown frame disposition {disposition!r}")
            dispositions.append(disposition)
            admitted += int(_raw_bool(record.get("admitted"), f"{label} admitted"))
            provenance += int(_provenance_is_complete(record.get("provenance")))
        return {
            "received_frames": len(records),
            "admitted_frames": admitted,
            "submitted_blits": dispositions.count("submitted"),
            "rejected_frames": dispositions.count("rejected"),
            "coalesced_frames": dispositions.count("coalesced"),
            "drawable_unavailable_events": dispositions.count("drawable_unavailable"),
            "provenance_records": provenance,
            "provenance_dropped_records": len(records) - provenance,
        }
    if kind == "input-transcript":
        duplicate_count = 0
        lost_count = 0
        split_count = 0
        bytes_mismatch_count = 0
        observed_sequences: list[int] = []
        observed_sources: set[str] = set()
        observed_types: set[str] = set()
        pty_bytes_event_count = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} group {index}")
            if set(record) != {"group_id", "expected_events", "observed_events"}:
                raise AcceptanceError(
                    f"{label} input group needs group_id plus expected/observed events"
                )
            _raw_string(record.get("group_id"), f"{label} group_id")
            expected_raw = record.get("expected_events")
            observed_raw = record.get("observed_events")
            if not isinstance(expected_raw, list) or not isinstance(observed_raw, list):
                raise AcceptanceError(f"{label} input group events must be arrays")
            expected: list[tuple[str, str, str, str]] = []
            for event_index, raw_event in enumerate(expected_raw):
                event = _raw_dict(raw_event, f"{label} expected event {event_index}")
                if set(event) != {"event_id", "source", "event_type", "pty_bytes_hex"}:
                    raise AcceptanceError(f"{label} expected input event keys differ")
                event_id = _raw_string(event.get("event_id"), f"{label} expected event ID")
                source = _raw_string(event.get("source"), f"{label} expected source")
                event_type = _raw_string(event.get("event_type"), f"{label} expected type")
                pty_bytes = event.get("pty_bytes_hex")
                if not isinstance(pty_bytes, str) or re.fullmatch(r"(?:[0-9a-f]{2})*", pty_bytes) is None:
                    raise AcceptanceError(f"{label} expected PTY bytes must be lowercase hex")
                expected.append((event_id, source, event_type, pty_bytes))
            observed: list[tuple[str, str, str, str]] = []
            group_sequences: list[int] = []
            for event_index, raw_event in enumerate(observed_raw):
                event = _raw_dict(raw_event, f"{label} observed event {event_index}")
                if set(event) != {
                    "event_id",
                    "global_sequence",
                    "source",
                    "event_type",
                    "pty_bytes_hex",
                }:
                    raise AcceptanceError(f"{label} observed input event keys differ")
                event_id = _raw_string(event.get("event_id"), f"{label} observed event ID")
                sequence = _raw_int(
                    event.get("global_sequence"), f"{label} global sequence", minimum=1
                )
                source = _raw_string(event.get("source"), f"{label} observed source")
                event_type = _raw_string(event.get("event_type"), f"{label} observed type")
                pty_bytes = event.get("pty_bytes_hex")
                if not isinstance(pty_bytes, str) or re.fullmatch(r"(?:[0-9a-f]{2})*", pty_bytes) is None:
                    raise AcceptanceError(f"{label} observed PTY bytes must be lowercase hex")
                observed.append((event_id, source, event_type, pty_bytes))
                group_sequences.append(sequence)
                observed_sequences.append(sequence)
                observed_sources.add(source)
                observed_types.add(event_type)
                pty_bytes_event_count += 1
            expected_counts = collections.Counter(event[0] for event in expected)
            observed_counts = collections.Counter(event[0] for event in observed)
            duplicate_count += sum((observed_counts - expected_counts).values())
            lost_count += sum((expected_counts - observed_counts).values())
            bytes_mismatch_count += sum(
                expected_event != observed_event
                for expected_event, observed_event in zip(expected, observed)
            ) + abs(len(expected) - len(observed))
            ordered_sequences = sorted(group_sequences)
            if len(ordered_sequences) > 1 and ordered_sequences != list(
                range(ordered_sequences[0], ordered_sequences[0] + len(ordered_sequences))
            ):
                split_count += 1
        ordered_global = sorted(observed_sequences)
        global_gap_count = 0
        if ordered_global:
            global_gap_count = len(ordered_global) - len(set(ordered_global))
            global_gap_count += sum(
                right != left + 1
                for left, right in zip(ordered_global, ordered_global[1:])
            )
        unknown_sources = observed_sources - MULTI2_INPUT_SOURCES
        unknown_types = observed_types - MULTI2_EVENT_TYPES
        if unknown_sources or unknown_types:
            raise AcceptanceError(
                f"{label} has unknown input sources/types: {sorted(unknown_sources)}, {sorted(unknown_types)}"
            )
        return {
            "group_count": len(records),
            "duplicate_count": duplicate_count,
            "lost_count": lost_count,
            "split_group_count": split_count,
            "global_sequence_count": len(observed_sequences),
            "global_sequence_gap_count": global_gap_count,
            "source_coverage_count": len(observed_sources),
            "event_type_coverage_count": len(observed_types),
            "pty_bytes_event_count": pty_bytes_event_count,
            "pty_bytes_mismatch_count": bytes_mismatch_count,
        }
    if kind == "latency-distribution":
        binding = _performance_binding_metrics(context, label)
        allowed_context = PERF_RUN_BINDING_FIELDS | {
            "source_commit",
            "workspace_count",
            "continuous_output_terminal_count",
        }
        if set(context) != allowed_context:
            raise AcceptanceError(
                f"{label} latency context keys differ from repository schema: {sorted(context)}"
            )
        samples: list[float] = []
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} latency {index}")
            event_ns = _raw_int(record.get("event_ns"), f"{label} event_ns")
            visible_ns = _raw_int(record.get("visible_ns"), f"{label} visible_ns")
            if visible_ns < event_ns:
                raise AcceptanceError(f"{label} visible timestamp precedes input")
            samples.append((visible_ns - event_ns) / 1_000_000)
        p95 = _percentile(samples, 0.95)
        return binding | {
            "sample_count": len(samples),
            "p50_ms": _percentile(samples, 0.50),
            "p95_ms": p95,
            "p99_ms": _percentile(samples, 0.99),
            "max_ms": max(samples),
            "workspace_count": _raw_int(context.get("workspace_count"), f"{label} workspace count"),
            "continuous_output_terminal_count": _raw_int(
                context.get("continuous_output_terminal_count"), f"{label} output terminal count"
            ),
        }
    if kind == "lease-transcript":
        acquired = collections.Counter()
        unauthorized_attempts = 0
        unauthorized_rejections = 0
        unauthorized_changes = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} lease event {index}")
            if set(record) != {"lease", "action", "authorized", "result", "state_changed"}:
                raise AcceptanceError(f"{label} lease event keys differ from repository schema")
            lease = _raw_string(record.get("lease"), f"{label} lease")
            action = _raw_string(record.get("action"), f"{label} action")
            authorized = _raw_bool(record.get("authorized"), f"{label} authorized")
            result = _raw_string(record.get("result"), f"{label} result")
            state_changed = _raw_bool(record.get("state_changed"), f"{label} state_changed")
            if lease not in {"input", "geometry"}:
                raise AcceptanceError(f"{label} has unknown lease kind")
            if action not in {"acquired", "renewed", "released", "resize-attempt"}:
                raise AcceptanceError(f"{label} has unknown lease action")
            if result not in {"accepted", "rejected"}:
                raise AcceptanceError(f"{label} has unknown lease result")
            if action == "acquired":
                acquired[lease] += 1
            if action == "resize-attempt" and not authorized:
                unauthorized_attempts += 1
                unauthorized_rejections += int(result == "rejected")
                unauthorized_changes += int(state_changed)
        return {
            "input_lease_count": acquired["input"],
            "geometry_lease_count": acquired["geometry"],
            "unauthorized_attempt_count": unauthorized_attempts,
            "unauthorized_rejected_count": unauthorized_rejections,
            "unauthorized_state_change_count": unauthorized_changes,
        }
    if kind == "linkage-audit":
        if source_commit is None:
            raise AcceptanceError(f"{label} needs the manifest-bound source commit")
        canonical = build_linkage_audit_artifact(repo_root, source_commit)
        if context != canonical["context"] or records != canonical["records"]:
            raise AcceptanceError(
                f"{label} does not match the repository's deterministic commit scan; "
                "empty or hand-authored linkage records are not evidence"
            )
        return {
            LINKAGE_AUDIT_METRIC_BY_CATEGORY[record["category"]]: len(record["findings"])
            for record in records
        }
    if kind == "memory-report":
        values: dict[str, list[int]] = collections.defaultdict(list)
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} memory sample {index}")
            role = _raw_string(record.get("role"), f"{label} memory role")
            if role not in {"swift", "backend", "renderer"}:
                raise AcceptanceError(f"{label} has unknown memory role")
            values[role].append(_raw_int(record.get("rss_bytes"), f"{label} RSS", minimum=1))
        if len(values["swift"]) != 1 or len(values["backend"]) != 1 or not values["renderer"]:
            raise AcceptanceError(f"{label} needs one Swift/backend and at least one renderer sample")
        return {
            "swift_rss_bytes": values["swift"][0],
            "backend_rss_bytes": values["backend"][0],
            "renderer_rss_bytes": sum(values["renderer"]),
        }
    if kind == "negative-test":
        cases = [_raw_dict(record, f"{label} case {index}") for index, record in enumerate(records)]
        return {
            "case_count": len(cases),
            "rejected_count": sum(
                _raw_bool(case.get("rejected"), f"{label} rejected") for case in cases
            ),
            "state_mutation_count": sum(
                _raw_bool(case.get("state_mutated"), f"{label} state mutated") for case in cases
            ),
        }
    if kind == "process-census":
        roles: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
        process_by_pid: dict[int, dict[str, Any]] = {}
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} process {index}")
            role = _raw_string(record.get("role"), f"{label} process role")
            pid = _raw_int(record.get("pid"), f"{label} process pid", minimum=1)
            if pid in process_by_pid:
                raise AcceptanceError(f"{label} repeats process PID {pid}")
            if criterion_id == "PERF-2":
                if set(record) != {
                    "role",
                    "pid",
                    "pty_master_fds",
                    "started_at",
                    "executable_sha256",
                }:
                    raise AcceptanceError(
                        f"{label} PERF-2 live process identity keys differ from schema"
                    )
                started_at = _raw_string(
                    record.get("started_at"), f"{label} process started_at"
                )
                parse_timestamp(started_at, f"{label} process started_at")
                executable_sha256 = _raw_string(
                    record.get("executable_sha256"), f"{label} process executable hash"
                )
                expect_sha256(executable_sha256, f"{label} process executable hash")
            process_by_pid[pid] = record
            masters = record.get("pty_master_fds")
            if not isinstance(masters, list) or any(not isinstance(fd, str) or not fd for fd in masters):
                raise AcceptanceError(f"{label} PTY master FDs must be string arrays")
            roles[role].append(record)
        if len(roles["swift-host"]) != 1 or len(roles["terminal-backend"]) != 1:
            raise AcceptanceError(f"{label} needs exactly one Swift host and backend")
        result: dict[str, Any] = {
            "swift_pid": roles["swift-host"][0]["pid"],
            "backend_pid": roles["terminal-backend"][0]["pid"],
            "renderer_pid_count": len(roles["renderer-worker"]),
            "swift_pty_master_count": len(roles["swift-host"][0]["pty_master_fds"]),
            "backend_pty_master_count": len(roles["terminal-backend"][0]["pty_master_fds"]),
            "renderer_pty_master_count": sum(
                len(record["pty_master_fds"]) for record in roles["renderer-worker"]
            ),
        }
        if criterion_id == "PERF-2":
            collector = _raw_dict(context.get("collector"), f"{label} collector")
            if set(collector) != {
                "name",
                "version",
                "file",
                "source_commit",
                "pid",
                "started_at",
                "command",
                "hardware_model",
                "host_identity_sha256",
                "os_build",
            }:
                raise AcceptanceError(f"{label} collector provenance keys differ")
            _raw_string(collector.get("name"), f"{label} collector name")
            _raw_string(collector.get("version"), f"{label} collector version")
            _, collector_sha256 = _verified_raw_file(
                path, collector.get("file"), f"{label} collector executable"
            )
            collector_commit = _raw_string(
                collector.get("source_commit"), f"{label} collector source commit"
            )
            expect_commit(collector_commit, f"{label} collector source commit")
            collector_pid = _raw_int(
                collector.get("pid"), f"{label} collector pid", minimum=1
            )
            collector_started_at = _raw_string(
                collector.get("started_at"), f"{label} collector started_at"
            )
            parse_timestamp(collector_started_at, f"{label} collector started_at")
            collector_command = collector.get("command")
            if (
                not isinstance(collector_command, list)
                or not collector_command
                or any(not isinstance(item, str) or not item for item in collector_command)
            ):
                raise AcceptanceError(f"{label} collector command must be a string array")
            _raw_string(collector.get("hardware_model"), f"{label} collector hardware")
            _raw_string(collector.get("os_build"), f"{label} collector OS build")
            host_identity = _raw_string(
                collector.get("host_identity_sha256"), f"{label} collector host identity"
            )
            expect_sha256(host_identity, f"{label} collector host identity")
            collector_record = process_by_pid.get(collector_pid)
            if collector_record is None or collector_record.get("role") != "evidence-collector":
                raise AcceptanceError(f"{label} collector PID lacks a live process record")
            if (
                collector_record.get("started_at") != collector_started_at
                or collector_record.get("executable_sha256") != collector_sha256
            ):
                raise AcceptanceError(f"{label} collector process identity does not match its file")

            phases = _raw_dict(context.get("phases"), f"{label} phases")
            if set(context) != {"collector", "phases"}:
                raise AcceptanceError(f"{label} PERF-2 context needs collector and phases only")
            expected_phases = ("dormant", "visible", "shared", "retired")
            if set(phases) != set(expected_phases):
                raise AcceptanceError(f"{label} process census phases differ from schema")
            observed_pids = set(process_by_pid)
            phase_provenance_count = 0
            phase_renderer_identity_count = 0
            parsed_phases: dict[str, dict[str, Any]] = {}
            backend_pid = roles["terminal-backend"][0]["pid"]
            last_captured_at: dt.datetime | None = None
            for phase in expected_phases:
                _raw_dict(phases.get(phase), f"{label} {phase} phase")
                phase_value = phases[phase]
                if set(phase_value) != {
                    "captured_at",
                    "collector_pid",
                    "backend_pid",
                    "workspace_ids",
                    "presentation_ids",
                    "renderer_processes",
                }:
                    raise AcceptanceError(f"{label} {phase} phase provenance keys differ")
                captured_at_raw = _raw_string(
                    phase_value.get("captured_at"), f"{label} {phase} captured_at"
                )
                captured_at = parse_timestamp(captured_at_raw, f"{label} {phase} captured_at")
                if last_captured_at is not None and captured_at <= last_captured_at:
                    raise AcceptanceError(f"{label} phase samples are not strictly chronological")
                last_captured_at = captured_at
                if _raw_int(
                    phase_value.get("collector_pid"), f"{label} {phase} collector pid", minimum=1
                ) != collector_pid:
                    raise AcceptanceError(f"{label} {phase} came from a different collector")
                if _raw_int(
                    phase_value.get("backend_pid"), f"{label} {phase} backend pid", minimum=1
                ) != backend_pid:
                    raise AcceptanceError(f"{label} {phase} sampled a different backend")
                workspaces = phase_value.get("workspace_ids")
                presentations = phase_value.get("presentation_ids")
                renderer_processes = phase_value.get("renderer_processes")
                if (
                    not isinstance(workspaces, list)
                    or any(not isinstance(item, str) or not item for item in workspaces)
                    or len(set(workspaces)) != len(workspaces)
                    or not isinstance(presentations, list)
                    or any(not isinstance(item, str) or not item for item in presentations)
                    or len(set(presentations)) != len(presentations)
                    or not isinstance(renderer_processes, list)
                ):
                    raise AcceptanceError(f"{label} {phase} contains invalid identity arrays")
                renderer_pids: set[int] = set()
                for renderer_index, raw_renderer in enumerate(renderer_processes):
                    renderer = _raw_dict(
                        raw_renderer, f"{label} {phase} renderer {renderer_index}"
                    )
                    if set(renderer) != {
                        "pid",
                        "started_at",
                        "executable_sha256",
                        "workspace_ids",
                    }:
                        raise AcceptanceError(f"{label} {phase} renderer identity keys differ")
                    pid = _raw_int(renderer.get("pid"), f"{label} renderer pid", minimum=1)
                    started_at = _raw_string(
                        renderer.get("started_at"), f"{label} renderer started_at"
                    )
                    parse_timestamp(started_at, f"{label} renderer started_at")
                    executable_sha256 = _raw_string(
                        renderer.get("executable_sha256"), f"{label} renderer executable hash"
                    )
                    expect_sha256(executable_sha256, f"{label} renderer executable hash")
                    renderer_workspaces = renderer.get("workspace_ids")
                    if (
                        not isinstance(renderer_workspaces, list)
                        or not renderer_workspaces
                        or any(
                            not isinstance(item, str) or item not in workspaces
                            for item in renderer_workspaces
                        )
                    ):
                        raise AcceptanceError(f"{label} renderer has invalid workspace provenance")
                    process = process_by_pid.get(pid)
                    if process is None or process.get("role") != "renderer-worker":
                        raise AcceptanceError(f"{label} phase renderer PID lacks a live process record")
                    if (
                        process.get("started_at") != started_at
                        or process.get("executable_sha256") != executable_sha256
                    ):
                        raise AcceptanceError(f"{label} phase renderer identity changed")
                    if pid in renderer_pids:
                        raise AcceptanceError(f"{label} {phase} repeats renderer PID {pid}")
                    renderer_pids.add(pid)
                    observed_pids.add(pid)
                    phase_renderer_identity_count += 1
                phase_provenance_count += 1
                parsed_phases[phase] = {
                    "workspace_ids": workspaces,
                    "presentation_ids": presentations,
                    "renderer_pids": renderer_pids,
                }
            dormant = parsed_phases["dormant"]
            visible = parsed_phases["visible"]
            shared = parsed_phases["shared"]
            retired = parsed_phases["retired"]
            result.update({
                "dormant_workspace_count": len(dormant["workspace_ids"]),
                "dormant_worker_count": len(dormant["renderer_pids"]),
                "visible_workspace_count": len(visible["workspace_ids"]),
                "visible_worker_count": len(visible["renderer_pids"]),
                "shared_workspace_presentation_count": len(shared["presentation_ids"]),
                "shared_workspace_worker_count": len(shared["renderer_pids"]),
                "retired_worker_count": len(retired["renderer_pids"]),
                "collector_pid": collector_pid,
                "collector_executable_sha256": collector_sha256,
                "collector_source_commit": collector_commit,
                "collector_command_sha256": sha256_json(collector_command),
                "collector_sample_count": len(expected_phases),
                "phase_provenance_count": phase_provenance_count,
                "observed_pid_set_sha256": sha256_json(sorted(observed_pids)),
            })
        return result
    if kind == "protocol":
        directions: list[str] = []
        errors = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} exchange {index}")
            direction = _raw_string(record.get("direction"), f"{label} direction")
            if direction not in {"request", "response"}:
                raise AcceptanceError(f"{label} has unknown protocol direction")
            directions.append(direction)
            errors += int(record.get("outcome") == "error")
        return {
            "request_count": directions.count("request"),
            "response_count": directions.count("response"),
            "error_count": errors,
        }
    if kind == "pty-size-samples":
        sizes: set[tuple[int, int]] = set()
        unauthorized_attempts = 0
        unauthorized_changes = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} size sample {index}")
            if set(record) != {
                "previous_columns",
                "previous_rows",
                "attempted_columns",
                "attempted_rows",
                "resulting_columns",
                "resulting_rows",
                "authorized",
            }:
                raise AcceptanceError(f"{label} resize sample keys differ from repository schema")
            attempted = (
                _raw_int(record.get("attempted_columns"), f"{label} attempted columns", minimum=1),
                _raw_int(record.get("attempted_rows"), f"{label} attempted rows", minimum=1),
            )
            previous = (
                _raw_int(record.get("previous_columns"), f"{label} previous columns", minimum=1),
                _raw_int(record.get("previous_rows"), f"{label} previous rows", minimum=1),
            )
            resulting = (
                _raw_int(record.get("resulting_columns"), f"{label} resulting columns", minimum=1),
                _raw_int(record.get("resulting_rows"), f"{label} resulting rows", minimum=1),
            )
            sizes.add(resulting)
            authorized = _raw_bool(record.get("authorized"), f"{label} authorized")
            if not authorized:
                unauthorized_attempts += 1
                unauthorized_changes += int(resulting != previous)
        return {
            "sample_count": len(records),
            "attempted_resize_count": len(records),
            "distinct_canonical_sizes": len(sizes),
            "unauthorized_resize_attempt_count": unauthorized_attempts,
            "unauthorized_resize_change_count": unauthorized_changes,
        }
    if kind == "queue-metrics":
        retained: list[int] = []
        events: list[str] = []
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} queue sample {index}")
            retained.append(_raw_int(record.get("retained_bytes"), f"{label} retained bytes"))
            event = record.get("event")
            if event is not None:
                events.append(_raw_string(event, f"{label} queue event"))
        return {
            "maximum_retained_bytes": max(retained, default=0),
            "overflow_count": events.count("overflow"),
            "resnapshot_count": events.count("resnapshot"),
            "blocked_parser_count": events.count("blocked_parser"),
            "retained_byte_budget": _raw_int(
                context.get("retained_byte_budget"), f"{label} retained byte budget", minimum=1
            ),
        }
    if kind == "restart-transcript":
        phases: dict[str, dict[str, Any]] = {}
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} restart phase {index}")
            phase = _raw_string(record.get("phase"), f"{label} restart phase")
            if phase in phases or phase not in {"before", "after"}:
                raise AcceptanceError(f"{label} has duplicate or unknown restart phase")
            phases[phase] = record
        if set(phases) != {"before", "after"}:
            raise AcceptanceError(f"{label} needs before and after restart phases")
        before, after = phases["before"], phases["after"]
        for name in ("shell_pid",):
            _raw_int(before.get(name), f"{label} before {name}", minimum=1)
            _raw_int(after.get(name), f"{label} after {name}", minimum=1)
        for name in ("terminal_id", "tty", "cwd", "topology_sha256", "reader_uuid"):
            _raw_string(before.get(name), f"{label} before {name}")
            _raw_string(after.get(name), f"{label} after {name}")
        return {
            "shell_pid_before": before["shell_pid"],
            "shell_pid_after": after["shell_pid"],
            "terminal_id_equal": before["terminal_id"] == after["terminal_id"],
            "tty_equal": before["tty"] == after["tty"],
            "cwd_equal": before["cwd"] == after["cwd"],
            "topology_equal": before["topology_sha256"] == after["topology_sha256"],
            "reader_uuid_equal": before["reader_uuid"] == after["reader_uuid"],
            "scrollback_sentinel_preserved": _raw_bool(
                after.get("scrollback_sentinel_preserved"), f"{label} scrollback sentinel"
            ),
            "unread_preserved": _raw_bool(after.get("unread_preserved"), f"{label} unread"),
        }
    if kind == "runtime-assertion":
        passed = [
            _raw_bool(_raw_dict(record, f"{label} assertion {index}").get("passed"), f"{label} passed")
            for index, record in enumerate(records)
        ]
        return {"assertion_count": len(passed), "failure_count": passed.count(False)}
    if kind == "saturation-test":
        clients: set[str] = set()
        events: list[str] = []
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} saturation event {index}")
            clients.add(_raw_string(record.get("client_id"), f"{label} client id"))
            events.append(_raw_string(record.get("event"), f"{label} saturation event"))
        return {
            "client_count": len(clients),
            "blocked_parser_count": events.count("blocked_parser"),
            "blocked_topology_count": events.count("blocked_topology"),
            "other_client_failure_count": events.count("other_client_failure"),
        }
    if kind == "state-hash":
        if set(context) != {"before_state", "after_state"}:
            raise AcceptanceError(f"{label} state hash context needs before_state and after_state")
        before = json.dumps(
            context["before_state"], sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        after = json.dumps(
            context["after_state"], sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        before_hash = hashlib.sha256(before).hexdigest()
        after_hash = hashlib.sha256(after).hexdigest()
        return {
            "before_sha256": before_hash,
            "after_sha256": after_hash,
            "equal": before_hash == after_hash,
        }
    if kind == "structured-log":
        accepted = 0
        missing = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} log record {index}")
            if _raw_bool(record.get("accepted"), f"{label} accepted"):
                accepted += 1
                missing += int(not _provenance_is_complete(record.get("provenance")))
        return {"accepted_frame_records": accepted, "missing_provenance_records": missing}
    if kind == "version-matrix":
        read_write = 0
        read_only = 0
        mutations = 0
        for index, raw_record in enumerate(records):
            record = _raw_dict(raw_record, f"{label} version case {index}")
            mode = _raw_string(record.get("mode"), f"{label} mode")
            if mode not in {"read-write", "read-only"}:
                raise AcceptanceError(f"{label} has unknown compatibility mode")
            success = _raw_bool(record.get("success"), f"{label} success")
            mutations += int(_raw_bool(record.get("state_mutated"), f"{label} state mutated"))
            read_write += int(success and mode == "read-write")
            read_only += int(success and mode == "read-only")
        return {
            "case_count": len(records),
            "read_write_success_count": read_write,
            "read_only_success_count": read_only,
            "state_mutation_count": mutations,
        }
    raise AcceptanceError(f"artifact kind {kind} has no repository-owned structured deriver")


def derive_payload_metrics(
    criterion_id: str,
    kind: str,
    path: pathlib.Path,
    label: str,
    *,
    process_roles: dict[int, str] | None = None,
    source_commit: str | None = None,
    repo_root: pathlib.Path = REPO_ROOT,
) -> dict[str, Any] | None:
    """Derive receipt metrics from immutable raw payloads.

    `None` means the payload is real and parseable, but this repository still
    lacks a semantic extractor for that Instruments template. Such an artifact
    can document a failing check, but can never make a P0 check pass.
    """
    if kind in TRACE_ARTIFACT_KINDS:
        if process_roles is None:
            raise AcceptanceError(f"{label} trace extraction needs commit-bound process roles")
        return derive_trace_metrics(
            kind,
            path,
            label,
            process_roles=process_roles,
        )
    if kind in GOLDEN_ARTIFACT_KINDS:
        return derive_fidelity_metrics(kind, path, label)
    if kind in PNG_ARTIFACT_KINDS:
        png = decode_png(path, label)
        return {"width": png.width, "height": png.height}
    if kind in VIDEO_ARTIFACT_KINDS:
        duration_ms, frame_count = validate_video(path, label)
        return {"duration_ms": duration_ms, "frame_count": frame_count}
    return derive_structured_metrics(
        criterion_id,
        kind,
        path,
        label,
        source_commit=source_commit,
        repo_root=repo_root,
    )


def validate_payload_format(kind: str, path: pathlib.Path, label: str) -> None:
    # Kept as a narrow public helper for tests and tooling callers. Semantic
    # receipt validation uses `derive_payload_metrics` so format validation and
    # metric extraction cannot diverge.
    if kind in TRACE_ARTIFACT_KINDS:
        validate_trace(path, label)
    elif kind in GOLDEN_ARTIFACT_KINDS:
        derive_fidelity_metrics(kind, path, label)
    elif kind in PNG_ARTIFACT_KINDS:
        decode_png(path, label)
    elif kind in VIDEO_ARTIFACT_KINDS:
        validate_video(path, label)
    else:
        load_raw_artifact(path, kind, label)


def parse_timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty date-time string")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise AcceptanceError(f"{label} is not a valid date-time: {value!r}") from error
    if parsed.tzinfo is None:
        raise AcceptanceError(f"{label} must include a timezone")
    return parsed


def expect_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise AcceptanceError(f"{label} must be a non-empty string")
    return value


def expect_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise AcceptanceError(f"{label} keys differ from schema: {sorted(value)}")


def expect_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise AcceptanceError(f"{label} must be a lowercase SHA-256 digest")
    return value


def expect_commit(value: Any, label: str) -> str:
    if not isinstance(value, str) or COMMIT_PATTERN.fullmatch(value) is None:
        raise AcceptanceError(f"{label} must be a lowercase 40-character Git commit")
    return value


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"could not read JSON at {path}: {error}") from error
    if not isinstance(value, dict):
        raise AcceptanceError(f"expected a JSON object at {path}")
    return value


def atomic_write_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def git_commit() -> str:
    value = run(["git", "rev-parse", "HEAD"])
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise AcceptanceError(f"unexpected Git commit: {value!r}")
    return value


def git_status() -> str:
    return run(["git", "status", "--porcelain=v1", "--untracked-files=all"])


def submodule_state(*, require_clean: bool) -> dict[str, str]:
    output = run(["git", "submodule", "status", "--recursive"])
    result: dict[str, str] = {}
    for line in output.splitlines():
        if not line:
            continue
        marker = line[0]
        fields = line[1:].split()
        if len(fields) < 2:
            raise AcceptanceError(f"could not parse submodule status: {line!r}")
        commit, relative = fields[0], fields[1]
        if marker != " ":
            raise AcceptanceError(f"submodule {relative} is not at the recorded commit: {line}")
        path = REPO_ROOT / relative
        if require_clean:
            dirty = run(
                ["git", "status", "--porcelain=v1", "--untracked-files=all"],
                cwd=path,
            )
            if dirty:
                raise AcceptanceError(f"submodule {relative} is dirty:\n{dirty}")
        result[relative] = commit
    return result


def assert_clean_source() -> tuple[str, dict[str, str]]:
    status = git_status()
    if status:
        raise AcceptanceError(f"source worktree is dirty:\n{status}")
    return git_commit(), submodule_state(require_clean=True)


def ensure_outside_source(path: pathlib.Path) -> pathlib.Path:
    resolved = path.expanduser().resolve()
    try:
        resolved.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return resolved
    raise AcceptanceError(f"artifact root must be outside the source worktree: {resolved}")


def locate_tagged_app(tag: str, explicit: pathlib.Path | None) -> pathlib.Path:
    if explicit is not None:
        candidates = [explicit.expanduser().resolve()]
    else:
        root = (
            pathlib.Path.home()
            / "Library/Developer/Xcode/DerivedData"
            / f"cmux-{tag}/Build/Products/Debug"
        )
        candidates = sorted(root.glob("*.app"))
    candidates = [candidate for candidate in candidates if candidate.is_dir()]
    if len(candidates) != 1:
        raise AcceptanceError(
            f"expected one tagged app for {tag!r}, found {len(candidates)}; pass --app"
        )
    return candidates[0]


def app_identity(app: pathlib.Path) -> tuple[str, pathlib.Path, str, str]:
    plist_path = app / "Contents/Info.plist"
    try:
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise AcceptanceError(f"could not read app Info.plist: {error}") from error
    bundle_id = plist.get("CFBundleIdentifier")
    executable_name = plist.get("CFBundleExecutable")
    source_commit = plist.get("CMUXSourceCommit")
    source_dirty = plist.get("CMUXSourceDirty")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise AcceptanceError("tagged app has no bundle identifier")
    if not isinstance(executable_name, str) or not executable_name:
        raise AcceptanceError("tagged app has no executable name")
    if not isinstance(source_commit, str) or COMMIT_PATTERN.fullmatch(source_commit) is None:
        raise AcceptanceError("tagged app has no valid CMUXSourceCommit")
    if source_dirty not in {"YES", "NO"}:
        raise AcceptanceError("tagged app has no valid CMUXSourceDirty")
    executable = app / "Contents/MacOS" / executable_name
    if not executable.is_file():
        raise AcceptanceError(f"tagged app executable is missing: {executable}")
    return bundle_id, executable, source_commit, source_dirty


def app_executables(app: pathlib.Path, swift_executable: pathlib.Path) -> list[dict[str, str]]:
    candidates = [
        ("swift-host", swift_executable),
        ("terminal-backend", app / "Contents/Resources/bin/cmux-terminal-backend"),
        ("renderer-worker", app / "Contents/Resources/bin/cmux-terminal-renderer"),
    ]
    result: list[dict[str, str]] = []
    for role, path in candidates:
        if not path.is_file() or not os.access(path, os.X_OK):
            raise AcceptanceError(f"tagged app {role} executable is missing: {path}")
        result.append(
            {
                "role": role,
                "path": str(path.relative_to(app)),
                "sha256": sha256_file(path),
            }
        )
    return result


def process_executable(pid: int) -> pathlib.Path:
    if pid <= 0:
        raise AcceptanceError("process PID must be positive")
    system = platform.system()
    if system == "Darwin":
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        proc_pidpath = library.proc_pidpath
        proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        proc_pidpath.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(4096)
        length = proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            error = ctypes.get_errno()
            raise AcceptanceError(f"could not resolve executable for PID {pid}: errno {error}")
        return pathlib.Path(os.fsdecode(buffer.raw[:length])).resolve()
    if system == "Linux":
        try:
            return pathlib.Path(os.readlink(f"/proc/{pid}/exe")).resolve()
        except OSError as error:
            raise AcceptanceError(f"could not resolve executable for PID {pid}: {error}") from error
    raise AcceptanceError(f"process executable lookup is unsupported on {system}")


def process_started_at(pid: int) -> str:
    raw = run(["ps", "-p", str(pid), "-o", "lstart="])
    try:
        parsed = dt.datetime.strptime(" ".join(raw.split()), "%a %b %d %H:%M:%S %Y")
    except ValueError as error:
        raise AcceptanceError(f"could not parse start time for PID {pid}: {raw!r}") from error
    local_timezone = dt.datetime.now().astimezone().tzinfo
    return parsed.replace(tzinfo=local_timezone).astimezone(dt.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )


def backend_socket(bundle_id: str) -> str:
    identity = load_identity(bundle_id)
    return f"/tmp/cmux-tui-{os.getuid()}/{identity['socketFileName']}"


def load_identity(bundle_id: str) -> dict[str, str]:
    try:
        value = json.loads(run([sys.executable, str(IDENTITY_TOOL), "--bundle-id", bundle_id]))
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"identity tool returned invalid JSON: {error}") from error
    if not isinstance(value, dict) or not isinstance(value.get("socketFileName"), str):
        raise AcceptanceError("identity tool omitted socketFileName")
    return value


def role_value(value: str | None, environment_name: str) -> str:
    return value or os.environ.get(environment_name) or "unassigned"


def load_spec() -> dict[str, Any]:
    schema = load_json(SCHEMA_PATH)
    schema_version = schema.get("properties", {}).get("schema_version", {}).get("const")
    if schema_version != SCHEMA_VERSION:
        raise AcceptanceError("acceptance manifest schema version does not match the tool")
    spec = load_json(SPEC_PATH)
    criteria = spec.get("criteria")
    if spec.get("schema_version") != SCHEMA_VERSION or not isinstance(criteria, list):
        raise AcceptanceError("acceptance spec has an unsupported shape")
    identifiers: set[str] = set()
    for criterion in criteria:
        if not isinstance(criterion, dict) or not isinstance(criterion.get("id"), str):
            raise AcceptanceError("acceptance spec contains an invalid criterion")
        expect_keys(
            criterion,
            {"id", "priority", "observable", "pass_condition", "required_artifact_kinds"},
            f"criterion {criterion['id']}",
        )
        identifier = criterion["id"]
        if identifier in identifiers:
            raise AcceptanceError(f"duplicate acceptance criterion {identifier}")
        identifiers.add(identifier)
        if criterion["priority"] not in {"P0", "P1"}:
            raise AcceptanceError(f"criterion {identifier} has an invalid priority")
        expect_string(criterion["observable"], f"criterion {identifier} observable")
        expect_string(criterion["pass_condition"], f"criterion {identifier} pass condition")
        kinds = criterion["required_artifact_kinds"]
        if (
            not isinstance(kinds, list)
            or not kinds
            or any(not isinstance(kind, str) or not kind for kind in kinds)
            or len(set(kinds)) != len(kinds)
        ):
            raise AcceptanceError(f"criterion {identifier} has invalid required artifact kinds")
        unknown_kinds = set(kinds) - set(ARTIFACT_REQUIRED_METRICS)
        if unknown_kinds:
            raise AcceptanceError(
                f"criterion {identifier} has artifact kinds without semantic contracts: "
                f"{sorted(unknown_kinds)}"
            )
    return spec


def capture(arguments: argparse.Namespace) -> pathlib.Path:
    commit, submodules = assert_clean_source()
    root = ensure_outside_source(arguments.artifact_root)
    app = locate_tagged_app(arguments.tag, arguments.app)
    bundle_id, executable, app_commit, app_dirty = app_identity(app)
    if app_commit != commit:
        raise AcceptanceError(f"tagged app was built from {app_commit}, expected clean HEAD {commit}")
    if app_dirty != "NO":
        raise AcceptanceError("tagged app was built from a dirty source snapshot")
    executables = app_executables(app, executable)
    spec = load_spec()
    run_root = root / "terminal-backend" / commit
    manifest_path = run_root / "manifest.json"
    if manifest_path.exists() and not arguments.replace:
        raise AcceptanceError(f"manifest already exists: {manifest_path}; pass --replace")
    checks = [
        {
            "id": criterion["id"],
            "priority": criterion["priority"],
            "status": "fail",
            "commands": [],
            "assertions": ["evidence has not been captured"],
            "artifacts": [],
        }
        for criterion in spec["criteria"]
    ]
    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "criteria_sha256": sha256_file(SPEC_PATH),
        "source": {"commit": commit, "clean": True, "submodules": submodules},
        "build": {
            "tag": arguments.tag,
            "bundle_id": bundle_id,
            "app_path": str(app),
            "info_plist_sha256": sha256_file(app / "Contents/Info.plist"),
            "executables": executables,
            "debug_socket": arguments.debug_socket or f"/tmp/cmux-debug-{arguments.tag}.sock",
            "backend_socket": arguments.backend_socket or backend_socket(bundle_id),
        },
        "environment": {
            "os_build": run(["sw_vers", "-buildVersion"]),
            "hardware_model": run(["sysctl", "-n", "hw.model"]),
            "captured_at": utc_now(),
        },
        "protocol": {
            "client_range": [arguments.protocol_min, arguments.protocol_max],
            "daemon_range": [arguments.protocol_min, arguments.protocol_max],
            "negotiated": arguments.protocol_max,
            "capabilities": [],
        },
        "roles": {
            "acceptance_author": role_value(
                arguments.acceptance_author, "CMUX_ACCEPTANCE_AUTHOR"
            ),
            "implementer": role_value(arguments.implementer, "CMUX_IMPLEMENTER"),
            "interaction_profiler": role_value(
                arguments.interaction_profiler, "CMUX_INTERACTION_PROFILER"
            ),
            "artifact_verifier": role_value(
                arguments.artifact_verifier, "CMUX_ARTIFACT_VERIFIER"
            ),
        },
        "processes": [],
        "checks": checks,
    }
    validate_shape(manifest, spec)
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def check_by_id(manifest: dict[str, Any], identifier: str) -> dict[str, Any]:
    checks = manifest.get("checks")
    if not isinstance(checks, list):
        raise AcceptanceError("manifest checks must be an array")
    matches = [check for check in checks if isinstance(check, dict) and check.get("id") == identifier]
    if len(matches) != 1:
        raise AcceptanceError(f"manifest must contain exactly one {identifier} check")
    return matches[0]


def resolve_artifact(run_root: pathlib.Path, relative: str) -> pathlib.Path:
    path = (run_root / relative).resolve()
    try:
        path.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError(f"artifact escapes the evidence directory: {relative}") from error
    if not path.is_file():
        raise AcceptanceError(f"artifact is missing: {path}")
    return path


def validate_evidence_receipt(
    *,
    receipt_path: pathlib.Path,
    run_root: pathlib.Path,
    criterion_id: str,
    artifact_kind: str,
    source_commit: str,
    artifact_pids: list[int],
    commands: list[list[str]],
    expected_pass: bool,
    process_build_roles: dict[int, str] | None = None,
    bound_processes: dict[int, dict[str, Any]] | None = None,
    environment: dict[str, Any] | None = None,
) -> str:
    if receipt_path.suffix.lower() != ".json":
        raise AcceptanceError(
            f"artifact {criterion_id}/{artifact_kind} must be a JSON evidence receipt"
        )
    receipt = load_json(receipt_path)
    expect_keys(
        receipt,
        {
            "schema_version",
            "criterion_id",
            "artifact_kind",
            "source_commit",
            "captured_at",
            "command",
            "passed",
            "pids",
            "observations",
            "metrics",
            "attachments",
        },
        f"evidence receipt {criterion_id}/{artifact_kind}",
    )
    if receipt["schema_version"] != 1:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} has unsupported schema version"
        )
    if receipt["criterion_id"] != criterion_id:
        raise AcceptanceError(
            f"evidence receipt criterion {receipt['criterion_id']!r} does not match {criterion_id}"
        )
    if receipt["artifact_kind"] != artifact_kind:
        raise AcceptanceError(
            f"evidence receipt kind {receipt['artifact_kind']!r} does not match {artifact_kind}"
        )
    if receipt["source_commit"] != source_commit:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} belongs to a different commit"
        )
    captured_at = expect_string(
        receipt["captured_at"], f"evidence receipt {criterion_id}/{artifact_kind} captured_at"
    )
    parse_timestamp(captured_at, f"evidence receipt {criterion_id}/{artifact_kind} captured_at")
    command = receipt["command"]
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(item, str) or not item for item in command)
        or command not in commands
    ):
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} command is not recorded by the check"
        )
    if receipt["passed"] is not expected_pass:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} pass result disagrees with the check"
        )
    receipt_pids = receipt["pids"]
    if (
        not isinstance(receipt_pids, list)
        or any(
            not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0
            for pid in receipt_pids
        )
        or receipt_pids != sorted(set(receipt_pids))
        or receipt_pids != artifact_pids
    ):
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} PIDs do not match its manifest entry"
        )
    observations = receipt["observations"]
    if (
        not isinstance(observations, list)
        or not observations
        or any(not isinstance(value, str) or not value for value in observations)
    ):
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} needs observed facts"
        )
    metrics = receipt["metrics"]
    if not isinstance(metrics, dict):
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} metrics must be an object"
        )
    base_metrics = ARTIFACT_REQUIRED_METRICS.get(artifact_kind)
    if base_metrics is None:
        raise AcceptanceError(f"artifact kind has no semantic contract: {artifact_kind}")
    required_metrics = base_metrics | CRITERION_REQUIRED_METRICS.get(
        (criterion_id, artifact_kind), set()
    )
    missing_metrics = required_metrics - set(metrics)
    if missing_metrics:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} lacks metrics: "
            f"{sorted(missing_metrics)}"
        )
    for name, value in metrics.items():
        expect_string(name, f"evidence receipt {criterion_id}/{artifact_kind} metric name")
        expect_scalar(value, f"evidence receipt {criterion_id}/{artifact_kind} metric {name}")
    attachments = receipt["attachments"]
    if not isinstance(attachments, list) or not attachments:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} needs hashed attachments"
        )
    primary_count = 0
    primary_payload: pathlib.Path | None = None
    seen_paths: set[str] = set()
    for index, attachment in enumerate(attachments):
        label = f"evidence receipt {criterion_id}/{artifact_kind} attachment {index}"
        if not isinstance(attachment, dict):
            raise AcceptanceError(f"{label} must be an object")
        expect_keys(attachment, {"role", "path", "sha256"}, label)
        role = attachment["role"]
        if role not in {"primary", "supporting"}:
            raise AcceptanceError(f"{label} role must be primary or supporting")
        primary_count += int(role == "primary")
        relative = expect_string(attachment["path"], f"{label} path")
        if relative in seen_paths:
            raise AcceptanceError(f"{label} duplicates attachment path {relative}")
        seen_paths.add(relative)
        payload = resolve_evidence_path(run_root, relative)
        if payload == receipt_path:
            raise AcceptanceError(f"{label} must not point back to its receipt")
        expected_hash = expect_sha256(attachment["sha256"], f"{label} hash")
        if sha256_path(payload) != expected_hash:
            raise AcceptanceError(f"{label} hash changed: {relative}")
        if role == "primary":
            primary_payload = payload
        elif payload.is_file() and payload.stat().st_size == 0:
            raise AcceptanceError(f"{label} is empty")
        elif payload.is_dir():
            sha256_path(payload)
    if primary_count != 1:
        raise AcceptanceError(
            f"evidence receipt {criterion_id}/{artifact_kind} needs exactly one primary attachment"
        )
    assert primary_payload is not None
    derived_metrics = derive_payload_metrics(
        criterion_id,
        artifact_kind,
        primary_payload,
        f"evidence receipt {criterion_id}/{artifact_kind} primary attachment",
        process_roles={
            pid: role
            for pid, role in (process_build_roles or {}).items()
            if pid in artifact_pids
        }
        if artifact_kind in TRACE_ARTIFACT_KINDS
        else None,
        source_commit=source_commit,
    )
    if derived_metrics is None:
        if expected_pass:
            raise AcceptanceError(
                f"passing evidence for {criterion_id}/{artifact_kind} has no "
                "repository-owned semantic trace extractor"
            )
    else:
        if set(derived_metrics) != required_metrics:
            raise AcceptanceError(
                f"repository deriver for {criterion_id}/{artifact_kind} produced the wrong metrics: "
                f"expected {sorted(required_metrics)}, got {sorted(derived_metrics)}"
            )
        if metrics != derived_metrics:
            raise AcceptanceError(
                f"evidence receipt {criterion_id}/{artifact_kind} metrics were not derived "
                "from its raw primary attachment"
            )
        if artifact_kind in {"conformance-test", "integration-test"}:
            if metrics["binary_source_commit"] != source_commit:
                raise AcceptanceError(
                    f"evidence receipt {criterion_id}/{artifact_kind} test binary belongs to a different commit"
                )
            if metrics["command_sha256"] != sha256_json(command):
                raise AcceptanceError(
                    f"evidence receipt {criterion_id}/{artifact_kind} runner command differs from the receipt"
                )
        if criterion_id == "FID-1" and artifact_kind == "golden-image":
            if metrics["source_commit"] != source_commit:
                raise AcceptanceError(f"FID-1 golden image belongs to a different commit")
            if artifact_pids != [metrics["process_pid"]]:
                raise AcceptanceError(f"FID-1 golden image PID does not match its provenance")
        if criterion_id == "FID-1" and artifact_kind == "image-diff":
            fidelity_pids = sorted(
                [metrics["expected_process_pid"], metrics["actual_process_pid"]]
            )
            if artifact_pids != fidelity_pids:
                raise AcceptanceError(f"FID-1 image-diff PIDs do not match both renderers")
            if (
                metrics["expected_source_commit"] != source_commit
                or metrics["actual_source_commit"] != source_commit
            ):
                raise AcceptanceError(f"FID-1 image-diff belongs to a different commit")
        if criterion_id == "PERF-2" and artifact_kind == "process-census":
            if metrics["collector_source_commit"] != source_commit:
                raise AcceptanceError(f"PERF-2 collector belongs to a different commit")
            if metrics["collector_command_sha256"] != sha256_json(command):
                raise AcceptanceError(f"PERF-2 collector command differs from the receipt")
            if metrics["observed_pid_set_sha256"] != sha256_json(artifact_pids):
                raise AcceptanceError(
                    f"PERF-2 artifact PIDs do not match the live collector process set"
                )
            if environment is None:
                raise AcceptanceError(f"PERF-2 collector lacks manifest environment binding")
            raw_context, _ = load_raw_artifact(
                primary_payload,
                artifact_kind,
                f"evidence receipt {criterion_id}/{artifact_kind} primary attachment",
            )
            collector_context = _raw_dict(raw_context.get("collector"), "PERF-2 collector")
            for environment_key in ("hardware_model", "os_build"):
                if collector_context.get(environment_key) != environment.get(environment_key):
                    raise AcceptanceError(
                        f"PERF-2 collector {environment_key} differs from the manifest"
                    )
            _, raw_records = load_raw_artifact(
                primary_payload,
                artifact_kind,
                f"evidence receipt {criterion_id}/{artifact_kind} primary attachment",
            )
            if bound_processes is None:
                raise AcceptanceError("PERF-2 live process identities are not manifest-bound")
            for index, raw_record in enumerate(raw_records):
                process = _raw_dict(raw_record, f"PERF-2 process {index}")
                pid = process["pid"]
                bound = bound_processes.get(pid)
                if bound is None or (
                    process.get("started_at") != bound.get("started_at")
                    or process.get("executable_sha256") != bound.get("executable_sha256")
                ):
                    raise AcceptanceError(
                        f"PERF-2 process PID {pid} differs from its manifest-bound identity"
                    )
    if expected_pass:
        validate_metric_invariants(
            criterion_id,
            artifact_kind,
            metrics,
            f"evidence receipt {criterion_id}/{artifact_kind}",
        )
    return captured_at


def parse_json_array(raw: str, label: str) -> list[Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"invalid {label} JSON: {error}") from error
    if not isinstance(value, list):
        raise AcceptanceError(f"{label} must be a JSON array")
    return value


def parse_lsof_pty_masters(output: str) -> list[str]:
    """Return PTY-master FD/name pairs from `lsof -F fn` output."""
    result: list[str] = []
    descriptor: str | None = None
    for line in output.splitlines():
        if line.startswith("f"):
            descriptor = line[1:]
        elif line.startswith("n") and descriptor is not None:
            name = line[1:]
            basename = pathlib.PurePosixPath(name).name
            is_master = name == "/dev/ptmx" or re.fullmatch(
                r"pty[p-sP-S][0-9a-vA-V]", basename
            ) is not None
            if is_master:
                result.append(f"{descriptor}:{name}")
    return sorted(set(result))


def collect_process_census(arguments: argparse.Namespace) -> pathlib.Path:
    """Capture live process identities and kernel-visible PTY master FDs."""
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit, expected_submodules = assert_clean_source()
    if manifest["source"]["commit"] != expected_commit:
        raise AcceptanceError("process census manifest is not for current clean HEAD")
    if manifest["source"]["submodules"] != expected_submodules:
        raise AcceptanceError("process census manifest submodules are stale")
    records: list[dict[str, Any]] = []
    for process in manifest["processes"]:
        role = process["build_role"]
        if role not in {"swift-host", "terminal-backend", "renderer-worker"}:
            continue
        pid = process["pid"]
        if process_started_at(pid) != process["started_at"]:
            raise AcceptanceError(f"PID {pid} no longer matches its bound start identity")
        executable = process_executable(pid)
        if sha256_file(executable) != process["executable_sha256"]:
            raise AcceptanceError(f"PID {pid} executable changed since it was bound")
        lsof_output = run(["lsof", "-n", "-P", "-a", "-p", str(pid), "-F", "fn"])
        records.append({
            "role": role,
            "pid": pid,
            "pty_master_fds": parse_lsof_pty_masters(lsof_output),
        })
    roles = collections.Counter(record["role"] for record in records)
    if roles["swift-host"] != 1 or roles["terminal-backend"] != 1:
        raise AcceptanceError("process census needs one bound Swift host and terminal backend")
    if roles["renderer-worker"] < 1:
        raise AcceptanceError("process census needs at least one bound renderer worker")
    run_root = manifest_path.parent
    output = (run_root / arguments.output).resolve()
    try:
        output.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError("process census output escapes the evidence directory") from error
    if output.suffix.lower() != ".json":
        raise AcceptanceError("process census output must be JSON")
    if output.exists() and not arguments.replace:
        raise AcceptanceError(f"process census already exists: {output}; pass --replace")
    atomic_write_json(output, {
        "schema_version": 1,
        "artifact_kind": "process-census",
        "context": {},
        "records": records,
    })
    return output


def collect_linkage_audit(arguments: argparse.Namespace) -> pathlib.Path:
    """Capture the fixed-root linkage scan for the manifest's exact commit."""
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit, expected_submodules = assert_clean_source()
    if manifest["source"]["commit"] != expected_commit:
        raise AcceptanceError("linkage audit manifest is not for current clean HEAD")
    if manifest["source"]["submodules"] != expected_submodules:
        raise AcceptanceError("linkage audit manifest submodules are stale")

    payload = build_linkage_audit_artifact(REPO_ROOT, expected_commit)
    run_root = manifest_path.parent
    output = (run_root / arguments.output).resolve()
    try:
        output.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError("linkage audit output escapes the evidence directory") from error
    if output.suffix.lower() != ".json":
        raise AcceptanceError("linkage audit output must be JSON")
    if output.exists() and not arguments.replace:
        raise AcceptanceError(f"linkage audit already exists: {output}; pass --replace")

    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (expected_commit, expected_submodules):
        raise AcceptanceError("source changed while the linkage audit was collected")
    atomic_write_json(output, payload)
    return output


def derive_receipt(arguments: argparse.Namespace) -> pathlib.Path:
    """Create a receipt whose metrics come only from its raw primary payload."""
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit = manifest["source"]["commit"]
    before_commit, before_submodules = assert_clean_source()
    if expected_commit != before_commit or manifest["source"]["submodules"] != before_submodules:
        raise AcceptanceError("manifest source is not the current clean source")
    criterion = next(
        (candidate for candidate in spec["criteria"] if candidate["id"] == arguments.id),
        None,
    )
    if criterion is None:
        raise AcceptanceError(f"unknown acceptance criterion {arguments.id}")
    if arguments.kind not in criterion["required_artifact_kinds"]:
        raise AcceptanceError(
            f"artifact kind {arguments.kind!r} is not required by criterion {arguments.id}"
        )
    commands = [parse_json_array(raw, "command") for raw in arguments.command_json]
    if len(commands) != 1 or not commands[0] or any(
        not isinstance(item, str) or not item for item in commands[0]
    ):
        raise AcceptanceError("derive-receipt requires exactly one non-empty string command array")
    if not arguments.observation or any(not value for value in arguments.observation):
        raise AcceptanceError("derive-receipt requires at least one observation")
    pids = sorted(set(arguments.pid))
    if not pids or any(pid <= 0 for pid in pids):
        raise AcceptanceError("derive-receipt requires positive live PIDs")
    known_pids = {process["pid"] for process in manifest["processes"]}
    unknown = set(pids) - known_pids
    if unknown:
        raise AcceptanceError(f"derive-receipt cites unbound PIDs: {sorted(unknown)}")

    run_root = manifest_path.parent
    primary = resolve_evidence_path(run_root, arguments.primary)
    process_roles = {
        process["pid"]: process["build_role"]
        for process in manifest["processes"]
        if process["pid"] in pids and process["build_role"] is not None
    }
    metrics = derive_payload_metrics(
        arguments.id,
        arguments.kind,
        primary,
        f"{arguments.id}/{arguments.kind} primary attachment",
        process_roles=process_roles if arguments.kind in TRACE_ARTIFACT_KINDS else None,
        source_commit=expected_commit,
    )
    if metrics is None:
        raise AcceptanceError(
            f"{arguments.kind} has no repository-owned semantic trace extractor; "
            "it cannot produce a passing receipt"
        )
    required_metrics = ARTIFACT_REQUIRED_METRICS[arguments.kind] | CRITERION_REQUIRED_METRICS.get(
        (arguments.id, arguments.kind), set()
    )
    if set(metrics) != required_metrics:
        raise AcceptanceError(
            f"repository deriver produced the wrong metric set for {arguments.id}/{arguments.kind}"
        )
    if arguments.kind in {"conformance-test", "integration-test"}:
        if metrics["binary_source_commit"] != expected_commit:
            raise AcceptanceError("test binary source commit differs from the manifest")
        if metrics["command_sha256"] != sha256_json(commands[0]):
            raise AcceptanceError("test runner command differs from the receipt command")
    if arguments.id == "FID-1" and arguments.kind == "golden-image":
        if metrics["source_commit"] != expected_commit or pids != [metrics["process_pid"]]:
            raise AcceptanceError("FID-1 golden provenance differs from the manifest/PIDs")
    if arguments.id == "FID-1" and arguments.kind == "image-diff":
        expected_pids = sorted(
            [metrics["expected_process_pid"], metrics["actual_process_pid"]]
        )
        if pids != expected_pids or any(
            metrics[f"{prefix}_source_commit"] != expected_commit
            for prefix in ("expected", "actual")
        ):
            raise AcceptanceError("FID-1 image provenance differs from the manifest/PIDs")
    if arguments.id == "PERF-2" and arguments.kind == "process-census":
        if metrics["collector_source_commit"] != expected_commit:
            raise AcceptanceError("PERF-2 collector source commit differs from the manifest")
        if metrics["collector_command_sha256"] != sha256_json(commands[0]):
            raise AcceptanceError("PERF-2 collector command differs from the receipt command")
        if metrics["observed_pid_set_sha256"] != sha256_json(pids):
            raise AcceptanceError("PERF-2 live process set differs from the receipt PIDs")
        raw_context, raw_records = load_raw_artifact(
            primary, arguments.kind, "PERF-2 process census"
        )
        collector = _raw_dict(raw_context.get("collector"), "PERF-2 collector")
        for environment_key in ("hardware_model", "os_build"):
            if collector.get(environment_key) != manifest["environment"].get(environment_key):
                raise AcceptanceError(
                    f"PERF-2 collector {environment_key} differs from the manifest"
                )
        bound = {process["pid"]: process for process in manifest["processes"]}
        for index, raw_record in enumerate(raw_records):
            process = _raw_dict(raw_record, f"PERF-2 process {index}")
            identity = bound.get(process["pid"])
            if identity is None or (
                identity.get("started_at") != process.get("started_at")
                or identity.get("executable_sha256") != process.get("executable_sha256")
            ):
                raise AcceptanceError(
                    f"PERF-2 process PID {process['pid']} differs from the manifest"
                )
    if arguments.status == "pass":
        validate_metric_invariants(arguments.id, arguments.kind, metrics, "derived receipt")

    attachment_paths: list[tuple[str, pathlib.Path]] = [("primary", primary)]
    for relative in arguments.supporting:
        attachment_paths.append(("supporting", resolve_evidence_path(run_root, relative)))
    if len({path for _, path in attachment_paths}) != len(attachment_paths):
        raise AcceptanceError("derive-receipt attachments must be unique")
    output = (run_root / arguments.output).resolve()
    try:
        output.relative_to(run_root.resolve())
    except ValueError as error:
        raise AcceptanceError("derive-receipt output escapes the evidence directory") from error
    if output.suffix.lower() != ".json":
        raise AcceptanceError("derive-receipt output must be a JSON file")
    if output in {path for _, path in attachment_paths}:
        raise AcceptanceError("derive-receipt output cannot overwrite an attachment")
    if output.exists() and not arguments.replace:
        raise AcceptanceError(f"receipt already exists: {output}; pass --replace")

    receipt = {
        "schema_version": 1,
        "criterion_id": arguments.id,
        "artifact_kind": arguments.kind,
        "source_commit": expected_commit,
        "captured_at": utc_now(),
        "command": commands[0],
        "passed": arguments.status == "pass",
        "pids": pids,
        "observations": arguments.observation,
        "metrics": metrics,
        "attachments": [
            {
                "role": role,
                "path": path.relative_to(run_root).as_posix(),
                "sha256": sha256_path(path),
            }
            for role, path in attachment_paths
        ],
    }
    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (before_commit, before_submodules):
        raise AcceptanceError("source changed while the receipt was derived")
    atomic_write_json(output, receipt)
    return output


def record(arguments: argparse.Namespace) -> pathlib.Path:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit = manifest.get("source", {}).get("commit")
    before_commit, before_submodules = assert_clean_source()
    if expected_commit != before_commit:
        raise AcceptanceError(
            f"manifest belongs to {expected_commit}, current source is {before_commit}"
        )
    if manifest.get("source", {}).get("submodules") != before_submodules:
        raise AcceptanceError("submodule commits changed since capture")
    check = check_by_id(manifest, arguments.id)
    criterion = next(
        criterion for criterion in spec["criteria"] if criterion["id"] == arguments.id
    )
    commands = [parse_json_array(raw, "command") for raw in arguments.command_json]
    for command in commands:
        if not command or any(not isinstance(item, str) for item in command):
            raise AcceptanceError("every command must be a non-empty string array")
    run_root = manifest_path.parent
    process_build_roles = {
        process["pid"]: process["build_role"]
        for process in manifest["processes"]
        if process["build_role"] is not None
    }
    bound_processes = {process["pid"]: process for process in manifest["processes"]}
    artifacts: list[dict[str, Any]] = []
    artifact_metrics: dict[str, dict[str, Any]] = {}
    recorded_kinds: set[str] = set()
    for raw in arguments.artifact_json:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise AcceptanceError(f"invalid artifact JSON: {error}") from error
        if not isinstance(value, dict):
            raise AcceptanceError("artifact must be a JSON object")
        kind = value.get("kind")
        relative = value.get("path")
        pids = value.get("pids", [])
        if not isinstance(kind, str) or not kind:
            raise AcceptanceError("artifact kind must be a non-empty string")
        if kind not in criterion["required_artifact_kinds"]:
            raise AcceptanceError(
                f"artifact kind {kind!r} is not required by criterion {arguments.id}"
            )
        if kind in recorded_kinds:
            raise AcceptanceError(
                f"criterion {arguments.id} contains duplicate artifact kind {kind!r}"
            )
        recorded_kinds.add(kind)
        if not isinstance(relative, str) or not relative:
            raise AcceptanceError("artifact path must be a non-empty string")
        if not isinstance(pids, list) or any(not isinstance(pid, int) or pid <= 0 for pid in pids):
            raise AcceptanceError("artifact pids must be positive integers")
        path = resolve_artifact(run_root, relative)
        sorted_pids = sorted(set(pids))
        captured_at = validate_evidence_receipt(
            receipt_path=path,
            run_root=run_root,
            criterion_id=arguments.id,
            artifact_kind=kind,
            source_commit=expected_commit,
            artifact_pids=sorted_pids,
            commands=commands,
            expected_pass=arguments.status == "pass",
            process_build_roles=process_build_roles,
            bound_processes=bound_processes,
            environment=manifest["environment"],
        )
        artifact_metrics[kind] = load_json(path)["metrics"]
        artifacts.append(
            {
                "kind": kind,
                "path": relative,
                "sha256": sha256_file(path),
                "captured_at": captured_at,
                "pids": sorted_pids,
            }
        )
    if arguments.status == "pass":
        validate_cross_artifact_invariants(
            arguments.id,
            artifact_metrics,
            f"criterion {arguments.id}",
            source_commit=expected_commit,
            environment=manifest["environment"],
        )
    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (before_commit, before_submodules):
        raise AcceptanceError("source changed while evidence was recorded")
    check["status"] = arguments.status
    check["commands"] = commands
    check["assertions"] = arguments.assertion
    check["artifacts"] = artifacts
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def bind_process(arguments: argparse.Namespace) -> pathlib.Path:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    expected_commit = manifest["source"]["commit"]
    before_commit, before_submodules = assert_clean_source()
    if expected_commit != before_commit:
        raise AcceptanceError(
            f"manifest belongs to {expected_commit}, current source is {before_commit}"
        )
    if manifest["source"]["submodules"] != before_submodules:
        raise AcceptanceError("submodule commits changed since capture")
    started_at = process_started_at(arguments.pid)
    executable = process_executable(arguments.pid)
    executable_hash = sha256_file(executable)
    packaged = {
        item["role"]: item["sha256"]
        for item in manifest["build"]["executables"]
        if isinstance(item, dict)
    }
    if arguments.build_role is not None:
        expected_hash = packaged.get(arguments.build_role)
        if expected_hash is None:
            raise AcceptanceError(f"unknown packaged executable role {arguments.build_role!r}")
        if executable_hash != expected_hash:
            raise AcceptanceError(
                f"PID {arguments.pid} executable does not match packaged {arguments.build_role}"
            )
    if process_started_at(arguments.pid) != started_at:
        raise AcceptanceError(f"PID {arguments.pid} changed identity while it was recorded")
    entry = {
        "role": arguments.role,
        "build_role": arguments.build_role,
        "pid": arguments.pid,
        "started_at": started_at,
        "executable_path": str(executable),
        "executable_sha256": executable_hash,
    }
    processes = manifest["processes"]
    identity = (arguments.pid, started_at)
    existing = [
        process
        for process in processes
        if (process.get("pid"), process.get("started_at")) == identity
    ]
    if existing:
        if len(existing) != 1 or existing[0] != entry:
            raise AcceptanceError(f"PID {arguments.pid} is already bound with different identity")
    else:
        processes.append(entry)
    after_commit, after_submodules = assert_clean_source()
    if (after_commit, after_submodules) != (before_commit, before_submodules):
        raise AcceptanceError("source changed while process identity was recorded")
    atomic_write_json(manifest_path, manifest)
    return manifest_path


def expect_type(value: Any, expected: type, label: str) -> None:
    if not isinstance(value, expected):
        raise AcceptanceError(f"{label} must be {expected.__name__}")


def validate_shape(manifest: dict[str, Any], spec: dict[str, Any]) -> None:
    required_top = {
        "schema_version",
        "criteria_sha256",
        "source",
        "build",
        "environment",
        "protocol",
        "roles",
        "processes",
        "checks",
    }
    expect_keys(manifest, required_top, "manifest top-level")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise AcceptanceError("unsupported manifest schema version")
    if manifest["criteria_sha256"] != sha256_file(SPEC_PATH):
        raise AcceptanceError("acceptance criteria changed after capture")
    for name in ("source", "build", "environment", "protocol", "roles"):
        expect_type(manifest[name], dict, name)
    expect_type(manifest["processes"], list, "processes")
    expect_type(manifest["checks"], list, "checks")

    source = manifest["source"]
    expect_keys(source, {"commit", "clean", "submodules"}, "source")
    expect_commit(source["commit"], "source commit")
    if source["clean"] is not True:
        raise AcceptanceError("source clean must be true")
    expect_type(source["submodules"], dict, "source submodules")
    for path, commit in source["submodules"].items():
        expect_string(path, "submodule path")
        expect_commit(commit, f"submodule {path} commit")

    build = manifest["build"]
    expect_keys(
        build,
        {
            "tag",
            "bundle_id",
            "app_path",
            "info_plist_sha256",
            "executables",
            "debug_socket",
            "backend_socket",
        },
        "build",
    )
    for field in ("tag", "bundle_id", "app_path", "debug_socket", "backend_socket"):
        expect_string(build[field], f"build {field}")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}", build["tag"]) is None:
        raise AcceptanceError("build tag contains unsafe characters")
    if not pathlib.Path(build["app_path"]).is_absolute():
        raise AcceptanceError("build app_path must be absolute")
    expect_sha256(build["info_plist_sha256"], "build info_plist_sha256")
    for field in ("debug_socket", "backend_socket"):
        if not pathlib.Path(build[field]).is_absolute():
            raise AcceptanceError(f"build {field} must be absolute")
    expect_type(build["executables"], list, "build executables")
    expected_build_roles = ["swift-host", "terminal-backend", "renderer-worker"]
    actual_build_roles: list[str] = []
    for index, executable in enumerate(build["executables"]):
        if not isinstance(executable, dict):
            raise AcceptanceError(f"build executable {index} must be an object")
        expect_keys(executable, {"role", "path", "sha256"}, f"build executable {index}")
        actual_build_roles.append(expect_string(executable["role"], f"build executable {index} role"))
        relative = expect_string(executable["path"], f"build executable {index} path")
        if pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
            raise AcceptanceError(f"build executable {index} path must stay inside the app")
        expect_sha256(executable["sha256"], f"build executable {index} hash")
    if actual_build_roles != expected_build_roles:
        raise AcceptanceError(
            f"build executable roles must be exactly {expected_build_roles}, got {actual_build_roles}"
        )

    environment = manifest["environment"]
    expect_keys(environment, {"os_build", "hardware_model", "captured_at"}, "environment")
    expect_string(environment["os_build"], "environment os_build")
    expect_string(environment["hardware_model"], "environment hardware_model")
    parse_timestamp(environment["captured_at"], "environment captured_at")

    protocol = manifest["protocol"]
    expect_keys(
        protocol,
        {"client_range", "daemon_range", "negotiated", "capabilities"},
        "protocol",
    )
    ranges: dict[str, tuple[int, int]] = {}
    for name in ("client_range", "daemon_range"):
        value = protocol[name]
        if (
            not isinstance(value, list)
            or len(value) != 2
            or any(not isinstance(item, int) or isinstance(item, bool) or item < 1 for item in value)
            or value[0] > value[1]
        ):
            raise AcceptanceError(f"protocol {name} must be an ascending positive integer pair")
        ranges[name] = (value[0], value[1])
    negotiated = protocol["negotiated"]
    if not isinstance(negotiated, int) or isinstance(negotiated, bool) or negotiated < 1:
        raise AcceptanceError("protocol negotiated must be a positive integer")
    if not all(lower <= negotiated <= upper for lower, upper in ranges.values()):
        raise AcceptanceError("protocol negotiated is outside one of the advertised ranges")
    capabilities = protocol["capabilities"]
    if (
        not isinstance(capabilities, list)
        or any(not isinstance(capability, str) or not capability for capability in capabilities)
        or len(set(capabilities)) != len(capabilities)
    ):
        raise AcceptanceError("protocol capabilities must be unique non-empty strings")

    roles = manifest["roles"]
    role_names = {
        "acceptance_author",
        "implementer",
        "interaction_profiler",
        "artifact_verifier",
    }
    expect_keys(roles, role_names, "roles")
    for name in role_names:
        expect_string(roles[name], f"role {name}")

    process_identities: set[tuple[int, str]] = set()
    for index, process in enumerate(manifest["processes"]):
        if not isinstance(process, dict):
            raise AcceptanceError(f"process {index} must be an object")
        expect_keys(
            process,
            {"role", "build_role", "pid", "started_at", "executable_path", "executable_sha256"},
            f"process {index}",
        )
        expect_string(process["role"], f"process {index} role")
        if process["build_role"] is not None and process["build_role"] not in expected_build_roles:
            raise AcceptanceError(f"process {index} has an unknown build role")
        pid = process["pid"]
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            raise AcceptanceError(f"process {index} PID must be a positive integer")
        started_at = expect_string(process["started_at"], f"process {index} started_at")
        parse_timestamp(started_at, f"process {index} started_at")
        executable_path = expect_string(
            process["executable_path"], f"process {index} executable_path"
        )
        if not pathlib.Path(executable_path).is_absolute():
            raise AcceptanceError(f"process {index} executable_path must be absolute")
        expect_sha256(process["executable_sha256"], f"process {index} executable hash")
        identity = (pid, started_at)
        if identity in process_identities:
            raise AcceptanceError(f"process {index} duplicates PID/start identity {identity}")
        process_identities.add(identity)

    expected_ids = [criterion["id"] for criterion in spec["criteria"]]
    actual_ids = [check.get("id") for check in manifest["checks"] if isinstance(check, dict)]
    if actual_ids != expected_ids:
        raise AcceptanceError("manifest criteria do not exactly match spec order")
    for criterion, check in zip(spec["criteria"], manifest["checks"], strict=True):
        if not isinstance(check, dict):
            raise AcceptanceError(f"check {criterion['id']} must be an object")
        expect_keys(
            check,
            {"id", "priority", "status", "commands", "assertions", "artifacts"},
            f"check {criterion['id']}",
        )
        if check["priority"] != criterion["priority"] or check["status"] not in {"pass", "fail"}:
            raise AcceptanceError(f"check {criterion['id']} has invalid priority or status")
        expect_type(check["commands"], list, f"{criterion['id']} commands")
        expect_type(check["assertions"], list, f"{criterion['id']} assertions")
        expect_type(check["artifacts"], list, f"{criterion['id']} artifacts")
        for command in check["commands"]:
            if not isinstance(command, list) or not command or any(
                not isinstance(item, str) for item in command
            ):
                raise AcceptanceError(f"check {criterion['id']} contains an invalid command")
        if any(not isinstance(assertion, str) or not assertion for assertion in check["assertions"]):
            raise AcceptanceError(f"check {criterion['id']} contains an invalid assertion")
        for artifact_index, artifact in enumerate(check["artifacts"]):
            if not isinstance(artifact, dict):
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} must be an object"
                )
            expect_keys(
                artifact,
                {"kind", "path", "sha256", "captured_at", "pids"},
                f"check {criterion['id']} artifact {artifact_index}",
            )
            expect_string(
                artifact["kind"], f"check {criterion['id']} artifact {artifact_index} kind"
            )
            relative = expect_string(
                artifact["path"], f"check {criterion['id']} artifact {artifact_index} path"
            )
            if pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} path must stay inside evidence"
                )
            expect_sha256(
                artifact["sha256"], f"check {criterion['id']} artifact {artifact_index} hash"
            )
            parse_timestamp(
                artifact["captured_at"],
                f"check {criterion['id']} artifact {artifact_index} captured_at",
            )
            pids = artifact["pids"]
            if (
                not isinstance(pids, list)
                or any(not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0 for pid in pids)
                or pids != sorted(set(pids))
            ):
                raise AcceptanceError(
                    f"check {criterion['id']} artifact {artifact_index} PIDs must be sorted unique positive integers"
                )


def verify(arguments: argparse.Namespace) -> None:
    manifest_path = arguments.manifest.expanduser().resolve()
    manifest = load_json(manifest_path)
    spec = load_spec()
    validate_shape(manifest, spec)
    source = manifest["source"]
    if source.get("clean") is not True:
        raise AcceptanceError("manifest was not captured from clean source")
    if arguments.require_final_head:
        commit, submodules = assert_clean_source()
        if source.get("commit") != commit:
            raise AcceptanceError(f"manifest commit {source.get('commit')} is not HEAD {commit}")
        if source.get("submodules") != submodules:
            raise AcceptanceError("manifest submodule commits are not current")
    build = manifest["build"]
    app = pathlib.Path(build.get("app_path", ""))
    bundle_id, _, app_commit, app_dirty = app_identity(app)
    if bundle_id != build.get("bundle_id"):
        raise AcceptanceError("tagged app bundle identifier changed after capture")
    if app_commit != source["commit"] or app_dirty != "NO":
        raise AcceptanceError("tagged app source identity no longer matches clean manifest source")
    if sha256_file(app / "Contents/Info.plist") != build["info_plist_sha256"]:
        raise AcceptanceError("tagged app Info.plist changed after capture")
    packaged_hashes: dict[str, str] = {}
    for item in build["executables"]:
        path = (app / item["path"]).resolve()
        try:
            path.relative_to(app.resolve())
        except ValueError as error:
            raise AcceptanceError(f"packaged executable escapes app: {item['path']}") from error
        if not path.is_file() or sha256_file(path) != item["sha256"]:
            raise AcceptanceError(f"packaged {item['role']} executable changed after capture")
        packaged_hashes[item["role"]] = item["sha256"]
    roles = manifest["roles"]
    role_values = [
        roles.get("acceptance_author"),
        roles.get("implementer"),
        roles.get("interaction_profiler"),
        roles.get("artifact_verifier"),
    ]
    if any(not isinstance(value, str) or not value or value == "unassigned" for value in role_values):
        raise AcceptanceError("all acceptance roles must be assigned")
    if len(set(role_values)) != len(role_values):
        raise AcceptanceError("all acceptance roles must differ")
    known_pids: set[int] = set()
    bound_build_roles: set[str] = set()
    process_build_roles: dict[int, str] = {}
    bound_processes: dict[int, dict[str, Any]] = {}
    for process in manifest["processes"]:
        known_pids.add(process["pid"])
        bound_processes[process["pid"]] = process
        build_role = process["build_role"]
        if build_role is not None:
            if process["executable_sha256"] != packaged_hashes[build_role]:
                raise AcceptanceError(
                    f"recorded PID {process['pid']} does not match packaged {build_role} hash"
                )
            bound_build_roles.add(build_role)
            process_build_roles[process["pid"]] = build_role
    if arguments.require_all_p0:
        missing_roles = set(packaged_hashes) - bound_build_roles
        if missing_roles:
            raise AcceptanceError(
                f"P0 verification lacks process identities for: {sorted(missing_roles)}"
            )
    run_root = manifest_path.parent
    criteria_by_id = {criterion["id"]: criterion for criterion in spec["criteria"]}
    failed: list[str] = []
    for check in manifest["checks"]:
        identifier = check["id"]
        criterion = criteria_by_id[identifier]
        artifact_kinds: set[str] = set()
        artifact_metrics: dict[str, dict[str, Any]] = {}
        for artifact in check["artifacts"]:
            if not isinstance(artifact, dict):
                raise AcceptanceError(f"check {identifier} has a non-object artifact")
            path = resolve_artifact(run_root, artifact.get("path", ""))
            if sha256_file(path) != artifact.get("sha256"):
                raise AcceptanceError(f"artifact hash changed: {artifact.get('path')}")
            unknown_pids = set(artifact["pids"]) - known_pids
            if unknown_pids:
                raise AcceptanceError(
                    f"artifact {artifact['path']} cites unbound PIDs: {sorted(unknown_pids)}"
                )
            kind = artifact.get("kind")
            if kind in artifact_kinds:
                raise AcceptanceError(
                    f"check {identifier} repeats artifact kind {kind!r}"
                )
            artifact_kinds.add(kind)
            receipt_captured_at = validate_evidence_receipt(
                receipt_path=path,
                run_root=run_root,
                criterion_id=identifier,
                artifact_kind=kind,
                source_commit=source["commit"],
                artifact_pids=artifact["pids"],
                commands=check["commands"],
                expected_pass=check["status"] == "pass",
                process_build_roles=process_build_roles,
                bound_processes=bound_processes,
                environment=manifest["environment"],
            )
            if receipt_captured_at != artifact["captured_at"]:
                raise AcceptanceError(
                    f"artifact {artifact['path']} capture time disagrees with its receipt"
                )
            artifact_metrics[kind] = load_json(path)["metrics"]
        if check["status"] == "pass":
            required_kinds = set(criterion["required_artifact_kinds"])
            if artifact_kinds != required_kinds:
                raise AcceptanceError(
                    f"passing check {identifier} artifact kinds differ from its contract: "
                    f"expected {sorted(required_kinds)}, got {sorted(artifact_kinds)}"
                )
            if not check["commands"] or not check["assertions"]:
                raise AcceptanceError(f"passing check {identifier} needs commands and assertions")
            validate_cross_artifact_invariants(
                identifier,
                artifact_metrics,
                f"criterion {identifier}",
                source_commit=source["commit"],
                environment=manifest["environment"],
            )
        elif criterion["priority"] == "P0":
            failed.append(identifier)
    if arguments.require_all_p0 and failed:
        raise AcceptanceError(f"P0 acceptance checks failed: {', '.join(failed)}")


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    subparsers = argument_parser.add_subparsers(dest="operation", required=True)

    capture_parser = subparsers.add_parser("capture", help="initialize commit-bound evidence")
    capture_parser.add_argument("--tag", required=True)
    capture_parser.add_argument("--artifact-root", type=pathlib.Path, required=True)
    capture_parser.add_argument("--app", type=pathlib.Path)
    capture_parser.add_argument("--debug-socket")
    capture_parser.add_argument("--backend-socket")
    capture_parser.add_argument("--protocol-min", type=int, default=8)
    capture_parser.add_argument("--protocol-max", type=int, default=9)
    capture_parser.add_argument("--acceptance-author")
    capture_parser.add_argument("--implementer")
    capture_parser.add_argument("--interaction-profiler")
    capture_parser.add_argument("--artifact-verifier")
    capture_parser.add_argument("--replace", action="store_true")

    derive_parser = subparsers.add_parser(
        "derive-receipt",
        help="derive a semantic receipt from a repository-defined raw artifact",
    )
    derive_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    derive_parser.add_argument("--id", required=True)
    derive_parser.add_argument("--kind", required=True)
    derive_parser.add_argument("--status", choices=("pass", "fail"), required=True)
    derive_parser.add_argument("--primary", required=True)
    derive_parser.add_argument("--supporting", action="append", default=[])
    derive_parser.add_argument("--output", required=True)
    derive_parser.add_argument("--pid", action="append", type=int, default=[])
    derive_parser.add_argument("--command-json", action="append", default=[])
    derive_parser.add_argument("--observation", action="append", default=[])
    derive_parser.add_argument("--replace", action="store_true")

    census_parser = subparsers.add_parser(
        "collect-process-census",
        help="capture bound process identities and PTY-master file descriptors",
    )
    census_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    census_parser.add_argument("--output", required=True)
    census_parser.add_argument("--replace", action="store_true")

    linkage_parser = subparsers.add_parser(
        "collect-linkage-audit",
        help="scan fixed production roots at the manifest-bound commit",
    )
    linkage_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    linkage_parser.add_argument("--output", required=True)
    linkage_parser.add_argument("--replace", action="store_true")

    record_parser = subparsers.add_parser("record", help="record one check's evidence")
    record_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    record_parser.add_argument("--id", required=True)
    record_parser.add_argument("--status", choices=("pass", "fail"), required=True)
    record_parser.add_argument("--command-json", action="append", default=[])
    record_parser.add_argument("--assertion", action="append", default=[])
    record_parser.add_argument("--artifact-json", action="append", default=[])

    process_parser = subparsers.add_parser(
        "bind-process", help="bind a live process identity to packaged binaries"
    )
    process_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    process_parser.add_argument("--role", required=True)
    process_parser.add_argument(
        "--build-role", choices=("swift-host", "terminal-backend", "renderer-worker")
    )
    process_parser.add_argument("--pid", type=int, required=True)

    verify_parser = subparsers.add_parser("verify", help="verify evidence and source binding")
    verify_parser.add_argument("--manifest", type=pathlib.Path, required=True)
    verify_parser.add_argument("--require-final-head", action="store_true")
    verify_parser.add_argument("--require-all-p0", action="store_true")
    return argument_parser


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.operation == "capture":
            path = capture(arguments)
            print(path)
        elif arguments.operation == "derive-receipt":
            path = derive_receipt(arguments)
            print(path)
        elif arguments.operation == "collect-process-census":
            path = collect_process_census(arguments)
            print(path)
        elif arguments.operation == "collect-linkage-audit":
            path = collect_linkage_audit(arguments)
            print(path)
        elif arguments.operation == "record":
            path = record(arguments)
            print(path)
        elif arguments.operation == "bind-process":
            path = bind_process(arguments)
            print(path)
        else:
            verify(arguments)
            print("terminal backend acceptance manifest verified")
    except AcceptanceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
