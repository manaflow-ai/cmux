import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class NameSanitizerTests: XCTestCase {

    // MARK: - Valid Names

    func testValidNamePassesThrough() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("Builder"), "Builder")
    }

    func testValidNameWithHyphen() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("my-script"), "my-script")
    }

    func testValidNameWithSpace() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("AI Dev"), "AI Dev")
    }

    func testValidNameWithUnderscore() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("script_v2"), "script_v2")
    }

    func testValidNameWithDot() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("file.backup"), "file.backup")
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(try NameSanitizer.sanitize("  Builder  "), "Builder")
    }

    // MARK: - Rejections

    func testRejectsEmptyString() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsWhitespaceOnly() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("   ")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsForwardSlash() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("foo/bar")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsBackslash() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("foo\\bar")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsColon() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("foo:bar")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsDoubleDot() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("..")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsParentTraversal() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("../../etc/passwd")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    func testRejectsEmbeddedDoubleDot() {
        XCTAssertThrowsError(try NameSanitizer.sanitize("foo..bar")) { error in
            XCTAssertTrue(error is NameSanitizer.Error)
        }
    }

    // MARK: - ScriptRepository Integration

    func testScriptRepositorySaveRejectsTraversal() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = ScriptRepository(directory: tempDir)
        XCTAssertThrowsError(try repo.saveScript(named: "../escape", content: "echo pwned"))
    }

    func testScriptRepositoryDeleteRejectsTraversal() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = ScriptRepository(directory: tempDir)
        XCTAssertThrowsError(try repo.deleteScript(named: "../../etc"))
    }

    func testScriptRepositoryGetReturnsNilForTraversal() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = ScriptRepository(directory: tempDir)
        XCTAssertNil(repo.getScript(named: "../escape"))
    }

    // MARK: - TemplateRepository Integration

    func testTemplateRepositorySaveRejectsTraversal() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = TemplateRepository(directory: tempDir)
        XCTAssertThrowsError(try repo.saveTemplate(named: "../escape", rawYaml: "root:\n  title: X"))
    }

    func testTemplateRepositoryDeleteRejectsSlash() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = TemplateRepository(directory: tempDir)
        XCTAssertThrowsError(try repo.deleteTemplate(named: "foo/bar"))
    }

    func testTemplateRepositoryHasReturnsFalseForTraversal() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = TemplateRepository(directory: tempDir)
        XCTAssertFalse(repo.hasTemplate(named: "../escape"))
    }

    // MARK: - Round-trip Sanity Check

    func testScriptRepositoryValidRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sanitizer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = ScriptRepository(directory: tempDir)
        let content = "#!/bin/bash\necho hello"
        try repo.saveScript(named: "my-script", content: content)
        XCTAssertEqual(repo.getScript(named: "my-script"), content)
    }
}
