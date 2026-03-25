import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ScriptRepositoryTests: XCTestCase {
    var tempDir: URL!
    var repo: ScriptRepository!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scripts-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        repo = ScriptRepository(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testListScriptsReturnsFileNames() throws {
        try "echo hello".write(
            to: tempDir.appendingPathComponent("My Script.sh"),
            atomically: true,
            encoding: .utf8
        )
        let scripts = repo.listScripts()
        XCTAssertEqual(scripts, ["My Script"])
    }

    func testListScriptsIgnoresNonShFiles() throws {
        try "echo hello".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "echo hello".write(
            to: tempDir.appendingPathComponent("Script.sh"),
            atomically: true,
            encoding: .utf8
        )
        let scripts = repo.listScripts()
        XCTAssertEqual(scripts, ["Script"])
    }

    func testListScriptsReturnsEmptyForMissingDirectory() {
        let missingRepo = ScriptRepository(
            directory: tempDir.appendingPathComponent("nonexistent")
        )
        XCTAssertEqual(missingRepo.listScripts(), [])
    }

    func testGetScriptReturnsContents() throws {
        let content = "cd $CMUX_FOLDER\nclaude"
        try content.write(
            to: tempDir.appendingPathComponent("Claude.sh"),
            atomically: true,
            encoding: .utf8
        )
        let result = repo.getScript(named: "Claude")
        XCTAssertEqual(result, content)
    }

    func testGetScriptReturnsNilForMissing() {
        XCTAssertNil(repo.getScript(named: "Nonexistent"))
    }

    func testSaveScriptWritesFile() throws {
        try repo.saveScript(named: "New Script", content: "echo test")
        let path = tempDir.appendingPathComponent("New Script.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let content = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(content, "echo test")
    }

    func testSaveScriptCreatesDirectory() throws {
        let nestedDir = tempDir.appendingPathComponent("nested/scripts")
        let nestedRepo = ScriptRepository(directory: nestedDir)
        try nestedRepo.saveScript(named: "Test", content: "echo hi")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: nestedDir.appendingPathComponent("Test.sh").path
        ))
    }

    func testDeleteScriptRemovesFile() throws {
        let path = tempDir.appendingPathComponent("Temp.sh")
        try "test".write(to: path, atomically: true, encoding: .utf8)
        try repo.deleteScript(named: "Temp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testHasScriptReturnsTrueForExisting() throws {
        try "test".write(
            to: tempDir.appendingPathComponent("Exists.sh"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(repo.hasScript(named: "Exists"))
        XCTAssertFalse(repo.hasScript(named: "Missing"))
    }

    // MARK: - Default Script Seeding

    func testSeedDefaultScriptsCreatesAllFourScripts() {
        repo.seedDefaultScripts()
        let scripts = repo.listScripts()
        XCTAssertTrue(scripts.contains("Builder"))
        XCTAssertTrue(scripts.contains("Fixer"))
        XCTAssertTrue(scripts.contains("Claude"))
        XCTAssertTrue(scripts.contains("Codex"))
    }

    func testSeedDefaultScriptsDoesNotOverwriteExisting() throws {
        let customContent = "#!/bin/bash\necho custom builder"
        try repo.saveScript(named: "Builder", content: customContent)
        repo.seedDefaultScripts()
        let result = repo.getScript(named: "Builder")
        XCTAssertEqual(result, customContent)
    }

    func testSeedDefaultScriptsCreatesOnlyMissing() throws {
        let customContent = "#!/bin/bash\necho custom"
        try repo.saveScript(named: "Claude", content: customContent)
        repo.seedDefaultScripts()
        // Claude should be untouched
        XCTAssertEqual(repo.getScript(named: "Claude"), customContent)
        // Others should be seeded
        XCTAssertTrue(repo.hasScript(named: "Builder"))
        XCTAssertTrue(repo.hasScript(named: "Fixer"))
        XCTAssertTrue(repo.hasScript(named: "Codex"))
    }

    func testSeedDefaultScriptsOnEmptyDirectoryPath() {
        let freshDir = tempDir.appendingPathComponent("fresh")
        let freshRepo = ScriptRepository(directory: freshDir)
        freshRepo.seedDefaultScripts()
        XCTAssertEqual(freshRepo.listScripts().count, 4)
    }
}
