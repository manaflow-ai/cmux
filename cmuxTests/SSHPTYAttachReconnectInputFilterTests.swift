import Foundation
import Testing

@Suite struct SSHPTYAttachReconnectInputFilterTests {
    @Test func keepsFilteringAcrossProbeOnlyReadsUntilFirstNormalInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R\u{1B}[?1;2c\u{1B}[?0u".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8)) == Data())
        #expect(filter.filter(Data("\u{1B}]12;rgb:ffff/ffff/ffff\u{07}".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)

        let laterReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(laterReply) == laterReply)
    }

    @Test func stopsFilteringAtIdleProbeBoundary() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}[1;1R".utf8)) == Data())
        #expect(filter.isFilteringAtProbeBoundary)

        filter.stopFilteringAtProbeBoundary()
        let liveReply = Data("\u{1B}[2;2R".utf8)
        #expect(filter.filter(liveReply) == liveReply)
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
        #expect(filter.filter(Data("2".utf8)) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data(";rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func buffersInitialEscapeUntilProbeContinuationArrives() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())

        let normalInput = Data("printf keep\n".utf8)
        #expect(filter.filter(Data("]11;rgb:e5e5/e9e9/f0f0\u{07}".utf8) + normalInput) == normalInput)
    }

    @Test func passesThroughAmbiguousEscapeAfterNonProbeContinuation() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.filter(Data("x".utf8)) == Data("\u{1B}x".utf8))

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }

    @Test func flushesPendingInputWhenNoContinuationArrives() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        #expect(filter.filter(escape) == Data())
        #expect(filter.hasPendingInput)
        #expect(filter.flushPendingInput() == escape)

        let keyInput = Data("\u{1B}[13;2u".utf8)
        #expect(filter.filter(keyInput) == keyInput)
    }
}
