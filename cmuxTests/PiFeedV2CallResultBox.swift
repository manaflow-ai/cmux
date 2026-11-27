#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Safety: one socket worker writes once, and the test reads only after its continuation resumes.
final class PiFeedV2CallResultBox: @unchecked Sendable {
    var value: TerminalController.V2CallResult?
}
