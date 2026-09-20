import Foundation
import Testing

struct CloudTuiSwiftSDKTests {
    @Test("typed presence command encodes the canonical wire shape")
    func typedPresenceCommandEncodesWireShape() throws {
        let anchor = CloudTuiGenerated.PresenceAnchor.cell(
            CloudTuiGenerated.PresenceAnchorCell(
                col: 4,
                row: 6,
                scrollOffset: .value(2)
            )
        )
        let request = CloudTuiGenerated.PresenceUpdateRequest(
            highlight: .missing,
            pointer: .value(anchor),
            surface: 42
        )
        let line = try CloudTuiGenerated.Command.presenceUpdate(id: 7, request: request).line()
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["cmd"] as? String == "presence-update")
        #expect(object["id"] as? NSNumber == 7)
        #expect(object["surface"] as? NSNumber == 42)
        #expect((object["pointer"] as? [String: Any])?["kind"] as? String == "cell")
        #expect((object["pointer"] as? [String: Any])?["scroll_offset"] as? NSNumber == 2)
        #expect(object["highlight"] == nil)
    }

    @Test("typed event decoder preserves nullable presence cleanup")
    func typedPresenceEventDecodesCleanup() throws {
        let data = Data(
            #"{"event":"presence-changed","client":11,"name":null,"kind":null,"color":3,"surface":null,"pointer":null,"highlight":null,"updated_at_ms":4,"generation":9}"#.utf8
        )
        let event = try JSONDecoder().decode(CloudTuiGenerated.Event.self, from: data)
        guard case .presenceChanged(let payload) = event else {
            Issue.record("expected presence-changed event")
            return
        }
        #expect(payload.client == 11)
        #expect(payload.surface == nil)
        #expect(payload.pointer == nil)
        #expect(payload.highlight == nil)
        #expect(payload.generation == 9)
    }
}
