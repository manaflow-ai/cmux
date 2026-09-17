import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxSocketEventMapperTests {
    @Test
    func paneResizeEventDistinguishesAppliedFromRemoteRequested() {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let command = #"{"id":1,"method":"pane.resize","params":{"direction":"right","amount":10}}"#
        let localResponse = #"{"id":1,"ok":true,"result":{"pane_id":"local-pane"}}"#
        let remoteResponse = #"{"id":1,"ok":true,"result":{"pane_id":"remote-pane","remote":true}}"#

        CmuxSocketEventMapper.publish(command: command, response: localResponse)
        CmuxSocketEventMapper.publish(command: command, response: remoteResponse)

        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == [
            "pane.resized",
            "pane.resize_requested",
        ])
        #expect(events.compactMap { $0["pane_id"] as? String } == [
            "local-pane",
            "remote-pane",
        ])
    }
}
