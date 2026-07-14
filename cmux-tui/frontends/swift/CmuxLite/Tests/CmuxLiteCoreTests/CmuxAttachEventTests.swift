@testable import CmuxLiteCore
import Foundation
import Testing

@Suite
struct CmuxAttachEventTests {
    @Test
    func decodesResizedReplayBytes() throws {
        let json = Data(
            #"{"event":"resized","surface":7,"cols":100,"rows":30,"data":"G1s/bA=="}"#.utf8
        )
        let event = try JSONDecoder().decode(CmuxAttachEvent.self, from: json)

        #expect(
            event == .resizedReplay(
                surface: 7,
                columns: 100,
                rows: 30,
                bytes: Data([0x1B, 0x5B, 0x3F, 0x6C])
            )
        )
    }

    @Test
    func decodesResizedReplayFallbackSpelling() throws {
        let json = Data(
            #"{"event":"resized","surface":7,"cols":100,"rows":30,"replay":"G1s/bA=="}"#.utf8
        )
        let event = try JSONDecoder().decode(CmuxAttachEvent.self, from: json)

        #expect(
            event == .resizedReplay(
                surface: 7,
                columns: 100,
                rows: 30,
                bytes: Data([0x1B, 0x5B, 0x3F, 0x6C])
            )
        )
    }

    @Test
    func rejectsInvalidOutputBase64() {
        let json = Data(#"{"event":"output","surface":1,"data":"%%%"}"#.utf8)
        #expect(throws: CmuxProtocolError.self) {
            _ = try JSONDecoder().decode(CmuxAttachEvent.self, from: json)
        }
    }
}
