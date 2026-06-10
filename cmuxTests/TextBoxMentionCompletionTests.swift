import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Text box mention completion")
@MainActor
struct TextBoxMentionCompletionTests {
    @Test
    func testTextBoxMentionCompletionDetectsFileAndSkillTokens() {
        let filePrompt = "open @Sources/TextBox"
        let fileQuery = TextBoxMentionCompletionDetector.query(
            in: filePrompt,
            selectedRange: NSRange(location: (filePrompt as NSString).length, length: 0)
        )
        #expect(fileQuery?.kind == .file)
        #expect(fileQuery?.trigger == "@")
        #expect(fileQuery?.query == "Sources/TextBox")
        #expect(fileQuery?.range == NSRange(location: 5, length: 16))

        let skillPrompt = "use /swift-guidance before editing"
        let cursor = (skillPrompt as NSString).range(of: " before").location
        let skillQuery = TextBoxMentionCompletionDetector.query(
            in: skillPrompt,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        #expect(skillQuery?.kind == .skill)
        #expect(skillQuery?.trigger == "/")
        #expect(skillQuery?.query == "swift-guidance")
        #expect(skillQuery?.range == NSRange(location: 4, length: 15))

        let dollarSkillPrompt = "use $axiom-swift now"
        let dollarCursor = (dollarSkillPrompt as NSString).range(of: " now").location
        let dollarSkillQuery = TextBoxMentionCompletionDetector.query(
            in: dollarSkillPrompt,
            selectedRange: NSRange(location: dollarCursor, length: 0)
        )
        #expect(dollarSkillQuery?.kind == .skill)
        #expect(dollarSkillQuery?.trigger == "$")
        #expect(dollarSkillQuery?.query == "axiom-swift")
        #expect(dollarSkillQuery?.range == NSRange(location: 4, length: 12))

        let bareSlashPrompt = "cd /"
        let bareSlashQuery = TextBoxMentionCompletionDetector.query(
            in: bareSlashPrompt,
            selectedRange: NSRange(location: (bareSlashPrompt as NSString).length, length: 0)
        )
        #expect(bareSlashQuery?.kind == .skill)
        #expect(bareSlashQuery?.trigger == "/")
        #expect(bareSlashQuery?.query == "")

        let bareDollarPrompt = "echo $"
        let bareDollarQuery = TextBoxMentionCompletionDetector.query(
            in: bareDollarPrompt,
            selectedRange: NSRange(location: (bareDollarPrompt as NSString).length, length: 0)
        )
        #expect(bareDollarQuery?.kind == .skill)
        #expect(bareDollarQuery?.trigger == "$")
        #expect(bareDollarQuery?.query == "")

        let emailPrompt = "mail lawrence@example.com"
        #expect(TextBoxMentionCompletionDetector.query(
            in: emailPrompt,
            selectedRange: NSRange(location: (emailPrompt as NSString).length, length: 0)
        ) == nil)
    }

    @Test
    func testTextBoxMentionMarkdownEscapesAngleTargetDelimiters() {
        let link = TextBoxMentionMarkdown.link(
            label: "@Docs/[draft].md",
            path: "Docs/roadmap <draft>.md"
        )

        #expect(link == "[@Docs/\\[draft\\].md](<Docs/roadmap %3Cdraft%3E.md>)")
    }

    @Test
    func testTextBoxProcessTerminationStatusResumesMultipleWaiters() async {
        let status = TextBoxProcessTerminationStatus()

        async let firstWaiter: Int32 = status.wait()
        async let secondWaiter: Int32 = status.wait()
        await Task.yield()

        await status.finish(status: 7)

        let (firstStatus, secondStatus) = await (firstWaiter, secondWaiter)
        #expect(firstStatus == 7)
        #expect(secondStatus == 7)
        #expect(await status.wait() == 7)
    }

}
