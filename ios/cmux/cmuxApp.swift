import CMUXMobileCore
import SwiftUI
import cmuxFeature

@main
struct cmuxApp: App {
    private static let runtime: CMUXMobileRuntime = {
        // `debugLoopback` (127.0.0.1) backs the UI-test mock Mac. Enable it on
        // the simulator and on DEBUG device builds so on-device XCUITests can
        // attach to an in-runner mock host; release device builds keep only
        // real transports.
        #if targetEnvironment(simulator) || DEBUG
        let supportedKinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = [.tailscale]
        #endif
        let networkFactory = CmxNetworkByteTransportFactory(supportedKinds: supportedKinds)
        let registrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(
                kind: kind,
                factory: networkFactory
            )
        }
        let transportFactory: CmxRouteTransportFactory
        do {
            transportFactory = try CmxRouteTransportFactory(registrations)
        } catch {
            preconditionFailure("Invalid mobile transport registrations: \(error)")
        }
        return CMUXMobileRuntime(transportFactory: transportFactory)
    }()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
                MobileZoomStressView()
            } else {
                CMUXMobileAppView(store: CMUXMobileShellStore(runtime: Self.runtime))
            }
            #else
            CMUXMobileAppView(store: CMUXMobileShellStore(runtime: Self.runtime))
            #endif
        }
    }
}
