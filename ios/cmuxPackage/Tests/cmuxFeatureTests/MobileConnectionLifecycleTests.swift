import CMUXMobileCore
import Foundation
import Testing
import UIKit
@testable import cmuxFeature

@MainActor
@Suite struct MobileConnectionLifecycleTests {
    @Test func eachForegroundPeriodRequiresActivation() async {
        let center = NotificationCenter()
        var state = UIApplication.State.active
        let readiness = MobileConnectionLifecycle(notificationCenter: center,
            applicationState: { state }, protectedDataAvailable: { true })
        var updates = readiness.changes().makeAsyncIterator()
        #expect(await updates.next() == true)

        state = .background
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(await updates.next() == false)
        state = .inactive
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(await updates.next() == false,
                "an earlier foreground period must not authorize a dial before new activation")
        #expect(!readiness.permitsConnection)

        state = .active
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await updates.next() == true)
        state = .inactive
        #expect(readiness.permitsConnection,
                "transient inactivity within this activated period still permits connections")
    }

    @Test func backgroundLaunchWaitsForForegroundAndProtectedData() async throws {
        let center = NotificationCenter()
        var state = UIApplication.State.background
        var protectedData = false
        let readiness = MobileConnectionLifecycle(notificationCenter: center,
                                                applicationState: { state },
                                                protectedDataAvailable: { protectedData })
        let factory = try CmxRouteTransportFactory([])
        let runtime = CMUXMobileRuntime(transportFactory: factory, connectionReadiness: readiness)
        #expect(runtime.connectionReadiness != nil, "the production route-aware initializer must retain readiness")
        var updates = readiness.changes().makeAsyncIterator()
        #expect(await updates.next() == false)
        protectedData = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(await updates.next() == false, "unlock alone must not dial from the background")
        state = .active
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(await updates.next() == true)
        state = .inactive
        #expect(readiness.permitsConnection, "a transient foreground interruption must not retire the owner")
        center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        #expect(await updates.next() == false)
        protectedData = false
        #expect(!readiness.permitsConnection)
        protectedData = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        #expect(await updates.next() == true)
    }
}
