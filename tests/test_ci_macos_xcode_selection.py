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
   Swift out of sight (scripts/ci/package-test-lane.sh runs `swift test`).
2. No macOS job chooses an Xcode itself (DEVELOPER_DIR into GITHUB_ENV,
   xcode-select --switch, a literal CMUX_CI_XCODE_APP path) outside EXEMPT.
3. Only the SDK 15 Ghostty CLI helper step lifts the pool pin and the floor.
4. Every pool pin is at least the .xcode-version floor, and check-pbxproj.sh
   knows the floor.
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
        "Zig-only Ghostty CLI helper, built with the submodule's Zig against "
        "the macOS 26 runner's default SDK; its cache key names that SDK",
    ("relay-tls.yml", "system-keychain"):
        "runs the relay TLS verifier under Xcode 16.2 / Swift 6, below the "
        "floor on purpose",
    ("remote-daemon.yml", "remote-daemon-macos-tests"): "Go only; no Xcode",
    ("nightly-next-launch-smoke.yml", "smoke"):
        "launches the published nightly-next DMG; builds nothing, no Xcode",
    ("cmux-tui.yml", "lint"): "Rust only; no Xcode",
    ("cmux-tui.yml", "test"): "Rust only; no Xcode",
    ("cmux-next-daemon-macos-shadow.yml", "cmux-next-daemon-macos-shadow"):
        "Rust only; no Xcode (the macOS-only daemon tests, a non-blocking shadow "
        "of the Linux promotion gate)",
    ("cmux-tui.yml", "cdp-browser-smoke"): "Rust only; no Xcode",
    ("cmux-tui.yml", "macos"):
        "Rust and Zig only (cargo clippy/test with libghostty-vt from Zig); no "
        "Swift or xcodebuild, like the lint and test jobs it combines (#17051)",
    ("cmux-next-source-archive.yml", "archive"):
        "Zig and Python only: Zig fetch lists and the source archive, and link "
        "sets read from the pinned xcframework; the CLI helper fetch list must "
        "come from the macOS 15 image's SDK 15 default, like the release helper",
    ("cmux-tui-build-package.yml", "build"):
        "Rust release binaries linked against the runner's default macOS SDK, "
        "as the nightly and release callers always have; pinning it would "
        "change published artifacts",
    ("relay-publish-npm.yml", "smoke"): "npm package smoke test; no Xcode",
    ("stable-next.yml", "smoke-27"): "launches the signed cmux NEXT Stable DMG; builds nothing, no Xcode",
    ("stable-next.yml", "smoke-26"): "launches the signed cmux NEXT Stable DMG; builds nothing, no Xcode",
    ("nightly.yml", "decide"):
        "control job: attempt 1 of a nightly-next push takes the owned nightly slot "
        "(CI_NIGHTLY_NEXT_BUILD_RUNNER); git, github-script and Python only, no Xcode",
    ("nightly.yml", "resolve-nightly-cmux-tui-client"):
        "control job: takes Blacksmith macOS only while Blacksmith Linux overflow is off "
        "(CI_CLOUD_OVERFLOW_SAVED); git, gh and Python only, no Xcode",
    ("nightly.yml", "resolve-nightly-ghostty-cli-helper"):
        "control job: takes Blacksmith macOS only while Blacksmith Linux overflow is off "
        "(CI_CLOUD_OVERFLOW_SAVED); git, gh and Python only, no Xcode",
    ("nightly.yml", "pick-nightly-build-runner"):
        "control job: takes Blacksmith macOS only while Blacksmith Linux overflow is off "
        "(CI_CLOUD_OVERFLOW_SAVED); git, gh and Python only, no Xcode",
    ("nightly.yml", "pick-nightly-sign-runner"):
        "control job: takes Blacksmith macOS only while Blacksmith Linux overflow is off "
        "(CI_CLOUD_OVERFLOW_SAVED); git, gh and Python only, no Xcode",
    ("nightly.yml", "find-nightly-next-recovery"):
        "control job: takes Blacksmith macOS only while Blacksmith Linux overflow is off "
        "(CI_CLOUD_OVERFLOW_SAVED); git, gh and Python only, no Xcode",
    ("nightly.yml", "prepare-nightly-variant-primary"):
        "takes Blacksmith macOS only while Blacksmith Linux overflow is off; builds nothing, only "
        "lipo -thin, whose bytes match llvm-lipo's on Linux whatever the Xcode",
    ("nightly.yml", "prepare-nightly-variant"):
        "takes Blacksmith macOS only while Blacksmith Linux overflow is off; builds nothing, only "
        "lipo -thin, whose bytes match llvm-lipo's on Linux whatever the Xcode",
    ("cmux-next-batch.yml", "build"):
        "submits the stack to the build fleet and waits; the build runs on a "
        "fleet worker, never with this runner's Xcode",
    ("cmux-next.yml", "swift-canary-fleet"):
        "build-fleet gateway: checks nothing out and only runs cmux-ci "
        "compile-check; the compile runs on a fleet worker, never with this "
        "runner's Xcode",
    ("cmux-next.yml", "app-compile-fleet"):
        "build-fleet gateway: checks nothing out and only runs cmux-ci "
        "compile-check; the compile runs on a fleet worker, never with this "
        "runner's Xcode",
    ("cmux-next.yml", "fast-tier-fleet"):
        "build-fleet gateway: checks nothing out and only runs cmux-ci "
        "run (package-test-lane.sh suites); the suites build on a fleet "
        "worker, never with this runner's Xcode",
    ("cmux-next.yml", "release-compile-fast"):
        "build-fleet gateway: checks nothing out and only runs cmux-ci "
        "compile-check --release; the compile runs on a fleet worker, never "
        "with this runner's Xcode",
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
        start = next(i for i, line in enumerate(lines) if re.match(r"^    steps:(?:\s+&[\w-]+)?\s*$", line))
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


STEP_ANCHOR = re.compile(r"^      - &([\w-]+)\s*$")
STEP_ALIAS = re.compile(r"^      - \*([\w-]+)\s*$")


def step_anchors(workflow_jobs: dict[str, str]) -> dict[str, str]:
    """Steps defined as `- &name` (shared with `- *name` elsewhere), keyed by anchor."""
    found = {}
    for job in workflow_jobs.values():
        for _, body in steps(job):
            match = STEP_ANCHOR.match(body.splitlines()[0])
            if match:
                found[match.group(1)] = body
    return found


def expand_step_aliases(job_steps: list[tuple[str, str]], anchors: dict[str, str]) -> list[tuple[str, str]]:
    """Replace each `- *name` step with the anchored step it runs (#30471 turned steps into aliases)."""
    expanded = []
    for step_name, body in job_steps:
        match = STEP_ALIAS.match(body.splitlines()[0]) if not step_name else None
        if match and match.group(1) in anchors:
            body = anchors[match.group(1)]
            name = re.search(r"^      [- ] name:\s*(.+)$", body, re.M)
            step_name = name.group(1).strip() if name else ""
        expanded.append((step_name, body))
    return expanded


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
    workflow_jobs = jobs(text)
    # A hyphenated job id such as swift-canary-fleet (in `needs.` or a message) names a job, not the toolchain.
    # A path such as scripts/build-x.sh keeps its name even when a job shares it.
    job_ids = [job_id for job_id in workflow_jobs if "-" in job_id]
    job_id_token = re.compile(r"(?<![\w/-])(" + "|".join(map(re.escape, job_ids)) + r")(?![\w-])") if job_ids else None
    # A job whose steps are a YAML alias (`steps: *name`, a same-run twin) runs the anchored job's steps.
    anchored = {m.group(1): job for job in workflow_jobs.values()
                for m in [re.search(r"^    steps:\s+&([\w-]+)\s*$", job, re.M)] if m}
    anchored_steps = step_anchors(workflow_jobs)
    for job_id, job in workflow_jobs.items():
        alias = re.search(r"^    steps:\s+\*([\w-]+)\s*$", job, re.M)
        if alias and alias.group(1) in anchored:
            body = anchored[alias.group(1)]
            after = body.index("\n", re.search(r"^    steps:", body, re.M).start()) + 1
            job = job[:alias.start()] + "    steps:\n" + body[after:]
        key = (name, job_id)
        if not is_macos(job) or key in EXEMPT:
            continue
        where = f"{name} job {job_id}"
        if LITERAL_XCODE_PIN.search(job):
            errors.append(f"{where} pins a literal Xcode path; name the pool's Xcode in scripts/ci/xcode-pins.txt")
        job_steps = expand_step_aliases(steps(job), anchored_steps)
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
            scanned = re.sub(r".*select-ci-xcode\.sh.*", "", body)
            uses_toolchain = TOOLCHAIN.search(job_id_token.sub("", scanned) if job_id_token else scanned)
            if uses_toolchain and first_select is not None and index < first_select:
                errors.append(f"{label} uses the toolchain ({uses_toolchain.group(0)}) before {SELECTOR} runs")
    return errors


def pin_below_floor(version: str, floor: str) -> bool:
    """Return whether an Xcode pin is below the repository's minimum major."""
    return floor.isdigit() and int(version.split(".")[0]) < int(floor)


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
        if pin_below_floor(fields[1], floor):
            errors.append(
                f"scripts/ci/xcode-pins.txt pins Xcode {fields[1]} for macOS {fields[0]}, "
                f"below the .xcode-version floor {floor}"
            )
    for pool in ("15", "26", "27"):
        if pool not in pins:
            errors.append(f"scripts/ci/xcode-pins.txt has no pin for the macOS {pool} pool CI runs on")
    if not re.search(rf"^\s*{floor}\)\s+EXPECTED_OBJECT_VERSION=", (ROOT / "scripts/check-pbxproj.sh").read_text(), re.M):
        errors.append(f"scripts/check-pbxproj.sh has no objectVersion case for Xcode {floor}")
    return errors


def check_detects_regressions() -> list[str]:
    """The checker must flag each way a job can slip off the selector."""
    floor = (ROOT / ".xcode-version").read_text().strip().split(".")[0]
    if pin_below_floor("27.0", floor):
        return ["self-test newer-major Xcode pin was rejected"]

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
        "job id is not the toolchain": (
            base.replace(
                "      - name: Select Xcode\n",
                "      - name: Report\n        if: ${{ needs.swift-check.outputs.ok == 'true' }}\n"
                "        run: echo \"swift-check passed\"\n      - name: Select Xcode\n",
            ) + "  swift-check:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n",
            [],
        ),
        "toolchain beside a job id": (
            base.replace(
                "      - name: Select Xcode\n",
                "      - name: Report\n        run: swift --version  # for swift-check\n      - name: Select Xcode\n",
            ) + "  swift-check:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n",
            ["before scripts/select-ci-xcode.sh runs"],
        ),
        "selector through a step alias": (
            base.replace("      - name: Select Xcode\n", "      - &select-xcode\n        name: Select Xcode\n")
            + "  twin:\n    runs-on: ${{ vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}\n    steps:\n"
            "      - *select-xcode\n      - run: swift test\n",
            [],
        ),
        "alias to another step is not the selector": (
            base.replace("      - name: Test\n", "      - &test-step\n        name: Test\n")
            + "  twin:\n    runs-on: ${{ vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}\n    steps:\n"
            "      - *test-step\n",
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
