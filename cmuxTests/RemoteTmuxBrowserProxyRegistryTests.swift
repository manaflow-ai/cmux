import Foundation
import Testing
import CmuxRemoteWorkspace

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor RecordingBrowserProxyTransport: RemoteTmuxBrowserProxyTransport {
    private var openedPorts: [Int] = []
    private var cancelledPorts: [Int] = []
    private var blocksOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func ensureMasterReady() async throws -> Bool { true }

    func openDynamicForward(localPort: Int) async throws -> RemoteTmuxCommandResult {
        openedPorts.append(localPort)
        if blocksOpen {
            await withCheckedContinuation { continuation in
                openWaiters.append(continuation)
            }
        }
        try Task.checkCancellation()
        return RemoteTmuxCommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func cancelDynamicForward(localPort: Int) async {
        cancelledPorts.append(localPort)
    }

    func setBlocksOpen(_ value: Bool) {
        blocksOpen = value
    }

    func resumeAllOpenCalls() {
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func openCount() -> Int { openedPorts.count }
    func cancelCount() -> Int { cancelledPorts.count }
}

@MainActor
@Suite(.serialized)
struct RemoteTmuxBrowserProxyRegistryTests {
    private func registry(
        using transport: RecordingBrowserProxyTransport
    ) -> RemoteTmuxBrowserProxyRegistry {
        let registry = RemoteTmuxBrowserProxyRegistry()
        registry.transportProvider = { _ in transport }
        registry.existingTransport = { _ in transport }
        return registry
    }

    private func waitForOpenCount(
        _ expected: Int,
        transport: RecordingBrowserProxyTransport
    ) async {
        for _ in 0..<100 {
            if await transport.openCount() >= expected { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(expected) dynamic-forward opens")
    }

    @Test func sharedHostRetentionKeepsTheForwardUntilTheFinalWorkspaceReleases() async throws {
        let transport = RecordingBrowserProxyTransport()
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-retention-\(UUID().uuidString)@host")
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()

        let first = registry.acquire(host: host, workspaceID: firstWorkspace)
        let second = registry.acquire(host: host, workspaceID: secondWorkspace)
        _ = try await first.value
        _ = try await second.value
        let openedOnce = await transport.openCount()
        #expect(openedOnce == 1)

        registry.release(workspaceID: firstWorkspace)
        await Task.yield()
        let cancelledAfterFirstRelease = await transport.cancelCount()
        #expect(cancelledAfterFirstRelease == 0)

        registry.release(workspaceID: secondWorkspace)
        for _ in 0..<20 {
            if await transport.cancelCount() > 0 { break }
            await Task.yield()
        }
        let cancelledAfterFinalRelease = await transport.cancelCount()
        #expect(cancelledAfterFinalRelease == 1)
    }

    @Test func rebuildCancelsTheStaleStartupBeforeItCanPublishAnEndpoint() async throws {
        let transport = RecordingBrowserProxyTransport()
        await transport.setBlocksOpen(true)
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-rebuild-\(UUID().uuidString)@host")
        var publishedEndpoints: [BrowserProxyEndpoint?] = []
        registry.onEndpointChange = { _, endpoint in
            publishedEndpoints.append(endpoint)
        }

        let stale = registry.acquire(host: host, workspaceID: UUID())
        await waitForOpenCount(1, transport: transport)
        registry.invalidateAndRebuild(connectionHash: host.connectionHash)
        await waitForOpenCount(2, transport: transport)
        await transport.resumeAllOpenCalls()

        do {
            _ = try await stale.value
            Issue.record("The invalidated startup unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: the stale task must not publish over the rebuilt entry.
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }

        for _ in 0..<100 where publishedEndpoints.compactMap({ $0 }).isEmpty {
            await Task.yield()
        }
        #expect(publishedEndpoints.compactMap({ $0 }).count == 1)
        let openedTwice = await transport.openCount()
        #expect(openedTwice == 2)
    }

    @Test func previewLifecycleUsesOnlyMasterAndDynamicForwardOperations() async throws {
        let transport = RecordingBrowserProxyTransport()
        let registry = registry(using: transport)
        let host = RemoteTmuxHost(destination: "registry-nondestructive-\(UUID().uuidString)@host")

        _ = try await registry.acquire(host: host, workspaceID: UUID()).value
        registry.releaseHost(connectionHash: host.connectionHash)
        for _ in 0..<20 {
            if await transport.cancelCount() > 0 { break }
            await Task.yield()
        }

        // The injected protocol intentionally exposes only ControlMaster readiness
        // plus `-O forward`/`-O cancel`; proxy setup cannot issue tmux create,
        // attach, kill-session, or kill-window commands through this lifecycle.
        let opened = await transport.openCount()
        let cancelled = await transport.cancelCount()
        #expect(opened == 1)
        #expect(cancelled == 1)
    }
}
