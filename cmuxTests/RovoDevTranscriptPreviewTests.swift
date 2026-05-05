import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RovoDevTranscriptPreviewTests: XCTestCase {
    func testReadsSessionContextMessagesObject() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "messages": [
            { "role": "user", "content": "Implement Rovo previews" },
            { "role": "assistant", "content": [{ "type": "text", "text": "Done" }] }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "user", text: "Implement Rovo previews"),
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Done"),
        ])
    }
}
