import CMUXAuthCore
import CmuxAuthRuntime
import CmuxMobileTransport
import Foundation
import Testing
import UIKit
@testable import cmuxFeature

/// Offline reachability stub for constructing the auth composition in tests.
/// File-scope (not nested in the suite) so it stays nonisolated.
private struct OfflineReachabilityStub: ReachabilityProviding {
    var isOnline: Bool { false }
    func pathChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// `MobileAuthComposition.shutdown()` is the live backend switch's teardown
/// for the OLD auth graph: after it runs, a protected-data availability
/// notification (delivered through the injected notification center) must not
/// reach the graph's revalidation observer anymore.
@MainActor
@Suite struct MobileAuthCompositionShutdownTests {
    @MainActor
    private final class ProtectedDataCallbackRecorder {
        private(set) var callbackCount = 0

        func record() {
            callbackCount += 1
        }
    }

    private func fixtureBundle() throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-auth-shutdown-fixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try #require(Bundle(path: directory.path))
    }

    private func makeComposition(
        notificationCenter: NotificationCenter
    ) throws -> MobileAuthComposition {
        let defaults = try #require(
            UserDefaults(suiteName: "cmux-auth-shutdown-tests-\(UUID().uuidString)")
        )
        return MobileAuthComposition(
            environment: [:],
            bundle: try fixtureBundle(),
            defaults: defaults,
            reachability: OfflineReachabilityStub(),
            policy: .current,
            notificationCenter: notificationCenter
        )
    }

    /// The notification block hops onto the main actor via a `Task`; drain a
    /// bounded number of turns so a delivered callback has run before the
    /// assertion (and an UNdelivered one had every chance to).
    private func drainMainActor() async {
        for _ in 0..<25 {
            await Task.yield()
        }
    }

    @Test func shutdownStopsProtectedDataObservationThroughTheInjectedCenter() async throws {
        let center = NotificationCenter()
        let composition = try makeComposition(notificationCenter: center)
        let recorder = ProtectedDataCallbackRecorder()
        // Install a counting observer through the composition's OWN
        // availability bridge (replacing the production revalidation callback
        // keeps the notification path identical while making delivery
        // observable; `startObserving` swaps the callback atomically).
        composition.protectedDataAvailability.startObserving { [recorder] in
            recorder.record()
        }

        center.post(
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        await drainMainActor()
        #expect(recorder.callbackCount == 1)

        composition.shutdown()

        center.post(
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        await drainMainActor()
        // No revalidation trigger after shutdown: the observer is gone.
        #expect(recorder.callbackCount == 1)
    }

    @Test func shutdownIsIdempotent() throws {
        let composition = try makeComposition(notificationCenter: NotificationCenter())
        composition.shutdown()
        composition.shutdown()
    }
}
