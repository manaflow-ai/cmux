import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct NestedTopologyCapabilitiesTests {
    @Test func systemCapabilitiesAdvertisesNestedTopologyReadAndFocus() throws {
        let defaults = UserDefaults.standard
        let key = "nestedTopology.beta.enabled"
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        let methods = try #require(result["methods"] as? [String])
        #expect(methods.contains("nested.topology.list"))
        #expect(methods.contains("nested.node.focus"))

        let capabilities = try #require(result["capabilities"] as? [String])
        #expect(capabilities.contains("nested_topology.read.v1"))
        #expect(capabilities.contains("nested_topology.focus.v1"))
    }


    @Test func systemCapabilitiesOmitsNestedTopologyWhenBetaOff() throws {
        let defaults = UserDefaults.standard
        let nestedKey = "nestedTopology.beta.enabled"
        let herdrKey = "remoteHerdrMirror.beta.enabled"
        let previousNested = defaults.object(forKey: nestedKey)
        let previousHerdr = defaults.object(forKey: herdrKey)
        defaults.set(false, forKey: nestedKey)
        defaults.set(false, forKey: herdrKey)
        defer {
            if let previousNested {
                defaults.set(previousNested, forKey: nestedKey)
            } else {
                defaults.removeObject(forKey: nestedKey)
            }
            if let previousHerdr {
                defaults.set(previousHerdr, forKey: herdrKey)
            } else {
                defaults.removeObject(forKey: herdrKey)
            }
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        let methods = try #require(result["methods"] as? [String])
        #expect(!methods.contains("nested.topology.list"))
        #expect(!methods.contains("nested.node.focus"))

        let capabilities = try #require(result["capabilities"] as? [String])
        #expect(!capabilities.contains("nested_topology.read.v1"))
        #expect(!capabilities.contains("nested_topology.focus.v1"))
    }

    @Test func nestedTopologyListReturnsDisabledWhenBetaOff() async throws {
        let defaults = UserDefaults.standard
        let key = "nestedTopology.beta.enabled"
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"nested.topology.list","params":{}}"#
        let responseText = await handleSocketLineOffMain(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "disabled")
    }

    @Test func nestedNodeFocusReturnsDisabledWhenBetaOff() async throws {
        let defaults = UserDefaults.standard
        let key = "nestedTopology.beta.enabled"
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let request = """
        {"jsonrpc":"2.0","id":1,"method":"nested.node.focus","params":{"host_surface_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","node_id":{"version":1,"provider_kind":"herdr","provider_instance_id":"x","node_kind":"pane","raw_id":"w1:p1"}}}
        """
        let responseText = await handleSocketLineOffMain(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "disabled")
    }

    @Test func nestedNodeFocusRejectsMissingNodeID() async throws {
        let defaults = UserDefaults.standard
        let key = "nestedTopology.beta.enabled"
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"nested.node.focus","params":{"host_surface_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}"#
        let responseText = await handleSocketLineOffMain(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
    }

    @Test func defaultSystemTreeOmitsNestedKey() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.tree","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        // Default tree must remain compatible: no nested payload unless requested.
        if let result = response["result"] as? [String: Any] {
            #expect(result["nested"] == nil)
        }
    }

    private static let socketWorker = DispatchQueue(label: "cmux.nested-topology.socket-worker")

    private func handleSocketLineOffMain(_ line: String) async -> String {
        let controller = TerminalController.shared
        return await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
    }
}
