import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxCapabilitiesTests {
    private func advertisedMethods() throws -> Set<String> {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        return Set(try #require(result["methods"] as? [String]))
    }

    @Test func systemCapabilitiesAdvertisesRemoteTmuxMethods() throws {
        let advertisedMethods = try advertisedMethods()

        #expect([
            "remote.tmux.sessions",
            "remote.tmux.attach",
            "remote.tmux.detach",
            "remote.tmux.state",
            "remote.tmux.mirror",
        ].allSatisfy { advertisedMethods.contains($0) })
    }

    @Test func systemCapabilitiesAdvertisesTerminalHierarchyMutations() throws {
        let advertisedMethods = try advertisedMethods()

        #expect([
            "mobile.terminal.close",
            "mobile.terminal.reorder",
            "terminal.close",
            "terminal.reorder",
        ].allSatisfy { advertisedMethods.contains($0) })
    }
}
