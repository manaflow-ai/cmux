import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudProviderRefreshCoordinatorTests {
    @Test("Concurrent catalog reads cannot supersede the initial graph publication")
    func concurrentReadersShareTheFirstPublication() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let joining = CloudLinkFirstValue<Bool>()
        var generation = 0
        let operation: @MainActor (Bool) async -> Bool = { _ in
            generation += 1
            let mine = generation
            started.resolve(true)
            _ = await release.result
            return mine == generation
        }
        let first = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let second = Task {
            joining.resolve(true)
            return await coordinator.refresh(force: false, operation: operation)
        }
        _ = await joining.result
        #expect(generation == 1)
        release.resolve(true)
        #expect(await first.value)
        #expect(await second.value)
    }

    @Test("Forced reads queued during a snapshot share one later forced pass")
    func forcedReadersWaitForAReadStartedAfterTheirRequest() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let firstWaiting = CloudLinkFirstValue<Bool>()
        let secondWaiting = CloudLinkFirstValue<Bool>()
        var forces: [Bool] = []
        let operation: @MainActor (Bool) async -> Bool = { force in
            forces.append(force)
            started.resolve(true)
            _ = await release.result
            return true
        }
        let background = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let first = Task {
            firstWaiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await firstWaiting.result
        let second = Task {
            secondWaiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await secondWaiting.result
        #expect(forces == [false])
        release.resolve(true)
        #expect(await background.value)
        #expect(await first.value)
        #expect(await second.value)
        #expect(forces == [false, true])
    }

    @Test("A metadata change restarts an invalidated pass before releasing its readers")
    func invalidatedPassFinishesWithTheCurrentGraph() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var calls = 0
        let read = Task {
            await coordinator.refresh(force: true) { _ in
                calls += 1
                if calls == 1 {
                    started.resolve(true)
                    _ = await release.result
                    return false
                }
                return true
            }
        }
        _ = await started.result
        coordinator.invalidate()
        release.resolve(true)
        #expect(await read.value)
        #expect(calls == 2)
    }

    @Test("Retiring a provider cancels its current pass and queued forced readers")
    func cancellationRetiresQueuedRequests() async {
        let coordinator = CloudProviderRefreshCoordinator()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let waiting = CloudLinkFirstValue<Bool>()
        var calls = 0
        let operation: @MainActor (Bool) async -> Bool = { _ in
            calls += 1
            started.resolve(true)
            _ = await release.result
            return true
        }
        let first = Task { await coordinator.refresh(force: false, operation: operation) }
        _ = await started.result
        let forced = Task {
            waiting.resolve(true)
            return await coordinator.refresh(force: true, operation: operation)
        }
        _ = await waiting.result
        coordinator.cancel()
        release.resolve(true)
        #expect(await first.value == false)
        #expect(await forced.value == false)
        #expect(calls == 1)
    }
}
