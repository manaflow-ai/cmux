import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentSessionSidebarDidChangeEventTests {
    private func record(
        state: ChatAgentState,
        lastActivityAt: Date,
        surfaceID: String? = "AAAAAAAA-0000-0000-0000-000000000001",
        lastPrompt: String? = "prompt"
    ) -> AgentChatSessionRecord {
        var record = AgentChatSessionRecord(
            sessionID: "s-1",
            agentKind: .claude,
            workspaceID: "BBBBBBBB-0000-0000-0000-000000000001",
            surfaceID: surfaceID,
            workingDirectory: nil,
            transcriptPath: nil,
            state: state,
            lastActivityAt: lastActivityAt,
            title: nil,
            pid: nil
        )
        record.lastPrompt = lastPrompt
        return record
    }

    @Test func activityInsideOneMinuteDoesNotChangeTheFingerprint() {
        let a = record(state: .idle, lastActivityAt: Date(timeIntervalSince1970: 3_605))
        let b = record(state: .idle, lastActivityAt: Date(timeIntervalSince1970: 3_650))
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(a) == AgentSessionSidebarDidChangeEvent.fingerprint(b))
    }

    @Test func crossingAMinuteBoundaryChangesTheFingerprint() {
        let a = record(state: .idle, lastActivityAt: Date(timeIntervalSince1970: 3_650))
        let b = record(state: .idle, lastActivityAt: Date(timeIntervalSince1970: 3_662))
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(a) != AgentSessionSidebarDidChangeEvent.fingerprint(b))
    }

    @Test func stateKindMattersButItsTimestampDoesNot() {
        let t = Date(timeIntervalSince1970: 100)
        let workingA = record(state: .working(since: Date(timeIntervalSince1970: 10)), lastActivityAt: t)
        let workingB = record(state: .working(since: Date(timeIntervalSince1970: 20)), lastActivityAt: t)
        let needsInput = record(state: .needsInput(since: Date(timeIntervalSince1970: 10)), lastActivityAt: t)
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(workingA) == AgentSessionSidebarDidChangeEvent.fingerprint(workingB))
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(workingA) != AgentSessionSidebarDidChangeEvent.fingerprint(needsInput))
    }

    @Test func promptAndTitleChangesChangeTheFingerprint() {
        let t = Date(timeIntervalSince1970: 100)
        let a = record(state: .idle, lastActivityAt: t, lastPrompt: "one")
        let b = record(state: .idle, lastActivityAt: t, lastPrompt: "two")
        var c = a
        c.aiTitle = "Titled"
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(a) != AgentSessionSidebarDidChangeEvent.fingerprint(b))
        #expect(AgentSessionSidebarDidChangeEvent.fingerprint(a) != AgentSessionSidebarDidChangeEvent.fingerprint(c))
    }

    @Test func eventCarriesCurrentAndPreviousPanels() {
        let previous = record(state: .idle, lastActivityAt: Date(), surfaceID: "AAAAAAAA-0000-0000-0000-000000000001")
        let current = record(state: .idle, lastActivityAt: Date(), surfaceID: "AAAAAAAA-0000-0000-0000-000000000002")
        let event = AgentSessionSidebarDidChangeEvent(current: current, previous: previous)
        #expect(event.panelIds == [
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
        ])
        #expect(event.workspaceIds == [UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!])
    }

    @Test func notificationRoundTrips() {
        let center = NotificationCenter()
        let panelId = UUID()
        let workspaceId = UUID()
        final class Received: @unchecked Sendable {
            var event: AgentSessionSidebarDidChangeEvent?
        }
        let received = Received()
        let observer = center.addObserver(
            forName: AgentSessionSidebarDidChangeEvent.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            received.event = AgentSessionSidebarDidChangeEvent(notification)
        }
        defer { center.removeObserver(observer) }
        AgentSessionSidebarDidChangeEvent(panelIds: [panelId], workspaceIds: [workspaceId]).post(center: center)
        #expect(received.event?.panelIds == [panelId])
        #expect(received.event?.workspaceIds == [workspaceId])
    }
}
