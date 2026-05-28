import XCTest
@testable import CmuxKit

/// Shell quoting is a recurring source of remote-shell vulnerabilities. We
/// pin the contract here so any regression that opens us up to command
/// injection trips a test before it ships.
final class ShellEscapeTests: XCTestCase {

    func testSafeAlphaPassthrough() {
        XCTAssertEqual(ShellEscape.single("workspace1"), "workspace1")
        XCTAssertEqual(ShellEscape.single("a-b_c.d"), "a-b_c.d")
        XCTAssertEqual(ShellEscape.single("/usr/local/bin"), "/usr/local/bin")
    }

    func testEmptyStringQuoted() {
        XCTAssertEqual(ShellEscape.single(""), "''")
    }

    func testSpacesQuoted() {
        XCTAssertEqual(ShellEscape.single("hello world"), "'hello world'")
    }

    func testSingleQuoteEscaped() {
        XCTAssertEqual(ShellEscape.single("it's me"), "'it'\\''s me'")
    }

    func testShellMetaCharsQuoted() {
        XCTAssertEqual(ShellEscape.single("rm -rf $HOME"), "'rm -rf $HOME'")
        XCTAssertEqual(ShellEscape.single("a;b"), "'a;b'")
        XCTAssertEqual(ShellEscape.single("a|b"), "'a|b'")
        XCTAssertEqual(ShellEscape.single("a`b"), "'a`b'")
        XCTAssertEqual(ShellEscape.single("a&b"), "'a&b'")
    }

    func testCommandJoinsArgumentsWithSpaces() {
        let cmd = ShellEscape.command(["cmux", "send", "--text", "echo $PATH"])
        XCTAssertEqual(cmd, "cmux send --text 'echo $PATH'")
    }

    func testNewlinesQuoted() {
        XCTAssertEqual(ShellEscape.single("line1\nline2"), "'line1\nline2'")
    }

    func testLeadingHyphenAlwaysQuoted() {
        // Regression: previously the safe-char allowlist let "--help"
        // through unquoted, turning into a CLI flag instead of an
        // argument value. See ConnectionManager → CMUXClient handling of
        // workspace handles that begin with `-`.
        XCTAssertEqual(ShellEscape.single("--help"), "'--help'")
        XCTAssertEqual(ShellEscape.single("-rf"), "'-rf'")
        XCTAssertEqual(ShellEscape.single("--all-read"), "'--all-read'")
    }

    func testInjectionRegressionCommandShape() {
        let cmd = ShellEscape.command(["cmux", "select-workspace", "--workspace", "--help"])
        XCTAssertEqual(cmd, "cmux select-workspace --workspace '--help'",
                       "Workspace handle starting with '-' must not collapse into a flag")
    }
}
