import Foundation
import Testing
@testable import CmuxNative

struct FeedTextParserTests {
    @Test func rejoinsSoftWrappedReply() {
        let text = """
        > Ship the phone build to TestFlight?

        ⏺ The build passed all checks. Do you want me to uploa
        d it to TestFlight now?

          ❯ 1. Yes, upload it
            2. No, wait for review
        """
        let result = FeedTextParser.parse(text, columns: 54)
        #expect(result.lastPrompt == "Ship the phone build to TestFlight?")
        #expect(result.lastReply == "The build passed all checks. Do you want me to upload it to TestFlight now?")
        #expect(result.options.map(\.key) == ["1", "2"])
    }

    @Test func selectionMenuIsNotAPrompt() {
        let text = """
        > Create a file named phone_hello.txt

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel
        """
        #expect(FeedTextParser.parse(text).lastPrompt == "Create a file named phone_hello.txt")
    }
}

struct FeedInputBoxTests {
    @Test func codexIdleInputIsNotThePrompt() {
        let text = """
        › Reply with just the number: what is 17 plus 25


        • 42

          Worked for 3s • 7:28 PM


        › Ask Codex to do anything

          GPT-6.1-Sol low · ~/cmux-native/demo/repo · Check e…
          ← for agents · ? for shortcuts
        """
        let result = FeedTextParser.parse(text)
        #expect(result.lastPrompt == "Reply with just the number: what is 17 plus 25")
        #expect(result.lastReply == "42")
    }

    @Test func claudeDraftInInputBoxIsNotThePrompt() {
        let text = """
        > Run the tests

        ⏺ All 12 tests passed.

        ─────────────────────────────
        > also check lint
        ─────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
        #expect(FeedTextParser.parse(text).lastPrompt == "Run the tests")
    }
}

struct FeedEnrichTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func newestPostBorrowsTheTerminal() {
        #expect(FeedStore.terminalStillShows(now, newerPostOnSurface: false, agentUpdatedAt: now.addingTimeInterval(2), now: now.addingTimeInterval(60)))
    }

    @Test func hoursOldFinishedPostIsLeftAlone() {
        #expect(!FeedStore.terminalStillShows(now, newerPostOnSurface: false, agentUpdatedAt: nil, now: now.addingTimeInterval(7 * 3600)))
        #expect(FeedStore.terminalStillShows(now, newerPostOnSurface: false, agentUpdatedAt: nil, waitingForAnswer: true, now: now.addingTimeInterval(7 * 3600)))
    }

    @Test func olderPostDoesNot() {
        #expect(!FeedStore.terminalStillShows(now, newerPostOnSurface: true, agentUpdatedAt: nil, now: now))
    }

    @Test func agentMovedOnSinceThePost() {
        #expect(!FeedStore.terminalStillShows(now, newerPostOnSurface: false, agentUpdatedAt: now.addingTimeInterval(3600), now: now))
    }
}

struct FeedUnwrapTests {
    @Test func staleColumnCountStillRejoins() {
        // Laid out at 53 columns while the tree still says 54.
        let rows = [String(repeating: "a", count: 53), "bc", "short"]
        #expect(FeedTextParser.unwrap(rows, columns: 54) == [String(repeating: "a", count: 53) + "bc", "short"])
    }
}
