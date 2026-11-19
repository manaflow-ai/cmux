#!/usr/bin/env python3
"""Reject Linux/macOS provider and owned-host literals in workflow runs-on values.

Use ``python3 scripts/ci/runner_literal_lint.py`` to check, or add ``--inventory``
to print the migration inventory as JSON without failing on existing literals.
Hosted fork images, Windows labels, and RUNNER_POOLS references remain valid.
Fork branches and allowlists inside runs-on are deliberately checked too: a
provider literal there still bypasses the live routing declaration.

This is a manual lint, not a new CI gate. YAML, expression strings and static
matrix expansion use the repository's shared workflow reader. Dynamic values
(inputs, variables, job outputs, dynamic matrices) are outside this text lint;
their values remain subject to runner_label_policy.py.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

# Complete label tokens only: startsWith(..., 'blacksmith-') is a provider
# predicate, not a pin. Do not match cmux job names, repository names or refs.
LABEL = re.compile(
    r"(?<![\w./-])(?:"
    r"blacksmith-\d+vcpu-(?:ubuntu|macos)-[a-z0-9][a-z0-9.-]*[a-z0-9]"
    r"|(?:glaeda|warp-macos|tart|cmux-(?:gcp|fleet|aws-macos|macos|local-macos|persistent))"
    r"-[a-z0-9][a-z0-9.-]*[a-z0-9]"
    r"|self-hosted|macfleet|mac-mini(?:-\d+)?"
    r")(?![\w.-])",
    re.IGNORECASE,
)


def literal_labels(text: str) -> set[str]:
    """Label tokens in plain text or expression string literals, never identifiers."""
    literals: list[str] = []
    end = 0
    for start, stop in workflow_jobs.expression_spans(text, strict=True):
        literals.append(text[end:start])
        for kind, token in workflow_jobs.tokens(text[start + 3:stop - 2]):
            if kind == "string":
                literals.append(token[1:-1].replace("''", "'"))
        end = stop
    literals.append(text[end:])
    return {match.group() for literal in literals for match in LABEL.finditer(literal)}


def job_labels(job: dict) -> set[str]:
    """Read direct labels and each resolvable matrix cell; deduplicate per job."""
    labels: set[str] = set()
    for value in workflow_jobs.runs_on_items(job):
        if not isinstance(value, str):
            raise ValueError(f"runs-on label is not text: {value!r}")
        labels.update(literal_labels(value))
        for cell in workflow_jobs.expand_matrix(job, value) or []:
            labels.update(literal_labels(cell))
        # expand_matrix expands a whole `${{ matrix.runner }}` only. A read
        # inside a fallback/function still names the same static axis values.
        for body in workflow_jobs.expressions(value, strict=True):
            for key in workflow_jobs.context_reads(body, "matrix"):
                if key is not None:
                    for cell in workflow_jobs.matrix_values(job, key) or []:
                        if isinstance(cell, str):
                            labels.update(literal_labels(cell))
    return labels


def inventory(workflows: Path) -> list[dict[str, str]]:
    """One sorted entry per workflow/job/label; malformed workflows fail closed."""
    paths = sorted({*workflows.glob("*.yml"), *workflows.glob("*.yaml")})
    if not paths:
        raise ValueError(f"no workflows in {workflows}")
    findings: list[dict[str, str]] = []
    for path in paths:
        document = yaml.load(path.read_text(encoding="utf-8"), Loader=workflow_jobs._UniqueKeyLoader) or {}
        if not isinstance(document, dict) or not isinstance(document.get("jobs") or {}, dict):
            raise ValueError(f"{path.name}: workflow jobs must be a mapping")
        for name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                raise ValueError(f"{path.name}#{name}: job must be a mapping")
            try:
                labels = job_labels(job)
            except (ValueError, TypeError) as error:
                raise ValueError(f"{path.name}#{name}: {error}") from error
            findings.extend({"workflow": path.name, "job": str(name), "label": label} for label in sorted(labels))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflows", type=Path, default=ROOT / ".github" / "workflows")
    parser.add_argument("--inventory", action="store_true", help="print JSON migration inventory (exit 0)")
    args = parser.parse_args(argv)
    try:
        findings = inventory(args.workflows)
    except (OSError, ValueError, TypeError, yaml.YAMLError) as error:
        print(f"runner-literal-lint: {error}; next: repair the workflow and rerun this lint", file=sys.stderr)
        return 2
    if args.inventory:
        print(json.dumps(findings, indent=2))
        return 0
    for finding in findings:
        print(f"{finding['workflow']}#{finding['job']}: literal runner {finding['label']}", file=sys.stderr)
    if findings:
        print("next: replace runner literals with fromJSON(vars.RUNNER_POOLS).<pool> or a declared placement output",
              file=sys.stderr)
    return int(bool(findings))


if __name__ == "__main__":
    raise SystemExit(main())
