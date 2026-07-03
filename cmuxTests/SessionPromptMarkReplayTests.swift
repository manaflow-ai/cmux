import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session prompt mark replay")
struct SessionPromptMarkReplayTests {
    // Regression for https://github.com/manaflow-ai/cmux/issues/6691.
    //
    // Ghostty's `write_screen_file:copy,vt` export drops OSC 133 semantic-prompt
    // markers, so replayed scrollback loses the prompt row metadata that drives
    // jump-to-prompt and click-to-move.
    @Test func reinjectsSemanticPromptMarkForLastUserMessage() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let promptPrefix = "\(esc)[2m> \(reset)"
        let message = "refactor the login flow"
        let scrollback = [
            "\(esc)[1mWelcome to the session\(reset)",
            "\(promptPrefix)\(message)",
            "\(esc)[32m● Done editing files\(reset)",
        ].joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )

        #expect(marked.contains("\(esc)]133;A"))
        #expect(marked.contains("\(SessionScrollbackReplayStore.semanticPromptStartMark)\(promptPrefix)\(message)"))
        #expect(marked.contains("Welcome to the session"))
        #expect(marked.contains("● Done editing files"))
    }

    @Test func leavesScrollbackUntouchedWithoutLastUserMessage() {
        let scrollback = "$ ls\nfile-a\nfile-b\n"
        #expect(
            SessionScrollbackReplayStore.reinjectingLastPromptMark(into: scrollback, lastUserMessage: nil)
                == scrollback
        )
        #expect(
            SessionScrollbackReplayStore.reinjectingLastPromptMark(into: scrollback, lastUserMessage: "   ")
                == scrollback
        )
    }

    @Test func noOpsOnAmbiguousBlockquoteEcho() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "fix the flaky test"
        let lines = [
            "> \(esc)[1mfix\(reset) the \(esc)[4mflaky\(reset) test",
            "\(esc)[33m⏺\(reset) Here's the plan:",
            "> fix the flaky test",
            "\(esc)[32m● done\(reset)",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )

        #expect(!marked.contains("\(esc)]133;A"))
        #expect(marked == scrollback)
    }

    @Test func marksSinglePromptThroughInterleavedSGR() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "fix the flaky test"
        let lines = [
            "\(esc)[1mready\(reset)",
            "> \(esc)[1mfix\(reset) the \(esc)[4mflaky\(reset) test",
            "\(esc)[32m● done\(reset)",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")

        #expect(markedLines[1].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
        #expect(marked.components(separatedBy: "\(esc)]133;A").count - 1 == 1)
    }

    @Test func marksFirstRowOfWrappedPrompt() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "please refactor the authentication flow and add regression tests"
        let firstRow = "> please refactor the authentication flow and"
        let secondRow = "add regression tests"
        let lines = [
            "\(esc)[1magent ready\(reset)",
            firstRow,
            secondRow,
            "\(esc)[32m● working\(reset)",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")

        #expect(markedLines.count == 4)
        #expect(markedLines[1].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
        #expect(!markedLines[2].contains("\(esc)]133;A"))
        #expect(marked.components(separatedBy: "\(esc)]133;A").count - 1 == 1)
    }

    @Test func doesNotMarkAgentOutputEchoingTheMessage() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "refactor the login flow"
        let lines = [
            "\(esc)[2m> \(reset)refactor the login flow",
            "\(esc)[33m⏺ I'll refactor the login flow now…\(reset)",
            "\(esc)[32m● Done\(reset)",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")

        #expect(markedLines[0].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
        #expect(!markedLines[1].contains("\(esc)]133;A"))
        #expect(marked.components(separatedBy: "\(esc)]133;A").count - 1 == 1)
    }

    @Test func prefersSigilPromptOverBareAgentEcho() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "refactor the login flow"
        let lines = [
            "\(esc)[2m> \(reset)refactor the login flow",
            "\(esc)[33m⏺\(reset) working…",
            "refactor the login flow is done; tests pass",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")

        #expect(markedLines[0].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
        #expect(!markedLines[2].contains("\(esc)]133;A"))
        #expect(marked.components(separatedBy: "\(esc)]133;A").count - 1 == 1)
    }

    @Test func doesNotMarkMarkdownBulletEchoingTheMessage() {
        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "refactor the login flow"
        let lines = [
            "\(esc)[2m> \(reset)refactor the login flow",
            "\(esc)[1mPlan:\(reset)",
            "- refactor the login flow",
            "# Refactor the login flow",
            "- add regression tests",
        ]
        let scrollback = lines.joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")

        #expect(markedLines[0].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
        #expect(!markedLines[2].contains("\(esc)]133;A"))
        #expect(!markedLines[3].contains("\(esc)]133;A"))
        #expect(marked.components(separatedBy: "\(esc)]133;A").count - 1 == 1)
    }

    @Test func marksMultilinePromptAcrossRows() {
        let esc = "\u{001B}"
        let message = "first line\nsecond line of the prompt"
        let scrollback = [
            "> first line",
            "second line of the prompt",
            "\(esc)[32m● ok\(esc)[0m",
        ].joined(separator: "\n")

        let marked = SessionScrollbackReplayStore.reinjectingLastPromptMark(
            into: scrollback,
            lastUserMessage: message
        )
        let markedLines = marked.components(separatedBy: "\n")
        #expect(markedLines[0].hasPrefix(SessionScrollbackReplayStore.semanticPromptStartMark))
    }

    @Test func replayEnvironmentReinjectsPromptMarkIntoReplayFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let esc = "\u{001B}"
        let reset = "\(esc)[0m"
        let message = "add a dark mode toggle"
        let scrollback = "\(esc)[1mclaude\(reset)\n> \(message)\n\(esc)[32m● Done\(reset)\n"

        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: scrollback,
            lastUserMessage: message,
            tempDirectory: tempDir
        )
        let path = try #require(environment[SessionScrollbackReplayStore.environmentKey])
        let contents = try String(contentsOfFile: path, encoding: .utf8)

        #expect(contents.contains("\(SessionScrollbackReplayStore.semanticPromptStartMark)> \(message)"))
        #expect(contents.contains("claude"))
        #expect(contents.contains("● Done"))
    }

    @Test func terminalSnapshotPromptMarkKeyRoundTripsIntoReplayInjection() throws {
        let esc = "\u{001B}"
        let message = "wire up the settings panel"
        let scrollback = "\(esc)[1mclaude\(esc)[0m\n> \(message)\n\(esc)[32m● Done\(esc)[0m\n"
        let key = try #require(SessionScrollbackReplayStore.persistablePromptMatchKey(
            forScrollback: scrollback,
            lastUserMessage: message
        ))
        let snapshot = SessionTerminalPanelSnapshot(scrollback: scrollback, lastPromptMarkKey: key)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.lastPromptMarkKey == key)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-scrollback-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let environment = SessionScrollbackReplayStore.replayEnvironment(
            for: decoded.scrollback,
            lastUserMessage: decoded.lastPromptMarkKey,
            tempDirectory: tempDir
        )
        let path = try #require(environment[SessionScrollbackReplayStore.environmentKey])
        let contents = try String(contentsOfFile: path, encoding: .utf8)

        #expect(contents.contains("\(SessionScrollbackReplayStore.semanticPromptStartMark)> \(message)"))
    }

    @Test func persistablePromptMatchKeyGatesPersistenceAndBoundsKey() {
        let esc = "\u{001B}"
        let message = "refactor the login flow"
        let withPrompt = "\(esc)[2m> \(esc)[0m\(message)\n\(esc)[32m● working\(esc)[0m\n"
        let unrelated = "building project…\n$ swift build\nCompiling…\n"

        #expect(
            SessionScrollbackReplayStore.persistablePromptMatchKey(forScrollback: withPrompt, lastUserMessage: message)
                != nil
        )
        #expect(
            SessionScrollbackReplayStore.persistablePromptMatchKey(forScrollback: unrelated, lastUserMessage: message)
                == nil
        )
        #expect(SessionScrollbackReplayStore.persistablePromptMatchKey(forScrollback: nil, lastUserMessage: message) == nil)
        #expect(SessionScrollbackReplayStore.persistablePromptMatchKey(forScrollback: withPrompt, lastUserMessage: nil) == nil)

        let longMessage = String(repeating: "alpha bravo ", count: 30)
        let longScrollback = "> \(longMessage)\noutput\n"
        let key = SessionScrollbackReplayStore.persistablePromptMatchKey(
            forScrollback: longScrollback,
            lastUserMessage: longMessage
        )
        #expect(key != nil)
        #expect((key ?? "").count <= 48)
        #expect(key != longMessage)
    }

    @Test func terminalSnapshotWithoutScrollbackDecodesNilPromptMarkKey() throws {
        let snapshot = SessionTerminalPanelSnapshot(workingDirectory: "/tmp")
        #expect(snapshot.lastPromptMarkKey == nil)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.lastPromptMarkKey == nil)
    }
}
