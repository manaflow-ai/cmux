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

    func testReadsRovoDevMessageHistoryParts() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "kind": "request",
              "parts": [
                { "part_kind": "system-prompt", "content": "Internal instructions" },
                { "part_kind": "user-prompt", "content": "Render the Rovo preview" }
              ],
              "timestamp": "2026-01-15T10:00:00.000Z"
            },
            {
              "kind": "response",
              "parts": [
                { "part_kind": "text", "content": "I'll inspect the transcript schema." },
                {
                  "part_kind": "tool_use",
                  "tool_name": "read_file",
                  "tool_input": { "path": "session_context.json" }
                },
                { "part_kind": "tool_result", "content": "message_history" },
                { "part_kind": "text", "content": "The preview parser is updated." }
              ],
              "timestamp": "2026-01-15T10:00:05.000Z"
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "tool", "tool", "assistant"])
        XCTAssertEqual(turns[0].text, "Render the Rovo preview")
        XCTAssertEqual(turns[1].text, "I'll inspect the transcript schema.")
        XCTAssertTrue(turns[2].text.contains("read_file"))
        XCTAssertTrue(turns[2].text.contains(#""path" : "session_context.json""#))
        XCTAssertEqual(turns[3].text, "message_history")
        XCTAssertEqual(turns[4].text, "The preview parser is updated.")
    }

    func testReadsRovoDevRoleBasedMessageHistory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "role": "user",
              "parts": [{ "part_kind": "text", "content": "Use the real Rovo schema" }]
            },
            {
              "role": "assistant",
              "parts": [{ "part_kind": "text", "content": "Parsed from message_history." }]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "user", text: "Use the real Rovo schema"),
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Parsed from message_history."),
        ])
    }

    func testSkipsUnknownRovoDevToolWithEmptyInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "role": "assistant",
              "parts": [
                { "part_kind": "tool_use", "tool_name": "unknown", "tool_input": {} },
                { "part_kind": "text", "content": "Readable assistant text" }
              ]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    func testSkipsUnknownRovoDevToolWithNonEmptyInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "role": "assistant",
              "parts": [
                {
                  "part_kind": "tool_use",
                  "tool_name": "unknown",
                  "tool_input": { "path": "internal/session_context.json" }
                },
                { "part_kind": "text", "content": "Readable assistant text" }
              ]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    func testSkipsUnknownRovoDevToolNameFieldWithNonEmptyInput() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "role": "assistant",
              "parts": [
                {
                  "part_kind": "tool_use",
                  "name": "unknown",
                  "input": { "path": "internal/session_context.json" }
                },
                { "part_kind": "text", "content": "Readable assistant text" }
              ]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    func testDoesNotFallBackToSystemPromptParts() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "message_history": [
            {
              "role": "user",
              "parts": [
                { "part_kind": "system-prompt", "content": "Internal instructions should stay hidden" }
              ]
            },
            {
              "role": "assistant",
              "parts": [
                { "part_kind": "text", "content": "Visible response" }
              ]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let turns = try XCTUnwrap(RovoDevTranscriptPreview.load(from: contextURL, limit: 10))

        XCTAssertEqual(turns, [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Visible response"),
        ])
    }
}
