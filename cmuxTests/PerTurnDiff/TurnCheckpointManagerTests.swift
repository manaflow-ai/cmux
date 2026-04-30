import XCTest
import Combine
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@MainActor
final class TurnCheckpointManagerTests: XCTestCase {
    private var tempDir: URL!
    private var session: UUID!
    private var workspace: TestWorkspaceStub!
    private var manager: TurnCheckpointManager!
    private var diffChanges: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try shell("git init -q && git config user.email t@t && git config user.name t && touch seed && git add . && git -c commit.gpgsign=false commit -q -m seed", in: tempDir.path)
        session = UUID()
        workspace = TestWorkspaceStub(id: session, currentDirectory: tempDir.path)
        manager = TurnCheckpointManager(workspace: workspace)
        manager.onDiffChanged = { [weak self] _ in self?.diffChanges.append("changed") }
        manager.start()
    }

    override func tearDown() async throws {
        manager.stop()
        try? FileManager.default.removeItem(at: tempDir)
        cancellables.removeAll()
    }

    func test_codeChangeTurn_updatesRefAndFiresDiffChanged() async throws {
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        try await Task.sleep(nanoseconds: 50_000_000)
        try "edited".write(toFile: tempDir.appendingPathComponent("touched").path,
                           atomically: true, encoding: .utf8)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(diffChanges.count, 1)
        let refs = try shell("git for-each-ref refs/cmux/", in: tempDir.path)
        XCTAssertTrue(refs.contains(session.uuidString.lowercased()))
    }

    func test_noOpTurn_doesNotUpdateRefOrFireDiffChanged() async throws {
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        try await Task.sleep(nanoseconds: 50_000_000)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(diffChanges.count, 0)
        let refs = try shell("git for-each-ref refs/cmux/", in: tempDir.path)
        XCTAssertFalse(refs.contains(session.uuidString.lowercased()))
    }

    func test_noOpAfterCodeChange_preservesPreviousDiff() async throws {
        // Code-change turn 1
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        try await Task.sleep(nanoseconds: 50_000_000)
        try "x".write(toFile: tempDir.appendingPathComponent("a").path, atomically: true, encoding: .utf8)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle")
        try await Task.sleep(nanoseconds: 100_000_000)
        let refsAfter1 = try shell("git for-each-ref refs/cmux/", in: tempDir.path)

        // No-op turn 2
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        try await Task.sleep(nanoseconds: 50_000_000)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle")
        try await Task.sleep(nanoseconds: 100_000_000)
        let refsAfter2 = try shell("git for-each-ref refs/cmux/", in: tempDir.path)

        XCTAssertEqual(refsAfter1, refsAfter2, "no-op turn must not change ref")
        XCTAssertEqual(diffChanges.count, 1)
    }

    private func shell(_ command: String, in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
final class TestWorkspaceStub: ObservableObject, TurnCheckpointManagerWorkspace {
    let id: UUID
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var currentDirectory: String

    var statusEntriesPublisher: Published<[String: SidebarStatusEntry]>.Publisher { $statusEntries }
    var currentDirectoryPublisher: Published<String>.Publisher { $currentDirectory }

    init(id: UUID, currentDirectory: String) {
        self.id = id
        self.currentDirectory = currentDirectory
    }
}
