import Foundation
import Testing
@testable import CnxTransport

@Suite struct DaemonClientTests {
    @Test func repliesRouteByIDAndEventsStream() async throws {
        let link = MockMacLink { _, request in
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let event = Data(#"{"event":"tree.changed"}"#.utf8) + Data([0x0A])
            // Reply split across two chunks to exercise line buffering.
            let reply = Data(#"{"id":"\#(id)","ok":true,"data":{"cmd":"\#(object["cmd"]!)"}}"#.utf8) + Data([0x0A])
            return [event, reply.prefix(10), reply.dropFirst(10)]
        }
        let channel = try await link.openChannel(service: "daemon", args: [:])
        let client = DaemonClient(channel: channel)
        let reply = try await client.request("identify")
        let object = try JSONSerialization.jsonObject(with: reply) as! [String: Any]
        #expect(object["ok"] as? Bool == true)
        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event.map { String(decoding: $0, as: UTF8.self) } == #"{"event":"tree.changed"}"#)
    }
}
