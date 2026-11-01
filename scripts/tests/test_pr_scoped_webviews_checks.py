"""ui-rules and gallery coverage on a pull request's merge commit
(webviews/test/support/prScope.ts): a finding already on the base branch is
printed as a warning, but only the PR that adds it, touches its file or
changes its list line goes red."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEBVIEWS = ROOT / 'webviews'
SWIFT = 'Packages/macOS/CmuxNext/Sources'
OUTSIDE = ('schemas', 'web', 'Packages/Shared')
UI_RULES = 'test/ui-rules.test.ts'
COVERAGE = 'test/gallery-coverage.test.ts'
RAW_KEYS = 'export function RawKeys() {\n  return <div onKeyDown={() => undefined} />;\n}\n'
ORPHAN = 'export function Orphan() {\n  return <div />;\n}\n'
CLEAN = 'export const clean = 1;\n'


class Checkout:
    """A copy of webviews (and the Swift page descriptors) whose HEAD is the merge commit GitHub builds."""

    def __init__(self, base_files):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name)
        web = self.path / 'webviews'
        for name in ('src', 'test', 'scripts'):
            shutil.copytree(WEBVIEWS / name, web / name, ignore=shutil.ignore_patterns('node_modules'))
        for name in ('package.json', 'tsconfig.json'):
            if (WEBVIEWS / name).exists():
                shutil.copy2(WEBVIEWS / name, web / name)
        (web / 'node_modules').symlink_to(WEBVIEWS / 'node_modules')
        # webviews/src imports these; they stay outside the fixture's history.
        for name in OUTSIDE:
            (self.path / name).parent.mkdir(parents=True, exist_ok=True)
            (self.path / name).symlink_to(ROOT / name)
        for source in (ROOT / SWIFT).rglob('*.swift'):
            if 'PageDescriptor(' in source.read_text(errors='ignore'):
                target = self.path / source.relative_to(ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        (self.path / '.gitignore').write_text(''.join(f'/{name}\n' for name in OUTSIDE) + 'node_modules\n')
        self.git('init', '-q', '-b', 'base')
        # This disposable repo is removed immediately after the test. Detached Git maintenance
        # must not keep writing .git/objects while TemporaryDirectory cleans it up.
        self.git('config', 'gc.auto', '0')
        self.git('config', 'maintenance.auto', 'false')
        self.commit(base_files, 'base')

    def git(self, *args):
        env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                   GIT_COMMITTER_EMAIL='t@t')
        return subprocess.run(['git', *args], cwd=self.path, env=env, check=True, text=True,
                              capture_output=True).stdout

    def commit(self, files, message):
        for name, text in files.items():
            (self.path / name).parent.mkdir(parents=True, exist_ok=True)
            (self.path / name).write_text(text)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)

    def open_pr(self, files):
        self.git('checkout', '-q', '-b', 'pr')
        self.commit(files, 'pr')
        self.git('checkout', '-q', 'base')
        self.git('merge', '-q', '--no-ff', '-m', 'merge pr', 'pr')

    def run(self, test_file, scoped=True, style_guards=None):
        """The test file as ci-web.yml's react-apps-check runs it on a pull request."""
        env = dict(os.environ)
        env.pop('CMUX_PR_CHANGED_FILES', None)
        env.pop('CMUX_NEXT_STYLE_GUARDS', None)
        if style_guards:
            env['CMUX_NEXT_STYLE_GUARDS'] = style_guards
        if scoped:
            listed = self.path / 'pr-changed-files'
            listed.write_text(self.git('diff', '--name-only', '--no-renames', 'HEAD^1', 'HEAD'))
            env['CMUX_PR_CHANGED_FILES'] = str(listed)
        return subprocess.run(['bun', 'test', test_file], cwd=self.path / 'webviews', env=env, text=True,
                              capture_output=True, timeout=120)

    def close(self):
        self.temporary.cleanup()


class ScopedChecksTests(unittest.TestCase):
    def checkout(self, base_files, pr_files):
        checkout = Checkout(base_files)
        self.addCleanup(checkout.close)
        checkout.open_pr(pr_files)
        return checkout

    def assertRun(self, result, owned, needle):
        output = result.stdout + result.stderr
        if owned:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertNotIn(f'::warning title=On the base branch, not in this PR::{needle}', output)
        else:
            self.assertEqual(result.returncode, 0, output)
            self.assertIn(f'::warning title=On the base branch, not in this PR::{needle}', output)
        self.assertIn(needle, output)

    def test_ui_rules_base_finding_warns_on_an_unrelated_pr(self):
        checkout = self.checkout({'webviews/src/pages/zz/RawKeys.tsx': RAW_KEYS},
                                 {'webviews/src/pages/zz/clean.ts': CLEAN})
        self.assertRun(checkout.run(UI_RULES), False, 'pages/zz/RawKeys.tsx:2 key-handler')

    def test_ui_rules_pr_adding_a_finding_fails(self):
        checkout = self.checkout({'webviews/src/pages/zz/clean.ts': CLEAN},
                                 {'webviews/src/pages/zz/RawKeys.tsx': RAW_KEYS})
        self.assertRun(checkout.run(UI_RULES), True, 'pages/zz/RawKeys.tsx:2 key-handler')

    def test_ui_rules_pr_changing_the_rules_owns_every_finding(self):
        rules = (WEBVIEWS / 'test/ui-rules.ts').read_text() + '// edited\n'
        checkout = self.checkout({'webviews/src/pages/zz/RawKeys.tsx': RAW_KEYS},
                                 {'webviews/test/ui-rules.ts': rules})
        self.assertRun(checkout.run(UI_RULES), True, 'pages/zz/RawKeys.tsx:2 key-handler')

    def test_ui_rules_without_a_pr_every_finding_counts(self):
        checkout = self.checkout({'webviews/src/pages/zz/RawKeys.tsx': RAW_KEYS},
                                 {'webviews/src/pages/zz/clean.ts': CLEAN})
        self.assertRun(checkout.run(UI_RULES, scoped=False), True, 'pages/zz/RawKeys.tsx:2 key-handler')

    def test_warn_only_style_guards_pass_a_pr_adding_a_finding(self):
        # feat-cmux-next (CMUX_NEXT_STYLE_GUARDS=warn): the PR's own finding prints and passes.
        checkout = self.checkout({'webviews/src/pages/zz/clean.ts': CLEAN},
                                 {'webviews/src/pages/zz/RawKeys.tsx': RAW_KEYS})
        for scoped in (True, False):
            with self.subTest(scoped=scoped):
                result = checkout.run(UI_RULES, scoped=scoped, style_guards='warn')
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                self.assertIn('::warning title=Style rule (warn-only)::', output)
                self.assertIn('pages/zz/RawKeys.tsx:2 key-handler', output)

    def test_coverage_base_gap_warns_on_an_unrelated_pr(self):
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN},
                                 {'webviews/src/pages/zz/clean.ts': CLEAN})
        self.assertRun(checkout.run(COVERAGE), False, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_pr_adding_an_uncovered_component_fails(self):
        checkout = self.checkout({'webviews/src/pages/zz/clean.ts': CLEAN},
                                 {'webviews/src/pages/zz/Orphan.tsx': ORPHAN})
        self.assertRun(checkout.run(COVERAGE), True, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_base_gap_warns_on_a_pr_changing_the_gallery_format(self):
        # format.ts only validates entries, so editing it owns entry problems, not coverage gaps (#19699).
        fmt = (WEBVIEWS / 'src/gallery/format.ts').read_text() + '// edited\n'
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN},
                                 {'webviews/src/gallery/format.ts': fmt})
        self.assertRun(checkout.run(COVERAGE), False, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_pr_changing_the_entry_constructors_owns_every_finding(self):
        # componentEntry and the other constructors build the covers the coverage tests read.
        entry = (WEBVIEWS / 'src/gallery/entry.ts').read_text() + '// edited\n'
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN},
                                 {'webviews/src/gallery/entry.ts': entry})
        self.assertRun(checkout.run(COVERAGE), True, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_pr_changing_the_gallery_format_owns_entry_problems(self):
        settings = 'webviews/src/pages/settings/components'
        duplicate = (WEBVIEWS / 'src/pages/settings/components/ThemeTokens.gallery.tsx').read_text()
        fmt = (WEBVIEWS / 'src/gallery/format.ts').read_text() + '// edited\n'
        checkout = self.checkout({f'{settings}/AThemeTokens.gallery.tsx': duplicate},
                                 {'webviews/src/gallery/format.ts': fmt})
        self.assertRun(checkout.run(COVERAGE), True, 'pages.settings.theme-tokens: duplicate id')

    def test_coverage_pr_changing_the_check_owns_every_finding(self):
        check = (WEBVIEWS / COVERAGE).read_text() + '// edited\n'
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN},
                                 {f'webviews/{COVERAGE}': check})
        self.assertRun(checkout.run(COVERAGE), True, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_pr_dropping_an_allowlist_line_owns_it(self):
        allowlist = WEBVIEWS / 'test/gallery-coverage.allowlist.json'
        text = allowlist.read_text()
        listed = text.replace('"components": [', '"components": [\n    "pages/zz/Orphan.tsx#Orphan",', 1)
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN,
                                  'webviews/test/gallery-coverage.allowlist.json': listed},
                                 {'webviews/test/gallery-coverage.allowlist.json': text})
        self.assertRun(checkout.run(COVERAGE), True, 'pages/zz/Orphan.tsx#Orphan')

    def test_coverage_pr_adding_a_duplicate_entry_id_fails(self):
        # The copy sorts before the entry it duplicates, so the id's last file is the unchanged one.
        settings = 'webviews/src/pages/settings/components'
        entry = (WEBVIEWS / 'src/pages/settings/components/ThemeTokens.gallery.tsx').read_text()
        checkout = self.checkout({f'{settings}/clean.ts': CLEAN}, {f'{settings}/AThemeTokens.gallery.tsx': entry})
        self.assertRun(checkout.run(COVERAGE), True, 'pages.settings.theme-tokens: duplicate id')

    def test_coverage_pr_dropping_an_owner_prefix_last_line_owns_it(self):
        allowlist = WEBVIEWS / 'test/gallery-coverage.allowlist.json'
        text = allowlist.read_text()
        owned = text.replace('"owners": {', '"owners": {\n    "pages/zz/": "lane",', 1)
        listed = owned.replace('"components": [', '"components": [\n    "pages/zz/Orphan.tsx#Orphan",', 1)
        checkout = self.checkout({'webviews/src/pages/zz/Orphan.tsx': ORPHAN,
                                  'webviews/test/gallery-coverage.allowlist.json': listed},
                                 {'webviews/src/pages/zz/Orphan.tsx': CLEAN.replace('clean', 'orphan'),
                                  'webviews/test/gallery-coverage.allowlist.json': owned})
        self.assertRun(checkout.run(COVERAGE), True, 'pages/zz/')


if __name__ == '__main__':
    unittest.main()
