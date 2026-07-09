import CmuxRemoteWorkspace
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxControlStreamParserBudgetTests {
    @Test func pendingLineOverflowEmitsStreamErrorAndResetsParser() {
        var parser = RemoteTmuxControlStreamParser(maxBufferedLineBytes: 8, maxCommandBlockBytes: 1024)

        let overflow = parser.feed(Data("abcdefghi".utf8))
        #expect(overflow == [.streamError("line exceeded 8 bytes")])
        #expect(parser.feed(Data("%exit\r\n".utf8)) == [.exit(reason: nil)])
    }

    @Test func commandBlockOverflowEmitsStreamErrorAndResetsParser() {
        var parser = RemoteTmuxControlStreamParser(maxBufferedLineBytes: 128, maxCommandBlockBytes: 10)

        #expect(parser.feed(Data("%begin 1700000000 7 1\r\n".utf8)).isEmpty)
        let overflow = parser.feed(Data("123456\r\nabcdef\r\n".utf8))
        #expect(overflow == [.streamError("command block exceeded 10 bytes")])
        #expect(parser.feed(Data("%window-add @5\r\n".utf8)) == [.windowAdd(windowId: 5)])
    }
}
