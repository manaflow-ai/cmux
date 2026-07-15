import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxCapabilitiesTests {
    @MainActor
    private func response(for method: String) throws -> [String: Any] {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    @MainActor
    private func advertisedMethods() throws -> Set<String> {
        let response = try response(for: "system.capabilities")
        let result = try #require(response["result"] as? [String: Any])
        return Set(try #require(result["methods"] as? [String]))
    }

    @MainActor
    @Test func systemCapabilitiesAdvertisesRemoteTmuxMethods() throws {
        let advertisedMethods = try advertisedMethods()

        #expect([
            "remote.tmux.sessions",
            "remote.tmux.attach",
            "remote.tmux.detach",
            "remote.tmux.state",
            "remote.tmux.mirror",
            "remote.tmux.window",
        ].allSatisfy { advertisedMethods.contains($0) })
    }

    @MainActor
    @Test func systemCapabilitiesAgreeWithDispatchForTerminalHierarchyMutations() throws {
        let advertisedMethods = try advertisedMethods()

        for method in [
            "mobile.terminal.close",
            "mobile.terminal.reorder",
            "terminal.close",
            "terminal.reorder",
        ] {
            let methodResponse = try response(for: method)
            let error = methodResponse["error"] as? [String: Any]
            let isDispatched = error?["code"] as? String != "method_not_found"
            #expect(
                advertisedMethods.contains(method) == isDispatched,
                "system.capabilities must advertise \(method) exactly when the local control socket dispatches it"
            )
        }

        #expect(MobileHostService.mobileHostCapabilities.contains("terminal.close.v1"))
        #expect(MobileHostService.mobileHostCapabilities.contains("terminal.reorder.v1"))
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

        #expect(
            code == "disabled" || code == "invalid_params",
            "Expected a network-free guard for \(method), got \(code)"
        )
    }
}
