#!/usr/bin/env python3
"""The nightly bundles the newest PUBLISHED cmux-tui tree and never waits for the tip's.

Regression: nightly-next run 37464320457 failed in resolve-nightly-cmux-tui-client
("cmux-tui for this checkout's tree 23f87460a409 is not published after 45 min").
cmux-tui-artifacts.yml lets a running build finish and a newer push replaces only
the pending run, so under steady pushes the tip's own tree may never publish.
The resolver walks back a bounded window of commits (pin-cmux-tui.sh
resolve-newest-published, behavior-tested by
scripts/cmux-next/tests/pin-cmux-tui-resolve-newest.test.sh, which this guard
also runs) and records the tree and commit it used.
"""

import subprocess
import sys
from pathlib import Path

import re

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


text = (ROOT / ".github/workflows/nightly.yml").read_text()
# The job block: from its key to the next job key (two-space indent), no YAML module needed.
match = re.search(r"^  resolve-nightly-cmux-tui-client:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", text, re.MULTILINE | re.DOTALL)
job = match.group(1) if match else ""
check(bool(job), "nightly.yml must keep the resolve-nightly-cmux-tui-client job")
resolve = job[job.find("id: resolve"):] if "id: resolve" in job else ""
check("pin-cmux-tui.sh resolve-newest-published" in resolve,
      "the resolve step must use pin-cmux-tui.sh resolve-newest-published")
check("resolve-commit" not in resolve and "CMUX_TUI_TREE_WAIT_SECONDS" not in resolve,
      "the resolve step must not wait for the tip's tree (resolve-commit / CMUX_TUI_TREE_WAIT_SECONDS)")
check("CMUX_TUI_TREE_SEARCH_COMMITS:" in resolve,
      "the resolve step must bound the search with CMUX_TUI_TREE_SEARCH_COMMITS")
check("GITHUB_STEP_SUMMARY" in resolve or "GITHUB_STEP_SUMMARY" in (ROOT / "scripts/cmux-next/pin-cmux-tui.sh").read_text(),
      "the resolver must record the tree and commit in the step summary")
outputs = re.search(r"^    outputs:\n((?:^      .*\n)+)", job, re.MULTILINE)
for name in ("commit", "key", "source_commit"):
    check(bool(outputs) and re.search(rf"^      {name}:", outputs.group(1), re.MULTILINE) is not None,
          f"resolve-nightly-cmux-tui-client must output {name}")
timeout = re.search(r"^    timeout-minutes: (\d+)", job, re.MULTILINE)
# It waits on nothing but GitHub's API budget: 60 of its minutes are the hour gh_budget_wait.sh may
# wait for a rate-limit reset (tests/test_gh_budget_wait.py); its own work stays within 20.
budget_wait = 60 if "scripts/ci/gh_budget_wait.sh --install" in job else 0
check(bool(timeout) and int(timeout.group(1)) <= 20 + budget_wait,
      "a resolver that never waits needs no 55-minute timeout")
depth = re.search(r"fetch-depth: (\d+)", job)
check(bool(depth) and (int(depth.group(1)) == 0 or int(depth.group(1)) > 50),
      "the checkout must hold the search window (fetch-depth > 50)")

# Build at the resolved commit: app and daemon always come from the same commit.
# Every job that checks out the source (except decide, the resolver itself and the
# scheduled cache warmers, which ship nothing) checks out the resolver's build_sha.
# main's NIGHTLY, RC and nightly-next all run these same jobs.
RESOLVE = "resolve-nightly-cmux-tui-client"
BUILD_SHA = "${{ needs.resolve-nightly-cmux-tui-client.outputs.build_sha }}"
jobs_text = text[text.index("\njobs:\n"):]
blocks = dict(re.findall(r"^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", jobs_text, re.MULTILINE | re.DOTALL))
# find-nightly-next-recovery and recover-nightly-next-notarization continue an
# EARLIER run's build with this run's tools; this run's build commit does not
# apply to them (the recovered build carries its own, from its manifest).
# The cmux NIGHTLY-identity jobs (sign-, verify- and publish-nightly-identity-legacy)
# build nothing: the signing job downloads this run's prepared app and makes a
# temporary NEXT DMG when available, or a published DMG for a continuation,
# re-signs that build as cmux NIGHTLY and publishes it with this run's tools;
# verify checks out the build's own commit only for its license check
# (cx-x7hwx, cx-vws1x).
# legacy-identity-target checks out only to run
# scripts/ci/nightly-next-legacy-target.py, which compares the feeds and admits
# the current signed artifact beside publication; it builds and ships nothing.
# verify-recovered-nightly-next smokes the DMG recover-nightly-next-notarization
# continued, with this run's tools. promote-nightly-next and its -acked job run
# only on main and check out the promote guard at github.sha; they move a branch
# and build nothing (#21049).
exempt = {"decide", RESOLVE, "refresh-compilation-cache", "refresh-test-compilation-cache", "probe-nightly-tag-permission",
          "find-nightly-next-recovery", "recover-nightly-next-notarization", "verify-recovered-nightly-next",
          "sign-nightly-identity-legacy", "verify-nightly-identity-legacy",
          "publish-nightly-identity-legacy", "legacy-identity-target", "promote-nightly-next", "promote-nightly-next-acked"}
# publish-nightly checks out the build it selected: this run's resolved build
# commit, or a recovered earlier build's own build commit.
SELECTED_SHA = "${{ steps.source.outputs.build_sha }}"
# publish-nightly-next-github copies that same selected build to the GitHub release.
PUBLISHED_SHA = "${{ needs.publish-nightly.outputs.build_sha }}"

def tooling_checkout(body: str) -> "tuple[int, int] | None":
    """The publication-tooling checkout of a job: `ref: github.sha` into .publish-tooling whose
    whole sparse-checkout value names only paths under scripts/, nothing else (a `/*` line would
    be the whole tree at the workflow's commit). Its span, the one stretch to drop before the build-ref check."""
    match = re.search(r"^( +)ref: \$\{\{ github\.sha \}\}\n\1path: \.publish-tooling\n\1sparse-checkout: (.*)\n", body, re.MULTILINE)
    if not match:
        return None
    indent, value = match.group(1), match.group(2).strip()
    rest = body[match.end():]
    # The value runs to the first non-blank line indented no deeper than its key; blank lines
    # inside it are part of it, so a later `/*` is still read. That holds for a `|` block and
    # for a plain scalar continued on deeper lines alike.
    lines = rest.splitlines(keepends=True)
    end = next((i for i, line in enumerate(lines) if line.strip() and not line.startswith(indent + " ")), len(lines))
    while end and not lines[end - 1].strip():
        end -= 1
    continuation = [line.strip() for line in lines[:end] if line.strip()]
    if value == "|":
        paths = continuation
    elif continuation:
        return None
    else:
        paths = [value]
    if not paths or not all(re.fullmatch(r"scripts(/(?!\.+(/|$))[\w.-]+)*", path) for path in paths):
        return None
    return match.start(), match.end() + len("".join(lines[:end]))


for bad in ("scripts/ci/x.py\n            /*", "/*", "scripts/../Sources"):
    sample = ("          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: |\n"
              + "".join(f"            {p}\n" for p in bad.split("\n            ")))
    check(tooling_checkout(sample) is None, f"a tooling checkout of {bad!r} must not be exempt")
check(tooling_checkout("          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: |\n"
                       "            scripts/ci/x.py\n\n            /*\n") is None,
      "a `/*` after a blank line in the sparse list must not be exempt")
check(tooling_checkout("          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: scripts\n\n"
                       "            /*\n          sparse-checkout-cone-mode: false\n") is None,
      "a `/*` continuing the inline sparse value must not be exempt")
check(tooling_checkout("\n  ref: ${{ github.sha }}\n\n  path: .publish-tooling\n\n  sparse-checkout: scripts\n\n    /*\n"
                       "  sparse-checkout-cone-mode: false\n") is None,
      "blank lines between the keys must not hide a `/*` continuation")
check(tooling_checkout("          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: scripts\n"
                       "          sparse-checkout-cone-mode: false\n") is not None,
      "a sibling key after the inline sparse value ends it")
safe = "          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: |\n            scripts/ci/x.py\n"
twice = safe + "      - uses: actions/checkout@v4\n        with:\n" + safe + "            /*\n"
start, end = tooling_checkout(twice)
check("${{ github.sha }}" in twice[:start] + twice[end:],
      "dropping the tooling checkout must leave a second checkout that shares its text but adds `/*`")
check(tooling_checkout("          ref: ${{ github.sha }}\n          path: .publish-tooling\n          sparse-checkout: scripts\n") is not None,
      "publish-nightly's `sparse-checkout: scripts` is the tooling checkout")

shipping = [name for name, body in blocks.items() if name not in exempt and "actions/checkout@" in body]
for name in ("build-nightly-app", "build-sign-notarize-nightly", "publish-nightly", "build-nightly-ghostty-cli-helper"):
    check(name in shipping, f"{name} must check out the source (guard setup)")
for name in shipping:
    body = blocks[name]
    # A sole, narrowly validated scripts checkout builds and ships no source.
    # Any second checkout still has to meet the resolver/build pin contract.
    tooling = tooling_checkout(body)
    if tooling and body.count("actions/checkout@") == 1:
        continue
    needs = re.search(r"^    needs: (.*)$", body, re.MULTILINE)
    check(bool(needs) and RESOLVE in needs.group(1), f"{name} must need {RESOLVE}")
    allowed = ({BUILD_SHA, SELECTED_SHA} if name == "publish-nightly"
               else {BUILD_SHA, PUBLISHED_SHA} if name == "publish-nightly-next-github" else {BUILD_SHA})
    # The publication tooling (not shipped source) comes from the workflow's own
    # commit, so a recovered older build runs this workflow's scripts. It is a
    # sparse checkout of scripts into .publish-tooling, never the build tree.
    if name == "publish-nightly":
        check(tooling is not None, "publish-nightly must check out its publication tooling at github.sha into .publish-tooling")
    if tooling:
        body = body[:tooling[0]] + body[tooling[1]:]
    if name in {"build-nightly-app", "build-sign-notarize-nightly"}:
        # Unsigned recovery restores bytes instead of compiling them, using
        # this workflow's controls. Its separate source checkout stays pinned.
        control_name = ("Checkout trusted unsigned-resume controls" if name == "build-nightly-app"
                        else "Checkout trusted signing controls for unsigned resume")
        control = re.search(rf"^      - name: {re.escape(control_name)}\n.*?(?=^      - name:|\Z)",
                            body, re.MULTILINE | re.DOTALL)
        check(control is not None, f"{name} must keep its explicit unsigned-recovery controls checkout")
        if control:
            check("if: inputs.nightly_next_unsigned_run != ''" in control.group(0),
                  f"{name} control checkout must run only during unsigned recovery")
            refs = re.findall(r"^\s+ref: (.*)$", control.group(0), re.MULTILINE)
            check(refs == ["${{ github.sha }}"], f"{name} recovery controls must come from this workflow's commit")
            if name == "build-sign-notarize-nightly":
                check("path: .nightly-signing-control" in control.group(0),
                      "signing controls must not replace the original source checkout")
            body = body.replace(control.group(0), "")
    for ref in re.findall(r"^\s+ref: (.*)$", body, re.MULTILINE):
        check(ref.strip() in allowed, f"{name} checks out {ref.strip()}, not the resolved build commit")
    for line in body.splitlines():
        if "needs.decide.outputs.head_sha" in line or "needs.decide.outputs.short_sha" in line:
            check("|| needs.decide.outputs.head_sha" in line,
                  f"{name} still uses the tip outside a cache key: {line.strip()}")
check(not re.search(r"^    if: .*build_only", blocks.get(RESOLVE, ""), re.MULTILINE),
      "the resolver must run for build_only too, so every app build has a build commit")
for output in ("build_sha", "build_short_sha", "tip_sha", "behind", "behind_hours"):
    check(re.search(rf"^      {output}:", blocks.get(RESOLVE, ""), re.MULTILINE) is not None,
          f"{RESOLVE} must output {output}")
check('CMUX_TUI_TREE_MAX_AGE_HOURS: "24"' in blocks.get(RESOLVE, ""), "the resolver must bound the age at 24 h")
publish = blocks.get("publish-nightly", "")
check(f"OWN_BUILD_SHA: {BUILD_SHA}" in publish,
      "publish-nightly must select this run's resolved build commit for its own build")
for needle in ("outputs.tip_sha", "outputs.behind }}", "outputs.behind_hours"):
    check(publish.count(needle) >= 2, f"both nightly release bodies must record {needle}")

# The publication check compares the RESOLVED build commit, not the tip, with
# the published marker: a run whose resolved commit is already published builds
# nothing (the tip may move while its tree is unpublished). The app build keys
# its Xcode compilation cache by the commit it builds.
check(re.search(r"^      force: \$\{\{ steps\.decide\.outputs\.force \}\}", blocks.get("decide", ""), re.MULTILINE) is not None,
      "decide must output force")
check("setOutput('force'" in blocks.get("decide", ""), "decide must set its force output")
resolver = blocks.get(RESOLVE, "")
check(re.search(r"^      already_published: \$\{\{ steps\.build\.outputs\.already_published \}\}", resolver, re.MULTILINE) is not None,
      f"{RESOLVE} must output already_published")
check("needs.decide.outputs.published_sha" in resolver and "needs.decide.outputs.force" in resolver,
      "already_published must compare build_sha with decide's published_sha and honor force")
for name in ("build-nightly-ghostty-cli-helper", "build-nightly-app", "build-sign-notarize-nightly", "publish-nightly"):
    job_if = re.search(r"^    if: (.*)$", blocks.get(name, ""), re.MULTILINE)
    check(bool(job_if) and f"needs.{RESOLVE}.outputs.already_published != 'true'" in job_if.group(1),
          f"{name} must skip a resolved commit that is already published")
for line in blocks.get("build-nightly-app", "").splitlines():
    if "key: xcode-compilation-release-" in line:
        check(line.rstrip().endswith(BUILD_SHA), f"build-nightly-app cache key must use build_sha: {line.strip()}")

test = ROOT / "scripts/cmux-next/tests/pin-cmux-tui-resolve-newest.test.sh"
result = subprocess.run(["bash", str(test)], capture_output=True, text=True)
check(result.returncode == 0, f"{test.name} failed:\n{result.stdout}{result.stderr}")

if failures:
    print("FAIL: nightly cmux-tui resolve\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly cmux-tui resolve")
