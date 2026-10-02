import CmuxRemoteDaemon
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor RecordingBrowserProxyTransport: RemoteTmuxBrowserProxyTransport {
    private var openerCount = 0
    private var blocksOpenerCreation = false
    private var openerWaiters: [CheckedContinuation<Void, Never>] = []

    func ensureMasterReady() async throws -> Bool { true }

    func makeBrowserProxyStreamOpener() async throws -> any RemoteProxyStreamOpening {
        openerCount += 1
        if blocksOpenerCreation {
            await withCheckedContinuation { continuation in
                openerWaiters.append(continuation)
            }
        }
        try Task.checkCancellation()
        return UnavailableRemoteProxyStreamOpener()
    }

    func setBlocksOpenerCreation(_ value: Bool) {
        blocksOpenerCreation = value
    }

    func resumeAllOpenerCalls() {
        let waiters = openerWaiters
        openerWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func openerCreationCount() -> Int { openerCount }
}

private final class UnavailableRemoteProxyStreamOpener: RemoteProxyStreamOpening, @unchecked Sendable {
    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String { throw RemoteTmuxError.unreachable("test opener") }
    func writeStream(streamID: String, data: Data) throws { throw RemoteTmuxError.unreachable("test opener") }
    func attachStream(streamID: String, queue: DispatchQueue, onEvent: @escaping (RemoteDaemonStreamEvent) -> Void) throws { throw RemoteTmuxError.unreachable("test opener") }
    func closeStream(streamID: String) {}
}

@MainActor
@Suite(.serialized)
struct RemoteTmuxBrowserProxyRegistryTests {
    private func registry(
        using transport: RecordingBrowserProxyTransport
    ) -> RemoteTmuxBrowserProxyRegistry {
        let registry = RemoteTmuxBrowserProxyRegistry()
        registry.transportProvider = { _ in transport }
        return registry
    }

    private func waitForOpenerCreationCount(
        _ expected: Int,
        transport: RecordingBrowserProxyTransport
    ) async {
        for _ in 0..<100 {
            if await transport.openerCreationCount() >= expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) browser stream openers")
    }

    @Test func sharedHostRetentionKeepsOneBrowserProxyUntilTheFinalWorkspaceReleases() async throws {
        let transport = RecordingBrowserProxyTransport()
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-retention-\(UUID().uuidString)@host")
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()

        let first = registry.acquire(host: host, workspaceID: firstWorkspace)
        let second = registry.acquire(host: host, workspaceID: secondWorkspace)
        _ = try await first.value
        _ = try await second.value
        let createdOnce = await transport.openerCreationCount()
        #expect(createdOnce == 1)

        registry.release(workspaceID: firstWorkspace)
        registry.release(workspaceID: secondWorkspace)
        #expect(await transport.openerCreationCount() == 1)
    }

    @Test func rebuildCancelsTheStaleStartupBeforeItCanPublishAnEndpoint() async throws {
        let transport = RecordingBrowserProxyTransport()
        await transport.setBlocksOpenerCreation(true)
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-rebuild-\(UUID().uuidString)@host")
        var readyEndpointCount = 0
        registry.onEndpointChange = { _, endpoint in
            if endpoint != nil {
                readyEndpointCount += 1
            }
        }

        let stale = registry.acquire(host: host, workspaceID: UUID())
        await waitForOpenerCreationCount(1, transport: transport)
        registry.invalidateAndRebuild(connectionHash: host.connectionHash)
        await waitForOpenerCreationCount(2, transport: transport)
        await transport.resumeAllOpenerCalls()

        do {
            _ = try await stale.value
            Issue.record("The invalidated startup unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: the stale task must not publish over the rebuilt entry.
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }

        for _ in 0..<100 where readyEndpointCount == 0 {
            await Task.yield()
        }
        #expect(readyEndpointCount == 1)
        let createdTwice = await transport.openerCreationCount()
        #expect(createdTwice == 2)
    }

    @Test func previewLifecycleUsesOnlyMasterAndOwnerOnlyStreamOperations() async throws {
        let transport = RecordingBrowserProxyTransport()
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-nondestructive-\(UUID().uuidString)@host")

        _ = try await registry.acquire(host: host, workspaceID: UUID()).value
        registry.releaseHost(connectionHash: host.connectionHash)
        // The injected protocol intentionally exposes only ControlMaster readiness
        // plus creation of pipe-backed stream openers; proxy setup cannot issue
        // tmux mutations or add a dynamic listener through this lifecycle.
        #expect(await transport.openerCreationCount() == 1)
    }
}
