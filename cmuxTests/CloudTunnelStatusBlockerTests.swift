import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Nothing the app opens depends on the system-wide VPN (Ports, Desktop, and
/// terminals ride the user-space hub), so an idle tunnel must not be reported
/// as something blocking the user; only an in-flight `cmux vpn up` is.
@Suite
struct CloudTunnelStatusBlockerTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "com.cmuxterm.app.tests.tunnel")

    @Test("an off tunnel blocks nothing and shows no copy")
    func offIsNotABlocker() {
        let status = CloudTunnelStatus(backend: backend, state: .off, isPinned: false)
        #expect(status.privateRouteBlocker == nil)
    }

    @Test("waiting for the extension approval names the System Settings pane")
    func awaitingApprovalNamesThePane() {
        let status = CloudTunnelStatus(backend: backend, state: .awaitingApproval, isPinned: true)
        #expect(status.privateRouteBlocker?.contains("Login Items & Extensions") == true)
    }
}
