import CMUXMobileCore
import SwiftUI
import cmuxFeature

@main
struct cmuxApp: App {
    private static let runtime: CMUXMobileRuntime = {
        #if targetEnvironment(simulator)
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
            CMUXMobileAppView(store: CMUXMobileShellStore(runtime: Self.runtime))
        }
    }
}
