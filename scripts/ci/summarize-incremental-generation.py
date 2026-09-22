#!/usr/bin/env python3
"""Summarize Xcode incremental-generation benchmark rows with transfer charged."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def number(value) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    return float(value)


def nested(mapping: object, *keys: str) -> object:
    value = mapping
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def row_download_seconds(row: dict[str, object]) -> float:
    combined = nested(row, "generation_download", "seconds")
    if isinstance(combined, (int, float)) and not isinstance(combined, bool):
        return float(combined)
    return sum(
        number(nested(row, key, "seconds"))
        for key in ("worktree_download", "derived_data_download")
    )


def row_source_seconds(row: dict[str, object]) -> float:
    return number(nested(row, "source", "source_transition_seconds"))


def row_normalization_seconds(row: dict[str, object]) -> float:
    return number(nested(row, "mtime_normalization", "normalization_seconds"))


def row_derived_extract_seconds(row: dict[str, object]) -> float:
    value = nested(row, "derived_restore", "derived_data_extract_seconds")
    if value is None:
        value = nested(row, "build", "derived_restore", "derived_data_extract_seconds")
    return number(value)


def row_build_components(row: dict[str, object]) -> dict[str, float]:
    build = row.get("build")
    if not isinstance(build, dict):
        return {"setup": 0.0, "package": 0.0, "build": 0.0}
    return {
        "setup": number(build.get("setup_seconds")),
        "package": number(build.get("package_resolve_seconds")),
        "build": number(build.get("build_wall_seconds")),
    }


def producer_publication_seconds(seed: dict[str, object]) -> float:
    return (
        number(nested(seed, "archive", "generation_compress_seconds"))
        + number(nested(seed, "worktree_upload", "seconds"))
        + number(nested(seed, "derived_data_upload", "seconds"))
    )


def candidate_total(row: dict[str, object], publication_seconds: float = 0.0) -> dict[str, float]:
    build = row_build_components(row)
    components = {
        "download": row_download_seconds(row),
        "source": row_source_seconds(row),
        "normalization": row_normalization_seconds(row),
        "derived_extract": row_derived_extract_seconds(row),
        "setup": build["setup"],
        "package": build["package"],
        "build": build["build"],
        "publication": publication_seconds,
    }
    components["total"] = sum(components.values())
    return components


def summarize(seed: dict[str, object], cold: dict[str, object], warm: dict[str, object]) -> dict[str, object]:
    publication = producer_publication_seconds(seed)
    cold_components = candidate_total(cold)
    warm_components = candidate_total(warm, publication_seconds=publication)
    warm_nonbuild = warm_components["total"] - warm_components["build"]
    threshold = cold_components["total"] - warm_nonbuild
    delta = cold_components["total"] - warm_components["total"]

    build = warm.get("build") if isinstance(warm.get("build"), dict) else {}
    return {
        "schema_version": 1,
        "cold_arm": cold.get("arm"),
        "warm_arm": warm.get("arm"),
        "producer_publication_proxy_seconds": round(publication, 6),
        "cold_components_seconds": {k: round(v, 6) for k, v in cold_components.items()},
        "warm_steady_state_components_seconds": {k: round(v, 6) for k, v in warm_components.items()},
        "warm_build_wall_break_even_seconds": round(threshold, 6),
        "steady_state_savings_seconds": round(delta, 6),
        "steady_state_improves": delta > 0,
        "incremental_evidence": {
            "swift_compile_source_file_lines": build.get("swift_compile_source_file_lines"),
            "swift_compile_task_count": build.get("swift_compile_task_count"),
            "swift_compile_timing_seconds": build.get("swift_compile_timing_seconds"),
            "emit_module_seconds": build.get("emit_module_seconds"),
        },
        "compiler_cas_evidence": {
            "hits": build.get("cas_hit_mentions"),
            "misses": build.get("cas_miss_mentions"),
            "cmux_hits": (build.get("cas_hit_mentions_by_target") or {}).get("cmux")
                if isinstance(build.get("cas_hit_mentions_by_target"), dict) else None,
            "cmux_misses": (build.get("cas_miss_mentions_by_target") or {}).get("cmux")
                if isinstance(build.get("cas_miss_mentions_by_target"), dict) else None,
        },
    }


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--cold", type=Path, required=True)
    parser.add_argument("--warm", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    result = summarize(load(args.seed), load(args.cold), load(args.warm))
    encoded = json.dumps(result, sort_keys=True, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    sys.stdout.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
