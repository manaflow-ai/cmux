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
    private var multiDiffPayloads: [[TurnCheckpointManager.RepoDiff]] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        _ = try shell("git init -q && git config user.email t@t && git config user.name t && touch seed && git add . && git -c commit.gpgsign=false commit -q -m seed", in: tempDir.path)
        session = UUID()
        workspace = TestWorkspaceStub(id: session, currentDirectory: tempDir.path)
        manager = TurnCheckpointManager(workspace: workspace, currentRoot: tempDir.path)
        manager.onMultiDiffChanged = { [weak self] payload in
            self?.multiDiffPayloads.append(payload)
        }
        manager.start()
    }

    override func tearDown() async throws {
        manager.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_codeChangeTurn_emitsDiffPayloadWithRepoEntry() async throws {
        try await runTurn(modifying: true)

        let payloadsForRoot = multiDiffPayloads.filter { payload in
            payload.contains { $0.root == self.tempDir.path && !$0.diff.isEmpty }
        }
        XCTAssertFalse(payloadsForRoot.isEmpty, "expected at least one emit with a non-empty diff for the modified repo")
    }

    func test_noOpTurn_doesNotProduceCachedDiff() async throws {
        try await runTurn(modifying: false)

        let cached = TurnCheckpointStore.readCachedDiff(workspaceId: session, repoRoot: tempDir.path)
        XCTAssertTrue(cached == nil || cached?.isEmpty == true,
                      "no-op turn must not write a cached diff")
    }

    func test_noOpAfterCodeChange_preservesPreviousDiff() async throws {
        try await runTurn(modifying: true)
        let cachedAfterChange = TurnCheckpointStore.readCachedDiff(workspaceId: session, repoRoot: tempDir.path)
        XCTAssertNotNil(cachedAfterChange)
        XCTAssertFalse(cachedAfterChange?.isEmpty ?? true)

        try await runTurn(modifying: false)
        let cachedAfterNoOp = TurnCheckpointStore.readCachedDiff(workspaceId: session, repoRoot: tempDir.path)
        XCTAssertEqual(cachedAfterChange, cachedAfterNoOp,
                       "no-op turn must preserve the previously-cached diff")
    }

    // MARK: - Helpers

    /// Drive one idle→running→idle cycle. When `modifying` is true, write a
    /// new file partway through so the captureEnd diff is non-empty.
    private func runTurn(modifying: Bool) async throws {
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
        try await Task.sleep(nanoseconds: 50_000_000)
        if modifying {
            let target = tempDir.appendingPathComponent("touched-\(UUID().uuidString)")
            try "edited".write(toFile: target.path, atomically: true, encoding: .utf8)
        }
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle")
        try await Task.sleep(nanoseconds: 200_000_000)
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
    var focusedPanePwd: String?

    var statusEntriesPublisher: Published<[String: SidebarStatusEntry]>.Publisher { $statusEntries }
    var currentDirectoryPublisher: Published<String>.Publisher { $currentDirectory }

    init(id: UUID, currentDirectory: String, focusedPanePwd: String? = nil) {
        self.id = id
        self.currentDirectory = currentDirectory
        self.focusedPanePwd = focusedPanePwd
    }
}
