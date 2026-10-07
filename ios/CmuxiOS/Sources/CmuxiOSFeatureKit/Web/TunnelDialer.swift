/// Opens tunnel streams to `localhost:<port>` of one machine (a paired Mac
/// or an SSH host). The machine decides which ports it accepts.
public protocol TunnelDialer: Sendable {
    func dial(port: UInt16) async throws -> any TunnelStream
}
