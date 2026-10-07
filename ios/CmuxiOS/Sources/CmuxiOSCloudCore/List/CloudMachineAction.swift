import Foundation

/// A lifecycle action a row offers. Resume is `cloud.machine.start`.
public enum CloudMachineAction: String, Hashable, Sendable, CaseIterable {
    case resume
    case pause
    case delete

    /// Delete asks for confirmation first.
    public var isDestructive: Bool { self == .delete }
}
