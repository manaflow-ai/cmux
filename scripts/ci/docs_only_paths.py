#!/usr/bin/env python3
"""The one `paths:` block that keeps a docs-only pull request from starting CI it can't affect.

A pull request that changes only prose (CLAUDE.md, a plan, a design note) used to start about 28 workflows and 180-275
jobs on feat-cmux-next: guards, routers, size and tab-switch budgets, Rust planners and their gates, each of which
reads no Markdown. Leo, 2026-11-19: "I kept saying, skip CI, skip it ... when it's unnecessary ... We need to skip
more often."

DOCS_ONLY_PATHS is that block: every path, then Markdown and docs images taken out, then the prose that code, a build
or a test reads put back after the excludes (it is `paths:` with `!`, not `paths-ignore:`, so a file can be put back;
GitHub lets the last matching pattern win). A workflow in WORKFLOWS carries it as its `on.pull_request.paths`,
between the BEGIN and END marker comments; `--sync` rewrites every copy from this file and `--check` fails on drift.
Push, schedule and workflow_dispatch triggers are never filtered.

tests/test_ci_docs_only_prs.py is the detector: a docs-only pull request starts only the workflows its ALLOWED table
names (the required checks, which must always start, and the cheap policy and merge-contract checks, each with its
reason); every file a Rust `include_str!`/`include_bytes!` compiles in is put back; every copy matches. The inputs of
the tests a filtered workflow runs are checked by tests/test_ci_workflow_paths_cover_inputs.py, as for any filter.

    python3 scripts/ci/docs_only_paths.py --sync            # rewrite every workflow's block from DOCS_ONLY_PATHS
    python3 scripts/ci/docs_only_paths.py --check           # exit 1 when a copy drifted
    python3 scripts/ci/docs_only_paths.py FILE...           # docs-only=true|false for a changed-file list
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_paths_cover_inputs as filters  # noqa: E402  (GitHub's paths glob, the one implementation)

ROOT = Path(__file__).resolve().parents[2]

# Docs images: under the prose trees only (an image elsewhere may be an asset or a test baseline).
_IMAGES = ("png", "jpg", "gif", "webp")

DOCS_ONLY_PATHS: tuple[str, ...] = (
    "**",
    "!**/*.md",
    *(f"!{tree}/**/*.{ext}" for tree in ("docs", "plans") for ext in _IMAGES),
    # Prose that agents, bots or the product read as instructions or data, never docs-only.
    "**/AGENTS.md",
    "**/CLAUDE.md",
    "**/SKILL.md",
    ".github/**",
    "**/skills/**",
    "**/references/**",
    "**/templates/**",
    "**/Resources/**",
    "**/fixtures/**",
    "**/testdata/**",
    "**/test/**",
    "**/tests/**",
    "CHANGELOG.md",
    "THIRD_PARTY_LICENSES.md",
    "release-notes/**",
    # Read by a check or a workflow (scripts/check-agent-hook-docs.py, workflow paths lists, generated-doc drift).
    "docs/agent-hooks.md",
    "docs/chief-setup-prompts.md",
    "docs/configuration.md",
    "docs/ci/node-product-cache-maintenance.md",
    # Generated (scripts/cmux-next/generated_outputs.py OUTPUTS): cmux-next-pr-autofix's drift check reads a hand edit.
    "plans/cmux-next/actions.md",
    "docs/mdm/managed-preferences.md",
    # Read by a ci-guards group test (test_no_guard_group_test_reads_docs lists any new one).
    "docs/ci/health-report.md",  # tests/test_ci_health_report.py
    "docs/privacy.md",  # tests/test_outbound_hosts.py
    "**/notices/**",  # third-party notice inputs (hand-written.md, REVIEW.md) that the bundle and release tests read
    "vendor/stack-auth-swift-sdk-prerelease/README.cmux.md",  # tests/test_supplychain_security.py
    "cmux-tui/README.md",  # tests/test_testbox_demo_cleanup.sh -> scripts/blacksmith-testbox-demo.sh
    # Compiled in by include_str! (the detector lists any new one).
    "docs/remote-agents-and-cloud.md",
    "docs/cmux-next/customize-recipes.md",
    "cmux-tui/crates/acpmux/README.md",
    "cmux-tui/crates/acpmux/docs/**",
    "cmux-tui/crates/cmux-browser-host/js/guide.md",
    "cmux-tui/crates/cmux-extension-sdk/README.md",
    "cmux-tui/vendor/terminput-crossterm/README.md",
    "mux/packages/brain/conformance/README.md",
)

# The workflows whose pull_request trigger carries DOCS_ONLY_PATHS. None is a required check: a required check that
# never starts stays "Expected" and blocks the merge (main: CLA Assistant, CLA policy guard, backend migrations
# applied; feat-cmux-next: cmux-tui-spec's clippy, React Doctor).
WORKFLOWS: tuple[str, ...] = (
    ".github/workflows/ci.yml",
    ".github/workflows/cmux-next-guards.yml",
    ".github/workflows/cmux-next-hot-verify.yml",
    ".github/workflows/cmux-next-pr-autofix.yml",
    ".github/workflows/cmux-next-size-budget.yml",
    ".github/workflows/cmux-next-tab-switch.yml",
    ".github/workflows/pr-checks.yml",
    ".github/workflows/rust-workspaces.yml",
    ".github/workflows/web-validation.yml",
)

BEGIN = "# docs-only paths: BEGIN (scripts/ci/docs_only_paths.py --sync writes this block; edit DOCS_ONLY_PATHS there)"
END = "# docs-only paths: END"


def is_docs(path: str) -> bool:
    """Whether a change to `path` alone starts none of WORKFLOWS on a pull request."""
    return not filters.admits("paths", list(DOCS_ONLY_PATHS), path)


def docs_only(paths: list[str]) -> bool:
    """Whether every changed path is docs. An empty list is not docs-only (GitHub starts every workflow then)."""
    return bool(paths) and all(is_docs(p) for p in paths)


def block(indent: str) -> list[str]:
    """The block as it sits under `pull_request:`, `indent` being the `paths:` key's indentation."""
    lines = [f"{indent}{BEGIN}", f"{indent}paths:"]
    lines += [f'{indent}  - "{pattern}"' for pattern in DOCS_ONLY_PATHS]
    lines.append(f"{indent}{END}")
    return lines


def rewrite(text: str, name: str) -> str:
    """The workflow's text with its marked block rewritten, or ValueError when it has no single marked block."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise ValueError(f"{name}: needs exactly one docs-only paths block between its BEGIN and END markers")
    start, end = starts[0], ends[0]
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    return "\n".join(lines[:start] + block(indent) + lines[end + 1:])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--sync", action="store_true", help="rewrite each workflow's block")
    mode.add_argument("--check", action="store_true", help="exit 1 when a workflow's block drifted")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("files", nargs="*", help="changed files: print docs-only=true|false")
    args = parser.parse_args(argv)
    if not (args.sync or args.check):
        print(f"docs-only={'true' if docs_only(args.files) else 'false'}")
        return 0
    drifted = []
    for name in WORKFLOWS:
        path = args.root / name
        text = path.read_text()
        try:
            new = rewrite(text, name)
        except ValueError as error:
            print(error, file=sys.stderr)
            drifted.append(name)
            continue
        if new != text:
            if args.sync:
                path.write_text(new)
                print(f"rewrote {name}")
            else:
                drifted.append(name)
    for name in drifted if args.check else ():
        print(f"{name}: its docs-only paths block differs from DOCS_ONLY_PATHS; run "
              "python3 scripts/ci/docs_only_paths.py --sync", file=sys.stderr)
    return 1 if drifted else 0


if __name__ == "__main__":
    raise SystemExit(main())
