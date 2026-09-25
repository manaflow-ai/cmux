#!/usr/bin/env python3
"""Every macOS CI job selects its Xcode through scripts/select-ci-xcode.sh.

A macOS job that runs Swift on whatever Xcode the image defaults to compiles
with the wrong toolchain the day it lands on a different image. On GitHub's
macos-15 image that default is Xcode 16.4, and a fork run there reported 1,309
compile errors instead of one line saying the Xcode was wrong. Jobs that each
chose their own Xcode also stopped sharing compilation caches and products.

select-ci-xcode.sh pins every job: to the job's own CMUX_CI_XCODE_APP, else to
the version scripts/ci/xcode-pins.txt names for the runner's macOS, and it
refuses anything below the .xcode-version major. This guard keeps jobs on it:

1. Every macOS job runs select-ci-xcode.sh, before any step that uses the
   toolchain, unless EXEMPT names it with a reason. The rule is "every macOS
   job", not "every job that visibly runs swift", because test scripts compile
   Swift out of sight (tests/run_cloud_command_deadline_tests.sh runs
   `swift test`).
2. No macOS job chooses an Xcode itself (DEVELOPER_DIR into GITHUB_ENV,
   xcode-select --switch, a literal CMUX_CI_XCODE_APP path) outside EXEMPT.
3. Only the SDK 15 Ghostty CLI helper step lifts the pool pin and the floor.
4. Every pool pin has the .xcode-version major, and check-pbxproj.sh knows it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SELECTOR = "scripts/select-ci-xcode.sh"
BELOW_FLOOR = "CMUX_CI_XCODE_ALLOW_BELOW_FLOOR"

# (workflow, job) -> why the job does not go through select-ci-xcode.sh.
EXEMPT = {
    ("build-ghosttykit.yml", "build-ghosttykit"):
        "Zig-only GhosttyKit xcframework build on the background lane; it takes "
        "the image's SDK, and moving it changes a published artifact",
    ("release.yml", "build-ghostty-cli-helper"):
        "Zig-only Ghostty CLI helper, built against the macOS 15 image's SDK 15 "
        "default like the helper in ci-macos.yml",
    ("nightly.yml", "build-nightly-ghostty-cli-helper"):
        "Zig-only Ghostty CLI helper, built against the macOS 15 image's SDK 15 "
        "default like the helper in ci-macos.yml",
    ("ci-macos-compat.yml", "compat-tests"):
        "compatibility lane: builds with the newest Xcode each older image "
        "carries (16.x on macos-14), below the floor on purpose",
    ("relay-tls.yml", "system-keychain"):
        "runs the relay TLS verifier under Xcode 16.2 / Swift 6, below the "
        "floor on purpose",
    ("remote-daemon.yml", "remote-daemon-macos-tests"): "Go only; no Xcode",
    ("ci.yml", "claude-wrapper"): "shell wrapper tests only; no Xcode",
    ("cmux-tui.yml", "lint"): "Rust only; no Xcode",
    ("cmux-tui.yml", "test"): "Rust only; no Xcode",
    ("cmux-tui.yml", "cdp-browser-smoke"): "Rust only; no Xcode",
    ("relay-publish-npm.yml", "smoke"): "npm package smoke test; no Xcode",
}

# (workflow, job, step name) allowed to set CMUX_CI_XCODE_ALLOW_BELOW_FLOOR.
BELOW_FLOOR_STEPS = {("ci-macos.yml", "swift-package-tests", "Select helper Xcode")}

# A step that reaches the Xcode toolchain directly or through a repo script.
TOOLCHAIN = re.compile(
    r"\bxcodebuild\b|\bxcrun\b|\bswiftc?\b|\bclang\b|\bcodesign\b|\blipo\b"
    r"|reload[a-z0-9]*\.sh|scripts/ci/workloads/|compile-app-host-test-product"
    r"|tests/run_[A-Za-z0-9_-]+\.sh|scripts/build-[A-Za-z0-9_-]+\.sh"
)
SELF_SELECTION = re.compile(
    r"DEVELOPER_DIR=[^\n]*GITHUB_ENV|xcode-select\s+(-s|--switch)\b"
)
LITERAL_XCODE_PIN = re.compile(r"^\s*CMUX_CI_(XCODE_APP|DEVELOPER_DIR):\s*['\"]?/", re.M)


def _block(lines: list[str], start: int, indent: int) -> tuple[list[str], int]:
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        end += 1
    return lines[start:end], end


def jobs(text: str) -> dict[str, str]:
    """Top-level jobs of a workflow as raw text, keyed by job id."""
    lines = text.splitlines()
    try:
        start = lines.index("jobs:") + 1
    except ValueError:
        return {}
    found: dict[str, str] = {}
    index = start
    while index < len(lines):
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", lines[index])
        if not match:
            if lines[index].strip() and not lines[index].startswith(" "):
                break
            index += 1
            continue
        block, index = _block(lines, index, 2)
        found[match.group(1)] = "\n".join(block)
    return found


def steps(job: str) -> list[tuple[str, str]]:
    """(name, text) for each step of a job."""
    lines = job.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if re.match(r"^    steps:\s*$", line))
    except StopIteration:
        return []
    found = []
    index = start + 1
    while index < len(lines):
        if not lines[index].startswith("      - "):
            if lines[index].strip() and len(lines[index]) - len(lines[index].lstrip()) <= 4:
                break
            index += 1
            continue
        block, index = _block(lines, index, 6)
        text = "\n".join(block)
        name = re.search(r"^      [- ] name:\s*(.+)$", text, re.M)
        found.append((name.group(1).strip() if name else "", text))
    return found


def is_macos(job: str) -> bool:
    runs_on = re.search(r"^    runs-on:(.*)$", job, re.M)
    if not runs_on:
        return False
    target = runs_on.group(1)
    if "matrix." in target:
        matrix = re.search(r"^    strategy:\n((?:      .*\n?|\s*\n)+)", job, re.M)
        target += matrix.group(1) if matrix else ""
    return "macos" in target.lower()


def check_workflow(name: str, text: str) -> list[str]:
    errors = []
    for job_id, job in jobs(text).items():
        key = (name, job_id)
        if not is_macos(job) or key in EXEMPT:
            continue
        where = f"{name} job {job_id}"
        if LITERAL_XCODE_PIN.search(job):
            errors.append(f"{where} pins a literal Xcode path; name the pool's Xcode in scripts/ci/xcode-pins.txt")
        job_steps = steps(job)
        select_at = next(
            (i for i, (_, body) in enumerate(job_steps) if SELECTOR in body and BELOW_FLOOR not in body),
            None,
        )
        if select_at is None:
            errors.append(f"{where} never runs {SELECTOR}, so it builds with the image's default Xcode")
        # The SDK 15 helper's own selection also orders the steps that use it.
        first_select = next((i for i, (_, body) in enumerate(job_steps) if SELECTOR in body), None)
        for index, (step_name, body) in enumerate(job_steps):
            label = f"{where} step {step_name or index + 1!r}"
            if SELF_SELECTION.search(body):
                errors.append(f"{label} chooses an Xcode itself; run {SELECTOR} instead")
            if BELOW_FLOOR in body and (name, job_id, step_name) not in BELOW_FLOOR_STEPS:
                errors.append(f"{label} sets {BELOW_FLOOR}; only the SDK 15 helper may")
            uses_toolchain = TOOLCHAIN.search(re.sub(r".*select-ci-xcode\.sh.*", "", body))
            if uses_toolchain and first_select is not None and index < first_select:
                errors.append(f"{label} uses the toolchain ({uses_toolchain.group(0)}) before {SELECTOR} runs")
    return errors


def check_repository() -> list[str]:
    errors = []
    texts = {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.yml"))}
    for name, text in texts.items():
        errors.extend(check_workflow(name, text))

    for (workflow, job_id), reason in EXEMPT.items():
        job = jobs(texts.get(workflow, "")).get(job_id)
        if job is None:
            errors.append(f"EXEMPT names {workflow} job {job_id}, which no longer exists ({reason})")
        elif SELECTOR in job and not any(BELOW_FLOOR in body for _, body in steps(job)):
            errors.append(f"EXEMPT names {workflow} job {job_id}, which now runs {SELECTOR}; drop the exemption")

    for workflow, job_id, step_name in BELOW_FLOOR_STEPS:
        job = jobs(texts[workflow]).get(job_id, "")
        if not any(n == step_name and BELOW_FLOOR in b for n, b in steps(job)):
            errors.append(f"{workflow} job {job_id} step {step_name!r} no longer sets {BELOW_FLOOR}")

    floor = (ROOT / ".xcode-version").read_text().strip().split(".")[0]
    if not floor.isdigit():
        errors.append(f".xcode-version must start with a numeric Xcode major, got {floor!r}")
    pins = {}
    for line in (ROOT / "scripts/ci/xcode-pins.txt").read_text().splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        if len(fields) != 2 or not fields[0].isdigit() or not re.fullmatch(r"\d+\.\d+(\.\d+)?", fields[1]):
            errors.append(f"scripts/ci/xcode-pins.txt: expected '<macOS major> <Xcode version>', got {line!r}")
            continue
        if fields[0] in pins:
            errors.append(f"scripts/ci/xcode-pins.txt pins macOS {fields[0]} twice")
        pins[fields[0]] = fields[1]
        if fields[1].split(".")[0] != floor:
            errors.append(
                f"scripts/ci/xcode-pins.txt pins Xcode {fields[1]} for macOS {fields[0]}, "
                f"outside the .xcode-version major {floor}"
            )
    for pool in ("15", "26"):
        if pool not in pins:
            errors.append(f"scripts/ci/xcode-pins.txt has no pin for the macOS {pool} pool CI runs on")
    if not re.search(rf"^\s*{floor}\)\s+EXPECTED_OBJECT_VERSION=", (ROOT / "scripts/check-pbxproj.sh").read_text(), re.M):
        errors.append(f"scripts/check-pbxproj.sh has no objectVersion case for Xcode {floor}")
    return errors


def check_detects_regressions() -> list[str]:
    """The checker must flag each way a job can slip off the selector."""
    base = """jobs:
  build:
    runs-on: ${{ vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}
    steps:
      - uses: actions/checkout@v6
      - name: Select Xcode
        run: ./scripts/select-ci-xcode.sh
      - name: Test
        run: swift test --package-path Packages/Shared/Example
  linux:
    runs-on: ubuntu-24.04
    steps:
      - run: swift test
"""
    cases = {
        "clean": (base, []),
        "no selector": (base.replace("./scripts/select-ci-xcode.sh", "echo skipped"), ["never runs"]),
        "selector after build": (
            base.replace(
                "      - name: Select Xcode\n        run: ./scripts/select-ci-xcode.sh\n      - name: Test\n        run: swift test --package-path Packages/Shared/Example\n",
                "      - name: Test\n        run: swift test --package-path Packages/Shared/Example\n      - name: Select Xcode\n        run: ./scripts/select-ci-xcode.sh\n",
            ),
            ["before scripts/select-ci-xcode.sh runs"],
        ),
        "image default": (
            base.replace(
                "run: ./scripts/select-ci-xcode.sh",
                'run: |\n          echo "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >> "$GITHUB_ENV"',
            ),
            ["never runs", "chooses an Xcode itself"],
        ),
        "xcode-select": (
            base.replace("      - name: Test\n", "      - run: sudo xcode-select -s /Applications/Xcode_16.4.app\n      - name: Test\n"),
            ["chooses an Xcode itself"],
        ),
        "literal pin": (
            base.replace("    steps:\n", "    env:\n      CMUX_CI_XCODE_APP: /Applications/Xcode_26.3.app\n    steps:\n", 1),
            ["literal Xcode path"],
        ),
        "below floor": (
            base.replace("run: ./scripts/select-ci-xcode.sh", "run: CMUX_CI_XCODE_ALLOW_BELOW_FLOOR=1 ./scripts/select-ci-xcode.sh"),
            ["never runs", "only the SDK 15 helper may"],
        ),
        "matrix macOS": (
            base.replace(
                "    runs-on: ${{ vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}\n",
                "    strategy:\n      matrix:\n        os: [macos-15]\n    runs-on: ${{ matrix.os }}\n",
            ).replace("./scripts/select-ci-xcode.sh", "echo skipped"),
            ["never runs"],
        ),
        "indirect Swift": (
            base.replace("./scripts/select-ci-xcode.sh", "echo skipped").replace(
                "swift test --package-path Packages/Shared/Example", "tests/run_example_tests.sh"
            ),
            ["never runs"],
        ),
    }
    errors = []
    for label, (text, expected) in cases.items():
        found = check_workflow("synthetic.yml", text)
        if not expected and found:
            errors.append(f"self-test {label!r}: expected no findings, got {found}")
        if expected and len(found) != len(expected):
            errors.append(f"self-test {label!r}: expected {len(expected)} findings, got {found}")
        for fragment in expected:
            if not any(fragment in finding for finding in found):
                errors.append(f"self-test {label!r}: no finding mentions {fragment!r}; got {found}")
        if any("linux" in finding for finding in found):
            errors.append(f"self-test {label!r}: flagged the Linux job: {found}")
    return errors


def main() -> int:
    errors = check_detects_regressions() + check_repository()
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print("PASS: every macOS job selects its Xcode through scripts/select-ci-xcode.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
