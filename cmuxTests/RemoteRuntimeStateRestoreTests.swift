import CmuxCore
import CmuxRemoteDaemon
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Remote runtime state restore", .serialized)
struct RemoteRuntimeStateRestoreTests {
    @MainActor
    @Test("serializes encoding and coalesces cancelled snapshots")
    func serializesEncodingAndCoalescesCancelledSnapshots() async {
        let pipeline = RemoteRuntimeStateEncodingPipeline()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let staleStarted = DispatchSemaphore(value: 0)
        let latestStarted = DispatchSemaphore(value: 0)

        _ = pipeline.enqueue {
            firstStarted.signal()
            releaseFirst.wait()
        }
        #expect(firstStarted.wait(timeout: .now() + 1) == .success)

        _ = pipeline.enqueue {
            staleStarted.signal()
        }
        let latest = pipeline.enqueue {
            latestStarted.signal()
        }

        #expect(staleStarted.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(latestStarted.wait(timeout: .now() + 0.1) == .timedOut)

        releaseFirst.signal()
        await latest.value

        #expect(staleStarted.wait(timeout: .now()) == .timedOut)
        #expect(latestStarted.wait(timeout: .now()) == .success)
    }

    @MainActor
    @Test("waits for the final snapshot enqueue before stopping the remote session")
    func waitsForFinalSnapshotBeforeStoppingRemoteSession() async {
        let pipeline = RemoteRuntimeStateEncodingPipeline()
        let finalSnapshotStarted = DispatchSemaphore(value: 0)
        let releaseFinalSnapshot = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        _ = pipeline.enqueue {
            finalSnapshotStarted.signal()
            releaseFinalSnapshot.wait()
        }
        #expect(finalSnapshotStarted.wait(timeout: .now() + 1) == .success)

        let stop = pipeline.finishPendingWork {
            stopped.signal()
        }

        #expect(stopped.wait(timeout: .now() + 0.1) == .timedOut)
        releaseFinalSnapshot.signal()
        await stop.value
        #expect(stopped.wait(timeout: .now()) == .success)
    }

    @MainActor
    @Test("omits attaching-machine configuration from portable runtime state")
    func omitsRemoteConfigurationFromPortableRuntimeState() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        let source = workspace.sessionSnapshot(includeScrollback: false)
        let sourceRemote = try #require(source.remote)

        let portable = workspace.remoteRuntimeStateSnapshot(from: source)

        #expect(sourceRemote.destination == "developer@example.test")
        #expect(sourceRemote.identityFile == "/tmp/cmux-runtime-test-key")
        #expect(sourceRemote.sshOptions == ["StrictHostKeyChecking=no"])
        #expect(portable.remote == nil)
    }

    @MainActor
    @Test("keeps the attaching connection while restoring server-owned presentation state")
    func preservesAttachingConnection() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        let attachingConfiguration = try #require(workspace.remoteConfiguration)

        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.processTitle = "Server workspace"
        snapshot.customTitle = "Cold-attached workspace"
        snapshot.currentDirectory = "/srv/project"
        snapshot.statusEntries = [
            SessionStatusEntrySnapshot(
                key: "claude_code",
                value: "Needs input",
                icon: "sparkles",
                color: "orange",
                timestamp: 1_750_000_000
            ),
            SessionStatusEntrySnapshot(
                key: "remote.error",
                value: "stale transport error",
                icon: nil,
                color: nil,
                timestamp: 1_750_000_001
            ),
        ]

        _ = workspace.restoreSessionSnapshot(snapshot, restoringRemoteRuntime: true)

        #expect(workspace.remoteConfiguration == attachingConfiguration)
        #expect(workspace.processTitle == "Server workspace")
        #expect(workspace.customTitle == "Cold-attached workspace")
        #expect(workspace.currentDirectory == "/srv/project")
        #expect(workspace.statusEntries["claude_code"]?.value == "Needs input")
        #expect(workspace.statusEntries["remote.error"] == nil)
    }

    @MainActor
    @Test("accepts a lower revision after changing persistent daemon slots")
    func resetsRevisionForNewRuntimeIdentity() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.configuration(slot: "runtime-state-a"), autoConnect: false)
        try Self.apply(Self.document(
            for: workspace,
            revision: 7,
            customTitle: "Runtime A"
        ), to: workspace)
        #expect(workspace.customTitle == "Runtime A")

        workspace.configureRemoteConnection(Self.configuration(slot: "runtime-state-b"), autoConnect: false)
        try Self.apply(Self.document(
            for: workspace,
            revision: 1,
            customTitle: "Runtime B"
        ), to: workspace)

        #expect(workspace.customTitle == "Runtime B")
        #expect(workspace.remoteRuntimeStateRevision == 1)
    }

    @MainActor
    @Test("does not advance the revision for an unsupported workspace schema")
    func rejectsUnsupportedSchemaWithoutAdvancingRevision() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Unsupported runtime"
        let unsupportedDocument = RemoteRuntimeStateDocument(
            schemaVersion: SessionSnapshotSchema.currentVersion + 1,
            revision: 7,
            updatedAtUnixMilliseconds: 1_750_000_000_000,
            state: try JSONEncoder().encode(snapshot),
            ptySessions: Data("[]".utf8)
        )
        try Self.apply(unsupportedDocument, to: workspace)

        try Self.apply(Self.document(
            for: workspace,
            revision: 1,
            customTitle: "Supported runtime"
        ), to: workspace)

        #expect(workspace.customTitle == "Supported runtime")
        #expect(workspace.remoteRuntimeStateRevision == 1)
    }

    @MainActor
    @Test("uses a lower server-committed revision after a same-slot reset")
    func acceptsLowerCommittedRevisionForSameRuntimeIdentity() {
        let workspace = Workspace()
        workspace.remoteRuntimeStateRevision = 7

        workspace.acknowledgeRemoteRuntimeStateRevision(1)

        #expect(workspace.remoteRuntimeStateRevision == 1)
    }

    @MainActor
    @Test("restores a lower authoritative document after a same-slot reset")
    func restoresLowerAuthoritativeDocumentForSameRuntimeIdentity() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: false)
        try Self.apply(Self.document(
            for: workspace,
            revision: 7,
            customTitle: "Before reset"
        ), to: workspace)

        try Self.apply(Self.document(
            for: workspace,
            revision: 1,
            customTitle: "After reset"
        ), to: workspace)

        #expect(workspace.customTitle == "After reset")
        #expect(workspace.remoteRuntimeStateRevision == 1)
    }

    @MainActor
    private static func apply(
        _ document: RemoteRuntimeStateDocument,
        to workspace: Workspace
    ) throws {
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: document.state)
        workspace.applyRemoteRuntimeState(document, snapshot: snapshot)
    }

    @MainActor
    private static func document(
        for workspace: Workspace,
        revision: UInt64,
        customTitle: String
    ) throws -> RemoteRuntimeStateDocument {
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = customTitle
        return RemoteRuntimeStateDocument(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            revision: revision,
            updatedAtUnixMilliseconds: 1_750_000_000_000,
            state: try JSONEncoder().encode(snapshot),
            ptySessions: Data("[]".utf8)
        )
    }

    private static func configuration(slot: String = "runtime-state-test") -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "developer@example.test",
            port: 2222,
            identityFile: "/tmp/cmux-runtime-test-key",
            sshOptions: ["StrictHostKeyChecking=no"],
            localProxyPort: 61_234,
            relayPort: 61_235,
            relayID: "runtime-test-relay",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-runtime-test.sock",
            terminalStartupCommand: "ssh developer@example.test",
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: slot
        )
    }
}
