import Foundation
import Testing

@Suite struct SSHPTYAttachReconnectInputFilterTests {
    @Test func keepsFilteringAcrossProbeOnlyReadsUntilFirstNormalInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R\u{1B}[?1;2c\u{1B}[?0u".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)

        let laterReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(laterReply) == laterReply)
    }

    @Test func buffersRecognizedSplitOSCColorReplyWithinInitialDrain() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("/f0f0\u{1B}\\".utf8) + normalInput) == normalInput)
    }

    @Test func buffersOSCColorReplySplitBeforeCommandSeparator() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]1".utf8)) == Data())
        #expect(filter.filter(Data("1".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data(";rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func passesThroughAmbiguousEscapeInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == escape)

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }
}
