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

    for job_name in CONSUMERS:
        job = job_block(workflow, job_name)
        source_key = step_block(job, "Source key of the web bundles")
        restore = step_block(job, "Restore the web bundles built for this source key")
        install = step_block(job, "Install the restored web bundles")
        build = step_block(job, "Build the web bundles")
        setup_bun = step_block(job, "Setup Bun")
        private_bun = step_block(job, "Give this job its own bun")
        setup_node = step_block(job, "Setup Node")

        assert cache_value(restore, "key") == WEB_CACHE_KEY
        assert cache_value(restore, "enableCrossOsArchive") == "true"
        assert step_if(install) == "steps.web-bundle-cache.outputs.cache-hit == 'true'"
        assert step_if(build) == "steps.web-bundle-cache.outputs.cache-hit != 'true'"
        for setup in (setup_bun, private_bun, setup_node):
            assert step_if(setup) == "steps.web-bundle-cache.outputs.cache-hit != 'true'"

        positions = {id(step): job.index(step) for step in (source_key, restore, install, build, setup_bun, private_bun, setup_node)}
        assert positions[id(source_key)] < positions[id(restore)]
        assert positions[id(restore)] < positions[id(install)]
        assert positions[id(install)] < positions[id(build)]
        assert positions[id(restore)] < positions[id(setup_bun)]
        assert positions[id(setup_node)] < positions[id(install)]

    print("cmux-next web-bundle cache workflow contract passed")


if __name__ == "__main__":
    main()
