"""Linux jobs that compile run on the one Linux label, cmux-linux, with no size picked in the workflow.

Leo, 2026-11-20: "you shouldn't have to think about sizing your f*** CI. Like 4V CPU, 8, 16, 32, who gives a
shit? Just send it somewhere. It'll scale up if it needs to. Scale down if it doesn't need anything."
scripts/ci/one_linux_label.py wrote every Linux x64 picker to one expression: a fork repository takes
GitHub-hosted Ubuntu, a fork pull request `vars.CI_FORK_LINUX_RUNNER` (GitHub-hosted Ubuntu while unset), a
nightly or release pin keeps its branch, and everything else takes `cmux-linux`. The jobs below compile
(cargo, cross builds, zig, Go, C++, Gradle) or run a web build or suite; each was sized here before.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import one_linux_label  # noqa: E402
import workflow_jobs  # noqa: E402
WORKFLOWS = ROOT / ".github" / "workflows"
SIZE = re.compile(r"blacksmith-\d+vcpu-ubuntu-2404(?!-)|RUNNER_POOLS\)\.linux(?!_arm)|vars\.LINUX_RUNNER(?![A-Z_])"
                  r"|CI_CLOUD_OVERFLOW_SAVED")
SUFFIX = "'cmux-linux' }}"

# (workflow, job, where the label lives). `where` is "runs-on",
# "matrix:<key>=<value>:<field>" for a matrix row, or "env:<step id>:<NAME>"
# for a runner a planning step hands to the build legs.
EXPECTED: tuple[tuple[str, str, str], ...] = (
    # Rust: cargo build, test, clippy, cross builds.
    ("ci-web.yml", "diff-sidecar-check", "runs-on"),
    ("cmux-next-fast-gates.yml", "fast-gates", "runs-on"),
    # cloudflare-relay.yml cloudflare-relay is `owned-pool-unfit` (its Worker builder install failed twice on cmux-linux).
    ("cmux-browser-host-chromium.yml", "chromium", "runs-on"),
    ("cmux-browser-host-release.yml", "build", "matrix:target=x86_64-unknown-linux-gnu:runs_on"),
    ("cmux-cloud-cli.yml", "test", "runs-on"),
    ("cmux-mobile-ffi.yml", "rust", "runs-on"),
    ("cmux-mobile-ffi.yml", "android", "runs-on"),
    ("cmux-next-car-guards.yml", "linux", "runs-on"),
    ("cmux-next-source-archive.yml", "vt-link-graph", "runs-on"),
    ("cmux-tui-artifacts.yml", "macos-cross-shadow", "runs-on"),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_BUILD_RUNNER"),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_DARWIN_RUNNER"),
    ("cmux-tui-headless-debug.yml", "build", "runs-on"),
    ("cmux-tui-spec.yml", "acpmux-protocol-ir", "runs-on"),
    ("cmux-tui-sdks.yml", "packages", "runs-on"),
    ("cmux-tui-sdks.yml", "consumers", "runs-on"),
    ("cmux-tui-sdks.yml", "conformance", "runs-on"),
    ("cmux-tui-sdks.yml", "rust-msrv", "runs-on"),
    ("cmux-tui-windows-check.yml", "windows-gnu-check", "runs-on"),
    ("cmux-tui.yml", "optchat-chief", "runs-on"),
    ("cmux-vm-clients.yml", "rust", "runs-on"),
    ("coderouter-ci.yml", "test", "runs-on"),
    ("coderouter-release.yml", "build-linux", "runs-on"),
    ("iroh-relay-minter.yml", "test", "runs-on"),
    # macos-cross-parity.yml linux-build: scheduled with no main twin, so the pre-push gate keeps it as it is until main has one.
    ("rust-workspaces.yml", "workspace", "runs-on"),
    ("sdk-publish-crates.yml", "bindings-e2e-rust", "runs-on"),
    ("sdk-publish-go.yml", "bindings-e2e-go", "runs-on"),
    ("sdk-publish-java.yml", "bindings-e2e-java", "runs-on"),
    ("sdk-publish-npm.yml", "bindings-e2e-typescript", "runs-on"),
    ("sdk-publish-python.yml", "bindings-e2e-python", "runs-on"),
    # Swift on Linux: swift build and swift test of the portable packages in the swift.org
    # container (ask-d3f5804560: "WE CAN COMPILE SWIFT ON LINUX").
    ("swift-linux-packages.yml", "swift-linux-packages", "runs-on"),
    # Web: production builds, bundle builds, the backend build and suites.
    ("backend.yml", "test", "runs-on"),
    ("ci-web.yml", "web-production-build", "runs-on"),
    ("cmux-next-web-bundle-publish.yml", "build", "runs-on"),
    ("cmux-next-web-bundles.yml", "bundles", "runs-on"),
    ("cmux-next.yml", "web-bundles", "runs-on"),
    # Small compiles: one type check, a small test suite, Go, C++ shims.
    # web-validation.yml's build and tests and gallery-health.yml's health read the live Linux pool
    # (fromJSON(vars.RUNNER_POOLS).linux, tests/test_ci_runner_set.py) instead of one fixed size.
    ("ci-web.yml", "web-typecheck", "runs-on"),
    ("ci-web.yml", "web-tests", "runs-on"),
    ("ci-web.yml", "web-instant-navigation", "runs-on"),
    ("cmux-next-web-bundles.yml", "webviews-checks", "runs-on"),
    ("cmux-actions.yml", "check", "runs-on"),
    ("cmux-vm.yml", "check", "runs-on"),
    ("cmux-vm-cloud.yml", "check", "runs-on"),
    ("cmux-vm-clients.yml", "sdk", "runs-on"),
    ("iroh-v2.yml", "backend", "runs-on"),
    ("presence.yml", "test", "runs-on"),
    ("cmux-tui.yml", "web-frontend", "runs-on"),
    ("cmux-tui.yml", "go-pane", "runs-on"),
    ("cmux-tui-spec.yml", "api-compat", "runs-on"),
    ("cmux-next-shim-cpp.yml", "shim-downloads-cpp", "runs-on"),
    ("remote-daemon.yml", "remote-daemon-tests", "runs-on"),
    ("sdk-bootstrap-crates.yml", "build", "runs-on"),
    ("sdk-publish-go.yml", "validate-go-module", "runs-on"),
    ("sdk-publish-go.yml", "verify-versioned-go-module", "runs-on"),
)

def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def selector(job: dict, where: str) -> str:
    if where == "runs-on":
        cells = workflow_jobs.runs_on_cells(job)
        if cells is None or len(cells) != 1:
            raise AssertionError(f"expected one runs-on, read {cells!r}")
        return cells[0]
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
    def test_each_compile_job_takes_the_one_label(self) -> None:
        docs: dict[str, dict] = {}
        for workflow, job_id, where in EXPECTED:
            with self.subTest(workflow=workflow, job=job_id, where=where):
                job = docs.setdefault(workflow, load(workflow))["jobs"].get(job_id)
                self.assertIsNotNone(job, f"{workflow} has no job {job_id!r}")
                value = selector(job, where)
                if one_linux_label.EPHEMERAL_ONLY.search(value):
                    continue  # a credentialed job kept on an ephemeral vendor runner (one_linux_label.py's exceptions)
                # A pin (a nightly arm, the darwin cross lane, a caller's override) may come before the fork branch.
                self.assertTrue(value.startswith("${{ " + one_linux_label.OWNER_GUARD + " || "), value)
                self.assertIn(" || " + one_linux_label.FORK_PR + " || ", value, f"{workflow}:{job_id} {where}: fork branch")
                self.assertTrue(value.endswith(SUFFIX), f"{workflow}:{job_id} {where}: ends in cmux-linux: {value}")
                self.assertIsNone(SIZE.search(value), f"{workflow}:{job_id} {where} names a Linux size: {value}")

    def test_a_fork_pull_request_never_reaches_an_owned_host(self) -> None:
        self.assertIn("(vars.CI_FORK_LINUX_RUNNER || 'ubuntu-24.04')", one_linux_label.FORK_PR)
        self.assertIn("head.repo.full_name != github.repository", one_linux_label.FORK_PR)


if __name__ == "__main__":
    unittest.main()
