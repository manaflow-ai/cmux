#!/usr/bin/env python3
"""Run the Release helper handoff with fake compilers and real installers/checks."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())


def expression(text, context):
    # The exercised workflow uses dotted outputs and the standard input override.
    if ' || ' in text:
        for part in text.split(' || '):
            value = expression(part, context)
            if value:
                return value
        return value
    if ' && ' in text:
        value = True
        for part in text.split(' && '):
            if not value:
                return value
            value = expression(part, context)
        return value
    if ' != ' in text:
        a, b = text.split(' != ', 1)
        return expression(a, context) != expression(b, context)
    if text.startswith("'") and text.endswith("'"):
        return text[1:-1]
    value = context
    for part in text.strip().split('.'):
        value = value.get(part, {})
    return value if not isinstance(value, dict) else ''


def render(value, context):
    return re.sub(r'\$\{\{\s*(.*?)\s*\}\}', lambda m: str(expression(m[1], context)), str(value))


class ReleaseHelperArchitectures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-release-arch-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.app = self.root / 'build-universal/Build/Products/Release/cmux.app'
        for name in ['scripts/ci/release-build-archs.sh', 'scripts/ci/verify-binary-archs.sh',
                     'scripts/install-prebuilt-ghostty-cli-helper.sh']:
            dest = self.root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dest)
            dest.chmod(0o755)
        self.tool('scripts/build-ghostty-cli-helper.sh', '''#!/bin/bash
set -eu
archs=""; out=""
while (( $# )); do
  case "$1" in
    --universal) archs="arm64 x86_64" ;;
    --target) shift; [[ "$1" == aarch64-macos ]] || exit 1; archs=arm64 ;;
    --output) shift; out="$1" ;;
    *) exit 2 ;;
  esac
  shift
done
printf '%s\\n' "$archs" > "$out"
chmod +x "$out"
''')
        self.tool('bin/lipo', '''#!/bin/bash
set -eu
if [[ "$1" == -archs ]]; then cat "$2"; exit; fi
file="$1"; shift
case "$1" in
  -thin)
    # Real lipo rejects -thin on a non-fat input.
    [[ "$(cat "$file")" == *" "* ]] || exit 1
    arch="$2"; [[ " $(cat "$file") " == *" $arch "* ]] || exit 1
    [[ "$3" == -output ]] || exit 2; printf '%s\\n' "$arch" > "$4" ;;
  -verify_arch)
    shift
    for arch in "$@"; do [[ " $(cat "$file") " == *" $arch "* ]] || exit 1; done ;;
  *) exit 2 ;;
esac
''')
        self.tool('bin/otool', '''#!/bin/bash
case "$2" in *ghostty-cli-helper*) sdk=15.5 ;; *) sdk=26.3 ;; esac
printf 'cmd LC_BUILD_VERSION\\n sdk %s\\n' "$sdk"
''')
        self.tool('bin/xcodebuild', '''#!/bin/bash
set -eu
archs=""
for arg in "$@"; do case "$arg" in ARCHS=*) archs="${arg#ARCHS=}" ;; esac; done
[[ -n "$archs" ]] || exit 1
app=build-universal/Build/Products/Release/cmux.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin"
for file in Contents/MacOS/cmux Contents/Resources/bin/cmux Contents/Resources/bin/cmux-cua Contents/Resources/bin/cmux-diff-sidecar; do
  printf '%s\\n' "$archs" > "$app/$file"; chmod +x "$app/$file"
done
''')
        self.tool('bin/codesign', '#!/bin/bash\nexit 0\n')
        self.tool('scripts/verify-diff-sidecar-artifact.sh', '#!/bin/bash\nexit 0\n')
        self.tool('tests/test_install_cmux_tui_client.sh', '#!/bin/bash\nexit 0\n')
        self.tool('scripts/install-cmux-tui-client.sh', '''#!/bin/bash
set -eu
app="$1"; shift
[[ $# == 2 && "$1" == --arch ]] || exit 2
case "$2" in arm64) archs=arm64 ;; universal) archs="arm64 x86_64" ;; *) exit 2 ;; esac
printf '%s\\n' "$archs" > "$app/Contents/Resources/bin/cmux-tui"
chmod +x "$app/Contents/Resources/bin/cmux-tui"
''')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.context = {'inputs': {'release_archs': 'default'}, 'vars': {'CI_RELEASE_BUILD_ARCHS': ''},
                        'steps': {}, 'needs': {}, 'github': {'token': 'fixture-no-token'}}

    def tool(self, name, content):
        dest = self.root / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content)
        dest.chmod(0o755)

    def step(self, job, *, name=None, identifier=None):
        matches = [s for s in WORKFLOW['jobs'][job]['steps']
                   if (s.get('id') == identifier if identifier else name(s.get('name', '')))]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def run_step(self, step):
        output = self.root / 'github-output'
        output.write_text('')
        env = dict(self.env, GITHUB_OUTPUT=str(output))
        env.update({k: render(v, self.context) for k, v in step.get('env', {}).items()})
        result = subprocess.run(['/bin/bash', '-e', '-c', step['run']], cwd=self.root,
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        if step.get('id'):
            self.context['steps'][step['id']] = {'outputs': dict(line.split('=', 1)
                for line in output.read_text().splitlines() if '=' in line)}
        return result

    def produce(self, setting='', dispatch='default'):
        self.context['vars']['CI_RELEASE_BUILD_ARCHS'] = setting
        self.context['inputs']['release_archs'] = dispatch
        self.run_step(self.step('swift-package-tests', identifier='release-archs'))
        self.run_step(self.step('swift-package-tests', name=lambda n: n.startswith('Build ') and n.endswith('Ghostty CLI helper')))
        outputs = {k: render(v, self.context) for k, v in WORKFLOW['jobs']['swift-package-tests'].get('outputs', {}).items()}
        self.context['needs']['swift-package-tests'] = {'outputs': outputs}
        # Model a distinct consumer: producer step outputs are not in scope.
        self.context['steps'] = {}

    def consume(self):
        self.run_step(self.step('release-build', name=lambda n: n == 'Build app (Release)'))
        self.run_step(self.step('release-build', name=lambda n: n.startswith('Install ') and ('Ghostty' in n or 'helpers' in n)))
        self.run_step(self.step('release-build', name=lambda n: n == 'Validate Release artifact slices'))

    def test_architecture_policy_flows_through_producer_and_consumer(self):
        for setting, dispatch, expected in [('', 'default', 'arm64 x86_64'), ('arm64', 'default', 'arm64'),
                ('arm64', 'universal', 'arm64 x86_64'), ('universal', 'arm64', 'arm64')]:
            with self.subTest(setting=setting, dispatch=dispatch):
                self.produce(setting, dispatch)
                self.consume()
                for file in ['Contents/MacOS/cmux', 'Contents/Resources/bin/ghostty', 'Contents/Resources/bin/cmux-tui']:
                    self.assertEqual((self.app / file).read_text().strip(), expected)

    def test_wrong_architecture_helper_is_rejected(self):
        self.produce('arm64')
        (self.root / 'ghostty-cli-helper/ghostty').write_text('arm64 x86_64\n')
        with self.assertRaises(AssertionError):
            self.consume()

    def test_missing_producer_policy_fails_closed(self):
        self.produce('arm64')
        self.context['needs']['swift-package-tests']['outputs'] = {}
        with self.assertRaises(AssertionError):
            self.consume()
        self.assertFalse(self.app.exists())

    def test_invalid_policy_rejects_before_building(self):
        with self.assertRaises(AssertionError):
            self.produce('invalid')
        self.assertFalse((self.root / 'ghostty-cli-helper/ghostty').exists())

    def test_installer_default_still_requires_universal(self):
        self.app.joinpath('Contents').mkdir(parents=True)
        helper = self.root / 'helper'
        for archs, success in [('arm64 x86_64', True), ('arm64', False)]:
            helper.write_text(archs + '\n')
            result = subprocess.run(['/bin/bash', str(self.root / 'scripts/install-prebuilt-ghostty-cli-helper.sh'),
                str(helper), str(self.app)], env=self.env, capture_output=True)
            self.assertEqual(result.returncode == 0, success)


if __name__ == '__main__':
    unittest.main()
