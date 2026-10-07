import Foundation

/// The write side of the diagnostic log that feature modules depend on.
/// `record` returns at once from any thread; it never does I/O on the caller.
public protocol DiagnosticRecording: Sendable {
    func record(_ level: DiagnosticLevel, category: String, _ message: String)
}

extension DiagnosticRecording {
    public func info(_ category: String, _ message: String) { record(.info, category: category, message) }
    public func warning(_ category: String, _ message: String) { record(.warning, category: category, message) }
    public func error(_ category: String, _ message: String) { record(.error, category: category, message) }
}
