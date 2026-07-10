import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SharedLiveAgentIndexCoalescingTests {
    @Test
    func concurrentForkAvailabilityRefreshesShareOneIndexLoad() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseLoads = DispatchSemaphore(value: 0)
        defer {
            releaseLoads.signal()
            releaseLoads.signal()
        }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                }
                releaseLoads.wait()
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            }
        )

        let firstRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow()
        }
        let firstDidStart = await Task.detached {
            Self.wait(for: firstLoadStarted)
        }.value
        #expect(firstDidStart, "The first index load should start.")
        guard firstDidStart else { return }

        let secondRefreshReachedSuspension = DispatchSemaphore(value: 0)
        let secondRefresh = Task { @MainActor in
            Task { @MainActor in
                secondRefreshReachedSuspension.signal()
            }
            await sharedIndex.refreshForkAvailabilityNow()
        }
        let secondDidReachSuspension = await Task.detached {
            Self.wait(for: secondRefreshReachedSuspension)
        }.value
        #expect(secondDidReachSuspension, "The second refresh should reach its load decision.")
        guard secondDidReachSuspension else { return }

        releaseLoads.signal()
        releaseLoads.signal()
        await firstRefresh.value
        await secondRefresh.value

        #expect(
            loadCount.withLock { $0 } == 1,
            "Concurrent refresh requests should await the same expensive index load."
        )
    }

    @Test
    func processDetectedResumeRequestsShareOneLoadStartedAfterTheirBoundary() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let secondLoadStarted = DispatchSemaphore(value: 0)
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        defer {
            releaseFirstLoad.signal()
            releaseSecondLoad.signal()
        }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                switch invocation {
                case 1:
                    firstLoadStarted.signal()
                    releaseFirstLoad.wait()
                case 2:
                    secondLoadStarted.signal()
                    releaseSecondLoad.wait()
                default:
                    break
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            }
        )

        let initialRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow()
        }
        let initialLoadDidStart = await Task.detached {
            Self.wait(for: firstLoadStarted)
        }.value
        #expect(initialLoadDidStart, "The initial index load should start.")
        guard initialLoadDidStart else { return }

        let firstFreshRequestReachedSuspension = DispatchSemaphore(value: 0)
        let firstFreshRequest = Task { @MainActor in
            Task { @MainActor in
                firstFreshRequestReachedSuspension.signal()
            }
            return await sharedIndex.processDetectedResumeIndexes()
        }
        let firstFreshRequestDidReachSuspension = await Task.detached {
            Self.wait(for: firstFreshRequestReachedSuspension)
        }.value
        #expect(firstFreshRequestDidReachSuspension, "The first fresh request should await the older load.")
        guard firstFreshRequestDidReachSuspension else { return }

        let secondFreshRequestReachedSuspension = DispatchSemaphore(value: 0)
        let secondFreshRequest = Task { @MainActor in
            Task { @MainActor in
                secondFreshRequestReachedSuspension.signal()
            }
            return await sharedIndex.processDetectedResumeIndexes()
        }
        let secondFreshRequestDidReachSuspension = await Task.detached {
            Self.wait(for: secondFreshRequestReachedSuspension)
        }.value
        #expect(secondFreshRequestDidReachSuspension, "The second fresh request should await the older load.")
        guard secondFreshRequestDidReachSuspension else { return }

        releaseFirstLoad.signal()
        let successorLoadDidStart = await Task.detached {
            Self.wait(for: secondLoadStarted)
        }.value
        #expect(successorLoadDidStart, "A successor load should start after the freshness boundary.")
        guard successorLoadDidStart else { return }
        #expect(loadCount.withLock { $0 } == 2)

        releaseSecondLoad.signal()
        await initialRefresh.value
        _ = await firstFreshRequest.value
        _ = await secondFreshRequest.value

        #expect(
            loadCount.withLock { $0 } == 2,
            "Fresh requests behind an older load should share one successor load."
        )
    }

    @Test
    func cancelledFreshRequestDoesNotStartSuccessorLoad() async {
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        defer { releaseFirstLoad.signal() }
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let invocation = loadCount.withLock { count in
                    count += 1
                    return count
                }
                if invocation == 1 {
                    firstLoadStarted.signal()
                    releaseFirstLoad.wait()
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: [],
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            }
        )

        let initialRefresh = Task { @MainActor in
            await sharedIndex.refreshForkAvailabilityNow()
        }
        let initialLoadDidStart = await Task.detached {
            Self.wait(for: firstLoadStarted)
        }.value
        #expect(initialLoadDidStart, "The initial index load should start.")
        guard initialLoadDidStart else { return }

        let freshRequestReachedSuspension = DispatchSemaphore(value: 0)
        let freshRequest = Task { @MainActor in
            Task { @MainActor in
                freshRequestReachedSuspension.signal()
            }
            return await sharedIndex.refreshedIndex()
        }
        let freshRequestDidReachSuspension = await Task.detached {
            Self.wait(for: freshRequestReachedSuspension)
        }.value
        #expect(freshRequestDidReachSuspension, "The fresh request should await the older load.")
        guard freshRequestDidReachSuspension else { return }

        freshRequest.cancel()
        releaseFirstLoad.signal()
        await initialRefresh.value
        _ = await freshRequest.value

        #expect(
            loadCount.withLock { $0 } == 1,
            "Canceling an interactive refresh should not launch a trailing physical load."
        )
    }

    @Test
    func autosaveOnlyLoadsNotifyOnlyWhenObservableIndexStateChanges() async {
        let processFingerprintChanged = OSAllocatedUnfairLock(initialState: false)
        let processScopeChanged = OSAllocatedUnfairLock(initialState: false)
        let forkValidationChanged = OSAllocatedUnfairLock(initialState: false)
        let validatedPanel = RestorableAgentSessionIndex.PanelKey(
            workspaceId: UUID(),
            panelId: UUID()
        )
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let fingerprint: Set<String> = processFingerprintChanged.withLock {
                    $0 ? ["changed"] : []
                }
                let scopeFingerprint: Set<String> = processScopeChanged.withLock {
                    $0 ? ["shell-changed"] : []
                }
                let forkValidatedPanels: Set<RestorableAgentSessionIndex.PanelKey> = forkValidationChanged.withLock {
                    $0 ? [validatedPanel] : []
                }
                return (
                    index: .empty,
                    surfaceResumeBindingIndex: .empty,
                    liveAgentProcessFingerprint: fingerprint,
                    processScopeFingerprint: scopeFingerprint,
                    forkValidatedPanels: forkValidatedPanels
                )
            }
        )
        let notificationCount = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .sharedLiveAgentIndexDidChange,
            object: sharedIndex,
            queue: nil
        ) { _ in
            notificationCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = await sharedIndex.processDetectedResumeIndexes()
        #expect(notificationCount.withLock { $0 } == 1)

        _ = await sharedIndex.processDetectedResumeIndexes()
        #expect(
            notificationCount.withLock { $0 } == 1,
            "An unchanged autosave-only load should not invalidate every workspace."
        )

        processScopeChanged.withLock { $0 = true }
        _ = await sharedIndex.processDetectedResumeIndexes()
        #expect(
            notificationCount.withLock { $0 } == 1,
            "Unrelated scoped-process churn should not invalidate every workspace."
        )

        forkValidationChanged.withLock { $0 = true }
        _ = await sharedIndex.processDetectedResumeIndexes()
        #expect(
            notificationCount.withLock { $0 } == 2,
            "Changed fork availability should notify shared-index observers."
        )

        processFingerprintChanged.withLock { $0 = true }
        _ = await sharedIndex.processDetectedResumeIndexes()
        #expect(
            notificationCount.withLock { $0 } == 3,
            "A changed live-process fingerprint should notify shared-index observers."
        )
    }

    nonisolated private static func wait(for semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 10.0) == .success
    }
}
