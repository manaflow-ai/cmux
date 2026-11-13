#!/usr/bin/env python3
"""The nightly builds only from Swift package artifacts its own SourcePackages holds.

Run 43304572615 (runner cmux7s-mac-mini-glaeda-nightly-only-5) failed with "There is no XCFramework found at
.../cmux-nightly-next/cmux7s-mac-mini-glaeda-nightly-only-2/.../SourcePackages/artifacts/iroh-ffi/Iroh/
Iroh.xcframework": the Mac's host build root had seeded its SourcePackages from slot -2's tree, workspace-state.json
and all, so every slot read slot -2's artifacts, and those were gone. This pins both halves of the fix:
- a seeded host tree keeps no other tree's workspace-state.json (nightly_build_state.seed_packages);
- before xcodebuild, spm_artifact_preflight.py finds an artifact that is missing or recorded outside the tree,
  drops the artifact state and resolves again with the build's own -clonedSourcePackagesDirPath.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import nightly_build_state as state  # noqa: E402
import spm_artifact_preflight as preflight  # noqa: E402

PREFLIGHT = ROOT / 'scripts/ci/spm_artifact_preflight.py'
BUILD_STEP = ROOT / 'scripts/ci/nightly-steps/app-build-release.sh'
IROH_PACKAGE = 'let package = Package(targets: [\n  .binaryTarget(\n    name: "Iroh",\n    url: "https://x/Iroh.zip", checksum: "0")\n])\n'


def write_state(source_packages: Path, artifact_path: Path) -> None:
    source_packages.mkdir(parents=True, exist_ok=True)
    (source_packages / 'workspace-state.json').write_text(json.dumps({'version': 6, 'object': {
        'artifacts': [{'packageRef': {'identity': 'iroh-ffi', 'kind': 'remoteSourceControl'},
                       'targetName': 'Iroh', 'path': str(artifact_path)}],
        'dependencies': [{'packageRef': {'identity': 'iroh-ffi', 'kind': 'remoteSourceControl',
                                         'location': 'https://github.com/manaflow-ai/iroh-ffi.git'},
                          'subpath': 'iroh-ffi', 'state': {'name': 'sourceControlCheckout'}}]}}))
    checkout = source_packages / 'checkouts/iroh-ffi'
    checkout.mkdir(parents=True, exist_ok=True)
    (checkout / 'Package.swift').write_text(IROH_PACKAGE)


class SpmArtifactPreflight(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.packages = self.root / 'host/SourcePackages'
        self.own = self.packages / 'artifacts/iroh-ffi/Iroh/Iroh.xcframework'

    def run_preflight(self, *resolve):
        args = [sys.executable, '-I', str(PREFLIGHT), str(self.packages)]
        if resolve:
            args += ['--', *resolve]
        return subprocess.run(args, capture_output=True, text=True)

    def resolver(self):
        """A stand-in for xcodebuild -resolvePackageDependencies: writes the artifact and a state naming it."""
        script = self.root / 'resolve.py'
        script.write_text(
            'import json, pathlib, sys\n'
            'sp = pathlib.Path(sys.argv[1])\n'
            "art = sp / 'artifacts/iroh-ffi/Iroh/Iroh.xcframework'\n"
            'art.mkdir(parents=True, exist_ok=True)\n'
            "(sp / 'workspace-state.json').write_text(json.dumps({'object': {'artifacts': [{'path': str(art)}]}}))\n")
        return [sys.executable, '-I', str(script), str(self.packages)]

    def test_another_trees_artifact_path_resolves_again(self):
        # The host tree, seeded from slot -2, still names slot -2's artifacts, which are gone.
        other = self.root / 'Caches/cmux-nightly-next/runner-2/id/SourcePackages/artifacts/iroh-ffi/Iroh/Iroh.xcframework'
        write_state(self.packages, other)
        self.own.mkdir(parents=True)
        found = preflight.problems(self.packages, [])
        self.assertTrue(any('outside' in problem for problem in found), found)
        result = self.run_preflight(*self.resolver())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('resolving again', result.stdout)
        recorded = json.loads((self.packages / 'workspace-state.json').read_text())['object']['artifacts'][0]['path']
        self.assertEqual(Path(recorded), self.own)
        self.assertEqual(preflight.problems(self.packages, []), [])

    def test_a_declared_binary_target_without_its_xcframework_resolves_again(self):
        write_state(self.packages, self.own)  # recorded in place, but the directory is gone
        found = preflight.problems(self.packages, [])
        self.assertTrue(any('Iroh.xcframework is missing' in problem for problem in found), found)
        result = self.run_preflight(*self.resolver())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.own.is_dir())

    def test_a_pin_in_package_resolved_needs_its_binary_target(self):
        # No workspace-state.json: the pins in Package.resolved still name the checkout's binary targets.
        checkout = self.packages / 'checkouts/iroh-ffi'
        checkout.mkdir(parents=True)
        (checkout / 'Package.swift').write_text(IROH_PACKAGE)
        resolved = self.root / 'Package.resolved'
        resolved.write_text(json.dumps({'pins': [{'identity': 'iroh-ffi',
                                                  'location': 'https://github.com/manaflow-ai/iroh-ffi.git'}]}))
        self.assertTrue(preflight.problems(self.packages, [resolved]))
        self.own.mkdir(parents=True)
        self.assertEqual(preflight.problems(self.packages, [resolved]), [])

    def test_a_complete_tree_does_not_resolve(self):
        write_state(self.packages, self.own)
        self.own.mkdir(parents=True)
        result = self.run_preflight('false')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('resolving again', result.stdout)
        self.assertTrue((self.packages / 'workspace-state.json').is_file())

    def test_a_resolve_that_leaves_it_missing_fails(self):
        write_state(self.packages, self.own)
        result = self.run_preflight('true')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('still missing', result.stdout)
        # The checkouts stay; only the artifact state went.
        self.assertTrue((self.packages / 'checkouts/iroh-ffi/Package.swift').is_file())

    def test_seeded_host_tree_keeps_no_other_trees_workspace_state(self):
        slot = self.root / 'Caches/cmux-nightly-next/runner-2/id/SourcePackages'
        write_state(slot, slot / 'artifacts/iroh-ffi/Iroh/Iroh.xcframework')
        workspace = self.root / 'workspace'
        workspace.mkdir()
        (workspace / '.spm-cache').symlink_to(slot, target_is_directory=True)
        state.seed_packages(self.packages, workspace)
        self.assertTrue((self.packages / 'checkouts/iroh-ffi/Package.swift').is_file())
        self.assertFalse((self.packages / 'workspace-state.json').exists())

    def test_release_build_runs_the_preflight_with_its_own_package_dir(self):
        text = BUILD_STEP.read_text()
        call = text.find('scripts/ci/spm_artifact_preflight.py .spm-cache')
        self.assertGreater(call, text.find('source scripts/ci/nightly-steps/app-host-build-root.sh'))
        self.assertLess(call, text.find('run_release_build 0'))
        resolve = text[call:text.find('\n)', call)]
        self.assertIn('xcodebuild -resolvePackageDependencies', resolve)
        self.assertIn('-clonedSourcePackagesDirPath .spm-cache', resolve)
        self.assertIn('-packageCachePath "$PWD/.spm-cache/.package-cache"', resolve)
        self.assertIn('cd "$build_root"', text[text.rfind('(', 0, call):call])


if __name__ == '__main__':
    unittest.main()
