#!/usr/bin/env bash
# Exercise the workflow resolver with controlled xcodebuild/cache failures.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
lines = Path('.github/workflows/ci-macos.yml').read_text().splitlines()
job_start = lines.index('  app-host-unit-tests:')
job_end = next(i for i in range(job_start + 1, len(lines))
               if lines[i].startswith('  ') and not lines[i].startswith('    ') and lines[i].strip())
start = lines.index('      - name: Resolve Swift packages', job_start, job_end)
run_start = lines.index('        run: |', start, job_end) + 1
end = next(i for i in range(run_start, job_end)
           if lines[i].startswith('      - name: '))
script = '\n'.join(line[10:] for line in lines[run_start:end])
script = script.replace('${{ matrix.shard }}', '1')

class ResolverTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bindir = root / 'bin'
            bindir.mkdir()
            home = root / 'home'
            collision = home / 'Library/Caches/org.swift.swiftpm/artifacts/iroh'
            collision.mkdir(parents=True)
            marker = root / '.ci-source-packages/partial'
            marker.parent.mkdir()
            marker.write_text('stale')
            diagnostics = root / 'scripts/ci/capture-network-diagnostics.sh'
            diagnostics.parent.mkdir(parents=True)
            diagnostics.write_text('#!/bin/bash\necho diagnostic >> "$FIXTURE_ROOT/diagnostics"\n')
            diagnostics.chmod(0o755)
            sleep = bindir / 'sleep'
            sleep.write_text('#!/bin/bash\nexit 0\n')
            sleep.chmod(0o755)
            resolver = bindir / 'xcodebuild'
            resolver.write_text('''#!/bin/bash
set -eu
count=0
[ ! -f "$FIXTURE_ROOT/count" ] || count=$(cat "$FIXTURE_ROOT/count")
count=$((count + 1))
echo "$count" > "$FIXTURE_ROOT/count"
if [ "$FIXTURE_MODE" = permanent ] || { [ "$FIXTURE_MODE" = collision ] && [ -d "$HOME/Library/Caches/org.swift.swiftpm/artifacts/iroh" ]; }; then
  echo "failed downloading Iroh: $HOME/Library/Caches/org.swift.swiftpm/artifacts/iroh already exists in file system"
  exit 74
fi
if [ "$FIXTURE_MODE" = network ]; then
  echo 'Could not resolve package dependencies: host unavailable'
  exit 74
fi
if [ "$FIXTURE_MODE" = missing ] && [ "$count" = 1 ]; then
  exit 0
fi
mkdir -p .ci-source-packages/artifacts/sparkle/Sparkle/Sparkle.xcframework
mkdir -p .ci-source-packages/artifacts/sentry-cocoa/Sentry/Sentry.xcframework
''')
            resolver.chmod(0o755)
            env = dict(os.environ, HOME=str(home), RUNNER_TEMP=str(root),
                       GITHUB_RUN_ID='1', GITHUB_RUN_ATTEMPT='1',
                       CMUX_DERIVED_DATA_PATH=str(root / 'derived'),
                       FIXTURE_ROOT=str(root), FIXTURE_MODE=mode,
                       PATH=str(bindir) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', '-c', script], cwd=root, env=env,
                                    text=True, capture_output=True, timeout=10)
            return (result, int((root / 'count').read_text()),
                    collision.exists(), marker.exists())

    def test_collision_recovers_on_second_attempt(self):
        result, attempts, collision, partial = self.exercise('collision')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(attempts, 2)
        self.assertFalse(collision)
        self.assertFalse(partial)

    def test_persistent_collision_stays_red_after_three_attempts(self):
        result, attempts, _, _ = self.exercise('permanent')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 3)

    def test_network_failure_stays_red_without_clearing_cache(self):
        result, attempts, collision, partial = self.exercise('network')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 3)
        self.assertTrue(collision)
        self.assertTrue(partial)

    def test_success_keeps_cache(self):
        result, attempts, collision, partial = self.exercise('success')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(attempts, 1)
        self.assertTrue(collision)
        self.assertTrue(partial)

    def test_missing_binary_artifacts_retry(self):
        result, attempts, collision, partial = self.exercise('missing')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(attempts, 2)
        self.assertTrue(collision)
        self.assertFalse(partial)

unittest.main()
PY
