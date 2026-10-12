import Testing
@testable import CmuxNative

struct ServiceClientTextTests {
    @Test func shortTextIsUnchanged() {
        #expect(ServiceClient.recentText("a\nb\n", maxBytes: 100) == "a\nb\n")
    }

    @Test func longTextKeepsTheTailFromALineStart() {
        let text = (0..<1000).map { "line \($0) ~/repo/file\($0).swift" }.joined(separator: "\n")
        let tail = ServiceClient.recentText(text, maxBytes: 2000)
        #expect(tail.utf8.count <= 2000)
        #expect(tail.hasPrefix("line "))
        #expect(tail.hasSuffix("line 999 ~/repo/file999.swift"))
    }

    @Test func multiByteTextStaysValid() {
        let text = String(repeating: "日本語\n", count: 2000)
        let tail = ServiceClient.recentText(text, maxBytes: 1000)
        #expect(tail.hasPrefix("日本語"))
        #expect(tail.utf8.count <= 1000)
    }
}
