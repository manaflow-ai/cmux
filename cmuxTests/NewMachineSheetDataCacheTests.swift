import CmuxAuthRuntime
import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The account-scoped cache that lets Cmd+Y present a populated New Machine
/// sheet without waiting on the network.
@MainActor
@Suite("New Machine sheet data cache")
struct NewMachineSheetDataCacheTests {
    /// Mutable test state the fetch closures share on the main actor.
    @MainActor
    final class Backend {
        var scope: AuthenticatedTeamScope?
        var planId = "pro"
        var pageFetches = 0
        var holdsPage = false
        var isHoldingPage = false
        let release = AsyncStream<Void>.makeStream()
    }

    private static func scope(_ account: String) -> AuthenticatedTeamScope {
        AuthenticatedTeamScope(
            session: AuthenticatedSessionIdentity(generation: 1, accountID: account),
            teamID: "team-\(account)",
            generation: 1
        )
    }

    private static let catalog = CloudNetworkPresetCatalog(
        presets: [CloudNetworkPreset(id: "npm", label: "npm", domains: ["registry.npmjs.org"])],
        requiredDomains: ["files.cmux.com"]
    )

    private static func makeCache(_ backend: Backend) -> NewMachineSheetDataCache {
        NewMachineSheetDataCache(
            currentScope: { backend.scope },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                backend.pageFetches += 1
                let planId = backend.planId
                if backend.holdsPage {
                    backend.isHoldingPage = true
                    for await _ in backend.release.stream { break }
                }
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: planId, freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192, 32768],
                    lockedMemoryOptionsMb: [32768], memoryUpgradePlanId: "max"
                ))
            },
            fetchCatalog: { Self.catalog }
        )
    }

    @Test func warmCacheAnswersWithoutWaitingOnAnotherFetch() async {
        let backend = Backend()
        backend.scope = Self.scope("a")
        let cache = Self.makeCache(backend)

        let warmed = await cache.data()
        #expect(warmed?.limits?.memoryOptionsMb == [4096, 8192, 32768])
        #expect(backend.pageFetches == 1)

        // Presenting reads the ready data synchronously; the fetch count
        // proves the sheet did not wait on the network for it.
        let ready = cache.readyData
        #expect(ready?.limits?.lockedMemoryOptionsMb == [32768])
        #expect(ready?.plan?.planId == "pro")
        #expect(backend.pageFetches == 1)
    }

    @Test func switchingAccountsDropsTheOldAccountsPlan() async {
        let backend = Backend()
        backend.scope = Self.scope("a")
        let cache = Self.makeCache(backend)
        _ = await cache.data()
        #expect(cache.readyData != nil)

        backend.scope = Self.scope("b")
        #expect(cache.readyData == nil)
        #expect(cache.currentData == nil)

        backend.scope = nil
        #expect(cache.currentData == nil)
        #expect(!cache.refresh())
    }

    @Test func aLateAnswerForAReplacedAccountIsNeverInstalled() async {
        let backend = Backend()
        backend.scope = Self.scope("a")
        backend.planId = "max"
        backend.holdsPage = true
        let cache = Self.makeCache(backend)

        #expect(cache.refresh())
        while !backend.isHoldingPage { await Task.yield() }

        // Account B signs in while A's list request is still in flight.
        backend.scope = Self.scope("b")
        backend.planId = "pro"
        backend.holdsPage = false
        let bData = await cache.data()
        backend.release.continuation.yield(())
        for _ in 0..<10 { await Task.yield() }

        #expect(bData?.plan?.planId == "pro")
        #expect(cache.readyData?.plan?.planId == "pro")
    }
    @Test func sizesAreReadyWhileNetworkPresetsAreStillLoading() async {
        let releaseCatalog = AsyncStream<Void>.makeStream()
        defer { releaseCatalog.continuation.finish() }
        let account = Self.scope("first-open")
        var pageFetches = 0
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                pageFetches += 1
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: {
                for await _ in releaseCatalog.stream { break }
                return Self.catalog
            }
        )
        let data = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(data?.limits?.memoryOptionsMb == [4096, 8192])
        #expect(cache.readyData != nil)
        #expect(data?.catalog == nil)
        _ = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(pageFetches == 1)
    }

    @Test func machineListWithoutLimitsIsNotAReadyPlan() async {
        let account = Self.scope("missing-plan")
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: { VMListPage(vms: []) },
            fetchCatalog: { Self.catalog }
        )
        _ = await cache.data()
        #expect(cache.readyData == nil)
        #expect(cache.currentData?.hasPlan == false)
    }

    @Test func enablingCloudPreloadsBeforeFirstPresentation() async {
        let backend = Backend()
        backend.scope = Self.scope("enable")
        let center = NotificationCenter()
        var enabled = false
        let delivered = AsyncStream<Void>.makeStream()
        let cache = NewMachineSheetDataCache(
            currentScope: { backend.scope },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                backend.pageFetches += 1
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: { Self.catalog },
            notificationCenter: center,
            isCloudEnabled: { enabled }
        )
        let listener = cache.addListener { data in
            if data.hasPlan { delivered.continuation.yield(()) }
        }
        defer {
            cache.removeListener(listener)
            delivered.continuation.finish()
        }
        cache.start()
        #expect(backend.pageFetches == 0)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        for await _ in delivered.stream { break }
        #expect(cache.readyData?.limits?.memoryOptionsMb == [4096, 8192])
        let firstOpen = await cache.data()
        #expect(firstOpen?.hasPlan == true)
        #expect(backend.pageFetches == 1)
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(cache.readyData == nil)
    }

    @Test func failedPlanCanRetryWhileCatalogIsPending() async {
        let releaseCatalog = AsyncStream<Void>.makeStream()
        defer { releaseCatalog.continuation.finish() }
        let account = Self.scope("retry-plan")
        var attempts = 0
        let cache = NewMachineSheetDataCache(
            currentScope: { account },
            scopes: { AsyncStream { $0.finish() } },
            fetchPage: {
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return VMListPage(vms: [], limits: VMPlanLimits(
                    planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192]
                ))
            },
            fetchCatalog: {
                for await _ in releaseCatalog.stream { break }
                return Self.catalog
            }
        )
        let first = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(first?.hasPlan != true)
        let second = await cache.data(waitingAtMost: .milliseconds(100))
        #expect(second?.limits?.memoryOptionsMb == [4096, 8192])
        #expect(attempts == 2)
    }

}
