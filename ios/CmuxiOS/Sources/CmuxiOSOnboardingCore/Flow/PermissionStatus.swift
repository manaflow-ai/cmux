import Foundation

/// A system permission as onboarding needs to know it: priming screens show
/// only while the system has not asked yet.
public enum PermissionStatus: String, Codable, Hashable, Sendable {
    case notDetermined
    case granted
    case denied
}
