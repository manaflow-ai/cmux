import AppKit
import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An agent session with two prompts that counts how often the rail asks for
/// it, so a test can tell whether a transcript tailer was started.
@MainActor
private final class CountingOutlineSource: AgentTurnOutlineSource {
    private(set) var observations = 0
    private(set) var outlineReads = 0

    func turnOutlineChanges(surfaceID: UUID) -> AsyncStream<Void> {
        observations += 1
        return AsyncStream { _ in }
    }

    func turnOutline(surfaceID: UUID) async -> AgentTurnOutlineSnapshot? {
        outlineReads += 1
        return AgentTurnOutlineSnapshot(
            sessionID: "session",
            agentKind: .claude,
            entries: ["fix the sidebar", "run it again"].enumerated().map { index, title in
                ChatOutlineEntry(
                    id: "entry-\(index)",
                    seq: index * 10,
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    title: title
                )
            },
            isHeadTruncated: false
        )
    }
}

/// Regression: the agent turn rail (#15398) shipped on by default in classic.
/// It is a Beta Features preview: until someone turns it on, an agent
/// terminal reserves no gutter, starts no transcript tailer, and leaves
/// Cmd-Shift-Up/Down to Ghostty's jump_to_prompt.
@MainActor
@Suite("Agent turn rail preview", .serialized)
struct AgentTurnRailPreviewTests {
    static let defaultsKey = "agentTurnRail.beta.enabled"

    private func withPreviewSetting(_ value: Bool?, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Self.defaultsKey)
        defer { defaults.set(saved, forKey: Self.defaultsKey) }
        defaults.set(value, forKey: Self.defaultsKey)
        try await body()
    }

    private func agentTerminal() -> GhosttySurfaceScrollView {
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)))
        hostedView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        return hostedView
    }

    @Test("by default an agent terminal gets no turn rail and never reads its transcript")
    func offByDefault() async {
        await withPreviewSetting(nil) {
            let source = CountingOutlineSource()
            let hostedView = agentTerminal()
            hostedView.installAgentTurnRail(surfaceID: UUID(), source: source)
            try? await Task.sleep(for: .milliseconds(200))
            #expect(hostedView.agentTurnRailModel == nil, "a rail reserves its gutter in every agent terminal")
            #expect(source.observations == 0 && source.outlineReads == 0, "the rail started a transcript tailer")
        }
    }

    @Test("turning the preview on attaches the rail, and turning it off removes it")
    func optInAndBack() async {
        await withPreviewSetting(true) {
            let hostedView = agentTerminal()
            hostedView.installAgentTurnRail(surfaceID: UUID(), source: CountingOutlineSource())
            #expect(hostedView.agentTurnRailModel != nil)

            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            hostedView.reconcileAgentTurnRail()
            #expect(hostedView.agentTurnRailModel == nil, "turning the preview off kept the rail and its gutter")
        }
    }
}
