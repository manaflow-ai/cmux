#!/usr/bin/env python3
"""cmux-tui release builds use fat LTO and one codegen unit.

Every cmux-tui tree build compiles this profile, and NEXT nightly waits on the
tree. Thin LTO with 16 codegen units for cmux-tui, cmux-tui-core and acpmux
made the stripped cmux-tui binary 24% larger (105.9 -> 131.7 MB) in #27830.
Fat LTO is the size baseline; its release-link cost is checked by the Linux
build and startup measurements for the change that enables it.

One exception, and only one: the Cloud machine channel's own copy of the Linux
binaries (cmux-tui-artifacts.yml build-linux) builds with thin LTO
(cmux-tui-build-package.yml `lto: thin`), named machine-channel-* and uploaded
only to cmux-tui/<sha>/machine/. Every other caller of the build workflow, and
so every shipped app, npm, PyPI, release, R2 and tree artifact, keeps the fat
profile. ChannelOnlyThinTest checks that.

cmux-tui-artifacts.yml's build calls take what they build (lto, target_set,
artifact_prefix, include_windows, windows_acpmux) from
scripts/cmux-next/cmux-tui-build-profiles.json, a tree-key input, never from a
literal in the workflow, which is not one: a literal there changes what gets
built and keeps the tree key (cmux#42622; handbook
reuse-key-leaves-out-an-input). BuildProfileSourceTest checks that.
"""

from __future__ import annotations

import json
import re
import tomllib
import unittest

import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEAVY_CRATES = ("cmux-tui", "cmux-tui-core", "acpmux")


class CmuxTuiReleaseProfileTest(unittest.TestCase):
    def setUp(self):
        manifest = tomllib.loads((ROOT / "cmux-tui/Cargo.toml").read_text(encoding="utf-8"))
        self.release = manifest["profile"]["release"]

    def test_release_profile_uses_fat_lto(self):
        self.assertEqual(self.release.get("lto"), "fat")
        self.assertEqual(self.release.get("codegen-units"), 1)

    def test_heavy_crates_get_one_codegen_unit(self):
        packages = self.release.get("package", {})
        for crate in HEAVY_CRATES:
            with self.subTest(crate=crate):
                self.assertEqual(packages.get(crate, {}).get("codegen-units"), 1)

    def test_heavy_crates_are_workspace_packages(self):
        # A renamed crate would leave its override silently matching nothing.
        for crate in HEAVY_CRATES:
            with self.subTest(crate=crate):
                manifest = ROOT / "cmux-tui/crates" / crate / "Cargo.toml"
                package = tomllib.loads(manifest.read_text(encoding="utf-8"))["package"]
                self.assertEqual(package["name"], crate)


BUILD_PACKAGE = "./.github/workflows/cmux-tui-build-package.yml"
MACHINE_PREFIX = "machine-channel-"
PROFILES_PATH = ROOT / "scripts/cmux-next/cmux-tui-build-profiles.json"
PROFILE_REF = re.compile(r"fromJSON\(needs\.tree-preflight\.outputs\.build_profiles\)\.([a-z_]+)\.([a-z_]+)")
# The build-package inputs that decide what a tree build makes.
BUILD_DEFINING = ("lto", "target_set", "artifact_prefix", "include_windows", "windows_acpmux")


def workflow(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def profiles():
    return json.loads(PROFILES_PATH.read_text(encoding="utf-8"))


def resolve(value):
    """A `${{ fromJSON(...build_profiles).P.K }}` input as the profile value it reads; else unchanged."""
    if isinstance(value, str):
        whole = re.fullmatch(r"\$\{\{\s*" + PROFILE_REF.pattern + r"\s*\}\}", value)
        if whole:
            return profiles()[whole.group(1)][whole.group(2)]
    return value


class ChannelOnlyThinTest(unittest.TestCase):
    """Only the Cloud machine channel's Linux legs build thin; every other build stays fat."""

    def callers(self):
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            for name, job in (workflow(path).get("jobs") or {}).items():
                if isinstance(job, dict) and job.get("uses") == BUILD_PACKAGE:
                    yield path.name, name, {k: resolve(v) for k, v in (job.get("with") or {}).items()}

    def test_only_the_machine_channel_legs_build_thin(self):
        thin = []
        callers = list(self.callers())
        self.assertGreater(len(callers), 5)
        for file, name, inputs in callers:
            lto = inputs.get("lto", "fat")
            with self.subTest(caller=f"{file}:{name}"):
                self.assertIn(lto, ("fat", "thin"))
                if lto == "thin":
                    thin.append((file, name))
                    self.assertEqual(inputs.get("target_set"), "linux")
                    self.assertEqual(inputs.get("artifact_prefix"), MACHINE_PREFIX)
                    self.assertFalse(inputs.get("package_npm", True))
                    self.assertFalse(inputs.get("package_pypi", True))
                else:
                    # A fat build's artifacts keep the names every shipped download reads.
                    self.assertEqual(inputs.get("artifact_prefix", ""), "")
        self.assertEqual(thin, [("cmux-tui-artifacts.yml", "build-linux")])

    def test_the_shipped_linux_binaries_come_from_the_fat_build(self):
        jobs = workflow(ROOT / ".github/workflows/cmux-tui-artifacts.yml")["jobs"]
        # Fat and every shipped Linux target: all on main and rc/**, Linux plus arm64 Mac elsewhere.
        target_set = jobs["build"]["with"]["target_set"]
        refs = PROFILE_REF.findall(target_set)
        self.assertEqual(refs, [("shipped", "target_set_main"), ("shipped", "target_set")])
        self.assertEqual(profiles()["shipped"]["target_set_main"], "all")
        self.assertEqual(profiles()["shipped"]["target_set"], "linux-macos-arm64")
        self.assertEqual(resolve(jobs["build"]["with"]["lto"]), "fat")
        for name in ("publish", "darwin-fallback-plan"):
            with self.subTest(job=name):
                self.assertNotIn("build-linux", jobs[name]["needs"])
                self.assertNotIn("build-linux", str(jobs[name].get("if", "")))

    def test_only_the_early_channel_job_reads_the_thin_artifacts(self):
        readers = []
        for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
            for name, job in (workflow(path).get("jobs") or {}).items():
                for step in (job.get("steps") or []) if isinstance(job, dict) else []:
                    # An artifact download (actions/download-artifact or gh run download) of a
                    # machine-channel-* name or pattern.
                    w = step.get("with") or {}
                    names = [str(w.get(k, "")) for k in ("name", "pattern")] if "download-artifact" in str(step.get("uses", "")) else []
                    names += re.findall(r"(?:--pattern|--name|-n)[ =]+[\"']?([^\s\"']+)", str(step.get("run", "")))
                    if any(n.startswith(MACHINE_PREFIX) for n in names):
                        readers.append((path.name, name))
        self.assertEqual(readers, [("cmux-tui-artifacts.yml", "point-machine-channel-early")])
        early = workflow(ROOT / ".github/workflows/cmux-tui-artifacts.yml")["jobs"]["point-machine-channel-early"]
        run = "\n".join(str(step.get("run", "")) for step in early["steps"])
        # Its payload names cmux-tui/<sha>/machine/, never the shipped names.
        self.assertIn("--machine-path", run)
        self.assertIn("cmux-machine-linux-bytes.sh early", run)

    def test_the_build_workflow_refuses_thin_outside_the_channel_shape(self):
        jobs = workflow(ROOT / ".github/workflows/cmux-tui-build-package.yml")["jobs"]
        plan = next(step["run"] for step in jobs["plan-build"]["steps"] if step.get("id") == "targets")
        self.assertIn('lto=thin needs target_set=linux, no packages and an artifact_prefix', plan)
        inputs = workflow(ROOT / ".github/workflows/cmux-tui-build-package.yml")[True]["workflow_call"]["inputs"]
        self.assertEqual(inputs["lto"]["default"], "fat")
        self.assertEqual(inputs["artifact_prefix"]["default"], "")


class BuildProfileSourceTest(unittest.TestCase):
    """What a tree build makes comes from the keyed profile file, not a workflow literal."""

    def test_artifacts_build_calls_read_the_profile_file(self):
        jobs = workflow(ROOT / ".github/workflows/cmux-tui-artifacts.yml")["jobs"]
        calls = {name: job.get("with") or {} for name, job in jobs.items()
                 if isinstance(job, dict) and job.get("uses") == BUILD_PACKAGE}
        self.assertEqual(sorted(calls), ["build", "build-darwin-fallback", "build-linux", "build-windows"])
        keyed = profiles()
        for name, inputs in calls.items():
            for key in BUILD_DEFINING:
                if key not in inputs:
                    continue
                value = str(inputs[key])
                with self.subTest(job=name, input=key):
                    if name == "build-darwin-fallback" and key == "target_set":
                        # The targets `build` left unbuilt, under the same profile.
                        self.assertEqual(value, "${{ needs.darwin-fallback-plan.outputs.target_set }}")
                        continue
                    if key == "include_windows" and inputs[key] is False:
                        continue  # no Windows leg: those are build-windows' own call
                    refs = PROFILE_REF.findall(value)
                    self.assertTrue(refs, f"{name}.{key} is {value!r}: read it from {PROFILES_PATH.relative_to(ROOT)}")
                    # A condition may compare with literals (the ref picks a profile field);
                    # a literal as the value itself is a build setting the key does not see.
                    stripped = PROFILE_REF.sub("", value)
                    stripped = re.sub(r"(?:==|!=)\s*'[^']*'|startsWith\([^)]*\)", "", stripped)
                    self.assertNotRegex(stripped, r"'[^']*'",
                                        f"{name}.{key} mixes a literal into the profile read: {value!r}")
                    for profile, field in refs:
                        self.assertIn(field, keyed.get(profile, {}), f"{name}.{key} reads {profile}.{field}, which the file lacks")

    def test_the_profile_file_is_a_tree_key_input(self):
        inputs = (ROOT / "scripts/cmux-next/cmux-tui-tree-inputs.txt").read_text(encoding="utf-8").splitlines()
        self.assertIn("blob scripts/cmux-next/cmux-tui-build-profiles.json", inputs)


if __name__ == "__main__":
    unittest.main()
