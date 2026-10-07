import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing
@testable import CmuxiOSTerminal

/// The adapter from the transport seam to the renderer's source protocol.
@Suite struct SessionTerminalByteSourceTests {
    @Test func framesAreDecoded() throws {
        let frame = TerminalFrame(kind: .bytes, generation: 3, offset: 5, payload: Data("hello".utf8))
        guard case .frame(let decoded)? = SessionTerminalByteSource.map(.frame(frame.encoded)) else {
            Issue.record("not a frame")
            return
        }
        #expect(decoded == frame)
    }

    @Test func undecodableAndUnknownFramesAreDropped() {
        #expect(SessionTerminalByteSource.map(.frame(Data([0, 1]))) == nil)
        var unknown = TerminalFrame(kind: .bytes, generation: 1, offset: 1, payload: Data([1])).encoded
        unknown[0] = 99
        #expect(SessionTerminalByteSource.map(.frame(unknown)) == nil)
    }

    @Test func controlEventsMapOneToOne() {
        if case .grid(46, 38, 7)? = SessionTerminalByteSource.map(.grid(cols: 46, rows: 38, generation: 7)) {} else {
            Issue.record("grid")
        }
        if case .snapshotThrottled(250, "r1")? = SessionTerminalByteSource.map(.snapshotThrottled(retryAfterMilliseconds: 250, requestID: "r1")) {} else {
            Issue.record("throttled")
        }
        if case .path(.relayed, 80)? = SessionTerminalByteSource.map(.path(.relayed, rttMilliseconds: 80)) {} else {
            Issue.record("path")
        }
        if case .kicked("Ann")? = SessionTerminalByteSource.map(.kicked(byDisplayName: "Ann")) {} else { Issue.record("kicked") }
        if case .closed("bye")? = SessionTerminalByteSource.map(.closed(reason: "bye")) {} else { Issue.record("closed") }
    }
}
