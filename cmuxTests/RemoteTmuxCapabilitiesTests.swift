import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxCapabilitiesTests {
    @Test func systemCapabilitiesAdvertisesRemoteTmuxMethods() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        let methods = try #require(result["methods"] as? [String])
        let advertisedMethods = Set(methods)

        #expect([
            "remote.tmux.sessions",
            "remote.tmux.attach",
            "remote.tmux.detach",
            "remote.tmux.state",
            "remote.tmux.mirror",
            "remote.tmux.window",
        ].allSatisfy { advertisedMethods.contains($0) })
    }

    /// Requests without a host must fail a network-free guard, never dispatch as
    /// unknown methods or touch SSH. This covers both placement entry points.
    @Test(arguments: ["remote.tmux.mirror", "remote.tmux.window"])
    func mirrorWithoutHostReturnsStructuredErrorBeforeNetwork(method: String) throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        let code = try #require(error["code"] as? String)

        #expect(code == "disabled" || code == "invalid_params")
    }
}
