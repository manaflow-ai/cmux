import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct VaultSessionCheckpointDerivationTests {
    private func writeTranscript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-checkpoint-derive-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    @Test
    func derivesOneCheckpointPerUserTurn() throws {
        let url = try writeTranscript([
            #"{"sessionId":"s","uuid":"u1","type":"user","timestamp":"2026-08-14T10:00:00Z","message":{"role":"user","content":"first prompt"}}"#,
            #"{"sessionId":"s","uuid":"a1","type":"assistant","timestamp":"2026-08-14T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}"#,
            #"{"sessionId":"s","uuid":"u2","type":"user","timestamp":"2026-08-14T10:01:00Z","message":{"role":"user","content":"second prompt"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let derivation = VaultSessionCheckpoints.deriveClaudeTurns(fileURL: url)
        #expect(derivation.checkpoints.count == 2)
        #expect(derivation.checkpoints[0].turnIndex == 1)
        #expect(derivation.checkpoints[0].anchorLineUUID == "u1")
        #expect(derivation.checkpoints[0].promptSnippet == "first prompt")
        #expect(derivation.checkpoints[0].timestamp != nil)
        #expect(derivation.checkpoints[1].turnIndex == 2)
        #expect(derivation.checkpoints[1].anchorLineUUID == "u2")
        #expect(derivation.checkpoints.allSatisfy { $0.source == .turn })
        #expect(!derivation.isTruncated)
        #expect(derivation.lastLineUUID == "u2")
    }

    @Test
    func skipsMetaAndToolEnvelopeLines() throws {
        let url = try writeTranscript([
            #"{"sessionId":"s","uuid":"m1","type":"user","isMeta":true,"message":{"role":"user","content":"<command-name>ls</command-name>"}}"#,
            #"{"sessionId":"s","uuid":"sys1","type":"system","message":{"role":"system","content":"boot"}}"#,
            #"{"sessionId":"s","uuid":"u1","type":"user","message":{"role":"user","content":"real prompt"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let derivation = VaultSessionCheckpoints.deriveClaudeTurns(fileURL: url)
        #expect(derivation.checkpoints.count == 1)
        #expect(derivation.checkpoints[0].anchorLineUUID == "u1")
        // lastLineUUID still tracks every line, not only prompts.
        #expect(derivation.lastLineUUID == "u1")
    }

    @Test
    func longPromptIsSnippetedToSingleLine() {
        let long = String(repeating: "word ", count: 60) + "\nsecond line"
        let snippet = VaultSessionCheckpoints.snippet(from: long)
        #expect(snippet.count <= VaultSessionCheckpoints.snippetLength + 1)
        #expect(!snippet.contains("\n"))
        #expect(snippet.hasSuffix("…"))
    }

    @Test
    func byteCapMarksTruncation() throws {
        let big = String(repeating: "x", count: 600)
        let url = try writeTranscript((1...10).map { index in
            #"{"sessionId":"s","uuid":"u\#(index)","type":"user","message":{"role":"user","content":"\#(big)"}}"#
        })
        defer { try? FileManager.default.removeItem(at: url) }

        let derivation = VaultSessionCheckpoints.deriveClaudeTurns(fileURL: url, maxBytes: 2048)
        #expect(derivation.isTruncated)
        #expect(derivation.checkpoints.count < 10)
    }
}

@Suite
struct VaultSessionCheckpointStoreTests {
    private func makeStore() -> (VaultSessionCheckpointStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-checkpoint-store-\(UUID().uuidString)", isDirectory: true)
        return (VaultSessionCheckpointStore(rootDirectory: root), root)
    }

    private func checkpoint(_ index: Int, name: String? = nil) -> VaultSessionCheckpoint {
        VaultSessionCheckpoint(
            id: "manual:\(index)",
            source: .manual,
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            name: name,
            turnIndex: index,
            anchorLineUUID: "uuid-\(index)",
            gitSHA: nil,
            promptSnippet: nil
        )
    }

    @Test
    func roundTripsManualCheckpoints() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try await store.append(checkpoint(1, name: "before refactor"), agentID: "claude", sessionID: "s1")
        try await store.append(checkpoint(2), agentID: "claude", sessionID: "s1")
        let loaded = await store.checkpoints(agentID: "claude", sessionID: "s1")
        #expect(loaded.map(\.id) == ["manual:1", "manual:2"])
        #expect(loaded[0].name == "before refactor")

        // Other sessions are isolated.
        let other = await store.checkpoints(agentID: "claude", sessionID: "s2")
        #expect(other.isEmpty)
    }

    @Test
    func capsStoredCheckpointsDroppingOldest() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...(VaultSessionCheckpointStore.maxCheckpointsPerSession + 5) {
            try await store.append(checkpoint(index), agentID: "claude", sessionID: "s1")
        }
        let loaded = await store.checkpoints(agentID: "claude", sessionID: "s1")
        #expect(loaded.count == VaultSessionCheckpointStore.maxCheckpointsPerSession)
        #expect(loaded.first?.id == "manual:6")
    }

    @Test
    func corruptFileStartsEmpty() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = store.fileURL(agentID: "claude", sessionID: "s1")
        try Data("not json at all".utf8).write(to: url)
        let loaded = await store.checkpoints(agentID: "claude", sessionID: "s1")
        #expect(loaded.isEmpty)
        // And appending over the corrupt file recovers.
        try await store.append(checkpoint(1), agentID: "claude", sessionID: "s1")
        let recovered = await store.checkpoints(agentID: "claude", sessionID: "s1")
        #expect(recovered.count == 1)
    }

    @Test
    func sanitizesPathHostileSessionIDs() {
        #expect(VaultSessionCheckpointStore.sanitizedComponent("../../etc/passwd") == ".._.._etc_passwd")
        #expect(VaultSessionCheckpointStore.sanitizedComponent("a/b:c") == "a_b_c")
        #expect(VaultSessionCheckpointStore.sanitizedComponent("") == "_")
        #expect(VaultSessionCheckpointStore.sanitizedComponent("normal-id_1.2") == "normal-id_1.2")
    }
}

@Suite
struct VaultGitHeadReaderTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-githead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test
    func readsDetachedHead() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((sha + "\n").utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == sha)
    }

    @Test
    func resolvesSymbolicRefViaLooseRefFile() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        let refDirectory = root.appendingPathComponent(".git/refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: refDirectory, withIntermediateDirectories: true)
        try Data((sha + "\n").utf8).write(to: refDirectory.appendingPathComponent("main"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == sha)
    }

    @Test
    func resolvesSymbolicRefViaPackedRefs() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ref: refs/heads/feature\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        let packed = "# pack-refs with: peeled fully-peeled sorted\n\(sha) refs/heads/feature\n"
        try Data(packed.utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == sha)
    }

    @Test
    func resolvesWorktreeGitdirIndirection() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-githead-wt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("worktree", isDirectory: true)
        let gitDirectory = container.appendingPathComponent("gitdir", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: workspace.appendingPathComponent(".git"))
        try Data((sha + "\n").utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: workspace.path) == sha)
    }

    @Test
    func missingRepoReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-githead-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == nil)
    }

    @Test
    func rejectsNonShaHeadGarbage() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("mangled".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == nil)
    }

    @Test
    func resolvesWorktreeRefThroughCommonDir() throws {
        // Worktree layout: the worktree's git dir has HEAD + commondir, while
        // the shared refs live in the main repo's git dir (relative path).
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-githead-common-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("worktree", isDirectory: true)
        let mainGit = container.appendingPathComponent("main/.git", isDirectory: true)
        let worktreeGit = mainGit.appendingPathComponent("worktrees/wt", isDirectory: true)
        let refDirectory = mainGit.appendingPathComponent("refs/heads", isDirectory: true)
        for directory in [workspace, worktreeGit, refDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("gitdir: \(worktreeGit.path)\n".utf8).write(to: workspace.appendingPathComponent(".git"))
        try Data("ref: refs/heads/feature\n".utf8).write(to: worktreeGit.appendingPathComponent("HEAD"))
        try Data("../..\n".utf8).write(to: worktreeGit.appendingPathComponent("commondir"))
        try Data((sha + "\n").utf8).write(to: refDirectory.appendingPathComponent("feature"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: workspace.path) == sha)
    }

    @Test
    func rejectsPathTraversalRefNames() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ref: ../../outside\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        #expect(VaultGitHeadReader.headSHA(workspacePath: root.path) == nil)
    }
}
