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
    "web-complexity.yml": "pull requests must not self-queue the contributor-side candidate job",
    # Pushes run only on codex/vm-api-cloud-* work branches and take backend/**
    # whole, which contains each backend path the pull_request list names.
    "cmux-vm-cloud.yml": "push covers backend/** on codex/vm-api-cloud-* branches; pull requests "
    "name the cloud-VM API files inside it",
    "cmux-next-hot-verify.yml": "push names only its own file, to register the workflow for dispatch; pull "
    "requests name the paths a no-build look can apply (web and Rust layers)",
    # #55455: the push runs only the `seed` job, which fills the R2 dependency cache from its key's inputs; the
    # journey itself runs on pull requests, on the CLI paths it dials through.
    "cloud-journey-pr.yml": "push seeds the R2 cargo cache from its key's inputs (Cargo.lock, rust-toolchain.toml, "
    "cloud-journey-cargo-key.sh); pull requests run the journey on the CLI paths it exercises",
    # #56329: pull requests get the before/after receipt only for the component library; the base push takes
    # webviews/** whole (which contains each pull_request path) and the gallery's build inputs.
    "gallery-advisory.yml": "push covers webviews/** and the gallery's build inputs on feat-cmux-next; pull requests "
    "name the component-library paths inside webviews/** (#56329)",
}

# name -> (filter, push-only patterns, why). A narrower exemption: only these
# patterns may appear on push without pull_request. Any other difference in the
# workflow, including any path guarded only on pull requests, still fails.
PUSH_ONLY_PATTERNS: dict[str, tuple[str, frozenset[str], str]] = {
    "cas-replay.yml": (
        "paths", frozenset({"webviews/**"}),
        "Every web merge replays the published bundles on the base.",
    ),
    "cloudflare-relay.yml": (
        "paths", frozenset({"scripts/cmux-next/cloud-journey*"}),
        "A journey change on the base retries deployment of the relay it exercises.",
    ),
    # A nightly repair must earn this commit's Release compile before promotion
    # carries it to nightly-next, so feat-cmux-next and main pushes also start
    # cmux-next.yml for the nightly release inputs (#21144).
    # Web merges and signed-envelope changes move the published bytes the replay measures, so
    # base pushes rerun it; a pull request does not need the report (it reports, never gates).
    "cas-replay.yml": (
        "paths",
        frozenset({"cmux-tui/crates/cmux-signed-envelope/**", "webviews/**"}),
        "the replay's rows move with each web or signed-envelope publish on the base; pull requests "
        "run it only for the replay's own inputs",
    ),
    # relay_deploy_plan.py: journey-staging gates the deploy, so a journey fix on the base retries it (#59812).
    "cloudflare-relay.yml": (
        "paths",
        frozenset({"scripts/cmux-next/cloud-journey*"}),
        "journey-staging gates the relay deploy; a push that fixes the journey retries the deploy "
        "(#59812), which a pull request has nothing to deploy for",
    ),
    "cmux-next.yml": (
        "paths",
        frozenset({
            ".github/workflows/nightly.yml",
            "scripts/apple-developer-id-certs/**",
            "scripts/ci/*nightly*",
            # The checks job runs the base-red classifier only on a push (#24773).
            "scripts/ci/base_red_checks.py",
            "scripts/ci/tests/test_base_red_checks.py",
            "scripts/ci/download-run-artifact.py",
            "scripts/ci/finalize-release.py",
            "scripts/ci/publish-release-assets.py",
            "scripts/ci/signing-keychain.sh",
            "scripts/ci/update-release-tag.py",
            "scripts/ci/upload-r2-object.py",
            "scripts/cmux-next/check-cef-objc-contract.py",
            "scripts/cmux-next/chromium-objc-contract.json",
            "scripts/import-apple-developer-id-intermediates.sh",
            "scripts/prune_nightly_release_assets.py",
            # The cmux-tui tree key's build recipe, named one by one on push; a pull request admits each through
            # .github/workflows/**, scripts/cmux-next/**, scripts/ci/** and Resources/** (below).
            ".github/workflows/cmux-tui-build-package.yml", "Resources/cmux-cli-path/**",
            "Resources/theme-files/**", "scripts/ci/stage-agent-detector.sh",
            "scripts/cmux-next/cmux-tui-build-profiles.json",
            # Files the app build or its packaging reads (cmux_next_route.py NATIVE_SCRIPT_INPUTS): pull
            # requests admit them through scripts/ci/** and scripts/cmux-next/**, which pushes do not take.
            "scripts/ci/cmux_tui_tree_key.py", "scripts/ci/fleet-rust-cache.sh",
            "scripts/ci/lib/signing-runtime-guard.sh", "scripts/ci/macho_minos.py",
            "scripts/ci/swift_incremental_diagnostics.py", "scripts/cmux-next/cef-license/LICENSE.txt",
            "scripts/cmux-next/cmux-tui-tree-inputs.txt",
        }),
        "base pushes also compile for the nightly release inputs, so a nightly repair "
        "earns its Release compile before promotion; the base-red classifier runs "
        "only on pushes",
    ),
}

# name -> (filter, pull-request-only patterns, why). The mirror allowance: only
# these broad patterns may appear on pull requests without push.
PULL_REQUEST_ONLY_PATTERNS: dict[str, tuple[str, frozenset[str], str]] = {
    # Empty since cmux-next.yml's push list took the rest of its pull_request list (#21504's product and CI
    # inputs): a pull request skips its checks job (scripts/ci/affected-jobs.json
    # pull_request_skip), so the push that lands it must start on every path the pull request does.
    # Left: the docs-only plan excludes (#47195). They narrow the pull request; the push keeps plans/cmux-next/**
    # whole, so it still starts on every plan file a pull request starts on.
    "cmux-next.yml": (
        "paths",
        frozenset({
            "!plans/cmux-next/**/*.md", "plans/cmux-next/actions.md", "plans/cmux-next/auto-mode/turncut/README.md",
            "plans/cmux-next/browser-repl/README.md",
            "plans/cmux-next/feed/prototypes/webkit-duplicate/README.md", "plans/cmux-next/formal/README.md",
            "plans/cmux-next/helium-density/README.md", "plans/cmux-next/home-messaging-invites/REPORT.md",
            "plans/cmux-next/markdown-omnibar-DESIGN.md", "plans/cmux-next/sidebar-owner/README.md",
            "plans/cmux-next/spec-proposals/visuals/README.md", "plans/cmux-next/status-notices/README.md",
        }),
        "a pull request of plan docs no Swift target names starts no run (tests/test_ci_docs_only_prs.py)",
    ),
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
        # A push with no such filter runs for every file, so it guards all the
        # pull request does (test-ios.yml builds on every feat-cmux-next push).
        if name not in push:
            continue
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


def unapproved(path, name=None):
    """Return divergence(path) minus the push-only patterns allowed for `name`."""
    name = name or path.name
    differences = divergence(path)
    if name in PULL_REQUEST_ONLY_PATTERNS:
        pr_filter, pr_allowed, _ = PULL_REQUEST_ONLY_PATTERNS[name]
        push_only, pull_request_only = differences.get(pr_filter, ([], []))
        if pull_request_only:
            # Only membership is allowed; a pure order difference ([], []) stays.
            narrowed = sorted(set(pull_request_only) - pr_allowed)
            if push_only or narrowed:
                differences[pr_filter] = (push_only, narrowed)
            else:
                del differences[pr_filter]
    if name not in PUSH_ONLY_PATTERNS:
        return differences
    allowed_filter, allowed, _ = PUSH_ONLY_PATTERNS[name]
    remaining = {}
    for filter_name, (push_only, pull_request_only) in differences.items():
        if filter_name == allowed_filter and (push_only or pull_request_only):
            # A pure order difference ([], []) is never allowed; only
            # membership of the named push-only patterns is.
            narrowed = sorted(set(push_only) - allowed)
            if not narrowed and not pull_request_only:
                events = triggers(path)
                push_patterns = events["push"].get(filter_name) or []
                pull_request_patterns = events["pull_request"].get(filter_name) or []
                # With a negated pattern the order matters, so the push list
                # without its allowed patterns must equal the pull_request list
                # without its own (PULL_REQUEST_ONLY_PATTERNS).
                if not any(pattern.startswith("!") for pattern in (*push_patterns, *pull_request_patterns)):
                    continue
                pr_allowed = PULL_REQUEST_ONLY_PATTERNS.get(name, ("", frozenset(), ""))
                pr_allowed = pr_allowed[1] if pr_allowed[0] == filter_name else frozenset()
                push_rest = [pattern for pattern in push_patterns if pattern not in allowed]
                pull_request_rest = [pattern for pattern in pull_request_patterns if pattern not in pr_allowed]
                if push_rest == pull_request_rest:
                    continue
                # Every negation is an allowed pull-request-only pattern: what is left orders nothing.
                if not any(p.startswith("!") for p in (*push_rest, *pull_request_rest)) \
                        and set(push_rest) == set(pull_request_rest):
                    continue
                narrowed = []
            push_only = narrowed
        remaining[filter_name] = (push_only, pull_request_only)
    return remaining


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
        differences = unapproved(path)
        if differences:
            drifted.append(describe(path.name, differences))
    assert not drifted, (
        "Every workflow that filters both events must filter them identically, "
        "or declare the difference in EXEMPTIONS or PUSH_ONLY_PATTERNS with a reason.\n"
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


def test_every_push_only_pattern_is_still_needed():
    """Reject obsolete or unexplained push-only pattern allowances."""
    for name, (filter_name, allowed, reason) in sorted(PUSH_ONLY_PATTERNS.items()):
        assert name not in EXEMPTIONS, f"{name}: use EXEMPTIONS or PUSH_ONLY_PATTERNS, not both"
        assert (WORKFLOWS / name).exists(), f"PUSH_ONLY_PATTERNS names {name}, which no longer exists"
        assert reason.strip(), f"{name}: push-only allowance needs a reason"
        push_only, _ = divergence(WORKFLOWS / name).get(filter_name, ([], []))
        stale = sorted(allowed - set(push_only))
        assert not stale, (
            f"{name}: {', '.join(stale)} is no longer push-only. "
            "Remove it from PUSH_ONLY_PATTERNS."
        )


def test_every_pull_request_only_pattern_is_still_needed():
    """Reject obsolete or unexplained pull-request-only pattern allowances."""
    for name, (filter_name, allowed, reason) in sorted(PULL_REQUEST_ONLY_PATTERNS.items()):
        assert name not in EXEMPTIONS, f"{name}: use EXEMPTIONS or the pattern allowances, not both"
        assert (WORKFLOWS / name).exists(), f"PULL_REQUEST_ONLY_PATTERNS names {name}, which no longer exists"
        assert reason.strip(), f"{name}: pull-request-only allowance needs a reason"
        _, pull_request_only = divergence(WORKFLOWS / name).get(filter_name, ([], []))
        stale = sorted(allowed - set(pull_request_only))
        assert not stale, (
            f"{name}: {', '.join(stale)} is no longer pull-request-only. "
            "Remove it from PULL_REQUEST_ONLY_PATTERNS."
        )


def test_push_only_allowance_still_catches_pull_request_only_paths():
    """An allowed push-only pattern hides nothing else in the same workflow."""
    _, allowed, _ = PUSH_ONLY_PATTERNS["cmux-next.yml"]
    check_push_only_allowance(allowed)


def check_push_only_allowance(allowed):
    shared = ["App/**", "Packages/macOS/CmuxNext/**"]
    with TemporaryDirectory() as directory:
        path = Path(directory) / "workflow.yml"

        def write(push, pull_request):
            path.write_text(yaml.safe_dump({"on": {
                "push": {"paths": push},
                "pull_request": {"paths": pull_request},
            }}), encoding="utf-8")

        write([*shared, *sorted(allowed)], shared)
        assert unapproved(path, "cmux-next.yml") == {}
        # A path guarded only on pull requests still fails.
        write([*shared, *sorted(allowed)], [*shared, "scripts/new-input.sh"])
        assert unapproved(path, "cmux-next.yml") == {
            "paths": ([], ["scripts/new-input.sh"])
        }
        # A push-only path outside the allowance still fails.
        write([*shared, *sorted(allowed), "web/**"], shared)
        assert unapproved(path, "cmux-next.yml") == {"paths": (["web/**"], [])}
        # With a negated pattern, the allowance does not hide a reorder.
        write([*shared, *sorted(allowed), "!docs/**"], [*shared, "!docs/**"])
        assert unapproved(path, "cmux-next.yml") == {}
        write([*sorted(allowed), "!docs/**", *shared], [*shared, "!docs/**"])
        assert unapproved(path, "cmux-next.yml") == {"paths": ([], [])}
        # cmux-next.yml takes no pull-request-only pattern: a path its push skips fails.
        write(shared, [*shared, "tests/**"])
        assert unapproved(path, "cmux-next.yml") == {"paths": ([], ["tests/**"])}
        # An allowed pull-request-only pattern passes; others still fail.
        PULL_REQUEST_ONLY_PATTERNS["cmux-next.yml"] = ("paths", frozenset({"tests/**"}), "test allowance")
        try:
            assert unapproved(path, "cmux-next.yml") == {}
            write(shared, [*shared, "tests/**", "docs/**"])
            assert unapproved(path, "cmux-next.yml") == {"paths": ([], ["docs/**"])}
        finally:
            del PULL_REQUEST_ONLY_PATTERNS["cmux-next.yml"]
        # The allowance belongs to its workflow only.
        write([*shared, *sorted(allowed)], shared)
        assert unapproved(path, "other.yml") == {"paths": (sorted(allowed), [])}


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
            ("paths", None, ["tests/**"], {}),
            ("paths", ["src/**"], None, {"paths": (["src/**"], [])}),
        ):
            path.write_text(yaml.safe_dump({"on": {
                "push": {"branches": ["main"]} if push is None else {filter_name: push},
                "pull_request": {"branches": ["main"]} if pull_request is None else {filter_name: pull_request},
            }}), encoding="utf-8")
            assert divergence(path) == expected, (filter_name, push, pull_request)
    assert "patterns differ in order or repetition" in describe(
        "workflow.yml", {"paths": ([], [])}
    )


if __name__ == "__main__":
    test_filter_pattern_order()
    test_push_and_pull_request_filter_the_same_files()
    test_every_exemption_is_still_needed()
    test_every_push_only_pattern_is_still_needed()
    test_every_pull_request_only_pattern_is_still_needed()
    test_push_only_allowance_still_catches_pull_request_only_paths()
    print("ok")
