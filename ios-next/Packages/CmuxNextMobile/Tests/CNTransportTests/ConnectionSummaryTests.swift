import CNCore
import CNSettingsUI
import CNTransport
import Testing

@Suite struct ConnectionSummaryTests {
    let offline = HostRecord(id: "h_1", name: "cmux15", os: "macOS", online: false, lastSeenAt: 1, createdAt: 1)

    @Test func offlineHostReplacesReconnecting() {
        let s = ConnectionSummary(.reconnecting(attempt: 7, lastError: "timed out"), host: offline)
        #expect(s.title == "cmux15 is offline")
        #expect(s.tone == .bad)
        #expect(!s.compact.contains("Attempt"))
    }

    @Test func reconnectingNeverShowsAttemptCount() {
        let s = ConnectionSummary(.reconnecting(attempt: 5, lastError: nil), host: nil)
        #expect(s.title == "Reconnecting")
        #expect(s.detail == nil)
    }

    @Test func connectedIgnoresStalePresence() {
        let s = ConnectionSummary(.connected(PathInfo(transport: "webrtc", localCandidate: .host, remoteCandidate: .host, rttMs: 3)), host: offline)
        #expect(s.title == "Direct (LAN)")
    }
}
