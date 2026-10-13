import CnxModel
import CnxShell
import SwiftUI

@main
struct CnxApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(store: .mock())
        }
    }
}

#if DEBUG
import CnxTransport

/// Keeps the Rust link linked into debug builds so FFI breakage shows at build time.
private let linkDialerProbe: any MacLinkDialer = FFIMacLinkDialer()
#endif
