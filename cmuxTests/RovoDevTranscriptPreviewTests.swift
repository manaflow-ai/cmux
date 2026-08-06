import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct RovoDevTranscriptPreviewTests {
    @Test
    func rejectsOversizedContentWhenFileSizeMetadataIsUnavailable() throws {
        #expect(URLProtocol.registerClass(RovoDevOversizedTranscriptURLProtocol.self))
        defer { URLProtocol.unregisterClass(RovoDevOversizedTranscriptURLProtocol.self) }
        let contextURL = try #require(URL(
            string: "\(RovoDevOversizedTranscriptURLProtocol.scheme)://session-context"
        ))

        let turns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)

        #expect(turns == nil)
    }

    @Test
    func readsSessionContextMessagesObject() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "user", text: "Implement Rovo previews"),
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Done"),
        ])
    }

    @Test
    func rejectsContentAppendedAfterExpectedGeneration() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let contextURL = tempDir.appendingPathComponent("session_context.json")
        try Data(#"{"messages":[{"role":"user","content":"captured"}]}"#.utf8)
            .write(to: contextURL)
        let generation = try #require(
            AgentConversationStorageGeneration.capture(atPath: contextURL.path)
        )

        let handle = try FileHandle(forWritingTo: contextURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.synchronize()
        try handle.close()

        let turns = try RovoDevTranscriptPreview.load(
            from: contextURL,
            limit: 10,
            expectedStorageGeneration: generation
        )
        #expect(turns == nil)
    }

    @Test
    func dialogueOnlyExcludesNestedToolContentFromRoleBasedMessages() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-rovodev-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let contextURL = tempDir.appendingPathComponent("session_context.json")
        let context = """
        {
          "messages": [
            {
              "role": "user",
              "content": [{ "type": "input_text", "text": "Keep dialogue only" }]
            },
            {
              "role": "assistant",
              "content": [
                { "type": "output_text", "text": "Visible before tools" },
                { "type": "tool_result", "content": "PRIVATE-TOOL-RESULT" },
                {
                  "type": "function_call",
                  "name": "read_secret",
                  "arguments": { "path": "PRIVATE-FUNCTION-ARGUMENT" }
                },
                { "part_kind": "tool_result", "content": "PRIVATE-PART-RESULT" },
                { "type": "output_text", "text": "Visible after tools" }
              ]
            }
          ]
        }
        """
        try context.write(to: contextURL, atomically: true, encoding: .utf8)

        let loadedTurns = try RovoDevTranscriptPreview.load(
            from: contextURL,
            limit: 10,
            dialogueOnly: true
        )
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "user", text: "Keep dialogue only"),
            RovoDevTranscriptPreviewTurn(
                role: "assistant",
                text: "Visible before tools\n\nVisible after tools"
            ),
        ])
    }

    @Test
    func readsRovoDevMessageHistoryParts() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns.map(\.role) == ["user", "assistant", "tool", "tool", "assistant"])
        #expect(turns[0].text == "Render the Rovo preview")
        #expect(turns[1].text == "I'll inspect the transcript schema.")
        #expect(turns[2].text.contains("read_file"))
        #expect(turns[2].text.contains(#""path" : "session_context.json""#))
        #expect(turns[3].text == "message_history")
        #expect(turns[4].text == "The preview parser is updated.")
    }

    @Test
    func readsRovoDevRoleBasedMessageHistory() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "user", text: "Use the real Rovo schema"),
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Parsed from message_history."),
        ])
    }

    @Test
    func skipsUnknownRovoDevToolWithEmptyInput() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    @Test
    func skipsUnknownRovoDevToolWithNonEmptyInput() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    @Test
    func skipsUnknownRovoDevToolNameFieldWithNonEmptyInput() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Readable assistant text"),
        ])
    }

    @Test
    func doesNotFallBackToSystemPromptParts() throws {
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

        let loadedTurns = try RovoDevTranscriptPreview.load(from: contextURL, limit: 10)
        let turns = try #require(loadedTurns)

        #expect(turns == [
            RovoDevTranscriptPreviewTurn(role: "assistant", text: "Visible response"),
        ])
    }
}
