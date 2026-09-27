#!/usr/bin/env python3
"""A workflow that filters both `push` and `pull_request` must filter them alike.

A workflow that names its inputs twice has two lists that can disagree, and
neither pull request that made them disagree can see it. When the `push` list is
the smaller one the failure is silent and expensive: a file is guarded on pull
requests, passes, merges, and is then unguarded on main forever.

Divergence that a maintainer genuinely wants goes in EXEMPTIONS with a reason,
so it is written down rather than implied by a list that looks like a typo.
"""

from pathlib import Path
from tempfile import TemporaryDirectory
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

# name -> why the two filters are deliberately different. Keep this empty unless
# a maintainer has chosen the divergence; an entry that is no longer needed is an
# error, so a synced workflow cannot keep a stale exemption.
EXEMPTIONS: dict[str, str] = {
    # The candidate complexity job runs contributor-controlled package install
    # scripts. A pull request that edits this workflow must not be able to queue
    # the job that would run its own edit, so the pull_request filter omits the
    # workflow's own path while push -- trusted and post-merge -- keeps it.
    # tests/test_web_complexity_trusted_workflow.py enforces the same boundary.
    "web-complexity.yml": "a pull request must not self-queue the candidate job",
}

FILTERS = ("paths", "paths-ignore")


def workflow_files():
    """List every workflow in deterministic order."""
    return sorted(
        [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")],
        key=lambda path: path.name,
    )


def triggers(path):
    """Return the workflow's `on:` mapping, or None if it has no usable one."""
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        return None
    # YAML 1.1 reads a bare `on:` key as the boolean True.
    events = document.get("on", document.get(True))
    return events if isinstance(events, dict) else None


def divergence(path):
    """Return {filter: (push_only, pull_request_only)} for the lists that differ."""
    events = triggers(path)
    if events is None:
        return {}
    push = events.get("push")
    pull_request = events.get("pull_request")
    if not isinstance(push, dict) or not isinstance(pull_request, dict):
        return {}

    differences = {}
    for name in FILTERS:
        push_patterns = push.get(name) or []
        pull_request_patterns = pull_request.get(name) or []
        on_push = set(push_patterns)
        on_pull_request = set(pull_request_patterns)
        # Negated paths can exclude and later re-include a match; their order
        # is meaningful. Exclusion-only paths-ignore has no such ordering.
        order_sensitive = name == "paths" and any(
            pattern.startswith("!") for pattern in (*push_patterns, *pull_request_patterns)
        )
        differs = (
            push_patterns != pull_request_patterns
            if order_sensitive
            else on_push != on_pull_request
        )
        if differs:
            differences[name] = (
                sorted(on_push - on_pull_request),
                sorted(on_pull_request - on_push),
            )
    return differences


def describe(name, differences):
    """Explain membership or ordering differences for a workflow."""
    lines = [f"{name}: push and pull_request filter different files"]
    for filter_name, (push_only, pull_request_only) in sorted(differences.items()):
        if not push_only and not pull_request_only:
            lines.append(f"  {filter_name}: patterns differ in order or repetition")
        if pull_request_only:
            lines.append(
                f"  {filter_name}: guarded on pull requests, not on push: "
                + ", ".join(pull_request_only)
            )
        if push_only:
            lines.append(
                f"  {filter_name}: guarded on push, not on pull requests: "
                + ", ".join(push_only)
            )
    return "\n".join(lines)


def test_push_and_pull_request_filter_the_same_files():
    """Reject unapproved differences between trigger path filters."""
    drifted = []
    for path in workflow_files():
        if path.name in EXEMPTIONS:
            continue
        differences = divergence(path)
        if differences:
            drifted.append(describe(path.name, differences))
    assert not drifted, (
        "Every workflow that filters both events must filter them identically, "
        "or declare the difference in EXEMPTIONS with a reason.\n"
        + "\n".join(drifted)
    )


def test_every_exemption_is_still_needed():
    """Reject obsolete or unexplained parity exemptions."""
    names = {path.name for path in workflow_files()}
    for name, reason in sorted(EXEMPTIONS.items()):
        assert name in names, f"EXEMPTIONS names {name}, which no longer exists"
        assert reason.strip(), f"{name}: exemption needs a reason"
        assert divergence(WORKFLOWS / name), (
            f"{name}: exempted from filter parity but its filters now agree. "
            "Remove the EXEMPTIONS entry."
        )


def test_filter_pattern_order():
    """Catch negation reordering without making paths-ignore order-sensitive."""
    with TemporaryDirectory() as directory:
        path = Path(directory) / "workflow.yml"
        for filter_name, push, pull_request, expected in (
            ("paths", ["**", "!docs/**"], ["!docs/**", "**"], {"paths": ([], [])}),
            ("paths", ["**", "!docs/**"], ["**", "!docs/**"], {}),
            ("paths", ["docs/**", "tests/**"], ["tests/**", "docs/**"], {}),
            ("paths-ignore", ["docs/**", "tests/**"], ["tests/**", "docs/**"], {}),
            ("paths", ["src/**"], ["tests/**"], {"paths": (["src/**"], ["tests/**"])}),
        ):
            path.write_text(yaml.safe_dump({"on": {
                "push": {filter_name: push},
                "pull_request": {filter_name: pull_request},
            }}), encoding="utf-8")
            assert divergence(path) == expected, (filter_name, push, pull_request)
    assert "patterns differ in order or repetition" in describe(
        "workflow.yml", {"paths": ([], [])}
    )


if __name__ == "__main__":
    test_filter_pattern_order()
    test_push_and_pull_request_filter_the_same_files()
    test_every_exemption_is_still_needed()
    print("ok")
