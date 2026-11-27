#!/usr/bin/env python3
"""Report pull-request size and surface metrics for the cmux-next split guard.

The first rollout is advisory.  The classifier is deliberately portable: it only
needs Python and Git, emits a stable JSON receipt, and never starts a native or
web build.  ``--mode required`` is available for the later rollout once the
labels have been reviewed against historical pull requests.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


PRODUCT_SURFACES = (
    "composer",
    "profile-menu",
    "sidebar",
    "new-tab",
    "summary-card",
    "gallery",
    "settings-schema",
)


@dataclass(frozen=True)
class PathClassification:
    path: str
    surfaces: tuple[str, ...]
    native_settings: bool
    webview_ui: bool
    workflow_ci: bool


@dataclass(frozen=True)
class SplitMetrics:
    merge_base: str
    head: str
    changed_files: int
    commit_count: int
    surfaces: tuple[str, ...]
    unknown_paths: tuple[str, ...]
    native_settings: bool
    webview_ui: bool
    workflow_ci: bool


def classify_path(path: str) -> PathClassification:
    """Classify one repository-relative path without consulting the filesystem."""

    normalized = path.replace("\\", "/").lstrip("/")
    lower = normalized.lower()
    surfaces: set[str] = set()
    native_settings_path = lower.startswith("packages/macos/cmuxnext/sources/cmuxnextsettings/")

    if (
        "/composer" in lower
        or lower.startswith("webviews/test/composer")
        or "/composer" in lower
        or lower.endswith("composer.tsx")
        or lower.endswith("composer.ts")
    ):
        surfaces.add("composer")
    if "profilemenu" in lower or "profile-menu" in lower or "/profile/" in lower:
        surfaces.add("profile-menu")
    if (
        "sidebar" in lower
        or "/sessionrail" in lower
        or lower.endswith("session-sidebar.tsx")
        or lower.endswith("sidebar.swift")
    ) and not native_settings_path:
        surfaces.add("sidebar")
    if (
        "/newtab/" in lower
        or "/new-tab" in lower
        or "newtabpage" in lower
        or lower.startswith("webviews/test/newtab")
    ):
        surfaces.add("new-tab")
    if (
        "/summary/" in lower
        or "summary-card" in lower
        or "summarycard" in lower
    ):
        surfaces.add("summary-card")
    if ".gallery." in lower or "/gallery/" in lower or lower.endswith("gallery.tsx"):
        surfaces.add("gallery")
    if (
        "settings-schema" in lower
        or lower.startswith("schemas/settings/")
        or "/settingsschema" in lower
        or "settings-schema" in lower
        or native_settings_path
    ):
        surfaces.add("settings-schema")

    workflow_ci = (
        lower.startswith(".github/workflows/")
        or lower.startswith("scripts/ci/")
        or lower.startswith("scripts/cmux-next/")
        or lower.startswith("tests/test_")
    )
    if workflow_ci:
        surfaces.add("ci")

    native_settings = (
        native_settings_path
        or "/settingsschema" in lower
        or "settings-schema" in lower
    )
    webview_ui = lower.startswith("webviews/") and lower.endswith(
        (".ts", ".tsx", ".css", ".html", ".js", ".jsx")
    )

    return PathClassification(
        path=normalized,
        surfaces=tuple(sorted(surfaces)),
        native_settings=native_settings,
        webview_ui=webview_ui,
        workflow_ci=workflow_ci,
    )


def classify_paths(paths: Iterable[str]) -> tuple[tuple[PathClassification, ...], tuple[str, ...]]:
    classified = tuple(classify_path(path) for path in paths if path.strip())
    unknown = tuple(item.path for item in classified if not item.surfaces)
    return classified, unknown


def build_metrics(
    *,
    merge_base: str,
    head: str,
    commit_count: int,
    paths: Sequence[str],
) -> SplitMetrics:
    classified, unknown = classify_paths(paths)
    surfaces = tuple(sorted({surface for item in classified for surface in item.surfaces}))
    return SplitMetrics(
        merge_base=merge_base,
        head=head,
        changed_files=len(classified),
        commit_count=commit_count,
        surfaces=surfaces,
        unknown_paths=unknown,
        native_settings=any(item.native_settings for item in classified),
        webview_ui=any(item.webview_ui for item in classified),
        workflow_ci=any(item.workflow_ci for item in classified),
    )


def findings(metrics: SplitMetrics) -> list[str]:
    result: list[str] = []
    if metrics.changed_files > 40:
        result.append(f"changed-files>{40} ({metrics.changed_files})")
    if metrics.commit_count > 25:
        result.append(f"commits>{25} ({metrics.commit_count})")
    product_surfaces = [surface for surface in metrics.surfaces if surface in PRODUCT_SURFACES]
    if len(product_surfaces) > 2:
        result.append(f"product-surfaces>{2} ({','.join(product_surfaces)})")
    if metrics.workflow_ci and product_surfaces:
        result.append("production-ui-and-workflow-ci")
    if metrics.native_settings and metrics.webview_ui:
        result.append("native-settings-and-webview-ui")
    if metrics.unknown_paths:
        result.append(f"unclassified-paths ({len(metrics.unknown_paths)})")
    return result


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def metrics_from_git(repo: Path, base: str, head: str) -> SplitMetrics:
    merge_base = _git(repo, "merge-base", base, head)
    resolved_head = _git(repo, "rev-parse", head)
    commit_count = int(_git(repo, "rev-list", "--count", f"{merge_base}..{head}"))
    changed = _git(repo, "diff", "--name-only", merge_base, head)
    paths = changed.splitlines() if changed else []
    return build_metrics(
        merge_base=merge_base,
        head=resolved_head,
        commit_count=commit_count,
        paths=paths,
    )


def receipt(metrics: SplitMetrics, mode: str, triggered: Sequence[str]) -> dict[str, object]:
    return {
        "mode": mode,
        "merge_base": metrics.merge_base,
        "head": metrics.head,
        "changed_files": metrics.changed_files,
        "commit_count": metrics.commit_count,
        "surfaces": list(metrics.surfaces),
        "unknown_paths": list(metrics.unknown_paths),
        "triggers": list(triggered),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True, help="base ref or SHA")
    parser.add_argument("--head", required=True, help="head ref or SHA")
    parser.add_argument("--mode", choices=("advisory", "required"), default="advisory")
    args = parser.parse_args(argv)

    try:
        metrics = metrics_from_git(args.repo, args.base, args.head)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"split-guard: unable to measure {args.base}..{args.head}: {error}", file=sys.stderr)
        return 2

    triggered = findings(metrics)
    data = receipt(metrics, args.mode, triggered)
    print("SPLIT_GUARD_JSON " + json.dumps(data, sort_keys=True, separators=(",", ":")))
    print(
        "split-guard: "
        f"merge-base={metrics.merge_base} head={metrics.head} "
        f"files={metrics.changed_files} commits={metrics.commit_count} "
        f"surfaces={','.join(metrics.surfaces) or 'none'}"
    )
    if triggered:
        prefix = "::warning::" if args.mode == "advisory" else "::error::"
        print(prefix + "split-plan triggers: " + "; ".join(triggered))
    else:
        print("split-guard: no split-plan trigger")

    # Advisory mode reports all findings but never blocks a pull request. Required
    # mode is intentionally opt-in until the historical-PR review is complete.
    return 1 if args.mode == "required" and triggered else 0


if __name__ == "__main__":
    raise SystemExit(main())
