import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct RemoteTmuxCapabilitiesTests {
    @Test func remoteTmuxDefaultsEnabledWhenUnset() {
        let key = SettingCatalog().betaFeatures.remoteTmux.userDefaultsKey
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        #expect(RemoteTmuxController.isEnabled)
    }

    @Test func systemCapabilitiesAdvertisesRemoteTmuxMethods() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let response = try Self.decodeResponse(responseText)
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

    @Test func disabledRemoteTmuxErrorExplainsLocalBetaGate() throws {
        let key = SettingCatalog().betaFeatures.remoteTmux.userDefaultsKey
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"remote.tmux.window","params":{"host":"cmux-lawrence"}}"#
        let response = try Self.decodeResponse(TerminalController.shared.handleSocketLine(request))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "disabled")

        let message = try #require(error["message"] as? String)
        #expect(message.contains("local cmux app"))
        #expect(message.contains("Settings > Beta Features > Remote tmux"))
        #expect(message.contains("No SSH connection was attempted"))
        #expect(message.contains("does not mean tmux is missing"))
    }

    private static func decodeResponse(_ responseText: String) throws -> [String: Any] {
        let responseData = try #require(responseText.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }
}
