import Network
import SwiftUI

@main
struct CmuxNextPhoneApp: App {
    @State private var model = AppModel()
    @State private var network = NetworkWatcher()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onOpenURL { model.pair(link: $0.absoluteString) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.becameActive()
                    case .background: model.enteredBackground()
                    default: break
                    }
                }
                .onAppear { network.start { model.networkChanged() } }
        }
    }
}

/// Reports interface changes (Wi-Fi to cellular, a new Wi-Fi network) so
/// the WireGuard link rebinds its UDP socket and handshakes at once.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var last: String?

    func start(_ changed: @escaping @MainActor () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = path.availableInterfaces.map(\.name).joined(separator: ",") + "\(path.status)"
            Task { @MainActor in
                guard let self else { return }
                if let last = self.last, last != signature { changed() }
                self.last = signature
            }
        }
        monitor.start(queue: DispatchQueue(label: "cmux.next.network"))
    }
}
