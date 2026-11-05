#!/usr/bin/env python3
"""A trusted NEXT worker keeps its package checkouts and compilation cache, never its build state.

An incremental Xcode build can keep stale autolink and force-load data in
objects it did not recompile after the module graph changed, so a shipped build
starts from an empty DerivedData even on a worker that kept one before. The one
exception is the dedicated nightly-next builder, which builds each tip on its kept
DerivedData and starts clean on the rules nightly_build_state.py lists.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import nightly_build_state as state


class NightlyBuildState(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'src'
        self.workspace.mkdir()
        self.home = self.root / 'home'

    def prepare(self, runner='cmux15-glaeda', toolchain='Xcode 26.6'):
        return state.prepare(self.workspace, self.home, runner, 'nightly-next', toolchain)

    def retained(self, runner='cmux15-glaeda'):
        return self.home / 'Library/Caches/cmux-nightly-next' / runner

    def test_kept_build_state_is_deleted_and_package_checkouts_stay(self):
        # State that an earlier revision of this script retained, for this
        # toolchain and for an older one, and linked into the workspace.
        for identity in ('current', 'older-xcode'):
            for path in ('DerivedData/Build/Intermediates.noindex/build.db',
                         'DerivedData/Build/Products/Release/cmux.app/binary',
                         'DerivedData/cmux-nightly-inputs.json'):
                target = self.retained() / identity / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('stale')
        (self.workspace / 'build-universal').symlink_to(self.retained() / 'current/DerivedData')

        self.assertTrue(self.prepare())
        checkout = self.workspace / '.spm-cache/checkouts/pkg/source.swift'
        checkout.parent.mkdir(parents=True)
        checkout.write_text('kept')
        derived = self.workspace / 'build-universal'
        (derived / 'Build').mkdir()
        (derived / 'Build/object.o').write_text('built by this job')
        cas = derived / 'CompilationCache.noindex/v1.1/data'
        cas.parent.mkdir(parents=True)
        cas.write_text('content-keyed')

        # Checkout's clean drops the workspace links; the next job prepares again.
        (self.workspace / '.spm-cache').unlink()
        self.assertTrue(self.prepare())

        self.assertFalse(derived.is_symlink())
        self.assertEqual([path.name for path in derived.iterdir()], ['CompilationCache.noindex'])
        self.assertTrue((derived / 'CompilationCache.noindex').is_symlink())
        self.assertEqual(cas.read_text(), 'content-keyed')
        self.assertEqual(sorted(self.retained().glob('*/DerivedData')), [])
        self.assertEqual(checkout.read_text(), 'kept')

    def test_hosted_and_classic_do_not_acquire_next_state(self):
        self.assertFalse(self.prepare(runner='blacksmith-12vcpu-macos-26-1'))
        self.assertFalse(state.prepare(self.workspace, self.home, 'cmux15-glaeda', 'nightly', 'Xcode 26.6'))
        self.assertFalse((self.workspace / 'build-universal').exists())
        self.assertFalse((self.workspace / '.spm-cache').exists())



class DedicatedBuilder(unittest.TestCase):
    RUNNER = 'cmux7s-mac-mini-glaeda-nightly-next'
    WORKFLOW = ('jobs:\n  build-nightly-app:\n    steps:\n      - name: Start\n        run: echo\n'
                '      - name: Build nightly app (Release)\n        run: xcodebuild OTHER_SWIFT_FLAGS={flags}\n'
                '      - name: Bundle\n        run: echo {{other}}\n')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'src'
        self.home = self.root / 'home'
        self.workspace.mkdir()
        self.git('init', '-q')
        self.commit({'Sources/a.swift': 'let a = 1\n', 'Package.resolved': '{}\n',
                     state.BUILD_WORKFLOW: self.WORKFLOW.format(flags='-DCMUX_A')})
        saved = {name: os.environ.pop(name) for name in state.BUILD_SETTINGS if name in os.environ}
        self.addCleanup(os.environ.update, saved)
        self.outputs = self.root / 'out'
        os.environ['GITHUB_OUTPUT'] = str(self.outputs)
        self.addCleanup(os.environ.pop, 'GITHUB_OUTPUT', None)

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.workspace), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                              check=True, capture_output=True, text=True).stdout

    def commit(self, files):
        for name, text in files.items():
            path = self.workspace / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git('add', '-A')
        self.git('commit', '-qm', 'x')

    def build(self, toolchain='Xcode 26.6', finish=True):
        self.outputs.write_text('')
        self.assertTrue(state.prepare(self.workspace, self.home, self.RUNNER, 'nightly-next', toolchain))
        derived = self.workspace / 'build-universal'
        self.assertTrue(derived.is_symlink())
        app = derived / 'Build/Products/Release/cmux.app/Contents'
        object_file = derived / 'Build/Intermediates.noindex/a.o'
        mode = self.outputs.read_text().strip()
        kept_object = object_file.exists()
        kept_app = app.exists()
        object_file.parent.mkdir(parents=True, exist_ok=True)
        object_file.write_text('compiled')
        app.mkdir(parents=True, exist_ok=True)
        (app / 'added-after-build').write_text('a later step put this here')
        if finish:
            self.assertTrue(state.mark_built(self.workspace, self.home, self.RUNNER))
        # The warm checkout's git clean drops the workspace links between jobs.
        derived.unlink()
        (self.workspace / '.spm-cache').unlink()
        return mode, kept_object, kept_app

    def test_the_first_build_is_clean_and_the_next_builds_on_it(self):
        self.assertEqual(self.build()[:2], ('mode=clean', False))
        self.commit({'Sources/a.swift': 'let a = 2\n'})
        mode, kept_object, kept_app = self.build()
        self.assertEqual((mode, kept_object), ('mode=incremental', True))
        # The app bundle is rebuilt each time, so what a later step added never ships again.
        self.assertFalse(kept_app)

    def test_an_unfinished_build_makes_the_next_one_clean(self):
        self.build()
        self.build(finish=False)
        self.assertEqual(self.build()[:2], ('mode=clean', False))

    def test_a_fleet_cache_settings_change_invalidates_incremental_state(self):
        self.build()
        self.commit({'scripts/ci/fleet-compilation-cache.sh': 'echo SWIFT_ENABLE_PREFIX_MAPPING=YES\n'})
        self.assertEqual(self.build()[0], 'mode=clean')
        self.assertEqual(self.build()[0], 'mode=incremental')

    def test_a_release_build_script_change_makes_it_clean(self):
        # The workflow step only runs app-build-release.sh, so its xcodebuild flags live in the scripts.
        for name in ('scripts/ci/nightly-steps/app-build-release.sh', 'scripts/cmux-next/lib/compilation-cache.sh'):
            with self.subTest(name=name):
                self.build()
                self.commit({name: f'xcodebuild OTHER_SWIFT_FLAGS=-DCHANGED_{len(name)}\n'})
                self.assertEqual(self.build()[0], 'mode=clean')
                self.assertEqual(self.build()[0], 'mode=incremental')

    def test_a_toolchain_lockfile_or_submodule_change_makes_it_clean(self):
        self.build()
        self.assertEqual(self.build(toolchain='Xcode 26.7')[:2], ('mode=clean', False))
        self.build(toolchain='Xcode 26.7')
        self.commit({'Package.resolved': '{"pins": []}\n'})
        self.assertEqual(self.build(toolchain='Xcode 26.7')[0], 'mode=clean')
        self.commit({'cmux-tui/rust-toolchain.toml': '[toolchain]\n'})
        self.assertEqual(self.build(toolchain='Xcode 26.7')[0], 'mode=clean')

    def test_a_cargo_lock_change_stays_incremental(self):
        # The Release build's cargo phases rerun on their own lockfile inputs and build separate executables,
        # so a Cargo.lock change leaves the kept Swift objects valid.
        self.build()
        self.commit({'cmux-tui/Cargo.lock': '# changed\n', 'Native/DiffSidecar/Cargo.lock': '# changed\n'})
        self.assertEqual(self.build()[0], 'mode=incremental')
        self.commit({'cmux-tui/rust-toolchain.toml': '[toolchain]\n'})
        self.assertEqual(self.build()[0], 'mode=clean')

    def test_a_module_or_link_structure_change_makes_it_clean(self):
        for name in ('Packages/macOS/CmuxNext/Package.swift', 'cmux.xcodeproj/project.pbxproj', 'Config/Release.xcconfig',
                     'Sources/module.modulemap'):
            with self.subTest(name=name):
                self.build()
                self.commit({name: f'changed {name}\n'})
                self.assertEqual(self.build()[0], 'mode=clean')

    def test_a_prototype_package_or_import_change_stays_incremental(self):
        self.build()
        self.commit({'Prototypes/Lab/Package.swift': '// swift-tools-version:5.9\n',
                     'Prototypes/Lab/Sources/Lab/a.swift': 'import SwiftUI\n'})
        self.assertEqual(self.build()[0], 'mode=incremental')
        self.commit({'Prototypes/Lab/Package.swift': '// removed\n', 'Sources/a.swift': 'import Foundation\n'})
        self.assertEqual(self.build()[0], 'mode=clean')

    def test_a_package_tests_import_or_structure_change_stays_incremental(self):
        self.build()
        self.commit({'Packages/Shared/Lab/Tests/LabTests/a.swift': 'import Testing\n#if DEBUG\n#endif\n',
                     'Packages/macOS/App/Tests/Support/module.modulemap': 'module X {}\n'})
        self.assertEqual(self.build()[0], 'mode=incremental')
        self.commit({'Packages/Shared/Lab/Sources/Lab/a.swift': 'import Foundation\n'})
        self.assertEqual(self.build()[0], 'mode=clean')

    def test_package_tests_trees_feed_only_test_targets(self):
        """PACKAGE_TESTS skips Packages/*/*/Tests/: no product and no non-test target outside Tests/ may
        depend on a target whose sources live there, or a change there would reach the app."""
        import re
        for package in sorted(ROOT.glob('Packages/*/*/Package.swift')):
            text = package.read_text()
            pieces = re.split(r'\.(target|testTarget|executableTarget|binaryTarget|plugin|library|executable)\(', text)
            in_tests, others = set(), []
            for kind, body in zip(pieces[1::2], pieces[2::2]):
                name = re.search(r'name:\s*"([^"]+)"', body)
                path = re.search(r'path:\s*"([^"]+)"', body)
                if name is None:
                    continue
                if kind in ('library', 'executable'):
                    others.append((kind, name.group(1), body.split(')', 1)[0]))
                elif path and re.match(r'(\./)?Tests(/|$)', path.group(1)):
                    in_tests.add(name.group(1))
                elif kind != 'testTarget':
                    others.append((kind, name.group(1), body.split('swiftSettings')[0]))
            for kind, name, body in others:
                for target in in_tests:
                    with self.subTest(package=str(package.relative_to(ROOT)), target=name, depends_on=target):
                        self.assertNotRegex(body, rf'"{re.escape(target)}"')

    def test_an_import_change_makes_it_clean(self):
        for name, text in (('Sources/a.swift', 'import Foundation\nlet a = 1\n'),
                           ('Sources/b.swift', '@_exported import Bar\n'),
                           ('Sources/c.m', '#import <Foundation/Foundation.h>\n'),
                           ('Sources/d.cc', '#include_next <x.h>\n'),
                           ('Sources/e.hpp', '#include "y.h"\n'),
                           ('Sources/f.m', '@import Darwin;\n'),
                           ('Sources/a.swift', 'let a = 1\n')):
            with self.subTest(name=name, text=text):
                self.build()
                self.commit({name: text})
                self.assertEqual(self.build()[0], 'mode=clean')
        self.build()
        self.commit({'Sources/a.swift': 'let a = 3\n'})
        self.assertEqual(self.build()[0], 'mode=incremental')

    def test_a_malformed_kept_state_falls_back_to_a_clean_build(self):
        state_file = self.home / state.STATE_ROOT / self.RUNNER
        for text in ('null', '[]', '"x"', '{'):
            with self.subTest(text=text):
                self.build()
                files = list(state_file.glob(f'*/{state.INCREMENTAL_STATE}'))
                self.assertEqual(len(files), 1)
                files[0].write_text(text)
                self.assertEqual(self.build()[:2], ('mode=clean', False))
        self.assertEqual(self.build()[0], 'mode=incremental')

    def test_any_malformed_field_of_a_valid_checkpoint_makes_it_clean(self):
        self.build()
        path = next((self.home / state.STATE_ROOT / self.RUNNER).glob(f'*/{state.INCREMENTAL_STATE}'))
        valid = json.loads(path.read_text())
        self.assertTrue(state.checkpoint_complete(valid))
        mutations = [('built', 'false'), ('built', 1), ('built', None), ('since_clean', 'many'),
                     ('since_clean', -1), ('since_clean', True), ('since_clean', 1.5), ('key', 7), ('sha', None)]
        mutations += [(field, ...) for field in ('built', 'since_clean', 'key', 'sha')]
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                self.build()
                path = next((self.home / state.STATE_ROOT / self.RUNNER).glob(f'*/{state.INCREMENTAL_STATE}'))
                broken = json.loads(path.read_text())
                if value is ...:
                    del broken[field]
                else:
                    broken[field] = value
                path.write_text(json.dumps(broken))
                self.assertEqual(self.build()[:2], ('mode=clean', False))

    def test_a_conditional_compilation_change_makes_it_clean(self):
        self.commit({'Sources/g.swift': '#if true\nimport Foo\n#endif\nlet g = 1\n',
                     'Sources/h.m': '#ifdef A\n#import "x.h"\n#endif\n'})
        for name, text in (('Sources/g.swift', '#if false\nimport Foo\n#endif\nlet g = 1\n'),
                           ('Sources/h.m', '#ifndef A\n#import "x.h"\n#endif\n')):
            with self.subTest(name=name):
                self.build()
                self.commit({name: text})
                self.assertEqual(self.build()[0], 'mode=clean')

    def test_a_build_setting_or_build_step_change_makes_it_clean(self):
        self.build()
        self.assertEqual(self.build()[0], 'mode=incremental')
        for name, value in (('SWIFT_IMPORT_FLAGS', '-DCMUX_NO_BROWSER_IMPORT'), ('NIGHTLY_COMPILE_ARCHS', 'arm64'),
                            ('EMPTY_BROWSER_SOURCES', 'true'), ('IMPORT_VARIANT', 'compiled-out')):
            with self.subTest(name=name):
                with mock.patch.dict(os.environ, {name: value}):
                    self.assertEqual(self.build()[0], 'mode=clean')
                    self.assertEqual(self.build()[0], 'mode=incremental')
                self.assertEqual(self.build()[0], 'mode=clean')
        self.commit({state.BUILD_WORKFLOW: self.WORKFLOW.format(flags='-DCMUX_B')})
        self.assertEqual(self.build()[0], 'mode=clean')
        self.commit({'scripts/cmux-next/lib/nightly-swift-defines.sh': 'CMUX_NIGHTLY_NEXT_SWIFT_DEFINES=-DX\n'})
        self.assertEqual(self.build()[0], 'mode=clean')
        # Another step of the workflow is not the build's settings.
        self.commit({state.BUILD_WORKFLOW: self.WORKFLOW.format(flags='-DCMUX_B').replace('Bundle', 'Pack')})
        self.assertEqual(self.build()[0], 'mode=incremental')

    def test_a_failed_checkpoint_write_never_fails_the_job_and_the_next_build_is_clean(self):
        self.build(finish=False)
        derived = next((self.home / state.STATE_ROOT / self.RUNNER).glob('*/DerivedData'))
        (self.workspace / 'build-universal').symlink_to(derived, target_is_directory=True)
        original = Path.write_text

        def refuse(path, *args, **kwargs):
            if path.name.endswith('.tmp'):
                raise OSError(28, 'No space left on device')
            return original(path, *args, **kwargs)

        with mock.patch.object(Path, 'write_text', refuse):
            self.assertFalse(state.mark_built(self.workspace, self.home, self.RUNNER))
        (self.workspace / 'build-universal').unlink()
        self.assertEqual(self.build()[:2], ('mode=clean', False))

    def test_mark_built_never_crashes_on_a_malformed_state(self):
        self.build(finish=False)
        (self.workspace / 'build-universal').symlink_to(
            next((self.home / state.STATE_ROOT / self.RUNNER).glob('*/DerivedData')), target_is_directory=True)
        for text in ('null', '[]', '{'):
            with self.subTest(text=text):
                next((self.home / state.STATE_ROOT / self.RUNNER).glob(f'*/{state.INCREMENTAL_STATE}')).write_text(text)
                self.assertFalse(state.mark_built(self.workspace, self.home, self.RUNNER))

    def test_a_cef_or_ghosttykit_download_pin_change_makes_it_clean(self):
        self.build()
        self.commit({'scripts/cmux-next/cef-manifest.json': '{"v": 2}\n'})
        self.assertEqual(self.build()[0], 'mode=clean')

    def test_every_tenth_build_is_clean(self):
        modes = []
        for index in range(2 * state.CLEAN_EVERY + 2):
            self.commit({'Sources/a.swift': f'let a = {index}\n'})
            modes.append(self.build()[0])
        clean = [index for index, mode in enumerate(modes) if mode == 'mode=clean']
        self.assertEqual(clean, [0, state.CLEAN_EVERY, 2 * state.CLEAN_EVERY])

    def test_another_identitys_derived_data_is_deleted(self):
        self.build(toolchain='Xcode 26.6')
        self.build(toolchain='Xcode 26.7')
        kept = sorted(path.parent.name for path in (self.home / state.STATE_ROOT / self.RUNNER).glob('*/DerivedData'))
        self.assertEqual(len(kept), 1)

    def test_a_workspace_that_is_not_a_git_checkout_builds_from_empty(self):
        subprocess.run(['rm', '-rf', str(self.workspace / '.git')], check=True)
        self.outputs.write_text('')
        self.assertTrue(state.prepare(self.workspace, self.home, self.RUNNER, 'nightly-next', 'Xcode 26.6'))
        derived = self.workspace / 'build-universal'
        self.assertFalse(derived.is_symlink())
        self.assertEqual([path.name for path in derived.iterdir()], ['CompilationCache.noindex'])
        self.assertEqual(self.outputs.read_text(), '')

    def test_only_the_dedicated_builder_keeps_derived_data(self):
        self.assertTrue(state.dedicated('cmux7s-mac-mini-nightly-next'))
        self.assertTrue(state.dedicated(self.RUNNER))
        for runner in ('cmux15-glaeda', 'cmux15-glaeda-2', 'blacksmith-12vcpu-macos-26-1'):
            with self.subTest(runner=runner):
                self.assertFalse(state.dedicated(runner))
        self.assertFalse(state.mark_built(self.workspace, self.home, 'cmux15-glaeda'))

    def test_every_nightly_only_runner_keeps_state_without_the_builder_label(self):
        # Runs 41586556429 and 41570134320: the picker could not read the runners (HTTP 403), so the build took
        # the plain nightly-only label, prepare chose no mode, and the job restored the compilation cache and
        # Swift packages from R2 (280-320 s) and compiled cold. No builder label is needed any more.
        nightly_only = 'cmux7s-mac-mini-glaeda-nightly-only-3'
        self.assertTrue(state.nightly_only(nightly_only))
        self.assertFalse(state.nightly_only('cmux15-glaeda-nightly-only-'))
        self.assertTrue(state.keeps_state(nightly_only))
        self.assertTrue(state.dedicated(nightly_only))
        self.assertFalse(state.dedicated('blacksmith-6vcpu-macos-26-x'))
        self.outputs.write_text('')
        self.assertTrue(state.prepare(self.workspace, self.home, nightly_only, 'nightly-next', 'Xcode 26.6'))
        self.assertIn('mode=clean', self.outputs.read_text())
        self.assertTrue((self.workspace / 'build-universal').is_symlink())
        self.assertTrue((self.workspace / '.spm-cache').is_symlink())
        # The build finished: the next build on this slot may be incremental.
        self.assertTrue(state.mark_built(self.workspace, self.home, nightly_only))
        self.outputs.write_text('')
        state.prepare(self.workspace, self.home, nightly_only, 'nightly-next', 'Xcode 26.6')
        self.assertIn('mode=incremental', self.outputs.read_text())
        # A workspace prepare never linked has nothing to mark.
        plain = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ['rm', '-rf', str(plain)])
        self.assertFalse(state.mark_built(plain, self.home, nightly_only))

    def test_prepare_offers_the_host_build_root_to_a_plain_nightly_only_slot(self):
        """main() with no NIGHTLY_ONLY_BUILDER in the environment: a mode, and the Release build step may
        take the Mac's one build root (app-host-build-root.sh)."""
        github_env = self.root / 'env'
        github_env.write_text('')
        self.outputs.write_text('')
        environ = {'RUNNER_NAME': 'cmux15-glaeda-nightly-only-2', 'GITHUB_ENV': str(github_env),
                   'GITHUB_WORKSPACE': str(self.workspace), 'HOME': str(self.home)}
        with mock.patch.dict(os.environ, environ), mock.patch.object(state, 'toolchain_identity',
                                                                   return_value='Xcode 26.6'):
            os.environ.pop('NIGHTLY_ONLY_BUILDER', None)
            self.assertEqual(state.main(['nightly_build_state.py', 'prepare', 'nightly-next']), 0)
        self.assertIn('mode=clean', self.outputs.read_text())
        self.assertIn('CMUX_NIGHTLY_HOST_BUILD_ROOT=1', github_env.read_text())
        self.assertIn('CMUX_NEXT_NOTICES_CACHE=', github_env.read_text())

    def test_kept_package_state_is_not_sanitized_away(self):
        """The warm builder skips the R2 package restore, so its kept workspace-state.json names this
        workspace; deleting it made xcodebuild re-fetch every package (up to 222 s, run 41439348303)."""
        workflow = (ROOT / '.github/workflows/nightly.yml').read_text()
        job = workflow[workflow.index('\n  build-nightly-app:\n'):workflow.index('\n  build-nightly-remote-daemon:\n')]
        restore = job[job.index('      - name: Cache Swift packages\n'):]
        restore = restore[:restore.index('\n      - name:', 1)]
        sanitize = job[job.index('      - name: Sanitize Swift package cache\n'):]
        sanitize = sanitize[:sanitize.index('\n      - name:', 1)]
        self.assertIn("steps.release-derived-data.outputs.mode == ''", restore)
        self.assertIn("steps.release-derived-data.outputs.mode == ''", sanitize)


class HostBuildRoot(unittest.TestCase):
    """Both dedicated slots of a nightly Mac build in one root (app-host-build-root.sh), so the
    compilation cache keys and the kept DerivedData are the same whichever slot builds."""
    SCRIPTS = ('scripts/ci/nightly-steps/app-host-build-root.sh', 'scripts/ci/canonical-build-root.sh',
               'scripts/ci/apfs_clone.py', 'scripts/cmux-next/host_build_lock.py', 'scripts/ci/nightly_build_state.py')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.origin = self.root / 'origin'
        self.origin.mkdir()
        self.git(self.origin, 'init', '-q')
        files = {name: (ROOT / name).read_text() for name in self.SCRIPTS}
        files.update({'Sources/a.swift': 'let a = 1\n', 'Package.resolved': '{}\n',
                      state.BUILD_WORKFLOW: DedicatedBuilder.WORKFLOW.format(flags='-DCMUX_A')})
        self.commit(files)
        for name in self.SCRIPTS:
            (self.origin / name).chmod((ROOT / name).stat().st_mode & 0o777)
        self.git(self.origin, 'add', '-A')
        self.git(self.origin, 'commit', '-qm', 'modes')
        self.home = self.root / 'home'
        self.host = self.root / 'host'
        self.slots = {}
        for slot in ('1', '2'):
            workspace = self.root / f'slot{slot}'
            subprocess.run(['git', 'clone', '-q', str(self.origin), str(workspace)], check=True)
            self.slots[slot] = workspace
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for tool, text in (('xcodebuild', 'echo Xcode 26.6'), ('xcrun', 'echo 25G5')):
            (bin_dir / tool).write_text(f'#!/bin/sh\n{text}\n')
            (bin_dir / tool).chmod(0o755)
        self.env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'HOME': str(self.home),
                    'BUILD_TRACK': 'nightly-next', 'CMUX_NIGHTLY_HOST_BUILD_ROOT': '1',
                    'CMUX_NIGHTLY_HOST_ROOT': str(self.host)}
        for name in ('GITHUB_ENV', 'GITHUB_OUTPUT', 'RUNNER_ENVIRONMENT', 'CMUX_CI_CANONICAL_ROOT', *state.BUILD_SETTINGS):
            self.env.pop(name, None)

    def git(self, repo, *args):
        return subprocess.run(['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                              check=True, capture_output=True, text=True).stdout

    def commit(self, files):
        for name, text in files.items():
            path = self.origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.origin, 'add', '-A')
        self.git(self.origin, 'commit', '-qm', 'x')

    def build(self, slot, succeed=True, hold=None):
        """One Release build step on SLOT: take the root, 'compile', hand the products over."""
        workspace = self.slots[slot]
        self.git(workspace, 'pull', '-q', '--ff-only')
        # The earlier step linked the slot's own kept state (nightly_build_state.py prepare).
        slot_dd = self.home / 'Library/Caches/cmux-nightly-next' / f'runner-{slot}' / 'identity/DerivedData'
        slot_dd.mkdir(parents=True, exist_ok=True)
        (workspace / 'build-universal').unlink(missing_ok=True)
        (workspace / 'build-universal').symlink_to(slot_dd)
        packages = slot_dd.parent / 'SourcePackages/checkouts/pkg'
        packages.mkdir(parents=True, exist_ok=True)
        (workspace / '.spm-cache').unlink(missing_ok=True)
        (workspace / '.spm-cache').symlink_to(slot_dd.parent / 'SourcePackages')
        script = (
            'set -euo pipefail\n'
            'source scripts/ci/nightly-steps/app-host-build-root.sh\n'
            'echo "root=$host_root"\n'
            'kept=no; [[ -f "$derived_data/Build/Intermediates.noindex/a.o" ]] && kept=yes\n'
            'echo "kept=$kept"\n'
            'mkdir -p "$derived_data/Build/Intermediates.noindex" "$derived_data/Build/Products/Release/cmux.app"\n'
            'echo compiled > "$derived_data/Build/Intermediates.noindex/a.o"\n'
            'echo app > "$derived_data/Build/Products/Release/cmux.app/binary"\n'
            + ('[[ -z "$host_root" ]] || python3 scripts/ci/nightly_build_state.py finish-host "$host_root"\n' if succeed else '')
        )
        env = {**self.env, 'GITHUB_WORKSPACE': str(workspace), 'RUNNER_NAME': f'runner-{slot}'}
        if hold:
            env['CMUX_NIGHTLY_HOST_ROOT'] = str(hold)
        result = subprocess.run(['bash', '-c', script], cwd=workspace, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result.stdout + result.stderr

    def test_both_slots_build_in_one_root_and_carry_its_derived_data(self):
        first = self.build('1')
        self.assertIn(f'root={self.host}', first)
        self.assertIn('NEXT Release build: clean', first)
        self.assertIn('kept=no', first)
        # The workspace gets its own copy of the products; the slot's own DerivedData is gone.
        products = self.slots['1'] / 'build-universal/Build/Products/Release/cmux.app/binary'
        self.assertEqual(products.read_text(), 'app\n')
        self.assertFalse((self.slots['1'] / 'build-universal').is_symlink())
        self.assertFalse((self.home / 'Library/Caches/cmux-nightly-next/runner-1/identity/DerivedData').exists())
        self.assertTrue((self.host / 'src/.spm-cache').is_symlink())
        self.assertTrue((self.host / 'SourcePackages/checkouts/pkg').is_dir())

        # The other slot builds the next tip incrementally on the same DerivedData, although its own
        # checkout never held the commit the host built last.
        self.commit({'Sources/a.swift': 'let a = 2\n'})
        second = self.build('2')
        self.assertIn('NEXT Release build: incremental', second)
        self.assertIn('kept=yes', second)

    def test_a_structure_change_since_the_hosts_last_build_is_clean(self):
        self.build('1')
        self.commit({'Package.swift': '// targets\n'})
        self.assertIn('NEXT Release build: clean DerivedData (Package.swift changed', self.build('2'))

    def test_an_unfinished_host_build_makes_the_next_one_clean(self):
        self.build('1', succeed=False)
        self.commit({'Sources/a.swift': 'let a = 3\n'})
        self.assertIn('the last build did not finish', self.build('2'))

    def test_a_held_root_builds_in_the_slots_own_tree(self):
        self.host.mkdir()
        holder = subprocess.Popen(['python3', '-c', 'import fcntl,sys,time\n'
                                   f'f=open({str(self.host / "lock")!r},"a");fcntl.flock(f,fcntl.LOCK_EX);'
                                   'print("held",flush=True);time.sleep(60)'], stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.addCleanup(holder.stdout.close)
        self.assertEqual(holder.stdout.readline().strip(), 'held')
        out = self.build('1')
        self.assertIn('root=\n', out)
        self.assertTrue((self.slots['1'] / 'build-universal').is_symlink())

    def test_the_job_summary_says_the_host_roots_decision(self):
        """The slot's own prepare line always read "no earlier build on this builder" after a host-root
        build (runs 42033609306, 42018687632), though the host root decided; the summary names that one."""
        summary = self.root / 'summary.md'
        self.env['GITHUB_STEP_SUMMARY'] = str(summary)
        self.build('1')
        self.assertIn('- DerivedData: clean (no earlier build on this builder), host build root', summary.read_text())
        self.commit({'Sources/a.swift': 'let a = 2\n'})
        self.build('2')
        self.assertIn('- DerivedData: incremental (1 since the last clean build), host build root', summary.read_text())

    def test_the_release_summary_reports_cache_hits_and_the_fallback(self):
        log = self.root / 'build.log'
        log.write_text('note: 311 hits / 391 cacheable tasks (80%)\nnote: 435 hits / 517 cacheable tasks (84%)\n')
        summary = self.root / 'summary.md'
        env = {**self.env, 'GITHUB_STEP_SUMMARY': str(summary)}
        script = ROOT / 'scripts/ci/nightly-steps/release-build-summary.sh'
        for fallback, said in (('0', 'fleet cache'), ('1', 'local cache after the fleet cache failed')):
            summary.write_text('')
            subprocess.run(['bash', str(script), str(log), fallback], env=env, check=True)
            text = summary.read_text()
            self.assertIn('- compile cache: 435 hits / 517 cacheable tasks (84%), 82 missed', text)
            self.assertIn(f'- cache: {said}', text)

    def test_off_unless_the_slot_keeps_build_state(self):
        self.env['CMUX_NIGHTLY_HOST_BUILD_ROOT'] = ''
        self.assertIn('root=\n', self.build('1'))
        self.assertFalse(self.host.exists())


if __name__ == '__main__':
    unittest.main()
