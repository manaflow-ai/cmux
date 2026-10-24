import CNMBackend
import CNMHost
import CNMHostRuntime
import ServiceManagement
import SwiftUI

/// Menu bar app: pairs this Mac with the iPhone app and keeps it reachable.
@main
struct CmuxNextHostApp: App {
    @State private var runtime = HostRuntime(
        environment: HostEnvironment(),
        backend: BackendClient(),
        name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    )

    var body: some Scene {
        MenuBarExtra {
            HostMenu(runtime: runtime)
        } label: {
            Image(systemName: runtime.phones > 0 ? "iphone.radiowaves.left.and.right" : "iphone")
        }
        .menuBarExtraStyle(.window)

        // First run: the code in a real window, so nobody has to find the
        // menu bar icon to pair. It closes itself once the Mac is paired.
        Window("Pair with your iPhone", id: "pairing") {
            PairingWindow(runtime: runtime)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(runtime.identity == nil ? .presented : .suppressed)
    }
}

