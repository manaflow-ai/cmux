import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileHostLifecycleCoordinatorTests {
    @Test func synchronousInvalidationObserverSeesRetirementAndCanReplaceIntent() async {
        let fixture = MobileHostLifecycleFixture()
        let coordinator = fixture.makeCoordinator()
        fixture.onInvalidation = {
            #expect(coordinator.isTransitioning)
            fixture.onInvalidation = nil
            coordinator.request("replacement")
        }
        coordinator.request("original")
        await coordinator.waitForTransition()
        #expect(fixture.retirements == 1)
        #expect(fixture.activations == ["replacement"])
    }

    @Test func repeatedStoppedIntentDoesNoWork() async {
        let fixture = MobileHostLifecycleFixture()
        let coordinator = fixture.makeCoordinator()
        let generation = coordinator.generation
        for _ in 0..<1_000 { coordinator.request(nil) }
        await coordinator.waitForTransition()
        #expect(coordinator.generation == generation)
        #expect(fixture.invalidations == 0)
        #expect(fixture.retirements == 0)
        #expect(fixture.activations.isEmpty)
    }

    @Test func latestIntentWaitsForCleanupWithoutOccupyingTheMainActor() async {
        let fixture = MobileHostLifecycleFixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.request("first")
        await coordinator.waitForTransition()
        let firstGeneration = coordinator.generation
        #expect(fixture.activations == ["first"])

        fixture.holdsRetirement = true
        coordinator.request(nil)
        await fixture.waitForHeldRetirement()
        #expect(coordinator.isTransitioning)
        #expect(coordinator.generation != firstGeneration)

        // Cleanup is causally parked. Every request still runs on MainActor,
        // invalidates old admission immediately, and retains only the final intent.
        for index in 0..<1_000 { coordinator.request("replacement-\(index)") }
        #expect(fixture.retirements == 2)
        #expect(fixture.activations == ["first"])
        #expect(fixture.invalidations == 1_002)
        let finalGeneration = coordinator.generation
        fixture.releaseRetirement()
        await coordinator.waitForTransition()
        #expect(!coordinator.isTransitioning)
        #expect(fixture.activations == ["first", "replacement-999"])
        #expect(fixture.activationGenerations.last == finalGeneration)
        #expect(fixture.retirements == 2)
    }

    @Test func stopWhileRetiringSuppressesAQueuedActivation() async {
        let fixture = MobileHostLifecycleFixture()
        fixture.holdsRetirement = true
        let coordinator = fixture.makeCoordinator()
        coordinator.request("account-a")
        await fixture.waitForHeldRetirement()
        coordinator.request("account-b")
        coordinator.request(nil)
        fixture.releaseRetirement()
        await coordinator.waitForTransition()
        #expect(coordinator.scope == nil)
        #expect(fixture.activations.isEmpty)
        #expect(fixture.retirements == 1)
    }

    @Test func unchangedScopePreservesGenerationUnlessConfigurationRestarts() async {
        let fixture = MobileHostLifecycleFixture()
        let coordinator = fixture.makeCoordinator()
        coordinator.request("account")
        await coordinator.waitForTransition()
        let original = coordinator.generation
        for _ in 0..<1_000 { coordinator.request("account") }
        #expect(coordinator.generation == original)
        #expect(fixture.retirements == 1)
        coordinator.request("account", restart: true)
        await coordinator.waitForTransition()
        #expect(coordinator.generation != original)
        #expect(fixture.retirements == 2)
        #expect(fixture.activations == ["account", "account"])
    }
}
