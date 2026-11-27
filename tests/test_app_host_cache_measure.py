#!/usr/bin/env python3
"""Exercise orchestration with a fake compiler and real archive/metrics tools."""
from __future__ import annotations

import importlib.util
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cache_measure", ROOT / "scripts/ci/app_host_cache_measure.py")
measure = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(measure)

FAKE_COMPILER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
operation, derived, packages, *rest = sys.argv[1:]
d = Path(derived)
d.mkdir(parents=True, exist_ok=True)
Path(packages).mkdir(exist_ok=True)
if operation == 'resolve':
    sys.exit(0)
cas, log = rest
cas = Path(cas)
cas.mkdir(exist_ok=True)
data = Path('Sources/AppDelegate.swift').read_text()
incremental = 'identical incremental input' in data
mode = os.environ['CMUX_CI_ENABLE_APP_COMPILATION_CACHE']
call = dict(mode=mode, incremental=incremental, source=data,
            derived=derived, cas=str(cas), profile=os.environ['CMUX_PRODUCT_PROFILE'],
            module_cache=os.environ['CMUX_CI_MODULE_CACHE_PATH'],
            remote_settings=os.environ['CMUX_FLEET_CAS_SETTINGS'],
            global_off=os.environ.get('CMUX_CI_DISABLE_COMPILATION_CACHE'),
            restored=(cas / 'seed').exists())
with open('calls.jsonl', 'a') as f:
    f.write(json.dumps(call) + '\n')
if incremental and mode == os.environ.get('FAKE_FAIL_MODE'):
    sys.exit(17)
products = d / 'Build/Products'
(products / 'Debug').mkdir(parents=True, exist_ok=True)
(products / 'Debug/cmux').write_text('test product')
(products / 'Debug/cmux').chmod(0o755)
(products / 'cmux.xctestrun').write_text('test plan')
line = "SwiftCompile normal arm64 Compiling\\ AppDelegate.swift (in target 'cmux' from project 'cmux')\n"
if incremental and os.environ.get('FAKE_NOOP'):
    line = ''
(d / 'cmux-build.log').write_text(line + 'note: 1 hits / 2 cacheable tasks\n')
Path(log).write_text(line)
if not incremental:
    (cas / 'seed').write_text(mode)
    (d / 'old-build.log').write_text(line * 99)
'''


class CacheMeasureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root, self.state, self.output = (base / name for name in ('src', 'state', 'out'))
        for path in (self.root / 'Sources', self.root / 'scripts/ci', self.state, self.output):
            path.mkdir(parents=True)
        self.source = self.root / measure.MUTATION_PATH
        self.original = b'func original() {}\n'
        self.source.write_bytes(self.original)
        self.mtime = self.source.stat().st_mtime_ns
        helper = self.root / 'scripts/ci/compile-app-host-test-product.sh'
        helper.write_text(FAKE_COMPILER)
        helper.chmod(0o755)
        shutil.copyfile(ROOT / 'scripts/ci/build_metrics.py', self.root / 'scripts/ci/build_metrics.py')
        (self.root / 'scripts/swift_warning_budget.py').write_text('raise SystemExit(0)\n')
        self.env = dict(os.environ, CMUX_CI_DISABLE_COMPILATION_CACHE='1',
                        CMUX_PRODUCT_PROFILE='cli', CMUX_CI_MODULE_CACHE_PATH='/must-not-use',
                        CMUX_FLEET_CAS_SETTINGS='/must-not-use')
        self.receipt = {'status': 'running'}

    def run_measure(self):
        measure.measure(self.root, self.state, self.output, self.env, self.receipt)

    def test_pair_restores_seed_and_compiles_same_edit_with_isolated_settings(self):
        self.run_measure()
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual([(c['mode'], c['incremental']) for c in calls],
                         [('0', False), ('0', True), ('1', False), ('1', True)])
        self.assertEqual([c['restored'] for c in calls], [False, True, False, True])
        self.assertEqual(calls[1]['source'], calls[3]['source'])
        self.assertEqual(len({c['derived'] for c in calls}), 1)
        self.assertEqual(len({c['cas'] for c in calls}), 1)
        for call in calls:
            self.assertEqual(call['profile'], 'app-host')
            self.assertIsNone(call['global_off'])
            self.assertTrue(call['module_cache'].startswith(str(self.state)))
            self.assertTrue(call['remote_settings'].startswith(str(self.state)))
        for arm in self.receipt['arms']:
            self.assertEqual(arm['status'], 'completed')
            self.assertEqual(arm['app_target']['swift_compile_events'], 1)
            self.assertEqual(arm['metrics']['derived_data_log_count'], 1)
            self.assertEqual(arm['metrics']['compiler_cache']['hits'], 1)
            self.assertGreater(arm['archive_bytes'], 0)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.source.stat().st_mtime_ns, self.mtime)

    def test_failed_second_build_restores_source_and_keeps_partial_receipt(self):
        self.env['FAKE_FAIL_MODE'] = '1'
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_measure()
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.source.stat().st_mtime_ns, self.mtime)
        saved = json.loads((self.output / 'receipt.json').read_text())
        self.assertEqual([arm['status'] for arm in saved['arms']], ['completed', 'failed'])
        self.assertNotEqual(saved['mutation']['before_sha256'], saved['mutation']['after_sha256'])

    def test_noop_is_not_accepted_as_measurement(self):
        self.env['FAKE_NOOP'] = '1'
        with self.assertRaisesRegex(RuntimeError, 'no app SwiftCompile'):
            self.run_measure()
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_setup_materializes_pinned_submodules_in_private_clone(self):
        env = dict(self.env, GIT_ALLOW_PROTOCOL='file', GIT_CONFIG_NOSYSTEM='1',
                   GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME='test',
                   GIT_AUTHOR_EMAIL='test@example.invalid', GIT_COMMITTER_NAME='test',
                   GIT_COMMITTER_EMAIL='test@example.invalid', GHOSTTY_SHA='wrong')

        def git(root, *args):
            return subprocess.check_output(['git', *args], cwd=root, env=env, text=True).strip()

        module = self.state / 'module'
        module.mkdir()
        git(module, 'init', '-q')
        (module / 'Package.swift').write_text('// test module\n')
        git(module, 'add', '.')
        git(module, 'commit', '-qm', 'fixture')
        pin = git(module, 'rev-parse', 'HEAD')
        git(self.root, 'init', '-q')
        git(self.root, 'submodule', 'add', '-q', str(module), 'ghostty')
        git(self.root, 'submodule', 'add', '-q', str(module), 'vendor/bonsplit')
        for name, body in {
            'select-ci-xcode.sh': 'echo DEVELOPER_DIR=/fixture/Xcode >> "$GITHUB_ENV"',
            'install-rust-ci.sh': 'exit 0',
            'download-prebuilt-ghosttykit.sh': 'printf "%s" "$GHOSTTY_SHA" > observed-ghostty-pin',
        }.items():
            script = self.root / 'scripts' / name
            script.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
            script.chmod(0o755)
        git(self.root, 'add', '.')
        git(self.root, 'commit', '-qm', 'fixture')
        clone = self.state / 'clone'
        git(self.root, 'clone', '--shared', str(self.root), str(clone))
        measure.setup(clone, self.state, env)
        for name in ('ghostty', 'vendor/bonsplit'):
            self.assertTrue((clone / name / 'Package.swift').is_file())
            self.assertEqual(git(clone / name, 'rev-parse', 'HEAD'), pin)
        self.assertEqual((clone / 'observed-ghostty-pin').read_text(), pin)
        self.assertEqual(env['DEVELOPER_DIR'], '/fixture/Xcode')

    def test_interruption_stops_term_resistant_compiler_descendant(self):
        lock = self.state / 'compiler.lock'
        child_code = '''import fcntl, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
lock = open(sys.argv[1], 'w')
fcntl.flock(lock, fcntl.LOCK_EX)
print('ready', flush=True)
time.sleep(60)
'''
        helper_code = '''import os, signal, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]], stdout=subprocess.PIPE)
assert child.stdout.readline() == b'ready\\n'
os.kill(int(sys.argv[3]), signal.SIGUSR1)
time.sleep(60)
'''

        def interrupt(signum, frame):
            raise InterruptedError('fixture interruption')

        previous = signal.signal(signal.SIGUSR1, interrupt)
        try:
            with self.assertRaises(InterruptedError):
                measure.command([sys.executable, '-c', helper_code, child_code, str(lock),
                                 str(os.getpid())], self.root, self.env)
        finally:
            signal.signal(signal.SIGUSR1, previous)
        with lock.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == '__main__':
    unittest.main()
