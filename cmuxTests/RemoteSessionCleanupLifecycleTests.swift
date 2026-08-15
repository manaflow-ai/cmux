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
        let finalTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let finalPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!finalTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalPersistentCleanup.contains("64007.shell"))
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
    func supersededDifferentIdentityTransitionCannotDestroyLatestPersistentSession() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configurationA = Self.configuration(slot: "ssh-lifecycle-a", relayPort: 64_007)
        let configurationB = Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_008)
        workspace.configureRemoteConnection(configurationA, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value

        runner.blockNextCleanup()
        workspace.configureRemoteConnection(configurationB, autoConnect: true)
        let cleanup = try #require(await Self.nextCleanupCommand(runner))
        workspace.configureRemoteConnection(configurationA, autoConnect: true)

        let transition = try #require(workspace.remoteSessionTransitionTask)
        runner.releaseBlockedCleanup()
        let handoffCleanup = try #require(await Self.nextCleanupCommand(runner))
        await transition.value
        #expect(!cleanup.contains("serve --persistent-stop --slot"))
        #expect(cleanup.contains("64007.slot"))
        #expect(!handoffCleanup.contains("serve --persistent-stop --slot"))
        #expect(workspace.remoteConfiguration == configurationA.scopedToOwnerWorkspace(workspace.id))
        #expect(workspace.remoteSessionController != nil)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let finalTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let finalPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!finalTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalPersistentCleanup.contains("serve --persistent-stop --slot"))
        workspace.teardownAllPanels()
    }

    @Test
    func completedPersistentCleanupIsReconciledAfterTransitionIsSuperseded() async throws {
        let runner = CleanupLifecycleRecordingRunner()
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configurationA = Self.configuration(slot: "ssh-lifecycle-a", relayPort: 64_007)
        let configurationB = Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_008)
        workspace.configureRemoteConnection(configurationA, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value

        runner.blockNextCleanup()
        workspace.configureRemoteConnection(configurationB, autoConnect: true)
        let transportCleanup = try #require(await Self.nextCleanupCommand(runner))
        runner.blockNextCleanup()
        runner.releaseBlockedCleanup()
        let persistentCleanup = try #require(await Self.nextCleanupCommand(runner))

        workspace.configureRemoteConnection(configurationA, autoConnect: true)
        let transition = try #require(workspace.remoteSessionTransitionTask)
        runner.releaseBlockedCleanup()
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await transition.value

        #expect(!transportCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("'ssh-lifecycle-a'"))
        #expect(runner.recordedCleanupCommands.isEmpty)
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
        #expect(workspace.remoteConfiguration == configurationA.scopedToOwnerWorkspace(workspace.id))
        #expect(workspace.remoteSessionController != nil)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        _ = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        workspace.teardownAllPanels()
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
    func failedDifferentIdentityCleanupOnSameRelayPreventsReplacementStartup() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [0, 1])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configurationA = Self.configuration(slot: "ssh-lifecycle-a", relayPort: 64_007)
        let configurationB = Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_007)
        workspace.configureRemoteConnection(configurationA, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value
        let requestsBeforeReplacement = runner.nonCleanupRequestCount

        workspace.configureRemoteConnection(configurationB, autoConnect: true)
        let transportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let persistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(!transportCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("'ssh-lifecycle-a'"))
        #expect(runner.nonCleanupRequestCount == requestsBeforeReplacement)
        #expect(workspace.remoteSessionController == nil)
        #expect(workspace.remoteSessionCleanupControllers.count == 1)
        #expect(workspace.remoteConnectionState == .error)
    }

    @Test
    func failedDifferentIdentityCleanupOnIndependentRelayAllowsReplacementStartup() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [0, 1])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configurationA = Self.configuration(slot: "ssh-lifecycle-a", relayPort: 64_007)
        let configurationB = Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_008)
        workspace.configureRemoteConnection(configurationA, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value
        let requestsBeforeReplacement = runner.nonCleanupRequestCount

        workspace.configureRemoteConnection(configurationB, autoConnect: true)
        let transportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let persistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(!transportCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(persistentCleanup.contains("'ssh-lifecycle-a'"))
        #expect(runner.nonCleanupRequestCount > requestsBeforeReplacement)
        #expect(workspace.remoteSessionController != nil)
        #expect(workspace.remoteSessionCleanupControllers.count == 1)
        #expect(workspace.remoteConfiguration == configurationB.scopedToOwnerWorkspace(workspace.id))
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
    func failedNonpersistentDisconnectRetainsOwnerForLaterCleanupRetry() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [1, 0])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(
            Self.configuration(preserveAfterTerminalExit: false),
            autoConnect: true
        )
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: false)
        let failedCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(!failedCleanup.contains("serve --persistent-stop --slot"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.disconnectRemoteConnection(clearConfiguration: false)
        let retriedCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value

        #expect(!retriedCleanup.contains("serve --persistent-stop --slot"))
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
        let finalTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let finalPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!finalTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(finalPersistentCleanup.contains("'ssh-lifecycle-test'"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    @Test
    func failedFinalCleanupSurvivesReplacementAndRetries() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [0, 1, 0, 0, 0, 0])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        workspace.configureRemoteConnection(Self.configuration(slot: "ssh-lifecycle-a"), autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let failedTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let failedPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!failedTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(failedPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(failedPersistentCleanup.contains("'ssh-lifecycle-a'"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.configureRemoteConnection(
            Self.configuration(slot: "ssh-lifecycle-b", relayPort: 64_008),
            autoConnect: true
        )
        let retriedTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let retriedPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(await Self.nextBootstrapRequest(runner))
        #expect(!retriedTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(retriedPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(retriedPersistentCleanup.contains("'ssh-lifecycle-a'"))

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let replacementTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let replacementPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!replacementTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(replacementPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(replacementPersistentCleanup.contains("'ssh-lifecycle-b'"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
    }

    @Test
    func failedFinalCleanupTransfersRetryOwnershipToSameIdentityReplacement() async throws {
        let runner = CleanupLifecycleRecordingRunner(cleanupStatuses: [0, 1, 0, 0, 0])
        let workspace = Workspace()
        workspace.remoteSessionProcessRunnerOverrideForTesting = runner
        let configuration = Self.configuration(slot: "ssh-lifecycle-a")
        workspace.configureRemoteConnection(configuration, autoConnect: true)
        _ = try #require(await Self.nextBootstrapRequest(runner))

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let failedTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let failedPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!failedTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(failedPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(failedPersistentCleanup.contains("'ssh-lifecycle-a'"))
        #expect(workspace.remoteSessionCleanupControllers.count == 1)

        workspace.configureRemoteConnection(configuration, autoConnect: true)
        let ownershipHandoff = try #require(await Self.nextCleanupCommand(runner))
        _ = try #require(await Self.nextBootstrapRequest(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!ownershipHandoff.contains("serve --persistent-stop --slot"))
        #expect(workspace.remoteSessionCleanupControllers.isEmpty)
        #expect(workspace.remoteSessionController != nil)

        workspace.disconnectRemoteConnection(clearConfiguration: true)
        let replacementTransportCleanup = try #require(await Self.nextCleanupCommand(runner))
        let replacementPersistentCleanup = try #require(await Self.nextCleanupCommand(runner))
        await workspace.remoteSessionTransitionTask?.value
        #expect(!replacementTransportCleanup.contains("serve --persistent-stop --slot"))
        #expect(replacementPersistentCleanup.contains("serve --persistent-stop --slot"))
        #expect(replacementPersistentCleanup.contains("'ssh-lifecycle-a'"))
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
    var recordedCleanupCommands: [String] { lock.withLock { cleanupCommands } }

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
        let isCleanup = command.contains("relay_socket=") ||
            command.contains("serve --persistent-stop --slot")
        guard isCleanup else {
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
        guard cleanupObserved.wait(timeout: .now() + 10) == .success else { return nil }
        return lock.withLock { cleanupCommands.isEmpty ? nil : cleanupCommands.removeFirst() }
    }

    func waitForNonCleanupRequest() -> String? {
        guard nonCleanupObserved.wait(timeout: .now() + 10) == .success else { return nil }
        return lock.withLock { nonCleanupCommands.last }
    }
}
