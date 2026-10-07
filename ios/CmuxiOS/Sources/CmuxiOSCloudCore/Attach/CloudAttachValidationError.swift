import CmuxiOSFeatureKit

public enum CloudAttachValidationError: Error, Hashable, Sendable {
    case invalidIdentity
    case machineMismatch
    case hostMismatch
    case invalidEpoch
    case invalidPeer
    case unavailable(CloudMachineStatus)
    case serviceUnavailable(CloudConnectInfo.Service)
}
