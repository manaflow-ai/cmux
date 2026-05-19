import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GeminiVoiceTests: XCTestCase {
    func testAPIKeyResolverPrefersEnvironmentGeminiKey() {
        let resolved = GeminiVoiceAPIKeyResolver.resolve(
            environment: [
                "GEMINI_API_KEY": " gemini-key ",
                "GOOGLE_API_KEY": "google-key",
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp/cmux-missing-home-\(UUID().uuidString)")
        )

        XCTAssertEqual(resolved?.value, "gemini-key")
        XCTAssertEqual(resolved?.source, .environment("GEMINI_API_KEY"))
    }

    func testAPIKeyResolverParsesEnvFiles() throws {
        let parsed = GeminiVoiceAPIKeyResolver.parseEnvFile(
            """
            # ignored
            export GEMINI_API_KEY='from-env-file'
            GOOGLE_API_KEY=other-value # comment
            """
        )

        XCTAssertEqual(parsed["GEMINI_API_KEY"], "from-env-file")
        XCTAssertEqual(parsed["GOOGLE_API_KEY"], "other-value")
    }

    func testAPIKeyResolverReadsSecretsEnv() throws {
        let home = temporaryDirectory()
        let secrets = home.appendingPathComponent(".secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try "GEMINI_API_KEY=from-secrets\n".write(
            to: secrets.appendingPathComponent("cmux.env", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let resolved = GeminiVoiceAPIKeyResolver.resolve(
            environment: [:],
            homeDirectory: home
        )

        XCTAssertEqual(resolved?.value, "from-secrets")
        XCTAssertEqual(resolved?.source, .file(secrets.appendingPathComponent("cmux.env"), "GEMINI_API_KEY"))
    }

    func testPromptIncludesCorrectionExamples() {
        let prompt = GeminiVoicePromptBuilder.makeTranscriptionPrompt(
            correctionExamples: [
                GeminiVoiceCorrectionExample(
                    transcript: "open the c mux window",
                    correction: "open the cmux window"
                ),
                GeminiVoiceCorrectionExample(
                    transcript: "use gem and I flash",
                    correction: "use Gemini Flash"
                ),
            ]
        )

        XCTAssertTrue(prompt.contains("open the c mux window"))
        XCTAssertTrue(prompt.contains("open the cmux window"))
        XCTAssertTrue(prompt.contains("use gem and I flash"))
        XCTAssertTrue(prompt.contains("use Gemini Flash"))
    }

    func testCorrectionExamplesComeFromSavedPairsOnly() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            record(id: UUID(), createdAt: base.addingTimeInterval(20), transcript: "later", correction: "later corrected"),
            record(id: UUID(), createdAt: base.addingTimeInterval(10), transcript: "missing correction", correction: ""),
            record(id: UUID(), createdAt: base, transcript: "earlier", correction: "earlier corrected"),
        ]

        let examples = GeminiVoicePromptBuilder.correctionExamples(from: records)

        XCTAssertEqual(
            examples,
            [
                GeminiVoiceCorrectionExample(transcript: "earlier", correction: "earlier corrected"),
                GeminiVoiceCorrectionExample(transcript: "later", correction: "later corrected"),
            ]
        )
    }

    func testGeminiRequestContainsInlineAudioAndPrompt() throws {
        let client = GeminiVoiceClient()
        let audioData = Data([0x01, 0x02, 0x03])
        let prepared = try client.prepareRequest(
            audioData: audioData,
            mimeType: "audio/wav",
            model: "models/gemini-3-flash-preview",
            prompt: "transcribe this",
            apiKey: "test-key"
        )

        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "x-goog-api-key"), "test-key")
        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.bodyData) as? [String: Any])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(contents.first)
        let parts = try XCTUnwrap(firstContent["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.first?["text"] as? String, "transcribe this")
        let inlineData = try XCTUnwrap(parts.dropFirst().first?["inlineData"] as? [String: String])
        XCTAssertEqual(inlineData["mimeType"], "audio/wav")
        XCTAssertEqual(inlineData["data"], audioData.base64EncodedString())
    }

    func testSessionStoreRoundTripsRecords() async throws {
        let root = temporaryDirectory()
        let store = GeminiVoiceSessionStore(rootDirectory: root)
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = record(
            id: id,
            createdAt: createdAt,
            transcript: "raw transcript",
            correction: "corrected transcript"
        )

        try await store.save([original])
        let loaded = try await store.load()

        XCTAssertEqual(loaded, [original])

        let requestPath = try await store.writeRequest(Data("{\"ok\":true}".utf8), id: id)
        let responsePath = try await store.writeResponse(Data("{\"done\":true}".utf8), id: id)

        XCTAssertEqual(requestPath, "requests/\(id.uuidString).json")
        XCTAssertEqual(responsePath, "responses/\(id.uuidString).json")
        let requestData = try await store.readData(relativePath: requestPath)
        let responseData = try await store.readData(relativePath: responsePath)
        XCTAssertEqual(requestData, Data("{\"ok\":true}".utf8))
        XCTAssertEqual(responseData, Data("{\"done\":true}".utf8))
    }

    private func record(
        id: UUID,
        createdAt: Date,
        transcript: String,
        correction: String
    ) -> GeminiVoiceSessionRecord {
        GeminiVoiceSessionRecord(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .completed,
            model: "gemini-3-flash-preview",
            mimeType: "audio/wav",
            audioFileName: "audio/\(id.uuidString).wav",
            durationSeconds: 1.2,
            inputPrompt: "prompt",
            transcript: transcript,
            correction: correction,
            rawResponseText: "{}"
        )
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-gemini-voice-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
