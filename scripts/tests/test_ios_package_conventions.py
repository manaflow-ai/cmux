import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class NamespaceLintTests(unittest.TestCase):
    def lint(self, source, ratchet=None, update=False):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            scripts = checkout / 'scripts'
            scripts.mkdir()
            for name in ('lint-ios-package-conventions.sh', 'swift_source_mask.py', 'lint_swift_namespaces.py'):
                path = root / 'scripts' / name
                if path.exists():
                    shutil.copy2(path, scripts / name)
            package = checkout / 'Packages/iOS/CmuxMobileFixture/Sources/Fixture'
            package.mkdir(parents=True)
            (package / 'Fixture.swift').write_text(source)
            ratchet_path = scripts / 'lint-namespace-types-ratchet.txt'
            if ratchet is not None:
                ratchet_path.write_text(''.join(f'{entry}\n' for entry in ratchet))
            env = dict(os.environ)
            env.pop('NAMESPACE_RATCHET_UPDATE', None)
            if update:
                env['NAMESPACE_RATCHET_UPDATE'] = '1'
            result = subprocess.run(
                ['bash', str(scripts / 'lint-ios-package-conventions.sh')],
                text=True, capture_output=True, timeout=30, env=env,
            )
            result.ratchet = ratchet_path.read_text() if ratchet_path.exists() else None
            return result

    def test_braces_in_strings_and_comments_do_not_hide_instance_members(self):
        result = self.lint('''public struct Resolver {
    public static let delimiters = ["}", "{"]
    /* nested comment: /* } */ } */
    public let root: String
    public init(root: String) { self.root = root }
    public func resolve() -> String { root }
}
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cases_in_comments_and_strings_do_not_hide_namespace_enum(self):
        result = self.lint('''public enum HiddenNamespace {
    // case imaginary
    public static let text = """
    case alsoImaginary
    """
    public static func value() -> Int { 1 }
}
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('namespace-enum', result.stdout)
        self.assertIn('namespace-type', result.stdout)

    def test_real_cases_and_value_factories_remain_allowed(self):
        result = self.lint('''public enum Choice {
    case first, second
    public static func preferred() -> Self { .first }
}
public struct Value {
    public let number: Int
    public static func one() -> Self { Self(number: 1) }
}
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nested_literals_inside_interpolation_preserve_type_boundaries(self):
        result = self.lint(r'''public struct Resolver {
    public static let marker = "\(String(describing: "}"))"
    public let root: String
    public init(root: String) { self.root = root }
}
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


    NAMESPACE = '''public nonisolated struct Tunables {
    public static let speed = 1
}
'''
    FIXTURE_KEY = 'Packages/iOS/CmuxMobileFixture/Sources/Fixture/Fixture.swift:Tunables'

    def test_modifiers_in_any_order_do_not_hide_a_namespace_type(self):
        for head in ('public nonisolated struct', 'nonisolated public struct', '@MainActor public final class'):
            with self.subTest(head=head):
                result = self.lint(self.NAMESPACE.replace('public nonisolated struct', head))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('namespace-type', result.stdout)

    def test_a_ratchet_entry_grandfathers_its_type(self):
        result = self.lint(self.NAMESPACE, ratchet=[self.FIXTURE_KEY])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_fixed_type_left_in_the_ratchet_fails_as_stale(self):
        fixed = '''public struct Tunables {
    public let speed = 1
    public init() {}
}
'''
        result = self.lint(fixed, ratchet=[self.FIXTURE_KEY])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('namespace-ratchet-stale', result.stdout)

    def test_updating_the_ratchet_only_drops_entries(self):
        result = self.lint(self.NAMESPACE, ratchet=['Packages/Gone.swift:Gone'], update=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('namespace-type', result.stdout)
        entries = [line for line in result.ratchet.splitlines() if line and not line.startswith('#')]
        self.assertEqual(entries, [])

    def test_updating_seeds_a_missing_ratchet(self):
        result = self.lint(self.NAMESPACE, update=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(self.FIXTURE_KEY, result.ratchet)


if __name__ == '__main__':
    unittest.main()
