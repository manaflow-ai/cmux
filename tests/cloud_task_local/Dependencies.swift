import Foundation

// Standalone collaborators for the real CloudOperationContext/Recorder. These
// replace unrelated UI, auth and network dependencies, never task-local binding.
struct VMRequestTraceContext {
    let traceId: String
    let spanId: String

    static func mint() -> Self {
        Self(traceId: UUID().uuidString, spanId: UUID().uuidString)
    }
}

enum CloudDiagnosticFailure: String, Codable, Sendable, Error {
    case cancelled, timeout, network, unknown

    static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        return error as? Self ?? .unknown
    }

    static func classify(status: Int) -> Self { .unknown }
}

enum CloudDiagnosticReport {
    static func operationText(_ operation: CloudOperationSnapshot) -> String {
        operation.reference
    }
}

extension Notification.Name {
    static let cmuxCloudVMAccessDidEnd = Notification.Name("test.cloud.accessDidEnd")
}
