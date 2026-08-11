import Foundation
import Testing
import CmuxGit
import CmuxSettings
import CmuxSidebar
import CmuxSidebarGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor PullRequestRefreshSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class LoadBlockingRepositoryDiscovery: GitRepositoryDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private let started = PullRequestRefreshSignal()
    private let finished = PullRequestRefreshSignal()
    private var storedInvocationCount = 0
    private var storedReachedCleanupDeadline = false
    private var isReleased = false

    func repositorySlugs(forDirectory directory: String) async -> [String] {
        recordInvocation()
        await started.signal()
        blockUntilReleased()
        await finished.signal()
        return []
    }

    private func blockUntilReleased() {
        if releaseGate.wait(timeout: .now() + 5) == .timedOut {
            recordCleanupDeadline()
        }
    }

    func checkedOutBranch(forDirectory directory: String) async -> GitCheckedOutBranch {
        .notARepository
    }

    private func recordInvocation() {
        lock.lock()
        storedInvocationCount += 1
        lock.unlock()
    }

    private func recordCleanupDeadline() {
        lock.lock()
        storedReachedCleanupDeadline = true
        isReleased = true
        lock.unlock()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func waitUntilFinished() async {
        await finished.wait()
    }

    func release() {
        lock.lock()
        let shouldSignal = !isReleased
        isReleased = true
        lock.unlock()
        if shouldSignal {
            releaseGate.signal()
        }
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocationCount
    }

    var reachedCleanupDeadline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedReachedCleanupDeadline
    }
}

@Suite(.serialized)
@MainActor
struct WorkspacePullRequestRefreshResponsivenessTests {
    @Test(.timeLimit(.minutes(1)))
    func repositoryDiscoveryDoesNotBlockMainActorUnderWorkspaceLoad() async throws {
        let defaults = UserDefaults.standard
        let sidebarSettings = SidebarCatalogSection()
        let hideAllDetailsKey = sidebarSettings.hideAllDetails.userDefaultsKey
        let previousWatchGitStatus = defaults.object(
            forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey
        )
        let previousShowPullRequests = defaults.object(
            forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey
        )
        let previousHideAllDetails = defaults.object(forKey: hideAllDetailsKey)
        defer {
            restore(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
            restore(previousShowPullRequests, key: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
            restore(previousHideAllDetails, key: hideAllDetailsKey)
        }
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showPullRequestsKey)
        defaults.set(false, forKey: hideAllDetailsKey)

        let discovery = LoadBlockingRepositoryDiscovery()
        defer { discovery.release() }
        let manager = TabManager()
        var seededPanels: [(workspaceId: UUID, panelId: UUID)] = []
        var workspaces = manager.tabs
        while workspaces.count < 45 {
            workspaces.append(manager.addLocalWorkspace(select: false, eagerLoadTerminal: false))
        }

        for (index, workspace) in workspaces.enumerated() {
            let panelId = try #require(workspace.focusedPanelId)
            workspace.updatePanelDirectory(
                panelId: panelId,
                directory: "/tmp/cmux-pr-refresh-main-thread-\(index)"
            )
            workspace.updatePanelGitBranch(
                panelId: panelId,
                branch: "issue-3033-\(index)",
                isDirty: false
            )
            seededPanels.append((workspace.id, panelId))
        }

        let triggerPanel = try #require(seededPanels.first)
        manager.updateSurfaceShellActivity(
            tabId: triggerPanel.workspaceId,
            surfaceId: triggerPanel.panelId,
            state: .promptIdle
        )
        let pollService = PullRequestPollService(
            gitMetadataService: discovery,
            probeService: manager.pullRequestProbeService
        )
        pollService.attach(host: manager)
        pollService.scheduleWorkspacePullRequestRefresh(
            workspaceId: triggerPanel.workspaceId,
            panelId: triggerPanel.panelId,
            reason: "testMainActorResponsivenessUnderWorkspaceLoad"
        )

        await discovery.waitUntilStarted()
        #expect(!discovery.reachedCleanupDeadline)
        #expect(discovery.invocationCount == 1)

        discovery.release()
        await discovery.waitUntilFinished()
        #expect(!discovery.reachedCleanupDeadline)
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
