import Foundation

// The resource actor, socket I/O, framing and request builders compile unchanged.
// Only app-level error and cursor declarations are stubbed for this isolated runner.
enum CloudMachineLink {
    enum LinkError: Error {
        case timedOut
        case inputTooLarge
        case exited(status: Int32, output: String)
    }
}
struct CloudVMCursor: Sendable {
    let generation: String
    let revision: UInt64
}
