import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("HostSettingsActions local tmux")
struct HostSettingsActionsLocalTmuxTests {
    @MainActor
    @Test func decodesAuthoritativeSessionListAndOrdersLiveFirst() throws {
        let managedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let payload: [String: Any] = [
            "sessions": [
                [
                    "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "session_name": "stale",
                    "cwd": "/tmp/stale",
                    "managed": true,
                    "live": false,
                ],
                [
                    "id": managedID.uuidString,
                    "session_name": "work",
                    "cwd": "/Users/test/src/work",
                    "clients": 2,
                    "managed": true,
                    "live": true,
                ],
                [
                    "id": NSNull(),
                    "session_name": "manual",
                    "clients": 0,
                    "managed": false,
                    "live": true,
                ],
            ],
            "count": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let sessions = try HostSettingsActions.decodeLocalTmuxSessions(data)

        #expect(sessions.map(\.name) == ["manual", "work", "stale"])
        #expect(sessions[0].id == "tmux:manual")
        #expect(sessions[0].logicalID == nil)
        #expect(sessions[0].isManaged == false)
        #expect(sessions[1].logicalID == managedID)
        #expect(sessions[1].clientCount == 2)
        #expect(sessions[1].cwd == "/Users/test/src/work")
        #expect(sessions[2].isLive == false)
        #expect(sessions[2].clientCount == 0)
    }

    @MainActor
    @Test func rejectsMalformedSessionRows() throws {
        let malformedRows: [[String: Any]] = [
            [
                "id": NSNull(),
                "session_name": "missing-live",
                "managed": false,
            ],
            [
                "id": "not-a-uuid",
                "session_name": "managed-bad-id",
                "clients": 1,
                "managed": true,
                "live": true,
            ],
            [
                "id": NSNull(),
                "session_name": "bad-clients",
                "clients": "two",
                "managed": false,
                "live": true,
            ],
        ]

        for row in malformedRows {
            let data = try JSONSerialization.data(withJSONObject: ["sessions": [row]])
            #expect(throws: Error.self) {
                _ = try HostSettingsActions.decodeLocalTmuxSessions(data)
            }
        }
    }

    @MainActor
    @Test func rejectsMalformedSessionListPayload() {
        let data = Data(#"{"count": 1}"#.utf8)

        #expect(throws: Error.self) {
            _ = try HostSettingsActions.decodeLocalTmuxSessions(data)
        }
    }
}
