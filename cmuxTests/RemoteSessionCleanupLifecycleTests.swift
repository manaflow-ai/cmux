import CmuxCore
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct RemoteSessionCleanupLifecycleTests {
    @Test
    func manualDisconnectPreservesPersistentSlotUntilFinalCleanup() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: false)
        let transportCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!transportCleanup.contains("serve --persistent-stop --slot"))
        #expect(!transportCleanup.contains("rm -rf"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let finalCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(finalCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalCleanup.contains("64007.shell"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    @Test
    func replacementStartsOnlyAfterPriorTransportCleanupFinishes() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configuration = Self.configuration()
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        let requestsBeforeReplacement = runner.nonCleanupRequestCount

        runner.blockNextCleanup()
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        let cleanup = try #require(await Self.nextCleanupCommand(runner))

        #expect(!cleanup.contains("serve --persistent-stop --slot"))
        #expect(runner.nonCleanupRequestCount == requestsBeforeReplacement)

        runner.releaseBlockedCleanup()
        _ = try #require(await Self.nextBootstrapRequest(runner))
        #expect(runner.nonCleanupRequestCount > requestsBeforeReplacement)
    }

    @Test
    func failedSameIdentityTransportCleanupPreventsReplacementStartup() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [1])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configuration = Self.configuration()
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        let requestsBeforeReplacement = runner.nonCleanupRequestCount

        workspace.configureRemoteConnection(configuration, autoConnect: true)
        let cleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(!cleanup.contains("serve --persistent-stop --slot"))
        #expect(runner.nonCleanupRequestCount == requestsBeforeReplacement)
        #expect(workspace.remoteSessionController == nil)
        #expect(workspace.remoteSessionCleanupControllers.count == 1)
        #expect(workspace.remoteConnectionState == .error)
    }

    @Test
    func nonpersistentDisconnectDoesNotRetainStoppedController() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(
            Self.configuration(preserveAfterTerminalExit: false),
            autoConnect: true
        )
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: false)
        _ = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    @Test
    func retainedOwnerMatchesStablePersistentIdentityAcrossConfigurationChanges() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(Self.configuration(), autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.configureRemoteConnection(
            Self.configuration(foregroundAuthToken: "replacement-auth"),
            autoConnect: false
        )
        let transportCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!transportCleanup.contains("serve --persistent-stop --slot"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.configureRemoteConnection(
            Self.configuration(slot: "ssh-lifecycle-next", relayPort: 64_008),
            autoConnect: false
        )
        let finalCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(finalCleanup.contains("'ssh-lifecycle-test'"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    @Test
    func failedFinalCleanupSurvivesReplacementAndRetries() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [1, 0, 0])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(Self.configuration(slot: "ssh-lifecycle-a"), autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let failedCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(failedCleanup.contains("'ssh-lifecycle-a'"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.configureRemoteConnection(
            Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_008),
            autoConnect: true
        )
        let retriedCleanup = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(await Self.nextBootstrapRequest(runner))
        #expect(retriedCleanup.contains("'ssh-lifecycle-a'"))

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let replacementCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(replacementCleanup.contains("'ssh-lifecycle-b'"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    private static func configuration(
        slot: String = "ssh-lifecycle-test",
        relayPort: Int = 64_007,
        foregroundAuthToken: String? = nil,
        preserveAfterTerminalExit: Bool = true
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini",
            foregroundAuthToken: foregroundAuthToken,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: slot
        )
    }

    private static func nextCleanupCommand(_ runner: CleanupLifecycleRecordingRunner) async -> String? {
        await Task.detached { runner.waitForCleanupCommand() }.value
    }

    private static func nextBootstrapRequest(_ runner: CleanupLifecycleRecordingRunner) async -> String? {
        await Task.detached { runner.waitForNonCleanupRequest() }.value
    }
}

// Synchronous process-runner callbacks require a lock for the test recorder's short state updates.
private final class CleanupLifecycleRecordingRunner: RemoteSessionProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let cleanupObserved = DispatchSemaphore(value: 0)
    private let nonCleanupObserved = DispatchSemaphore(value: 0)
    private let blockedCleanupRelease = DispatchSemaphore(value: 0)
    private var cleanupCommands: [String] = []
    private var nonCleanupCommands: [String] = []
    private var cleanupStatuses: [Int32]
    private var shouldBlockNextCleanup = false

    init(cleanupStatuses: [Int32] = []) {
        self.cleanupStatuses = cleanupStatuses
    }

    var nonCleanupRequestCount: Int { lock.withLock { nonCleanupCommands.count } }

    func blockNextCleanup() {
        lock.withLock { shouldBlockNextCleanup = true }
    }

    func releaseBlockedCleanup() {
        blockedCleanupRelease.signal()
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let command = request.arguments.last ?? ""
        guard command.contains("relay_socket='127.0.0.1:") else {
            lock.withLock { nonCleanupCommands.append(command) }
            nonCleanupObserved.signal()
            return RemoteCommandResult(status: 1, stdout: "", stderr: "intentional bootstrap stop")
        }

        let state = lock.withLock { () -> (status: Int32, shouldBlock: Bool) in
            cleanupCommands.append(command)
            let status = cleanupStatuses.isEmpty ? 0 : cleanupStatuses.removeFirst()
            let shouldBlock = shouldBlockNextCleanup
            shouldBlockNextCleanup = false
            return (status, shouldBlock)
        }
        cleanupObserved.signal()
        if state.shouldBlock { blockedCleanupRelease.wait() }
        return RemoteCommandResult(status: state.status, stdout: "", stderr: "")
    }

    func waitForCleanupCommand() -> String? {
        guard cleanupObserved.wait(timeout: .now() + 2) == .success else { return nil }
        return lock.withLock { cleanupCommands.isEmpty ? nil : cleanupCommands.removeFirst() }
    }

    func waitForNonCleanupRequest() -> String? {
        guard nonCleanupObserved.wait(timeout: .now() + 2) == .success else { return nil }
        return lock.withLock { nonCleanupCommands.last }
    }
}
