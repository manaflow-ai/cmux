import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class DeviceRouteTestAuthorization: DeviceLinkAuthorizationSource {
    var evidence: CmxLegacyTailscaleAuthorizationEvidence?
    var pairedDevices: [DevicePairedDevice] { [] }
    let authorizationDidChangeNotification = Notification.Name("DeviceRouteTestAuthorization")

    init(evidence: CmxLegacyTailscaleAuthorizationEvidence?) { self.evidence = evidence }

    func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? {
        evidence
    }
}
