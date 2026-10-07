import CmuxiOSFeatureKit
import Foundation

/// The result of validating one Cloud VM dial before a carrier is opened.
/// No credential is retained in this value; the caller must mint a fresh
/// one-shot token for the VM hello after choosing a carrier.
public struct CloudAttachPlan: Hashable, Sendable {
    public var info: CloudConnectInfo
    public var service: CloudConnectInfo.Service

    public init(info: CloudConnectInfo, service: CloudConnectInfo.Service) {
        self.info = info
        self.service = service
    }
}
