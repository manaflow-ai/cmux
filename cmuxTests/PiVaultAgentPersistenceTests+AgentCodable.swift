import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - SessionAgent codable & equality
extension PiVaultAgentPersistenceTests {
    func testRegisteredSessionAgentCodablePreservesPresentation() throws {
        let encoded = try JSONEncoder().encode(
            SessionAgent.registered(RegisteredSessionAgent(
                id: "acme-agent",
                name: "Acme Agent",
                iconAssetName: "AgentIcons/Acme"
            ))
        )

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        guard case .registered(let agent) = decoded else {
            return XCTFail("Expected registered agent")
        }
        XCTAssertEqual(agent.id, "acme-agent")
        XCTAssertEqual(agent.name, "Acme Agent")
        XCTAssertEqual(agent.iconAssetName, "AgentIcons/Acme")
    }

    func testBuiltInIDWithRegisteredMetadataDecodesAsRegisteredAgent() throws {
        let encoded = Data(#"{"id":"grok","name":"Custom Grok","iconAssetName":"AgentIcons/CustomGrok"}"#.utf8)

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        guard case .registered(let agent) = decoded else {
            return XCTFail("Expected legacy registered Grok metadata to be preserved")
        }
        XCTAssertEqual(agent.id, "grok")
        XCTAssertEqual(agent.name, "Custom Grok")
        XCTAssertEqual(agent.iconAssetName, "AgentIcons/CustomGrok")
    }

    func testBuiltInIDWithoutRegisteredMetadataDecodesAsBuiltInAgent() throws {
        let encoded = Data(#"{"id":"grok"}"#.utf8)

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        XCTAssertEqual(decoded, .grok)
    }

    func testRegisteredSessionAgentEqualityIncludesPresentation() {
        XCTAssertNotEqual(
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Acme Agent")),
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Renamed Agent"))
        )
        XCTAssertEqual(
            Set([
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Acme")),
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Renamed")),
            ]).count,
            2
        )
    }

}
