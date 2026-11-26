import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TabManagerBackgroundWorkspaceMountBoundTests {
    // Regression coverage for issue #7136: a burst of eagerly-loaded background
    // workspaces (e.g. dozens of scripted or auto-resumed agent workspaces) must
    // NOT all force-mount into the single main-window SwiftUI GraphHost. When they
    // do, `GraphHost.flushTransactions()` performs O(number-of-hosted-panes) work
    // every runloop tick and pins the main thread at 100%+ CPU. The mounted
    // background-load set that inflates `reconcileMountedWorkspaceIds`' mount cap
    // must therefore stay bounded to a small constant no matter how many
    // workspaces request a background prime.
    @Test func backgroundWorkspaceMountsStayBoundedUnderEagerLoadBurst() {
        let manager = TabManager()

        let workspaceIds = (0..<50).map { _ in UUID() }
        for id in workspaceIds {
            manager.requestBackgroundWorkspaceLoad(for: id)
            manager.retainBackgroundWorkspaceMount(for: id)
        }

        // Anchor to the production cap so any change to the limit is re-justified
        // against this guard, not silently re-admitting O(all panes) growth (#7136).
        #expect(
            manager.mountedBackgroundWorkspaceLoadIds.count <= TabManager.maxConcurrentBackgroundWorkspaceMounts,
            "Background-prime mounts must stay bounded regardless of how many workspaces are eagerly loaded (#7136)."
        )
    }

    // The bound must be a *concurrency* limit with reusable slots, not a lifetime
    // cap — otherwise background priming would stall permanently after the first
    // few workspaces. Releasing a retained mount must free a slot for another.
    @Test func backgroundWorkspaceMountSlotIsReusableAfterRelease() {
        let manager = TabManager()

        let workspaceIds = (0..<10).map { _ in UUID() }
        for id in workspaceIds {
            manager.retainBackgroundWorkspaceMount(for: id)
        }

        let mountedAfterBurst = manager.mountedBackgroundWorkspaceLoadIds
        #expect(mountedAfterBurst.count <= TabManager.maxConcurrentBackgroundWorkspaceMounts)
        #expect(!mountedAfterBurst.isEmpty)

        guard let releasedId = mountedAfterBurst.first,
              let refusedId = workspaceIds.first(where: { !mountedAfterBurst.contains($0) }) else {
            Issue.record("Expected at least one retained and one refused background mount")
            return
        }

        manager.releaseBackgroundWorkspaceMount(for: releasedId)
        manager.retainBackgroundWorkspaceMount(for: refusedId)

        #expect(
            manager.mountedBackgroundWorkspaceLoadIds.contains(refusedId),
            "A freed background-mount slot must be reusable by another workspace (#7136)."
        )
        #expect(
            manager.mountedBackgroundWorkspaceLoadIds.count <= TabManager.maxConcurrentBackgroundWorkspaceMounts,
            "The background-mount set must remain bounded after slot reuse (#7136)."
        )
    }

    // A `cmux ssh --no-focus` burst can add many pending terminal startups while
    // the first background prime is running. The SwiftUI task identity must stay
    // stable until the entire pending set drains; changing it for every inserted
    // or completed workspace cancels the active prime and strands later SSH workspaces.
    @Test func backgroundPrimeTaskIdentityStaysStableWhileBurstDrains() {
        let manager = TabManager()
        let coordinator = BackgroundWorkspacePrimeCoordinator()
        let workspaceIds = (0..<22).map { _ in UUID() }

        manager.requestBackgroundWorkspaceLoad(for: workspaceIds[0])
        let activeTaskIdentity = coordinator.taskKey(for: manager)

        for workspaceId in workspaceIds.dropFirst() {
            manager.requestBackgroundWorkspaceLoad(for: workspaceId)
        }
        #expect(
            coordinator.taskKey(for: manager) == activeTaskIdentity,
            "Adding pending SSH workspaces must not cancel the active background-prime drain."
        )

        for workspaceId in workspaceIds.dropLast() {
            manager.completeBackgroundWorkspaceLoad(for: workspaceId)
        }
        #expect(
            coordinator.taskKey(for: manager) == activeTaskIdentity,
            "Completing part of a burst must keep the background-prime task alive for the remaining workspace."
        )

        manager.completeBackgroundWorkspaceLoad(for: workspaceIds[workspaceIds.count - 1])
        #expect(
            coordinator.taskKey(for: manager) != activeTaskIdentity,
            "The background-prime task identity should change only after all pending work drains."
        )
    }
}
