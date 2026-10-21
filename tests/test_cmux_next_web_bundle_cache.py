#!/usr/bin/env python3
"""Keep the cmux-next web-bundle cache usable across Linux and macOS jobs."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
WEB_CACHE_KEY = "cmux-next-web-bundles-v1-${{ steps.web-bundle-key.outputs.key }}"
CONSUMERS = ("swift-test", "daemon-test", "generated-files")


def job_block(workflow: str, name: str) -> str:
    match = re.search(rf"^  {re.escape(name)}:\n(?P<body>(?:^(?!  [a-z0-9_-]+:\n).*(?:\n|$))*)", workflow, re.MULTILINE)
    assert match, f"missing job {name}"
    return match.group("body")


def step_block(job: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = job.find(marker)
    assert start >= 0, f"missing step {name!r}"
    end = job.find("\n      - name: ", start + len(marker))
    return job[start : len(job) if end < 0 else end]


def cache_value(step: str, field: str) -> str:
    match = re.search(rf"^          {re.escape(field)}: (.+)$", step, re.MULTILINE)
    assert match, f"missing cache field {field}"
    return match.group(1)


def step_if(step: str) -> str:
    match = re.search(r"^        if: (.+)$", step, re.MULTILINE)
    assert match, "missing step condition"
    return match.group(1)


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    producer = job_block(workflow, "web-bundles")
    for name in ("Look up the cached web bundles", "Cache the web bundles under this source key"):
        step = step_block(producer, name)
        assert cache_value(step, "key") == WEB_CACHE_KEY
        assert cache_value(step, "enableCrossOsArchive") == "true"

    # Consumers read R2 first (feat-cmux-next's published bundles, #22576),
    # then this run's GitHub cache entry, and build only when both miss. Bun
    # and Node are set up on every path, before the bundles are installed.
    r2_hit = "steps.web-bundle-r2.outputs.cache-hit == 'true'"
    r2_miss = "steps.web-bundle-r2.outputs.cache-hit != 'true'"
    gh_hit = "steps.web-bundle-cache.outputs.cache-hit == 'true'"
    gh_miss = "steps.web-bundle-cache.outputs.cache-hit != 'true'"
    for job_name in CONSUMERS:
        job = job_block(workflow, job_name)
        source_key = step_block(job, "Source key of the web bundles")
        r2 = step_block(job, "Restore the web bundles from R2")
        restore = step_block(job, "Restore the web bundles built for this source key")
        install = step_block(job, "Install the restored web bundles")
        build = step_block(job, "Build the web bundles")
        setup_node = step_block(job, "Setup Node")

        assert cache_value(r2, "key") == WEB_CACHE_KEY, job_name
        assert cache_value(restore, "key") == WEB_CACHE_KEY, job_name
        assert cache_value(restore, "enableCrossOsArchive") == "true", job_name
        assert step_if(restore) == r2_miss, job_name
        assert step_if(install) == f"{r2_hit} || {gh_hit}", job_name
        assert step_if(build) == f"{r2_miss} && {gh_miss}", job_name

        order = [job.index(step) for step in (setup_node, source_key, r2, restore, install, build)]
        assert order == sorted(order), f"{job_name}: web-bundle steps out of order"

    print("cmux-next web-bundle cache workflow contract passed")


if __name__ == "__main__":
    main()
