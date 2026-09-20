import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class NamespaceLintTests(unittest.TestCase):
    def lint(self, source):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            scripts = checkout / 'scripts'
            scripts.mkdir()
            for name in ('lint-ios-package-conventions.sh', 'swift_source_mask.py'):
                path = root / 'scripts' / name
                if path.exists():
                    shutil.copy2(path, scripts / name)
            package = checkout / 'Packages/iOS/CmuxMobileFixture/Sources/Fixture'
            package.mkdir(parents=True)
            (package / 'Fixture.swift').write_text(source)
            return subprocess.run(
                ['bash', str(scripts / 'lint-ios-package-conventions.sh')],
                text=True, capture_output=True,
            )

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


if __name__ == '__main__':
    unittest.main()
