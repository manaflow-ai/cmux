import CMUXMobileCore
import SwiftUI
import cmuxMobileFeature

@main
struct cmuxMobileApp: App {
    private static let runtime: CMUXMobileRuntime = {
        #if targetEnvironment(simulator)
        let supportedKinds: [CmxAttachTransportKind] = [.debugLoopback, .tailscale]
        #else
        let supportedKinds: [CmxAttachTransportKind] = [.tailscale]
        #endif
        let registrations = supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(
                kind: kind,
                factory: CmxNetworkByteTransportFactory(supportedKinds: [kind])
            )
        }
        let transportFactory = try! CmxRouteTransportFactory(registrations)
        return CMUXMobileRuntime(transportFactory: transportFactory)
    }()

    var body: some Scene {
        WindowGroup {
            CMUXMobileAppView(store: .preview(runtime: Self.runtime))
        }
    }
}
