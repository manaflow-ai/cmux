import CmuxAgentReplica
import CmuxAgentWire
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct AgentGUIStreamProducerTests {
    @Test func extractsCodexAndClaudeStreamingAnswersWithoutTerminalChrome() {
        let extractor = AgentGUIProseScreenExtractor()
        let codex = extractor.extract(lines: [
            "› summarize this file",
            "Streaming answer line one.",
            "Streaming answer line two.",
            "Working (3s • Esc to interrupt)",
            "❯ ",
        ], agentKind: .codex)
        #expect(codex == "Streaming answer line one.\nStreaming answer line two.")

        let claude = extractor.extract(lines: [
            "❯ explain blue",
            "⏺ Blue light scatters strongly.",
            "  This is why the sky looks blue.",
            "✻ Forming… (4s · ↓ 21 tokens)",
            "❯ ",
            "⏵⏵ auto mode · esc to interrupt · ← for agents",
        ], agentKind: .claude)
        #expect(claude == "Blue light scatters strongly.\nThis is why the sky looks blue.")
    }

    @Test func rejectsSettledAndPreAnswerScreens() {
        let extractor = AgentGUIProseScreenExtractor()
        #expect(extractor.extract(lines: [
            "⏺ Finished answer.",
            "✻ Brewed for 3s",
        ], agentKind: .claude) == nil)
        #expect(extractor.extract(lines: [
            "❯ explain blue",
            "✶ Thinking… (2s · esc to interrupt)",
        ], agentKind: .claude) == nil)
    }

    @Test func emitsChangedPreviewAndExplicitClearWithJournalContext() {
        let sessionID = AgentSessionID(rawValue: "stream-session")
        let surfaceID = UUID()
        let journalID = JournalID(rawValue: "journal-stream")
        var frames: [GuiStreamTickEvent] = []
        let producer = AgentGUIStreamProducer(
            publish: { publishedSessionID, event in
                #expect(publishedSessionID == sessionID)
                frames.append(event)
            },
            snapshot: { requestedSurfaceID in
                #expect(requestedSurfaceID == surfaceID)
                return [
                    "› prompt",
                    "Live answer.",
                    "Working (3s • Esc to interrupt)",
                ]
            },
            hasSubscribers: { $0 == sessionID },
            context: { requestedSessionID in
                guard requestedSessionID == sessionID else { return nil }
                return .init(journalID: journalID, afterSeq: EntrySeq(rawValue: 7))
            },
            pollInterval: .seconds(60),
            sleep: { _ in }
        )

        producer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        producer.emitPreviewIfChanged(sessionID: sessionID)
        producer.emitPreviewIfChanged(sessionID: sessionID)
        producer.authoritativeProseArrived(sessionID: sessionID)

        #expect(frames.count == 2)
        #expect(frames[0].journalID == journalID)
        #expect(frames[0].afterSeq == EntrySeq(rawValue: 7))
        #expect(frames[0].textTail == "Live answer.")
        #expect(frames[0].revision == 1)
        #expect(frames[1].textTail.isEmpty)
        #expect(frames[1].revision == 2)
        producer.turnEnded(sessionID: sessionID)
    }

    @Test func resetWindowContainingDurableProseSettlesPreviewAndEmitsClear() {
        let sessionID = AgentSessionID(rawValue: "reset-stream-session")
        let surfaceID = UUID()
        let journalID = JournalID(rawValue: "reset-stream-journal")
        var frames: [GuiStreamTickEvent] = []
        var screenLines = [
            "› prompt",
            "Live answer.",
            "Working (3s • Esc to interrupt)",
        ]
        let producer = AgentGUIStreamProducer(
            publish: { _, event in frames.append(event) },
            snapshot: { requestedSurfaceID in
                #expect(requestedSurfaceID == surfaceID)
                return screenLines
            },
            hasSubscribers: { $0 == sessionID },
            context: { _ in
                .init(journalID: journalID, afterSeq: EntrySeq(rawValue: 1))
            },
            pollInterval: .seconds(60),
            sleep: { _ in }
        )
        producer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        defer { producer.turnEnded(sessionID: sessionID) }
        producer.emitPreviewIfChanged(sessionID: sessionID)
        #expect(frames.count == 1)
        #expect(frames[0].textTail == "Live answer.")

        var window = AgentGUIJournalWindow(journalID: journalID)
        window.apply(EntrySnapshot(
            journalID: journalID,
            seq: EntrySeq(rawValue: 1),
            kind: .agentProse,
            content: EntryContent(
                contentHash: 1,
                payload: .agentProse(AgentProsePayload(markdown: "Live answer."))
            ),
            version: EntityVersion(rawValue: 1)
        ))
        producer.journalEventArrived(
            .reset(journalID: journalID, tailSeq: EntrySeq(rawValue: 1)),
            sessionID: sessionID,
            window: window
        )

        #expect(frames.count == 2)
        #expect(frames[1].textTail.isEmpty)
        screenLines[1] = "A preview that must not reappear."
        producer.emitPreviewIfChanged(sessionID: sessionID)
        #expect(frames.count == 2)
    }
}
