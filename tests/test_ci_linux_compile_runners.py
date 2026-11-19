"""Linux jobs that compile run on the one Linux label, cmux-linux; a fork pull request keeps its Blacksmith size.

cmuxterm-hq#14156, "capacity comes to the job": one literal Linux label, with overflow as more runners on that
label. Each job below compiles (cargo, Swift, cross builds, zig, Go, C++, Gradle) or runs a web build or test
suite. Its own-branch label is the literal 'cmux-linux': no `vars.LINUX_RUNNER`, no `RUNNER_POOLS` linux pool,
no `CI_CLOUD_OVERFLOW_SAVED` outage switch and no broker `inputs.runner` choice in its selector
(scripts/ci/check_linux_runs_on.py is the repository-wide detector). The vendor runners stay only as an
occasional overflow switch (ci-cloud-overflow-probe.yml); no job here routes to them by default.

What stays as it was: a fork repository runs on hosted `ubuntu-24.04`, and a fork pull request runs on the
Blacksmith size it took before the move (compile and test suites a sized lane, small routing/status jobs the
4-vCPU lane), since it cannot use the organization's own runners.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402
WORKFLOWS = ROOT / ".github" / "workflows"

LABEL = "cmux-linux"

# (workflow, job, where the label lives). `where` is "runs-on", "matrix:<key>=<value>:<field>" for a matrix
# row, or "env:<step id>:<NAME>" for a runner a planning step hands to the build legs.
EXPECTED: tuple[tuple[str, str, str], ...] = (
    # Rust: cargo build, test, clippy, cross builds.
    ("ci-web.yml", "diff-sidecar-check", "runs-on"),
    ("cmux-next-fast-gates.yml", "fast-gates", "runs-on"),
    ("cloudflare-relay.yml", "cloudflare-relay", "runs-on"),
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
    ("macos-cross-parity.yml", "linux-build", "runs-on"),
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

OWNER = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
FORK_PULL_REQUEST = (
    "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name"
    " != github.repository && '{label}' || "
)
# The Blacksmith size a fork pull request keeps; every other job with a fork pull request branch takes 4 vCPU.
FORK_PR_LABELS = {
    ("ci-web.yml", "web-typecheck", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("ci-web.yml", "web-production-build", "runs-on"): "blacksmith-32vcpu-ubuntu-2404",
    ("ci-web.yml", "web-tests", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("ci-web.yml", "web-instant-navigation", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("ci-web.yml", "diff-sidecar-check", "runs-on"): "blacksmith-32vcpu-ubuntu-2404",
    ("cmux-next-fast-gates.yml", "fast-gates", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("cmux-next-car-guards.yml", "linux", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_BUILD_RUNNER"): "blacksmith-16vcpu-ubuntu-2404",
    ("cmux-tui-sdks.yml", "conformance", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("cmux-vm-clients.yml", "rust", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("cmux-vm-clients.yml", "sdk", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("remote-daemon.yml", "remote-daemon-tests", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
    ("sdk-publish-crates.yml", "bindings-e2e-rust", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("sdk-publish-go.yml", "bindings-e2e-go", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("sdk-publish-npm.yml", "bindings-e2e-typescript", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("sdk-publish-python.yml", "bindings-e2e-python", "runs-on"): "blacksmith-8vcpu-ubuntu-2404",
    ("swift-linux-packages.yml", "swift-linux-packages", "runs-on"): "blacksmith-16vcpu-ubuntu-2404",
}
# Selectors with the fork repository branch and no fork pull request branch.
OWNER_ONLY = {
    ("cmux-browser-host-chromium.yml", "chromium", "runs-on"),
    ("cmux-browser-host-release.yml", "build", "matrix:target=x86_64-unknown-linux-gnu:runs_on"),
    ("cmux-mobile-ffi.yml", "rust", "runs-on"),
    ("cmux-mobile-ffi.yml", "android", "runs-on"),
    ("cmux-tui-artifacts.yml", "macos-cross-shadow", "runs-on"),
    ("cmux-tui-build-package.yml", "plan-build", "env:targets:LINUX_DARWIN_RUNNER"),
    ("cmux-tui-windows-check.yml", "windows-gnu-check", "runs-on"),
    ("iroh-relay-minter.yml", "test", "runs-on"),
    ("macos-cross-parity.yml", "linux-build", "runs-on"),
    ("sdk-publish-java.yml", "bindings-e2e-java", "runs-on"),
    ("cmux-next-web-bundle-publish.yml", "build", "runs-on"),
    ("presence.yml", "test", "runs-on"),
    ("sdk-bootstrap-crates.yml", "build", "runs-on"),
}
# Owner-gated jobs (an `if:` on the repository) with no fork branch at all: the bare literal.
LITERAL_ONLY = {
    ("cmux-tui-headless-debug.yml", "build", "runs-on"),
    ("coderouter-release.yml", "build-linux", "runs-on"),
}

# A label picker a Linux job's own branch must not read (cmuxterm-hq#14156).
PICKERS = re.compile(
    r"vars\.(LINUX_RUNNER|LINUX_BUILD_RUNNER|CI_TRUSTED_RUNNER|CI_LINUX_GATE_OWNED_RUNNER|CI_CLOUD_OVERFLOW_SAVED)(?!\w)"
    r"|RUNNER_POOLS|inputs\.(runner|linux_runner|linux_build_runner)(?!\w)|needs\.[\w-]+\.outputs\.\w*runner"
)


def expected_selector(workflow: str, job_id: str, where: str) -> str:
    key = (workflow, job_id, where)
    if key in LITERAL_ONLY:
        return LABEL
    if key in OWNER_ONLY:
        prefix = OWNER
    else:
        prefix = OWNER + FORK_PULL_REQUEST.format(label=FORK_PR_LABELS.get(key, "blacksmith-4vcpu-ubuntu-2404"))
    return "${{ " + prefix + f"'{LABEL}'" + " }}"


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
    def test_each_compile_job_runs_on_cmux_linux(self) -> None:
        docs: dict[str, dict] = {}
        for workflow, job_id, where in EXPECTED:
            with self.subTest(workflow=workflow, job=job_id, where=where):
                doc = docs.setdefault(workflow, load(workflow))
                job = doc["jobs"].get(job_id)
                self.assertIsNotNone(job, f"{workflow} has no job {job_id!r}")
                value = selector(job, where)
                self.assertTrue(value == LABEL or value.endswith(f"|| '{LABEL}' }}}}"),
                                f"{workflow}:{job_id} {where}: own branch is not the literal {LABEL}: {value}")

    def test_no_compile_job_reads_a_linux_picker(self) -> None:
        # No shared variable, pool, outage switch or broker input chooses the label (cmuxterm-hq#14156).
        for workflow, job_id, where in EXPECTED:
            value = selector(load(workflow)["jobs"][job_id], where)
            with self.subTest(workflow=workflow, job=job_id, where=where):
                self.assertIsNone(PICKERS.search(value), f"{workflow}:{job_id} {where}: {value}")

    def test_fork_branches_keep_their_labels(self) -> None:
        # A fork repository takes hosted ubuntu-24.04; a fork pull request keeps the Blacksmith size it had.
        for workflow, job_id, where in EXPECTED:
            value = selector(load(workflow)["jobs"][job_id], where)
            with self.subTest(workflow=workflow, job=job_id, where=where):
                self.assertEqual(value, expected_selector(workflow, job_id, where))

    def test_every_listed_label_is_known_to_actionlint(self) -> None:
        config = yaml.safe_load((ROOT / ".github" / "actionlint.yaml").read_text(encoding="utf-8"))
        known = set(config["self-hosted-runner"]["labels"])
        fork_labels = set(FORK_PR_LABELS.values()) | {"blacksmith-4vcpu-ubuntu-2404"}
        self.assertLessEqual({LABEL} | fork_labels, known)


if __name__ == "__main__":
    unittest.main()
