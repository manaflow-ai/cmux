#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentHibernationController {
    nonisolated static func processFallbackFingerprint(
        kind: RestorableAgentKind,
        sessionId: String,
        processIDs: Set<Int>
    ) -> String {
        "process:\(kind.rawValue):\(sessionId):\(processIDs.sorted().map(String.init).joined(separator: ","))"
    }
}
