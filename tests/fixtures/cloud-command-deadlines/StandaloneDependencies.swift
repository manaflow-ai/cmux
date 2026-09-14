import Foundation

// Only non-command dependencies are stubbed for the standalone process fixture.
// CloudMachineLink.run/runMeasured and its pipe/exit helpers compile unchanged.
enum SurfaceLinkState { case connecting, connected, error, unavailable }
struct CloudVMCursor: Sendable, Equatable {
    let generation: String
    let revision: UInt64
    init?(wire: [String: Any]) { return nil }
}
struct CloudTuiCommandLine {
    static func linkArguments(route: String, deviceName: String, stateDir: String, carrier: Bool, wireguardHubSocket: String?) -> [String] { [] }
    static func eventsArguments(socketPath: String, cursor: CloudVMCursor?) -> [String] { [] }
}
struct CmuxTuiSnapshotParser {
    static func localSocket(fromLinkLine line: String) -> String? { nil }
}
struct CloudWireNumber {
    static func unsigned(_ raw: Any?) -> UInt64? { nil }
}
struct CloudOperationContext {
    enum Phase { case process }
    static func phase<T>(_ phase: Phase, isolation: isolated (any Actor)? = #isolation, _ work: () async throws -> T) async rethrows -> T {
        try await work()
    }
}
