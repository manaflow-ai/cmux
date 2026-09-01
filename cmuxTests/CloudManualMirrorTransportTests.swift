import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the byte-oriented cloud terminal attachment seam.
/// The fixture speaks the same JSON lines as a cmux-tui `attach-surface` stream;
/// it never invokes the ratatui renderer or inspects source text.
@Suite
struct CloudManualMirrorTransportTests {
    @Test
    func rawAttachFramesDeliverOutputAndResizeReplay() throws {
        let decoder = CloudTuiManualIOFrameDecoder()
        let initial = try #require(decoder.decode(Self.line([
            "event": "vt-state",
            "surface": 17,
            "cols": 99,
            "rows": 35,
            "data": Data("initial screen".utf8).base64EncodedString(),
        ])))
        #expect(initial == .snapshot(surfaceID: 17, columns: 99, rows: 35, bytes: Data("initial screen".utf8)))

        let output = try #require(decoder.decode(Self.line([
            "event": "output",
            "surface": 17,
            "data": Data("prompt> ".utf8).base64EncodedString(),
        ])))
        #expect(output == .output(surfaceID: 17, bytes: Data("prompt> ".utf8)))

        let resized = try #require(decoder.decode(Self.line([
            "event": "resized",
            "surface": 17,
            "cols": 140,
            "rows": 48,
            "replay": Data("resized screen".utf8).base64EncodedString(),
        ])))
        #expect(resized == .resized(surfaceID: 17, columns: 140, rows: 48, bytes: Data("resized screen".utf8)))
    }

    @Test
    func inputAndResizeCommandsTargetTheRemotePtyWithoutRendering() throws {
        let attach = try #require(CloudTuiManualIOCommand.attach(surfaceID: 17, columns: 120, rows: 40))
        #expect(attach["cmd"] as? String == "attach-surface")
        #expect(attach["surface"] as? UInt64 == 17)
        #expect(attach["cols"] as? UInt64 == 120)
        #expect(attach["rows"] as? UInt64 == 40)

        let input = CloudTuiManualIOCommand.input(surfaceID: 17, bytes: Data("claude\r".utf8))
        #expect(input["cmd"] as? String == "send")
        #expect(input["surface"] as? UInt64 == 17)
        #expect(input["bytes"] as? String == Data("claude\r".utf8).base64EncodedString())

        let resize = CloudTuiManualIOCommand.resize(surfaceID: 17, columns: 160, rows: 52)
        #expect(resize["cmd"] as? String == "resize-surface")
        #expect(resize["surface"] as? UInt64 == 17)
        #expect(resize["cols"] as? UInt64 == 160)
        #expect(resize["rows"] as? UInt64 == 52)
    }

    private static func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
