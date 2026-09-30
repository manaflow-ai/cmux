import CmuxCloud
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudActivationCoordinatorTests {

    @Test("Tagged debug reload preserves the Cloud activation marker")
    func taggedDebugReloadPreservesActivation() throws {
        let suite = "cmux.cloud.activation.reload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudActivationCoordinator.activationKey)
        let capability = CmuxFeatureFlagOverrideCapability(
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )
        _ = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: capability,
            remoteFlagValueProvider: { _ in false }
        )
        #expect(defaults.bool(forKey: CloudActivationCoordinator.activationKey))

        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            isAvailable: { true },
            prepare: {}
        )
        #expect(coordinator.state == .enabled)
    }

    @Test("A rollout change during setup cannot commit activation")
    func availabilityFlipDuringActivation() async throws {
        let suite = "cmux.cloud.activation.availabilityFence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        var available = true
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { available },
            prepare: {
                started.continuation.yield(())
                await withCheckedContinuation { release = $0 }
            }
        )

        coordinator.enable()
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        available = false
        release?.resume()
        await coordinator.waitForActivation()
        #expect(coordinator.state == .unavailable)
        #expect(!defaults.bool(forKey: CloudActivationCoordinator.activationKey))
    }

    @Test("A failed activation stays actionable when the Cloud tab is reopened")
    func failedActivationPersistsAcrossReconcile() async throws {
        let suite = "cmux.cloud.activation.reconcile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        let center = NotificationCenter()
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: center,
            isAvailable: { true },
            prepare: { throw VMClientError.backendUnreachable(url: "https://cloud.invalid", detail: "fixture") }
        )

        coordinator.enable()
        await coordinator.waitForActivation()
        #expect(coordinator.state == .failed(.serviceUnavailable))
        coordinator.reconcile()
        #expect(coordinator.state == .failed(.serviceUnavailable))
        #expect(!defaults.bool(forKey: CloudActivationCoordinator.activationKey))
    }

    @Test("Cancellation serializes cleanup before a replacement attempt")
    func cancellationFencesReplacement() async throws {
        let suite = "cmux.cloud.activation.cancelFence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        let firstStarted = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        var firstRelease: CheckedContinuation<Void, Never>?
        var secondRelease: CheckedContinuation<Void, Never>?
        var prepareCalls = 0
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { true },
            prepare: {
                prepareCalls += 1
                if prepareCalls == 1 {
                    firstStarted.continuation.yield(())
                    await withCheckedContinuation { firstRelease = $0 }
                } else {
                    secondStarted.continuation.yield(())
                    await withCheckedContinuation { secondRelease = $0 }
                }
            }
        )

        coordinator.enable()
        var firstIterator = firstStarted.stream.makeAsyncIterator()
        _ = await firstIterator.next()
        coordinator.cancel()
        #expect(coordinator.state == .cancelled)
        coordinator.retry()
        #expect(coordinator.state == .enabling)
        await Task.yield()
        #expect(prepareCalls == 1)

        // The replacement waits for the cancelled attempt to unwind, so the
        // two setup owners can never overlap.
        firstRelease?.resume()
        var secondIterator = secondStarted.stream.makeAsyncIterator()
        _ = await secondIterator.next()
        #expect(prepareCalls == 2)
        secondRelease?.resume()
        await coordinator.waitForActivation()
        #expect(coordinator.state == .enabled)
        #expect(defaults.bool(forKey: CloudActivationCoordinator.activationKey))
    }

    @Test("Resetting the legacy marker stops Cloud and notifies runtime owners")
    func markerRemovalReconcilesRuntime() throws {
        let suite = "cmux.cloud.activation.reset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudActivationCoordinator.activationKey)
        let center = NotificationCenter()
        var changes = 0
        let token = center.addObserver(
            forName: RightSidebarBetaFeatureSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in changes += 1 }
        defer { center.removeObserver(token) }
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: center,
            isAvailable: { true },
            prepare: {}
        )

        defaults.removeObject(forKey: CloudActivationCoordinator.activationKey)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(coordinator.state == .disabled)
        #expect(changes == 1)
    }

}
