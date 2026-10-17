import CmuxConversation
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct NativeConversationArtifactStoreTests {
    @Test func transferPinsOneVersionAndRequiresItsHashOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("output.bin")
        let original = Data(repeating: 7, count: 100_000)
        try original.write(to: path)
        let snapshot = snapshot(root: root, file: path)
        let store = NativeConversationArtifactStore()
        let first = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact"), snapshot: snapshot)
        #expect(first.data.count == 65_536)
        #expect(first.totalBytes == original.count)
        try Data(repeating: 9, count: 100_000).write(to: path)
        let last = try await store.chunk(query: .init(
            sessionID: "session", artifactID: "artifact", offset: 65_536, expectedSHA256: first.sha256
        ), snapshot: snapshot)
        #expect(first.data + last.data == original)
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact", offset: 65_536), snapshot: snapshot)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(
                sessionID: "session", artifactID: "artifact", offset: 65_536, expectedSHA256: "changed"
            ), snapshot: snapshot)
        }
    }

    @Test func journalMembershipAndDescendantScopeAreRequired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeConversationArtifactStore()
        let outside = root.deletingLastPathComponent().appendingPathComponent("unrelated-private-file")
        let snapshot = snapshot(root: root, file: outside)
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact"), snapshot: snapshot)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "unknown"), snapshot: snapshot)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "other", artifactID: "artifact"), snapshot: snapshot)
        }
    }

    @Test func symlinksCannotEscapeTheTrustedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("private".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let store = NativeConversationArtifactStore()
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact"), snapshot: snapshot(root: root, file: link))
        }
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact"), snapshot: snapshot(root: root, file: directoryLink.appendingPathComponent("file")))
        }
    }

    @Test func oversizedArtifactIsRejectedBeforeReadingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("large")
        #expect(FileManager.default.createFile(atPath: path.path, contents: nil))
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 16_777_217)
        try handle.close()
        let store = NativeConversationArtifactStore()
        await #expect(throws: (any Error).self) {
            _ = try await store.chunk(query: .init(sessionID: "session", artifactID: "artifact"), snapshot: snapshot(root: root, file: path))
        }
    }

    private func snapshot(root: URL, file: URL) -> ConversationSnapshot {
        .init(
            session: .init(id: "session", provider: .codex, title: "Task", workspaceID: "workspace", directory: root.path, generation: "generation"),
            cursor: 1, generation: "generation",
            items: [.init(id: "item", sequence: 1, kind: .artifact, artifact: .init(
                artifactID: "artifact", fileName: file.lastPathComponent,
                mediaType: "application/octet-stream", remoteURL: file.absoluteString
            ))],
            capabilities: .init(protocolVersion: "test/1", supportsResume: false)
        )
    }
}
