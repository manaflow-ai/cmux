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
            "remote.tmux.attach_here",
            "remote.tmux.mirror",
            "remote.tmux.window",
        ].allSatisfy { advertisedMethods.contains($0) })
    }

    /// Regression guard for `remote.tmux.attach_here`: sending a request with no
    /// `host` param must fail one of the two network-free guards in
    /// `v2RemoteTmuxAttachHere` (beta-gate or param validation) - never dispatch
    /// as an unknown method, and never touch the network. This proves the method
    /// stays registered/dispatched and keeps validating before SSH regardless of
    /// which way the `remoteTmux.beta.enabled` flag happens to be set in the test
    /// environment.
    @Test(arguments: ["remote.tmux.attach_here", "remote.tmux.mirror"])
    func attachHereWithoutHostReturnsStructuredErrorBeforeNetwork(method: String) throws {
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
