import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CloudBannerDismissalTests: XCTestCase {
    func testPortsVPNWarningProjectionExplainsOptionalSystemRoute() {
        XCTAssertNil(CloudPortsVPNWarning.projection(isVPNConnected: true))
        let warning = CloudPortsVPNWarning.projection(isVPNConnected: false)
        XCTAssertEqual(warning?.title, "Cloud VPN is off")
        XCTAssertTrue(warning?.help.contains("terminals, Ports, and Desktop") == true)
    }

    func testBannerDismissalPersistsUntilSignatureChanges() {
        let suiteName = "cloud-banner-dismissal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store = CloudBannerDismissalStore(defaults: defaults)
        XCTAssertFalse(store.isDismissed(id: "tunnel", signature: "awaiting-v1"))
        store.dismiss(id: "tunnel", signature: "awaiting-v1")

        let reloaded = CloudBannerDismissalStore(defaults: defaults)
        XCTAssertTrue(reloaded.isDismissed(id: "tunnel", signature: "awaiting-v1"))
        XCTAssertFalse(reloaded.isDismissed(id: "tunnel", signature: "connected-v1"))
    }
}
