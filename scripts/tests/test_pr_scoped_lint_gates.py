"""The package-conventions-lint and crash-class gates on a pull request's merge
commit: a violation already on the base branch is reported, but only the PR
that adds or touches a violating file goes red."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = (
    'scripts/lint-ios-package-conventions.sh',
    'scripts/lint_swift_namespaces.py',
    'scripts/swift_source_mask.py',
    'scripts/ci/package-conventions-gate.sh',
    'scripts/ci/crash-class-gate.sh',
    'scripts/ci/pr_owned_findings.py',
    'scripts/cmux-next/check-concurrency.sh',
    'scripts/cmux-next/check-main-actor-work.py',
    'scripts/cmux-next/swift_scope.py',
    'Packages/macOS/CmuxNext/Package.swift',
)
# The fixture starts with no grandfathered debt.
EMPTY_BASELINES = (
    'scripts/lint-ios-package-conventions-baseline.txt',
    'scripts/lint-namespace-types-baseline.txt',
    'scripts/lint-namespace-types-ratchet.txt',
)
IOS = 'Packages/iOS/CmuxMobileFixture/Sources/Fixture'
NEXT = 'Packages/macOS/CmuxNext/Sources/CmuxNextApp'
SINGLETON = 'public final class Store {\n    public static let shared = Store()\n}\n'
NAMESPACE = 'public enum Helpers {\n    public static func run() {}\n}\n'
ISOLATED_DEINIT = 'final class Owner {\n    isolated deinit {}\n}\n'
CLEAN = 'public struct Clean {\n    public init() {}\n}\n'
LOCKED = 'import Foundation\nfinal class Locked {\n    private let lock = NSLock()\n}\n'
UNLOCKED = 'import Foundation\nfinal class Locked {\n    private let count = 0\n}\n'
CONVENTIONS_BASELINE = 'scripts/lint-ios-package-conventions-baseline.txt'
MANIFEST = 'Packages/macOS/CmuxNext/Package.swift'
APP_DEPENDENCY = '                "CmuxNextChiefMemory",\n'


class Checkout:
    """A repository whose HEAD is the merge commit GitHub builds for a PR."""

    def __init__(self, base_files):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name)
        for name in SCRIPTS:
            source = ROOT / name
            if source.exists():
                (self.path / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, self.path / name)
        for name in EMPTY_BASELINES:
            (self.path / name).write_text('')
        self.git('init', '-q', '-b', 'base')
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

    def gate(self, script, *args):
        return subprocess.run(['bash', str(self.path / 'scripts/ci' / script), *args], cwd=self.path, text=True,
                              capture_output=True, timeout=60)

    def close(self):
        self.temporary.cleanup()


class GateTests(unittest.TestCase):
    def checkout(self, base_files, pr_files=None):
        checkout = Checkout(base_files)
        self.addCleanup(checkout.close)
        if pr_files is not None:
            checkout.open_pr(pr_files)
        return checkout

    def assertGate(self, result, passes, *needles):
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode == 0, passes, output)
        for needle in needles:
            self.assertIn(needle, output)

    def test_conventions_pr_beside_a_base_violation_passes_and_names_it(self):
        checkout = self.checkout({f'{IOS}/Store.swift': SINGLETON, f'{IOS}/Clean.swift': CLEAN},
                                 {f'{IOS}/Clean.swift': CLEAN + '// edited\n'})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), True,
                        '::warning', f'{IOS}/Store.swift')

    def test_conventions_pr_beside_a_base_namespace_rewrite_passes(self):
        checkout = self.checkout({f'{IOS}/Helpers.swift': NAMESPACE, f'{IOS}/Clean.swift': CLEAN},
                                 {f'{IOS}/Clean.swift': CLEAN + '// edited\n'})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), True,
                        '::warning', f'{IOS}/Helpers.swift')

    def test_conventions_pr_adding_a_violation_fails(self):
        checkout = self.checkout({f'{IOS}/Clean.swift': CLEAN}, {f'{IOS}/Store.swift': SINGLETON})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), False, f'{IOS}/Store.swift')

    def test_conventions_pr_adding_a_namespace_rewrite_fails(self):
        checkout = self.checkout({f'{IOS}/Clean.swift': CLEAN}, {f'{IOS}/Helpers.swift': NAMESPACE})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), False, f'{IOS}/Helpers.swift')

    def test_conventions_pr_editing_a_violating_file_fails(self):
        checkout = self.checkout({f'{IOS}/Store.swift': SINGLETON},
                                 {f'{IOS}/Store.swift': SINGLETON + '// edited\n'})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), False, f'{IOS}/Store.swift')

    def test_conventions_pr_changing_the_rules_owns_every_violation(self):
        checkout = self.checkout({f'{IOS}/Store.swift': SINGLETON},
                                 {'scripts/swift_source_mask.py':
                                  (ROOT / 'scripts/swift_source_mask.py').read_text() + '# edited\n'})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), False, f'{IOS}/Store.swift')

    def test_conventions_pr_paying_down_baselined_debt_passes_beside_base_debt(self):
        entry = f'lock\t{IOS}/Locked.swift\tprivate let lock = NSLock()\n'
        checkout = self.checkout({f'{IOS}/Store.swift': SINGLETON, f'{IOS}/Locked.swift': LOCKED,
                                  CONVENTIONS_BASELINE: entry},
                                 {f'{IOS}/Locked.swift': UNLOCKED, CONVENTIONS_BASELINE: ''})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), True,
                        '::warning', f'{IOS}/Store.swift')

    def test_conventions_pr_dropping_another_files_baseline_entry_owns_it(self):
        entry = f'lock\t{IOS}/Locked.swift\tprivate let lock = NSLock()\n'
        checkout = self.checkout({f'{IOS}/Locked.swift': LOCKED, CONVENTIONS_BASELINE: entry},
                                 {CONVENTIONS_BASELINE: ''})
        self.assertGate(checkout.gate('package-conventions-gate.sh', '--pr'), False, f'{IOS}/Locked.swift')

    def test_conventions_without_pr_scope_fail_on_any_violation(self):
        checkout = self.checkout({f'{IOS}/Store.swift': SINGLETON})
        self.assertGate(checkout.gate('package-conventions-gate.sh'), False, f'{IOS}/Store.swift')

    def test_crash_class_pr_beside_a_base_violation_passes_and_names_it(self):
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT, f'{NEXT}/Clean.swift': CLEAN},
                                 {f'{NEXT}/Clean.swift': CLEAN + '// edited\n'})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), True, '::warning', f'{NEXT}/Owner.swift')

    def test_crash_class_pr_adding_a_violation_fails(self):
        checkout = self.checkout({f'{NEXT}/Clean.swift': CLEAN}, {f'{NEXT}/Owner.swift': ISOLATED_DEINIT})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, 'Owner.swift')

    def test_crash_class_pr_whose_file_crashes_the_lint_fails(self):
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT, f'{NEXT}/Clean.swift': CLEAN})
        checkout.git('checkout', '-q', '-b', 'pr')
        (checkout.path / NEXT / 'Zed.swift').write_bytes(ISOLATED_DEINIT.encode() + b'// \xff\n')
        checkout.git('add', '-A')
        checkout.git('commit', '-q', '-m', 'pr')
        checkout.git('checkout', '-q', 'base')
        checkout.git('merge', '-q', '--no-ff', '-m', 'merge pr', 'pr')
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False)

    def manifest(self, old, new, count=1):
        text = (ROOT / MANIFEST).read_text()
        self.assertIn(old, text)
        return text.replace(old, new, count)

    def test_crash_class_pr_editing_only_manifest_dependencies_passes_beside_a_base_violation(self):
        manifest = self.manifest(APP_DEPENDENCY, APP_DEPENDENCY + '                "CmuxNextAdded",\n')
        manifest = manifest.replace('// Umbrella package', '// The umbrella package', 1)
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT}, {MANIFEST: manifest})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), True, '::warning', f'{NEXT}/Owner.swift')

    def test_crash_class_pr_editing_manifest_swift_settings_owns_every_violation(self):
        manifest = self.manifest('swiftSettings: uiSwiftSettings', 'swiftSettings: daemonSwiftSettings')
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT}, {MANIFEST: manifest})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, f'{NEXT}/Owner.swift',
                        MANIFEST)

    def test_crash_class_pr_adding_a_target_dependency_owns_every_violation(self):
        # A line that opens a target call counts as the lint's code wherever it sits: the lint reads each
        # target call by balanced parentheses, so it can change which call the lines after it belong to.
        manifest = self.manifest(APP_DEPENDENCY, APP_DEPENDENCY + '                .target(name: "CmuxNextAdded"),\n')
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT}, {MANIFEST: manifest})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, f'{NEXT}/Owner.swift')

    def test_crash_class_pr_whose_manifest_diff_is_unreadable_owns_every_violation(self):
        manifest = self.manifest(APP_DEPENDENCY, APP_DEPENDENCY + '                "CmuxNextAdded",\n')
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT, '.gitattributes': f'{MANIFEST} -diff\n'},
                                 {MANIFEST: manifest})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, f'{NEXT}/Owner.swift')

    def test_crash_class_pr_making_a_type_generic_owns_the_classes_of_its_extensions(self):
        # Only Ledger.swift changes; the class in the untouched Ledger+Cursor.swift becomes generic by context.
        cursor = 'extension Ledger {\n    final class Cursor {\n        var index = 0\n    }\n}\n'
        checkout = self.checkout({f'{NEXT}/Ledger.swift': 'struct Ledger {\n    var count = 0\n}\n',
                                  f'{NEXT}/Ledger+Cursor.swift': cursor},
                                 {f'{NEXT}/Ledger.swift': 'struct Ledger<Entry> {\n    var count = 0\n}\n'})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, f'{NEXT}/Ledger+Cursor.swift')

    def test_crash_class_pr_changing_only_the_shared_detector_owns_every_violation(self):
        # check-concurrency.sh's crash-class rules read scripts/cmux-next/swift_scope.py: a PR that changes
        # only it changes the lint, so a violation in a file it does not touch is its own.
        detector = 'scripts/cmux-next/swift_scope.py'
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT},
                                 {detector: (ROOT / detector).read_text() + '# edited\n'})
        self.assertGate(checkout.gate('crash-class-gate.sh', '--pr'), False, f'{NEXT}/Owner.swift', detector)

    def test_crash_class_without_pr_scope_fails_on_any_violation(self):
        checkout = self.checkout({f'{NEXT}/Owner.swift': ISOLATED_DEINIT})
        self.assertGate(checkout.gate('crash-class-gate.sh'), False, 'Owner.swift')


if __name__ == '__main__':
    unittest.main()
