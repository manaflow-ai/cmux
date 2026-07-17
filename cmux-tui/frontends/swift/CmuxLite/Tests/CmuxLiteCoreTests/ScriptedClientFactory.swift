@testable import CmuxLiteCore

actor ScriptedClientFactory: CmuxProtocolClientFactory {
    private var transports: [ScriptedTransport]

    init(transports: [ScriptedTransport]) {
        self.transports = transports
    }

    func makeClient() -> CmuxProtocolClient {
        precondition(!transports.isEmpty, "scripted attachment client exhausted")
        return CmuxProtocolClient(transport: transports.removeFirst())
    }
}
