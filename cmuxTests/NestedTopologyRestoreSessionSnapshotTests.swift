import Foundation
import Testing
import CmuxNestedTopology

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// App-level Codable coverage for PR6 nested attachment intent on session panels.
@Suite struct NestedTopologyRestoreSessionSnapshotTests {
    @Test func olderPanelSnapshotWithoutNestedIntentStillDecodes() throws {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "type": "terminal",
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": [] as [Int],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        #expect(decoded.nestedAttachmentIntent == nil)
        #expect(decoded.type == .terminal)
    }

    @Test func nestedAttachmentIntentRoundTripsOnSessionPanelSnapshot() throws {
        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .autoIfProviderInstanceMatches,
            endpointLocator: NestedAttachmentEndpointLocator(socketPath: "/tmp/cmux-herdr.sock"),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "durable-abc"),
            providerInstanceIdentityProofAvailable: true,
            lastVerifiedFileIdentity: NestedUnixSocketFileIdentity(deviceID: 3, inode: 4)
        )
        let snapshot = SessionPanelSnapshot(
            id: UUID(),
            stableSurfaceId: UUID(),
            type: .terminal,
            title: "term",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            nestedAttachmentIntent: intent
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)
        #expect(decoded.nestedAttachmentIntent == intent)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = try #require(object["nestedAttachmentIntent"] as? [String: Any])
        let keys = NestedAttachmentIntentDescriptor.collectJSONKeys(nested)
        for forbidden in NestedAttachmentIntentDescriptor.forbiddenPersistenceKeys {
            #expect(keys.contains(forbidden) == false)
        }
        #expect(nested["token"] == nil)
        #expect(nested["latest_snapshot"] == nil)
        #expect(nested["associations"] == nil)
    }

    @Test func sessionPanelSnapshotDoesNotPersistLiveTopologyFromIntent() throws {
        // Even if a caller stuffed a live-looking intent, encoding must stay intent-only.
        let intent = NestedAttachmentIntentDescriptor(
            providerKind: .herdr,
            reattachPolicy: .requireConfirmation,
            endpointLocator: NestedAttachmentEndpointLocator(socketPath: "/tmp/x.sock"),
            lastVerifiedProviderInstanceID: NestedProviderInstanceID(rawValue: "minted-not-proof"),
            providerInstanceIdentityProofAvailable: false
        )
        #expect(intent.allowsUnattendedAutoReattach == false)
        let data = try JSONEncoder().encode(intent)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("workspaces") == false)
        #expect(text.contains("bearer") == false)
        #expect(text.contains("association") == false)
    }
}
