#!/usr/bin/env python3
"""nightly-next stops when the cmux-next source archive cannot be built.

The source archive step collects the Ghostty dependency licenses. Until every
Ghostty Zig package had a reviewed text the step ran with continue-on-error,
so a package with no license text gave a red step and an app with no Ghostty
license tree, and the build still shipped. Now the step is blocking: a missing
text fails the helper job, the sign job does not run, and the step tells the
maintainer to pin the text in pinned-licenses/MANIFEST.json. The sign job
downloads the tree without continue-on-error and always injects it.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
NEXT_FULL_BUILD = (
    "needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.fast_build != 'true'"
)


def step(name: str) -> str:
    """The text of the one step called `name` (dash line through the next step)."""
    text = WORKFLOW.read_text(encoding="utf-8")
    starts = [m.start() for m in re.finditer(r"^      - name: ", text, re.MULTILINE)]
    blocks = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(text)
        block = text[start:end]
        # A job header ends the step too.
        job = re.search(r"^  [A-Za-z0-9_-]+:\s*$", block, re.MULTILINE)
        if job:
            block = block[: job.start()]
        if block.splitlines()[0] == f"      - name: {name}":
            blocks.append(block)
    assert len(blocks) == 1, f"expected one step {name!r}, found {len(blocks)}"
    return blocks[0]


def field(block: str, key: str) -> str | None:
    match = re.search(rf"^        {key}: (.*)$", block, re.MULTILINE)
    return match.group(1).strip() if match else None


def with_field(block: str, key: str) -> str | None:
    match = re.search(rf"^          {key}: (.*)$", block, re.MULTILINE)
    return match.group(1).strip() if match else None


def test_source_archive_step_blocks() -> None:
    build = step("Build the cmux-next source archive")
    assert field(build, "continue-on-error") is None, "the source archive step must be blocking"
    assert field(build, "if") == NEXT_FULL_BUILD, field(build, "if")
    assert "pinned-licenses/MANIFEST.json" in build, (
        "a failed source archive step must say to pin the license in pinned-licenses/MANIFEST.json"
    )
    assert "::error" in build, "the pin instruction must be a workflow error annotation"


def test_upload_and_inject_do_not_depend_on_a_soft_outcome() -> None:
    upload = step("Upload the cmux-next source archive")
    assert field(upload, "continue-on-error") is None
    assert field(upload, "if") == NEXT_FULL_BUILD, field(upload, "if")
    download = step("Download the Ghostty dependency license trees (cmux-next)")
    assert field(download, "continue-on-error") is None, "a missing license tree must stop the sign job"
    assert field(download, "if") == NEXT_FULL_BUILD, field(download, "if")
    assert with_field(download, "name") == "cmux-next-license-trees"
    assert with_field(download, "path") == "nightly-inputs/license-trees"
    inject = step("Inject the Ghostty dependency licenses (cmux-next)")
    assert field(inject, "continue-on-error") is None
    assert field(inject, "if") == NEXT_FULL_BUILD, field(inject, "if")


def test_signing_handoff_is_license_only() -> None:
    upload = step("Upload cmux-next license trees")
    assert field(upload, "if") == NEXT_FULL_BUILD, field(upload, "if")
    assert with_field(upload, "name") == "cmux-next-license-trees"
    assert with_field(upload, "path") == "${{ runner.temp }}/source-archive/*-licenses"
    inject = step("Inject the Ghostty dependency licenses (cmux-next)")
    assert "nightly-inputs/license-trees/ghostty-licenses" in inject
    assert "nightly-inputs/source-archive" not in inject


def test_the_ghostty_next_license_tree_ships_too() -> None:
    # bin/cmux links libghostty-vt from the submodule ghostty-vt-sys's build.rs
    # names; its license tree ships beside Ghostty's, resolved from the tree.
    inject = step("Inject the Ghostty dependency licenses (cmux-next)")
    assert "ghostty-next-licenses" in inject
    assert "check_ghostty_vt_notices.py --print-source" in inject


def test_libghostty_vt_check_blocks() -> None:
    # Every Zig package of the libghostty-vt in bin/cmux must be covered by a
    # shipped license tree; a gap stops nightly-next and the dry run.
    check = step("libghostty-vt Zig packages are covered by the notices")
    assert field(check, "continue-on-error") is None, "the libghostty-vt check must be blocking"
    assert field(check, "if") == NEXT_FULL_BUILD, field(check, "if")
    assert "check_ghostty_vt_notices.py" in check
    assert "--ghostty-revision" not in check, "cmux-next follows the gitlink"
    dry_run = (ROOT / ".github" / "workflows" / "cmux-next-source-archive.yml").read_text(encoding="utf-8")
    block = dry_run[dry_run.index("- name: libghostty-vt Zig packages are covered by the notices"):]
    block = block[: block.index("\n      - name:", 1)]
    assert "continue-on-error" not in block, "the dry-run libghostty-vt check must be blocking"


def test_the_link_graph_blocks() -> None:
    # The linked set (vt-link-graph.json) is checked with the declared set, in
    # nightly-next and in the dry run, with no continue-on-error.
    check = step("libghostty-vt Zig packages are covered by the notices")
    assert "--link-graph scripts/cmux-next/notices/vt-link-graph.json" in check
    dry_run = (ROOT / ".github" / "workflows" / "cmux-next-source-archive.yml").read_text(encoding="utf-8")
    block = dry_run[dry_run.index("- name: libghostty-vt Zig packages are covered by the notices"):]
    block = block[: block.index("\n      - name:", 1)]
    assert "--link-graph scripts/cmux-next/notices/vt-link-graph.json" in block
    assert "continue-on-error" not in dry_run, "no dry-run notices step may be soft"
    notices = (ROOT / ".github" / "workflows" / "cmux-next-notices.yml").read_text(encoding="utf-8")
    assert "--check-link-graph scripts/cmux-next/notices/vt-link-graph.json" in notices


def test_no_other_step_reads_the_soft_outcome() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "steps.source_archive.outcome" not in text
    assert "steps.ghostty_licenses.outcome" not in text


def main() -> int:
    test_source_archive_step_blocks()
    test_upload_and_inject_do_not_depend_on_a_soft_outcome()
    test_the_ghostty_next_license_tree_ships_too()
    test_libghostty_vt_check_blocks()
    test_the_link_graph_blocks()
    test_no_other_step_reads_the_soft_outcome()
    print("nightly-next source archive workflow tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
