import Foundation

/// What the device and account look like right now. Steps whose condition
/// is already met (signed in, permission answered, a Mac paired) do not show.
public struct OnboardingContext: Hashable, Sendable {
    public var isSignedIn: Bool
    public var notifications: PermissionStatus
    public var localNetwork: PermissionStatus
    public var camera: PermissionStatus
    /// A Mac other than this device is trusted on the account.
    public var hasTrustedMac: Bool
    public var mode: OnboardingMode
    /// The Cloud step is on (flag) and the app registered a create hook (C12).
    public var offersCloudMachine: Bool
    /// The keep-awake card is on (flag) and the app registered its hook (E5).
    public var offersKeepAwake: Bool

    public init(
        isSignedIn: Bool = false, notifications: PermissionStatus = .notDetermined,
        localNetwork: PermissionStatus = .notDetermined, camera: PermissionStatus = .notDetermined,
        hasTrustedMac: Bool = false, mode: OnboardingMode = .firstRun, offersCloudMachine: Bool = false,
        offersKeepAwake: Bool = false
    ) {
        self.isSignedIn = isSignedIn
        self.notifications = notifications
        self.localNetwork = localNetwork
        self.camera = camera
        self.hasTrustedMac = hasTrustedMac
        self.mode = mode
        self.offersCloudMachine = offersCloudMachine
        self.offersKeepAwake = offersKeepAwake
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .notifications: notifications
        case .localNetwork: localNetwork
        case .camera: camera
        }
    }

    public mutating func setStatus(_ status: PermissionStatus, of kind: PermissionKind) {
        switch kind {
        case .notifications: notifications = status
        case .localNetwork: localNetwork = status
        case .camera: camera = status
        }
    }
}
