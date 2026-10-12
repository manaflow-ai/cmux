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
