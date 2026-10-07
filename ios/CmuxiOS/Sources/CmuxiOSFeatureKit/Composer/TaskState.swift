import Foundation

/// A task's lifecycle state, written only by the Mac's task runner.
public enum TaskState: String, Hashable, Sendable, Codable {
    case queued
    case running
    case needsInput = "needs_input"
    case done
    case failed

    public var isFinished: Bool { self == .done || self == .failed }
}
