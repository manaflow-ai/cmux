#!/usr/bin/env python3
"""Every compile, build or test job names the warm state it starts from (.github/warm-sources.json).

Leo, 2026-10-30: "just make these steps more fucking obvious for next fucking time so we're not
always inundated wit fucking bullshit cold compiles where we never use the fucking existing
resources that we fucking have like, all the parts, it's just fucking unacceptable."

The fleet has warm state for most builds: a runner's kept DerivedData, the per-mini SwiftPM
scratch, the fleet compiler-CAS nodes, the DEV CAS seed, actions/cache on Blacksmith, the
controller's warm Linux lanes and green-product reuse for a tree that already compiled. A job
that uses none of it compiles cold every time, and nothing said so. .github/warm-sources.json is
the one declared table: each compile, build or test job (found structurally, below) lists the
sources it starts warm from, or an exemption with its reason. This test fails when

  (a) a compile, build or test job is missing from the table;
  (b) an entry lists no warm source and no exemption, or an exemption with no real reason;
  (c) an entry lists a source its steps do not wire (the source's marker is absent from the
      job's steps and from the repository scripts and composite actions those steps call);
  (d) an entry names a workflow or job that no longer exists.

`python3 tests/test_ci_warm_sources.py --suggest` prints the entry each compile job would get
from its steps (sources found wired, or a stub exemption to fill in), so a new job is one paste.
"""

from __future__ import annotations

import json
import os
import re
import sys
import unittest
from functools import lru_cache
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
TABLE = ROOT / ".github" / "warm-sources.json"
SCHEMA = "warm-sources/v1"

# ---------------------------------------------------------------------------------------------
# The compile detector. A job is a compile, build or test job when one of its steps runs a
# compiler, a build tool or a compiled test runner, runs a repository compile/build script, or
# when the job runs on a Mac (an owned glaeda label or a macOS image): a Mac is the fleet's
# scarce resource, so every Mac job says what warm state it uses or why it needs none.
# Interpreter-only checks (python3 tests/test_*.py, shellcheck, actionlint) are not compiles.
# ---------------------------------------------------------------------------------------------
def _names(*names: str) -> str:
    """Script file names as whole names: owned_spm_scratch.py, never test_ci_owned_spm_scratch.py."""
    return r"(?<![\w-])(?:" + "|".join(re.escape(name) for name in names) + r")(?![\w-])"


COMPILE_COMMANDS: dict[str, re.Pattern] = {
    "xcodebuild": re.compile(r"\bxcodebuild\b"),
    "swift": re.compile(r"\bswift\s+(?:build|test)\b"),
    "cargo": re.compile(r"\bcargo\s+(?:\+\S+\s+)?(?:build|test|clippy|check|nextest|zigbuild|install|run|bench)\b"),
    "zig": re.compile(r"\bzig\s+build\b"),
    "go": re.compile(r"\bgo\s+(?:-C\s+\S+\s+)?(?:build|test|vet|install)\b"),
    "js": re.compile(
        r"\b(?:bun|npm|pnpm|yarn)\s+(?:run\s+)?(?:build|test|typecheck|tsc|check)\b"
        r"|\bbunx?\s+(?:--bun\s+)?(?:tsc|vitest|playwright\s+test)\b|\bnpx\s+(?:tsc|vitest|playwright\s+test)\b"
    ),
    "gradle": re.compile(r"\bgradlew?\s+\S*(?:build|test|assemble)"),
    # A repository shell script whose name says it compiles or builds
    # (compile-dev-release.sh, check-release-compile.sh, build-web-bundles.sh, testflight-build.sh),
    # or reload.sh. Not a script's own test (*.test.sh, test_*.sh), and not a name in a path list
    # (`case` patterns and change filters: "scripts/ci/compile-app-host-test-product.sh|...").
    "script": re.compile(
        r"(?<![\w.-])(?!test_)[\w.-]*(?:compile|build)[\w.-]*(?<!\.test)\.sh\b(?![|\w.-])"
        r"|(?<![\w.-])reload\.sh\b(?![|\w.-])"
    ),
    # Compile drivers whose names do not say so: the Swift package lane, the Linux-to-macOS cross
    # build, the export regenerators (swift build, then swift test) and the nightly web-bundle inputs.
    "driver": re.compile(_names("package-test-lane.sh", "run-swift-testing-suites.sh", "macos-cross.sh",
                                "inputs-web-bundles.sh") + r"|(?<![\w-])regenerate-[\w-]+-exports\.sh\b"),
    # A compile handed to the build fleet's controller (cmux-ci run, build or compile-check).
    "fleet": re.compile(r"(?:\bcmux-ci|\"?\$\{?client\}?\"?)\s+(?:run|build|compile-check)\s"),
}
MAC_RUNS_ON = re.compile(r"macos|glaeda", re.IGNORECASE)
# A job that selects Xcode runs on a Mac whatever label a picker gave it (runs-on: needs.route.outputs.runs_on).
XCODE_STEP = re.compile(r"select-ci-xcode\.sh|\bxcode-select\s+-s\b|\bxcrun\b")


def step_text(step: dict) -> str:
    """What a step runs: its script, the action it uses and the action's inputs."""
    parts = [str(step.get("run") or ""), str(step.get("uses") or "")]
    if isinstance(step.get("with"), dict):
        parts.extend(f"{key}: {value}" for key, value in step["with"].items())
    if isinstance(step.get("env"), dict):
        parts.extend(f"{key}={value}" for key, value in step["env"].items())
    return "\n".join(parts)


def job_steps_text(job: dict) -> str:
    texts = [step_text(step) for step in job.get("steps") or [] if isinstance(step, dict)]
    if isinstance(job.get("env"), dict):
        texts.extend(f"{key}={value}" for key, value in job["env"].items())
    return "\n".join(texts)


def runs_on_text(job: dict) -> str:
    return json.dumps(job.get("runs-on"), sort_keys=True) if "runs-on" in job else ""


def compile_reasons(job: dict) -> list[str]:
    """Why a job counts as a compile, build or test job; empty when it does not."""
    if not isinstance(job, dict) or "uses" in job:  # a reusable-workflow call: its callee's jobs count
        return []
    text = uncommented(job_steps_text(job))  # a comment about xcodebuild is not a compile
    reasons = [name for name, pattern in COMPILE_COMMANDS.items() if pattern.search(text)]
    if MAC_RUNS_ON.search(runs_on_text(job)) or XCODE_STEP.search(text):
        reasons.append("mac-runner")
    return reasons


# ---------------------------------------------------------------------------------------------
# Wiring. A source is wired in a job when its marker appears in the job's steps, or in a
# repository script or composite action they call (followed up to SCRIPT_DEPTH levels). Sources
# with no marker here are declared only; (c) checks the others.
# ---------------------------------------------------------------------------------------------
WIRING: dict[str, re.Pattern] = {
    # Kept DerivedData: the owned Mac's admission state, the nightly seed, the e2e warm copy, the
    # scheme and Release compiles' worker-local tree, or a build handed to the controller's warm slots.
    "deriveddata-reuse": re.compile(
        _names("owned_build_state.py", "seed_derived_data.py", "e2e_warm_derived_data.py", "release-derived-data-path.sh")
        + r"|\bCMUX_COMPILE_ADMISSION_DERIVED_DATA\b|\bcmux_next_cas_fresh_tree\b"
        # A tour or visual-gate build in its claimed warm slot's DerivedData, and the Chief's per-runner target.
        + r"|" + _names("media_tag_lock.py", "prune_media_derived_data.py") + r"|\bCMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR=\"?\$HOME/"
        + r"|\"?\$\{?client\}?\"?\s+(?:run|build)\s"
    ),
    # The per-mini SwiftPM scratch: package .build directories kept outside the cleaned workspace.
    "spm-shared": re.compile(_names("owned_spm_scratch.py") + r"|\bCMUX_OWNED_PACKAGE_STORE\b"),
    # The fleet compiler-CAS node glaeda installs on owned minis.
    "ssd-cas": re.compile(r"\bfleet-cas\b"),
    # The DEV CAS seed store.
    "dev-cas": re.compile(r"\bCMUX_NEXT_DEV_CAS_URL\b|" + _names("dev_cas_seed.py")),
    # actions/cache (Blacksmith serves it on its runners) and the actions built on it.
    "actions-cache": re.compile(
        r"(?m)^\s*(?:-\s+)?(?:uses:\s*)?(?:actions/cache(?:/restore|/save)?@|\./\.github/actions/(?:cache-restore|cache-save|playwright-apt-cache|ghostty-zig-packages)\b"
        r"|Swatinem/rust-cache@|useblacksmith/stickydisk@|useblacksmith/cache@)"
    ),
    # The controller's warm Linux lanes.
    "linux-pool-warm": re.compile(r"\bcompile-check\b[^\n]*--app\b|\bcmux-next-swift-check\b"),
    # A green product or pass for the same tree, reused instead of compiled again.
    "product-reuse": re.compile(
        _names("reuse_app_host_products.py", "nightly_release_product_reuse.py", "dev_release_product_reuse.py",
               "reuse_release_product.py", "job_reuse.py", "media_app_cache.py")
        + r"|\./\.github/actions/download-test-product\b"
    ),
}
SCRIPT_DEPTH = 3
# A path into the repository's scripts or composite actions, or a bare script file name (a script
# that runs "$here/lib/compilation-cache.sh"), resolved through SCRIPT_DIRS when the name is unique.
SCRIPT_REF = re.compile(r"(?<![\w.-])((?:\./)?(?:scripts|\.github/actions|cmux-next-ios/scripts)/[\w./-]+?)(?=[\s\"');|&`]|$)")
SCRIPT_NAME = re.compile(r"(?<![\w-])([\w-][\w.-]*\.(?:sh|py))\b(?![|\w.-])")
SCRIPT_DIRS = ("scripts", ".github/actions", "cmux-next-ios/scripts")


@lru_cache(maxsize=None)
def script_index(root: Path) -> dict[str, str]:
    """Unique script file names under SCRIPT_DIRS, to their repository paths."""
    seen: dict[str, list[str]] = {}
    for directory in SCRIPT_DIRS:
        base = root / directory
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix in (".sh", ".py") and path.is_file():
                seen.setdefault(path.name, []).append(path.relative_to(root).as_posix())
    return {name: paths[0] for name, paths in seen.items() if len(paths) == 1}


@lru_cache(maxsize=None)
def file_text(root: Path, rel: str) -> str:
    path = (root / rel.removeprefix("./")).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return ""
    if path.is_dir():
        for name in ("action.yml", "action.yaml"):
            if (path / name).is_file():
                return (path / name).read_text(encoding="utf-8", errors="replace")
        return ""
    if path.is_file():
        return path.read_text(encoding="utf-8", errors="replace")
    return ""


def script_refs(root: Path, text: str) -> list[str]:
    """The shell scripts and composite actions a text runs. A Python script is matched by its own
    name (the markers name them) and never opened: its docstrings name every script it knows of."""
    refs = [ref.removeprefix("./").rstrip(".") for ref in SCRIPT_REF.findall(text)]
    index = script_index(root)
    refs.extend(index[name] for name in SCRIPT_NAME.findall(text) if name in index)
    return [ref for ref in refs
            if (ref.endswith(".sh") or ref.startswith(".github/actions/")) and not ref.endswith(".test.sh") and "/tests/" not in ref]


def uncommented(text: str) -> str:
    """Text without its comment lines, so a script's notes about another source never wire it."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


@lru_cache(maxsize=None)
def expanded_text(root: Path, text: str, depth: int = SCRIPT_DEPTH) -> str:
    """A job's text plus the repository scripts and composite actions it calls, depth levels down."""
    seen: set[str] = set()
    out = [text]
    frontier = [text]
    for _ in range(depth):
        nxt = []
        for chunk in frontier:
            for ref in script_refs(root, chunk):
                if ref in seen:
                    continue
                seen.add(ref)
                body = uncommented(file_text(root, ref))
                if body:
                    out.append(body)
                    nxt.append(body)
        frontier = nxt
    return "\n".join(out)


# actions/setup-go caches the module and build caches unless told not to; setup-node, setup-python
# and setup-java cache only when given a `cache` input.
SETUP_CACHE = re.compile(r"^actions/setup-(go|node|python|java)@")


def setup_action_cache(job: dict) -> bool:
    for step in job.get("steps") or []:
        if not isinstance(step, dict):
            continue
        match = SETUP_CACHE.match(str(step.get("uses") or ""))
        if not match:
            continue
        cache = str((step.get("with") or {}).get("cache", "") if isinstance(step.get("with"), dict) else "").strip().lower()
        if (match.group(1) == "go" and cache != "false") or (match.group(1) != "go" and cache not in ("", "false")):
            return True
    return False


def wired_sources(root: Path, job: dict) -> list[str]:
    text = expanded_text(root, uncommented(job_steps_text(job)))
    wired = [source for source, pattern in WIRING.items() if pattern.search(text)]
    if "actions-cache" not in wired and setup_action_cache(job):
        wired.append("actions-cache")
    return wired


# ---------------------------------------------------------------------------------------------
# The table.
# ---------------------------------------------------------------------------------------------
# An exemption names why the job has nothing to warm. These say only that it is missing.
# An exemption that starts "cold:" is a known gap: the job compiles but no warm source is wired
# yet. The test lists them (a warning in CI) and fails once the job wires a source, so the entry
# moves to "warm" the day its cache lands.
COLD = "cold:"
EMPTY_REASON = re.compile(r"^\s*(?:|n/?a|none|todo|tbd|exempt|-|\?|cold|no reason)\s*\.?\s*$", re.IGNORECASE)
MIN_REASON = 12


@lru_cache(maxsize=None)
def workflow_jobs(root: Path) -> dict[str, dict]:
    jobs: dict[str, dict] = {}
    for path in sorted([*(root / ".github" / "workflows").glob("*.yml"), *(root / ".github" / "workflows").glob("*.yaml")]):
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
        for job_id, job in (data.get("jobs") or {}).items():
            if isinstance(job, dict):
                jobs[f"{path.name}:{job_id}"] = job
    return jobs


def compile_jobs(root: Path) -> dict[str, list[str]]:
    return {key: reasons for key, job in workflow_jobs(root).items() if (reasons := compile_reasons(job))}


def load_table(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def problems(root: Path, table: dict) -> list[str]:
    errors: list[str] = []
    if table.get("schema") != SCHEMA:
        errors.append(f"schema is {table.get('schema')!r}, expected {SCHEMA!r}")
    sources = table.get("sources") or {}
    for source_id, source in sources.items():
        if not isinstance(source, dict) or not str(source.get("what") or "").strip() or not str(source.get("runbook") or "").strip():
            errors.append(f"source {source_id}: needs a 'what' and a 'runbook'")
    entries = table.get("jobs") or {}
    jobs = workflow_jobs(root)
    detected = {key: reasons for key, job in jobs.items() if (reasons := compile_reasons(job))}
    for key in sorted(set(detected) - set(entries)):
        errors.append(f"(a) {key} compiles, builds or tests ({', '.join(detected[key])}) but is not in .github/warm-sources.json;"
                      f" add {json.dumps({key: suggestion(root, jobs[key])})}")
    for key, entry in sorted(entries.items()):
        if key not in jobs:
            errors.append(f"(d) {key} is in .github/warm-sources.json but no workflow has that job")
            continue
        if not isinstance(entry, dict) or not str(entry.get("class") or "").strip():
            errors.append(f"{key}: entry needs a 'class'")
            continue
        warm = entry.get("warm")
        if not isinstance(warm, list):
            errors.append(f"{key}: 'warm' must be a list of source ids")
            continue
        exempt = entry.get("exempt")
        if not warm:
            if exempt is None or EMPTY_REASON.match(str(exempt)) or len(str(exempt).strip()) < MIN_REASON:
                errors.append(f"(b) {key} lists no warm source and no exemption with a reason")
        elif exempt is not None:
            errors.append(f"{key}: an exemption is only for a job with no warm source; drop 'exempt' or 'warm'")
        wired = wired_sources(root, jobs[key])
        if not warm and wired:
            errors.append(f"(b) {key} is exempt but its steps wire {wired}; list them under 'warm' instead")
        unknown = [source for source in warm if source not in sources]
        if unknown:
            errors.append(f"{key}: unknown source ids {unknown}; declare them under 'sources'")
        for source in warm:
            if source in WIRING and source not in wired:
                errors.append(f"(c) {key} lists {source} but its steps never wire it (no match for {WIRING[source].pattern[:60]}...)")
    return errors


def cold_jobs(table: dict) -> list[str]:
    return sorted(key for key, entry in (table.get("jobs") or {}).items()
                  if isinstance(entry, dict) and str(entry.get("exempt") or "").startswith(COLD))


def suggestion(root: Path, job: dict) -> dict:
    wired = wired_sources(root, job)
    if wired:
        return {"class": "?", "warm": wired}
    return {"class": "?", "warm": [], "exempt": "<why it needs no warm state, or cold: <what compiles cold>>"}


# ---------------------------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------------------------
def job(*runs: str, runs_on: object = "blacksmith-4vcpu-ubuntu-2404", uses: list[str] | None = None) -> dict:
    steps: list[dict] = [{"uses": action} for action in uses or []]
    steps.extend({"run": run} for run in runs)
    return {"runs-on": runs_on, "steps": steps}


class Detector(unittest.TestCase):
    def test_compilers_and_build_tools_count(self) -> None:
        for command, reason in (
            ("xcodebuild -scheme cmux build", "xcodebuild"),
            ("swift test --package-path Packages/x", "swift"),
            ("swift build -c release", "swift"),
            ("cargo test --locked", "cargo"),
            ("cargo +nightly clippy -- -D warnings", "cargo"),
            ("cargo nextest run", "cargo"),
            ("zig build -Doptimize=ReleaseFast", "zig"),
            ("go test ./...", "go"),
            ("go -C daemon/remote test -race ./...", "go"),
            ("bun run build", "js"),
            ("bun test", "js"),
            ("bunx tsc --noEmit", "js"),
            ("npx playwright test", "js"),
            ("./scripts/cmux-next/compile-dev-release.sh", "script"),
            ("bash scripts/build-web-bundles.sh", "script"),
            ("scripts/cmux-next/check-release-compile.sh \"$dd\"", "script"),
            ("./scripts/reload.sh --tag x", "script"),
            ("bash scripts/ci/package-test-lane.sh suite Packages/x all", "driver"),
            ("bash scripts/cmux-next/regenerate-swift-exports.sh", "driver"),
            ('"$client" run --class light --script scripts/ci/package-test-lane.sh', "fleet"),
            ("cmux-ci build cmux --ref $SHA", "fleet"),
        ):
            with self.subTest(command=command):
                self.assertIn(reason, compile_reasons(job(command)))

    def test_a_mac_runner_counts_whatever_it_runs(self) -> None:
        self.assertEqual(compile_reasons(job("echo sign", runs_on="glaeda-mini-xcode-26.3")), ["mac-runner"])
        self.assertEqual(compile_reasons(job("echo", runs_on="${{ needs.pick.outputs.runner || 'blacksmith-6vcpu-macos-26' }}")), ["mac-runner"])
        self.assertEqual(compile_reasons(job("echo", runs_on=["self-hosted", "macOS"])), ["mac-runner"])
        self.assertEqual(compile_reasons(job("./scripts/select-ci-xcode.sh", runs_on="${{ needs.route.outputs.runs_on }}")), ["mac-runner"])

    def test_interpreter_only_checks_do_not_count(self) -> None:
        for command in ("python3 tests/test_ci_runs_on_fallback.py", "shellcheck scripts/*.sh", "actionlint",
                        "swift --version", "cargo --version", "go version", "bun install --frozen-lockfile",
                        "echo build-something", "gh run list", "bash tests/test_build_names.sh",
                        "bash scripts/cmux-next/tests/release-compile-derived-data.test.sh",
                        "case $f in scripts/ci/compile-app-host-test-product.sh|scripts/x.sh) ;; esac",
                        "python3 scripts/ci/build_input_fingerprint.py",
                        "  # One xcodebuild invocation runs one scheme.\npython3 plan.py"):
            with self.subTest(command=command):
                self.assertEqual(compile_reasons(job(command)), [])

    def test_a_reusable_workflow_call_is_its_callees(self) -> None:
        self.assertEqual(compile_reasons({"uses": "./.github/workflows/ci-macos.yml", "runs-on": "macos-26"}), [])


class Wiring(unittest.TestCase):
    def test_markers_in_steps(self) -> None:
        self.assertEqual(wired_sources(ROOT, job("true", uses=["actions/cache@v5"])), ["actions-cache"])
        self.assertEqual(wired_sources(ROOT, job("true", uses=["Swatinem/rust-cache@v2"])), ["actions-cache"])
        self.assertEqual(wired_sources(ROOT, job('python3 scripts/cmux-next/dev_cas_seed.py fetch')), ["dev-cas"])
        self.assertEqual(wired_sources(ROOT, job("python3 scripts/ci/reuse_app_host_products.py lookup")), ["product-reuse"])
        self.assertEqual(wired_sources(ROOT, job('"$client" compile-check --ref "$SHA" --app')), ["linux-pool-warm"])
        self.assertEqual(wired_sources(ROOT, job("cargo build")), [])
        self.assertEqual(wired_sources(ROOT, job("python3 scripts/ci/owned_spm_scratch.py link .")), ["spm-shared"])
        # A test of a source's script is not the source.
        self.assertEqual(wired_sources(ROOT, job("python3 tests/test_ci_owned_spm_scratch.py")), [])
        # A tour claims a kept DerivedData slot; the Chief's cargo target counts only when set to a kept path.
        self.assertEqual(wired_sources(ROOT, job("python3 scripts/ci/media_tag_lock.py claim")), ["deriveddata-reuse"])
        kept = 'export CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$HOME/Library/Caches/x"'
        self.assertEqual(wired_sources(ROOT, job(kept)), ["deriveddata-reuse"])
        self.assertEqual(wired_sources(ROOT, job('echo "${CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR:-target}"')), [])
        # A comment naming a source does not wire it.
        self.assertEqual(wired_sources(ROOT, job("# restore with actions/cache@v5 later\ncargo build")), [])

    def test_setup_actions_cache_by_their_own_rules(self) -> None:
        self.assertEqual(wired_sources(ROOT, {"steps": [{"uses": "actions/setup-go@v5"}]}), ["actions-cache"])
        self.assertEqual(wired_sources(ROOT, {"steps": [{"uses": "actions/setup-go@v5", "with": {"cache": "false"}}]}), [])
        self.assertEqual(wired_sources(ROOT, {"steps": [{"uses": "actions/setup-node@v4"}]}), [])
        self.assertEqual(wired_sources(ROOT, {"steps": [{"uses": "actions/setup-node@v4", "with": {"cache": "npm"}}]}), ["actions-cache"])

    def test_markers_in_called_scripts(self) -> None:
        # compile-app-host-test-product.sh takes the fleet-cas node itself; a job that calls it is wired.
        wired = wired_sources(ROOT, job("./scripts/ci/compile-app-host-test-product.sh"))
        self.assertIn("ssd-cas", wired)

    def test_expansion_stays_in_the_repository(self) -> None:
        self.assertEqual(file_text(ROOT, "scripts/../../../../etc/passwd"), "")


class Table(unittest.TestCase):
    def fake_root(self, workflows: dict[str, dict]) -> Path:
        import tempfile
        tmp = Path(tempfile.mkdtemp(prefix="warm-sources-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        (tmp / ".github" / "workflows").mkdir(parents=True)
        for name, jobs in workflows.items():
            (tmp / ".github" / "workflows" / name).write_text(yaml.safe_dump({"on": "push", "jobs": jobs}), encoding="utf-8")
        return tmp

    def table(self, jobs: dict) -> dict:
        return {"schema": SCHEMA, "sources": load_table(TABLE)["sources"], "jobs": jobs}

    def test_each_rule_fires(self) -> None:
        root = self.fake_root({"w.yml": {
            "cold": job("cargo build"),
            "cached": job("cargo build", uses=["Swatinem/rust-cache@v2"]),
            "lint": job("python3 tests/test_x.py"),
        }})
        errors = problems(root, self.table({}))
        self.assertTrue(any(e.startswith("(a) w.yml:cold") for e in errors), errors)
        self.assertTrue(any(e.startswith("(a) w.yml:cached") for e in errors), errors)
        self.assertFalse(any("w.yml:lint" in e for e in errors), errors)

        errors = problems(root, self.table({"w.yml:cold": {"class": "linux", "warm": []},
                                            "w.yml:cached": {"class": "linux", "warm": ["actions-cache"]}}))
        self.assertEqual([e[:16] for e in errors], ["(b) w.yml:cold l"])

        errors = problems(root, self.table({"w.yml:cold": {"class": "linux", "warm": [], "exempt": "TODO"},
                                            "w.yml:cached": {"class": "linux", "warm": ["actions-cache"]}}))
        self.assertTrue(any(e.startswith("(b) w.yml:cold") for e in errors), errors)

        errors = problems(root, self.table({"w.yml:cold": {"class": "linux", "warm": ["actions-cache"]},
                                            "w.yml:cached": {"class": "linux", "warm": ["actions-cache"]}}))
        self.assertTrue(any(e.startswith("(c) w.yml:cold lists actions-cache") for e in errors), errors)

        errors = problems(root, self.table({"w.yml:cold": {"class": "linux", "warm": [], "exempt": "one-off bootstrap, no compile output kept"},
                                            "w.yml:cached": {"class": "linux", "warm": ["actions-cache"]},
                                            "w.yml:gone": {"class": "linux", "warm": [], "exempt": "lint only, no compile"}}))
        self.assertEqual(errors, ["(d) w.yml:gone is in .github/warm-sources.json but no workflow has that job"])

        # A cold exemption fails once the job wires a source.
        errors = problems(root, self.table({"w.yml:cold": {"class": "linux", "warm": [], "exempt": "cold: cargo from an empty target"},
                                            "w.yml:cached": {"class": "linux", "warm": [], "exempt": "cold: cargo from an empty target"}}))
        self.assertEqual(errors, ["(b) w.yml:cached is exempt but its steps wire ['actions-cache']; list them under 'warm' instead"])

    def test_without_the_table_this_tree_fails(self) -> None:
        errors = problems(ROOT, {"schema": SCHEMA, "sources": {}, "jobs": {}})
        self.assertTrue(any(e.startswith("(a) ") for e in errors))


class ThisTree(unittest.TestCase):
    def test_every_compile_job_names_its_warm_sources(self) -> None:
        table = load_table(TABLE)
        errors = problems(ROOT, table)
        self.assertEqual(errors, [], "\n" + "\n".join(errors))
        cold = cold_jobs(table)
        if cold:
            note = f"{len(cold)} compile jobs still start cold (.github/warm-sources.json 'cold:' entries): {', '.join(cold)}"
            print(f"::warning title=Cold compile jobs::{note}" if os.environ.get("GITHUB_ACTIONS") else note, file=sys.stderr)

    def test_sources_are_the_shared_set(self) -> None:
        self.assertEqual(set(load_table(TABLE)["sources"]), {
            "deriveddata-reuse", "spm-shared", "ssd-cas", "dev-cas", "actions-cache", "linux-pool-warm", "product-reuse"})


def main() -> None:
    if "--suggest" in sys.argv:
        jobs = workflow_jobs(ROOT)
        table = load_table(TABLE) if TABLE.exists() else {"jobs": {}}
        out = {key: suggestion(ROOT, jobs[key]) for key in sorted(compile_jobs(ROOT)) if key not in table["jobs"]}
        print(json.dumps(out, indent=2))
        return
    unittest.main()


if __name__ == "__main__":
    main()
