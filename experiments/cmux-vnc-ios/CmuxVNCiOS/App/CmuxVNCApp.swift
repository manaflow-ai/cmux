import SwiftUI

/// cmux VNC on iOS: a demo of how VNC streaming would feel in the future
/// cmux iOS app, on the same `CmuxVNC` engine the cmux-next Mac app uses.
@main
struct CmuxVNCApp: App {
    @State private var hosts = HostStore()

    var body: some Scene {
        WindowGroup {
            ConnectionsView()
                .environment(hosts)
                .onAppear { Snapshotter().start() }
        }
    }
}
