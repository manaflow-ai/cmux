import Foundation
import Testing
@testable import CnxFeed

/// Full verify D10: short inline rows skip the web view.
@Suite struct FeedPlainTextTests {
    @Test func shortInlineTextIsNative() {
        #expect(FeedPlainText("Finished its turn in the terminal. Open it to see the result.").isInline)
        #expect(FeedPlainText("**Needs approval:** run `ls -la` in **web**").isInline)
        #expect(FeedPlainText("**Needs approval:** run `ls`").attributed != nil)
    }

    @Test func blocksKeepTheWebRenderer() {
        #expect(!FeedPlainText("Here:\n```swift\nlet a = 1\n```").isInline)
        #expect(!FeedPlainText("- one\n- two").isInline)
        #expect(!FeedPlainText("# Title").isInline)
        #expect(!FeedPlainText("| a | b |\n|---|---|").isInline)
        #expect(!FeedPlainText("1. first").isInline)
        #expect(!FeedPlainText(String(repeating: "word ", count: 80)).isInline)
        #expect(!FeedPlainText("a\nb\nc\nd\ne").isInline)
    }
}
