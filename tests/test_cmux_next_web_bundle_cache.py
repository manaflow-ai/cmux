#!/usr/bin/env python3
"""Keep the cmux-next web-bundle cache usable across Linux and macOS jobs."""

from __future__ import annotations

from pathlib import Path
import sys
import re


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from blacksmith_linux_sizes import size_label  # noqa: E402
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
        # A job may add its own guard (swift-test skips all of it on a reused result).
        assert r2_miss in step_if(restore), job_name
        assert f"{r2_hit} || {gh_hit}" in step_if(install), job_name
        assert f"{r2_miss} && {gh_miss}" in step_if(build), job_name

        order = [job.index(step) for step in (setup_node, source_key, r2, restore, install, build)]
        assert order == sorted(order), f"{job_name}: web-bundle steps out of order"

    check_dev_release_compile(workflow)
    print("cmux-next web-bundle cache workflow contract passed")


def check_dev_release_compile(workflow: str) -> None:
    """The DEV Release compile installs the Linux-built bundles and builds on its Mac only without them.

    Leo, 2026-10-26: "just give them the cache. we have done this before with classic. we have
    so many 32vcpu linux blacksmith machines". The web-bundles job runs on DEV daily runs too
    (it was skipped there), at the commit the compile builds, so a DEV commit whose sources no
    push stored still gets its bundles from Linux. On the Mac, bun and node are set up only for
    the fallback build, and a refused install (incomplete tree, stale inspector page) builds.
    """
    producer = job_block(workflow, "web-bundles")
    producer_if = re.search(r"^    if: (.+)$", producer, re.MULTILINE).group(1)
    assert "inputs.dev_daily != true && inputs.same_tree_sha == ''" not in producer_if, \
        "web-bundles must not be skipped on DEV daily runs"
    assert "(inputs.dev_daily == true || inputs.same_tree_sha == '')" in producer_if
    assert "ref: ${{ inputs.same_tree_sha || '' }}" in producer, \
        "web-bundles must build the commit a same-tree DEV run compiles"
    assert "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'" in producer
    # Its Blacksmith size is the one .github/runners.json linux_sizes measured for it.
    assert size_label("cmux-next.yml", "web-bundles") in producer

    job = job_block(workflow, "cmux-scheme-compile")
    source_key = step_block(job, "Source key of the web bundles")
    r2 = step_block(job, "Restore the web bundles from R2")
    restore = step_block(job, "Restore the web bundles built for this source key")
    install = step_block(job, "Install the restored web bundles")
    setup_bun = step_block(job, "Setup Bun")
    setup_node = step_block(job, "Setup Node")
    build = step_block(job, "Build the web bundles")
    compile_step = step_block(job, "Compile the cmux NEXT DEV Release app")

    assert cache_value(r2, "key") == WEB_CACHE_KEY
    assert cache_value(restore, "key") == WEB_CACHE_KEY
    assert cache_value(restore, "enableCrossOsArchive") == "true"
    assert "rm -rf web-bundles-out" in source_key, "a reused mini workspace must not install an old tree"
    assert "build-web-bundles.sh --from web-bundles-out" in install
    for step in (r2, restore, install):
        assert "continue-on-error: true" in step, "a restore problem must fall back to the Mac build"
    fallback = "steps.web-bundles-from.outcome != 'success'"
    for step in (setup_bun, setup_node, build):
        assert fallback in step_if(step), "bun, node and the build run only when no tree was installed"
        assert "steps.dev-product.outputs.hit != 'true'" in step_if(step)
    assert "--from" not in build and "--out-root" not in build

    order = [job.index(step) for step in (source_key, r2, restore, install, setup_bun, setup_node, build, compile_step)]
    assert order == sorted(order), "DEV Release compile web-bundle steps out of order"


if __name__ == "__main__":
    main()
