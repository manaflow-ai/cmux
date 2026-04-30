import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
final class TurnCheckpointStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pertd-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try shell("git init -q", in: tempDir.path)
        _ = try shell("git config user.email 'test@cmux.test'", in: tempDir.path)
        _ = try shell("git config user.name 'cmux test'", in: tempDir.path)
        _ = try shell("touch a.txt && git add a.txt && git -c commit.gpgsign=false commit -q -m initial", in: tempDir.path)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_gitCommonDir_returnsAbsolutePath() throws {
        let dir = TurnCheckpointStore.gitCommonDir(for: tempDir.path)
        XCTAssertNotNil(dir)
        XCTAssertTrue(dir!.contains(".git"))
    }

    func test_writeTreeIsolatedIndex_capturesUntrackedFile() throws {
        try "hello".write(toFile: tempDir.appendingPathComponent("untracked.txt").path,
                         atomically: true, encoding: .utf8)
        let sha = try TurnCheckpointStore.writeTreeIsolated(in: tempDir.path)
        XCTAssertEqual(sha.count, 40)
        let tree = try shell("git ls-tree \(sha)", in: tempDir.path)
        XCTAssertTrue(tree.contains("untracked.txt"))
    }

    func test_writeTree_doesNotMutateUserIndex() throws {
        try "indexed".write(toFile: tempDir.appendingPathComponent("indexed.txt").path,
                            atomically: true, encoding: .utf8)
        _ = try shell("git add indexed.txt", in: tempDir.path)
        let beforeIndex = try shell("git ls-files --stage", in: tempDir.path)

        try "x".write(toFile: tempDir.appendingPathComponent("scratch.txt").path,
                      atomically: true, encoding: .utf8)
        _ = try TurnCheckpointStore.writeTreeIsolated(in: tempDir.path)

        let afterIndex = try shell("git ls-files --stage", in: tempDir.path)
        XCTAssertEqual(beforeIndex, afterIndex, "real index must be untouched")
    }

    func test_commitTreeAndUpdateRef_createsHiddenRef() throws {
        let tree = try TurnCheckpointStore.writeTreeIsolated(in: tempDir.path)
        let head = try shell("git rev-parse HEAD", in: tempDir.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try TurnCheckpointStore.commitTree(tree, parent: head, message: "test", in: tempDir.path)
        XCTAssertEqual(commit.count, 40)

        let session = UUID()
        try TurnCheckpointStore.updateRef(session: session, commit: commit, in: tempDir.path)

        let refs = try shell("git for-each-ref refs/cmux/", in: tempDir.path)
        XCTAssertTrue(refs.contains(session.uuidString.lowercased()))
        XCTAssertTrue(refs.contains(commit))
    }

    func test_diffAgainstWorkingTree_showsAddedFile() throws {
        let tree = try TurnCheckpointStore.writeTreeIsolated(in: tempDir.path)
        let head = try shell("git rev-parse HEAD", in: tempDir.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try TurnCheckpointStore.commitTree(tree, parent: head, message: "t1", in: tempDir.path)
        let session = UUID()
        try TurnCheckpointStore.updateRef(session: session, commit: commit, in: tempDir.path)

        try "new content".write(toFile: tempDir.appendingPathComponent("new.txt").path,
                                 atomically: true, encoding: .utf8)
        let diff = try TurnCheckpointStore.diffAgainstWorkingTree(session: session, in: tempDir.path)
        XCTAssertTrue(diff.contains("new.txt"))
        XCTAssertTrue(diff.contains("+new content"))
    }

    func test_cleanup_deletesAllRefsForSession() throws {
        let session = UUID()
        let tree = try TurnCheckpointStore.writeTreeIsolated(in: tempDir.path)
        let head = try shell("git rev-parse HEAD", in: tempDir.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try TurnCheckpointStore.commitTree(tree, parent: head, message: "t", in: tempDir.path)
        try TurnCheckpointStore.updateRef(session: session, commit: commit, in: tempDir.path)
        try TurnCheckpointStore.cleanup(session: session, in: tempDir.path)

        let refs = try shell("git for-each-ref refs/cmux/", in: tempDir.path)
        XCTAssertFalse(refs.contains(session.uuidString.lowercased()))
    }

    private func shell(_ command: String, in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "shell", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
