"""Linux jobs that compile run on the 32 or 16 vCPU Blacksmith size.

Leo, 2026-10-21: "MOVE STUFF TO BLACKSMITH 16 OR 32. IF WE HAVE 256 OF 32,
JUST USE 32." Every Linux job below compiles (cargo, cross builds, zig, Go,
C++, Gradle) or runs a web build or test suite, so its manaflow-ai runner is
`blacksmith-32vcpu-ubuntu-2404`, or `blacksmith-16vcpu-ubuntu-2404` for the
small ones.

The size must not come from `vars.LINUX_RUNNER` while it names a Blacksmith
label: that shared variable names `blacksmith-4vcpu-ubuntu-2404` for every
small Linux job (docs/ci-runners.md), so `vars.LINUX_RUNNER ||
'blacksmith-32vcpu-ubuntu-2404'` would still run on 4 vCPU. But the Blacksmith
outage switch (scripts/ci/cloud_overflow_switch.py) points `LINUX_RUNNER` at
`ubuntu-24.04`, and these jobs must follow it there, or the switch's
force-cancel and rerun sends them straight back to the stalled pool. So each
trusted fallback ends in exactly

    !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || '<size>'

Fork pull requests use the same sized Blacksmith lane as the trusted job for
the compile and test suites below. Small routing/status jobs can keep the
4-vCPU lane.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

BIG = "blacksmith-32vcpu-ubuntu-2404"
SMALL = "blacksmith-16vcpu-ubuntu-2404"

# (workflow, job, where the label lives, expected label). `where` is "runs-on",
# "matrix:<key>=<value>:<field>" for a matrix row, or "env:<step id>:<NAME>"
# for a runner a planning step hands to the build legs.
EXPECTED: tuple[tuple[str, str, str, str], ...] = (
    # Rust: cargo build, test, clippy, cross builds.
    ("ci-web.yml", "diff-sidecar-check", "runs-on", BIG),
    ("cmux-next-fast-gates.yml", "fast-gates", "runs-on", SMALL),
    ("cloudflare-relay.yml", "cloudflare-relay", "runs-on", BIG),
    ("cmux-browser-host-chromium.yml", "chromium", "runs-on", BIG),
    ("cmux-browser-host-release.yml", "build", "matrix:target=x86_64-unknown-linux-gnu:runs_on", BIG),
    ("cmux-cloud-cli.yml", "test", "runs-on", BIG),
    ("cmux-mobile-ffi.yml", "rust", "runs-on", BIG),
    ("cmux-mobile-ffi.yml", "android", "runs-on", BIG),
    ("cmux-next-car-guards.yml", "linux", "runs-on", BIG),
    ("cmux-next-source-archive.yml", "vt-link-graph", "runs-on", BIG),
    ("cmux-next-terminal.yml", "rust-terminal-linux", "runs-on", BIG),
    ("cmux-tui-artifacts.yml", "macos-cross-shadow", "runs-on", BIG),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_BUILD_RUNNER", BIG),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_DARWIN_RUNNER", BIG),
    ("cmux-tui-headless-debug.yml", "build", "runs-on", BIG),
    ("cmux-tui-sdks.yml", "packages", "runs-on", BIG),
    ("cmux-tui-sdks.yml", "consumers", "runs-on", BIG),
    ("cmux-tui-sdks.yml", "conformance", "runs-on", BIG),
    ("cmux-tui-sdks.yml", "rust-msrv", "runs-on", BIG),
    ("cmux-tui-windows-check.yml", "windows-gnu-check", "runs-on", BIG),
    ("cmux-tui.yml", "optchat-chief", "runs-on", BIG),
    ("cmux-vm-clients.yml", "rust", "runs-on", BIG),
    ("coderouter-ci.yml", "test", "runs-on", BIG),
    ("coderouter-release.yml", "build", "matrix:rust_target=x86_64-unknown-linux-gnu:runner", BIG),
    ("iroh-relay-minter.yml", "test", "runs-on", BIG),
    ("macos-cross-parity.yml", "linux-build", "runs-on", BIG),
    ("rust-workspaces.yml", "workspace", "runs-on", BIG),
    ("sdk-publish-crates.yml", "bindings-e2e-rust", "runs-on", BIG),
    ("sdk-publish-go.yml", "bindings-e2e-go", "runs-on", BIG),
    ("sdk-publish-java.yml", "bindings-e2e-java", "runs-on", BIG),
    ("sdk-publish-npm.yml", "bindings-e2e-typescript", "runs-on", BIG),
    ("sdk-publish-python.yml", "bindings-e2e-python", "runs-on", BIG),
    # Web: production builds, bundle builds, the backend build and suites.
    ("backend.yml", "test", "runs-on", BIG),
    ("ci-web.yml", "web-production-build", "runs-on", BIG),
    ("web-validation.yml", "build", "runs-on", BIG),
    ("cmux-next-web-bundle-publish.yml", "build", "runs-on", BIG),
    ("cmux-next-web-bundles.yml", "bundles", "runs-on", BIG),
    ("cmux-next.yml", "web-bundles", "runs-on", BIG),
    # Small compiles: one type check, a small test suite, Go, C++ shims.
    ("ci-web.yml", "web-typecheck", "runs-on", SMALL),
    ("ci-web.yml", "web-tests", "runs-on", SMALL),
    ("ci-web.yml", "web-instant-navigation", "runs-on", SMALL),
    ("web-validation.yml", "tests", "runs-on", SMALL),
    ("cmux-next-web-bundles.yml", "webviews-checks", "runs-on", SMALL),
    ("gallery-health.yml", "health", "runs-on", SMALL),
    ("cmux-actions.yml", "check", "runs-on", SMALL),
    ("cmux-vm.yml", "check", "runs-on", SMALL),
    ("cmux-vm-cloud.yml", "check", "runs-on", SMALL),
    ("cmux-vm-clients.yml", "sdk", "runs-on", SMALL),
    ("iroh-v2.yml", "backend", "runs-on", SMALL),
    ("presence.yml", "test", "runs-on", SMALL),
    ("cmux-tui.yml", "web-frontend", "runs-on", SMALL),
    ("cmux-tui.yml", "go-pane", "runs-on", SMALL),
    ("cmux-tui-spec.yml", "api-compat", "runs-on", SMALL),
    ("cmux-next-shim-cpp.yml", "shim-downloads-cpp", "runs-on", SMALL),
    ("remote-daemon.yml", "remote-daemon-tests", "runs-on", SMALL),
    ("sdk-bootstrap-crates.yml", "build", "runs-on", SMALL),
    ("sdk-publish-go.yml", "validate-go-module", "runs-on", SMALL),
    ("sdk-publish-go.yml", "verify-versioned-go-module", "runs-on", SMALL),
)

LINUX_LABEL = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+(?!-arm)\b")
# `vars.LINUX_RUNNER` exactly; `vars.LINUX_RUNNER_DARWIN_CROSS` is its own knob.
SHARED_VARIABLE = re.compile(r"vars\.LINUX_RUNNER(?!\w)")


def trusted_fallback(label: str) -> str:
    """The size, unless the outage switch names a non-Blacksmith runner."""
    return f"!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || '{label}'"


# What comes before the trusted fallback: the fork and fork pull request
# branches as they were before the move, byte for byte.
OWNER = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
FORK_PULL_REQUEST = (
    "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name"
    " != github.repository && '{label}' || "
)
FORK_PR_LABELS = {
    ("ci-web.yml", "web-typecheck", "runs-on"): SMALL,
    ("ci-web.yml", "web-production-build", "runs-on"): BIG,
    ("ci-web.yml", "web-tests", "runs-on"): SMALL,
    ("ci-web.yml", "web-instant-navigation", "runs-on"): SMALL,
    ("ci-web.yml", "diff-sidecar-check", "runs-on"): BIG,
    ("cmux-next-fast-gates.yml", "fast-gates", "runs-on"): SMALL,
    ("cmux-next.yml", "web-bundles", "runs-on"): BIG,
    ("cmux-vm-clients.yml", "rust", "runs-on"): BIG,
    ("cmux-vm-clients.yml", "sdk", "runs-on"): SMALL,
    ("remote-daemon.yml", "remote-daemon-tests", "runs-on"): SMALL,
}
PREFIX: dict[tuple[str, str, str], tuple[str, str]] = {
    # (prefix, closing) for selectors with a special owner/fork expression.
    ("cmux-tui-sdks.yml", "conformance", "runs-on"): (
        OWNER + FORK_PULL_REQUEST.format(label="blacksmith-8vcpu-ubuntu-2404"), ""),
    # These read no variable before the move, so a fork pull request took the
    # trusted literal. Reading LINUX_RUNNER now needs the fork pull request
    # branch first (test_ci_fork_runner_routing.py).
    ("cmux-next-car-guards.yml", "linux", "runs-on"): (
        OWNER + FORK_PULL_REQUEST.format(label="blacksmith-16vcpu-ubuntu-2404"), ""),
    ("cmux-tui-artifacts.yml", "macos-cross-shadow", "runs-on"): (OWNER + "vars.LINUX_RUNNER_DARWIN_CROSS || ", ""),
    ("macos-cross-parity.yml", "linux-build", "runs-on"): (OWNER + "vars.LINUX_RUNNER_DARWIN_CROSS || ", ""),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_DARWIN_RUNNER"): (
        OWNER + "vars.LINUX_RUNNER_DARWIN_CROSS || ", ""),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_BUILD_RUNNER"): (
        OWNER + "(inputs.linux_runner != '' && inputs.linux_runner || vars.LINUX_BUILD_RUNNER || ", ")"),
    # Owner-gated jobs with no fork branch.
    ("cmux-next-terminal.yml", "rust-terminal-linux", "runs-on"): ("", ""),
    ("cmux-tui-headless-debug.yml", "build", "runs-on"): ("", ""),
    ("coderouter-release.yml", "build", "matrix:rust_target=x86_64-unknown-linux-gnu:runner"): ("", ""),
}
# Selectors with the owner branch and no fork pull request branch.
OWNER_ONLY = {
    ("cmux-browser-host-chromium.yml", "chromium"),
    ("cmux-browser-host-release.yml", "build"),
    ("cmux-mobile-ffi.yml", "rust"),
    ("cmux-mobile-ffi.yml", "android"),
    ("cmux-next-source-archive.yml", "vt-link-graph"),
    ("cmux-tui-windows-check.yml", "windows-gnu-check"),
    ("iroh-relay-minter.yml", "test"),
    ("sdk-publish-crates.yml", "bindings-e2e-rust"),
    ("sdk-publish-go.yml", "bindings-e2e-go"),
    ("sdk-publish-java.yml", "bindings-e2e-java"),
    ("sdk-publish-npm.yml", "bindings-e2e-typescript"),
    ("sdk-publish-python.yml", "bindings-e2e-python"),
    ("cmux-next-web-bundle-publish.yml", "build"),
    ("presence.yml", "test"),
    ("sdk-bootstrap-crates.yml", "build"),
    ("sdk-publish-go.yml", "validate-go-module"),
    ("sdk-publish-go.yml", "verify-versioned-go-module"),
}


def expected_selector(workflow: str, job_id: str, where: str, label: str) -> str:
    prefix, closing = PREFIX.get((workflow, job_id, where), (None, ""))
    if prefix is None:
        if (workflow, job_id) in OWNER_ONLY:
            prefix = OWNER
        else:
            fork_label = FORK_PR_LABELS.get((workflow, job_id, where), "blacksmith-4vcpu-ubuntu-2404")
            prefix = OWNER + FORK_PULL_REQUEST.format(label=fork_label)
    return "${{ " + prefix + trusted_fallback(label) + closing + " }}"


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def selector(job: dict, where: str) -> str:
    if where == "runs-on":
        return str(job["runs-on"])
    kind, _, rest = where.partition(":")
    if kind == "matrix":
        match, field = rest.rsplit(":", 1)
        key, value = match.split("=", 1)
        rows = [row for row in job["strategy"]["matrix"]["include"] if str(row.get(key)) == value]
        if len(rows) != 1:
            raise AssertionError(f"expected one matrix row {key}={value}, found {len(rows)}")
        return str(rows[0][field])
    if kind == "env":
        step_id, name = rest.split(":", 1)
        steps = [s for s in job["steps"] if s.get("id") == step_id]
        if len(steps) != 1:
            raise AssertionError(f"expected one step with id {step_id!r}, found {len(steps)}")
        return str(steps[0]["env"][name])
    raise AssertionError(f"unknown location {where!r}")


class LinuxCompileRunners(unittest.TestCase):
    def test_each_compile_job_runs_on_the_16_or_32_vcpu_size(self) -> None:
        docs: dict[str, dict] = {}
        for workflow, job_id, where, label in EXPECTED:
            with self.subTest(workflow=workflow, job=job_id, where=where):
                doc = docs.setdefault(workflow, load(workflow))
                job = doc["jobs"].get(job_id)
                self.assertIsNotNone(job, f"{workflow} has no job {job_id!r}")
                value = selector(job, where)
                labels = LINUX_LABEL.findall(value)
                self.assertTrue(labels, f"{workflow}:{job_id} {where} names no Blacksmith Ubuntu label: {value}")
                self.assertEqual(labels[-1], label, f"{workflow}:{job_id} {where}: {value}")
                # vars.LINUX_RUNNER appears only in the outage guard, never as
                # a plain `vars.LINUX_RUNNER ||` that would pick 4 vCPU.
                self.assertEqual(
                    len(SHARED_VARIABLE.findall(value)), 2,
                    f"{workflow}:{job_id} {where} must read vars.LINUX_RUNNER only in "
                    f"{trusted_fallback(label)!r}: {value}",
                )

    def test_each_compile_job_follows_the_blacksmith_outage_switch(self) -> None:
        # cloud_overflow_switch.py sets LINUX_RUNNER=ubuntu-24.04 when Blacksmith
        # stalls; the guard sends these jobs there too, and keeps the size otherwise.
        for workflow, job_id, where, label in EXPECTED:
            value = selector(load(workflow)["jobs"][job_id], where)
            with self.subTest(workflow=workflow, job=job_id, where=where):
                self.assertEqual(value.count(trusted_fallback(label)), 1, f"{workflow}:{job_id} {where}: {value}")
                self.assertRegex(
                    value, re.escape(trusted_fallback(label)) + r"\)? \}\}$",
                    f"{workflow}:{job_id} {where}: the outage guard must be the trusted fallback",
                )

    def test_fork_pull_requests_use_the_selected_blacksmith_size(self) -> None:
        # The trusted job's size is also the fork pull request's size, while
        # small routing/status jobs retain the 4-vCPU default.
        for workflow, job_id, where, label in EXPECTED:
            value = selector(load(workflow)["jobs"][job_id], where)
            with self.subTest(workflow=workflow, job=job_id, where=where):
                self.assertEqual(value, expected_selector(workflow, job_id, where, label))
                if "repository_owner != 'manaflow-ai'" in value:
                    self.assertRegex(value, r"github\.repository_owner != 'manaflow-ai' && '(ubuntu-24\.04|ubuntu-latest)'")
                if (workflow, job_id) not in OWNER_ONLY and (workflow, job_id, where) not in PREFIX:
                    fork_label = FORK_PR_LABELS.get((workflow, job_id, where), "blacksmith-4vcpu-ubuntu-2404")
                    self.assertIn(
                        OWNER + FORK_PULL_REQUEST.format(label=fork_label),
                        value,
                        f"fork pull requests use {fork_label}",
                    )

    def test_every_listed_label_is_known_to_actionlint(self) -> None:
        config = yaml.safe_load((ROOT / ".github" / "actionlint.yaml").read_text(encoding="utf-8"))
        known = set(config["self-hosted-runner"]["labels"])
        self.assertLessEqual({BIG, SMALL}, known)


if __name__ == "__main__":
    unittest.main()
