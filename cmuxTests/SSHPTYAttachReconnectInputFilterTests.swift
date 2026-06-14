import Foundation
import XCTest

final class SSHPTYAttachReconnectInputFilterTests: XCTestCase {
    func testDropsInitialProbeRepliesThenDisablesFiltering() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        XCTAssertEqual(
            filter.filter(Data("\u{1B}[1;1R\u{1B}[?1;2c\u{1B}[?0u".utf8)),
            Data()
        )

        let legitimateReply = Data("\u{1B}[2;2R".utf8)
        XCTAssertEqual(filter.filter(legitimateReply), legitimateReply)
    }

    func testBuffersRecognizedSplitOSCColorReplyWithinInitialDrain() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        XCTAssertEqual(filter.filter(Data("\u{1B}]11;rgb:e5e5/e9e9".utf8)), Data())

        let normalInput = Data("printf keep\n".utf8)
        XCTAssertEqual(
            filter.filter(Data("/f0f0\u{1B}\\".utf8) + normalInput),
            normalInput
        )
    }

    func testPassesThroughAmbiguousEscapeInput() {
        let filter = SSHPTYAttachReconnectInputFilter(enabled: true)
        let escape = Data([0x1B])
        XCTAssertEqual(filter.filter(escape), escape)

        let keyInput = Data("\u{1B}[13;2u".utf8)
        XCTAssertEqual(filter.filter(keyInput), keyInput)
    }
}
