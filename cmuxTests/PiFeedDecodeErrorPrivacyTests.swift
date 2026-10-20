import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pi Feed decode error privacy")
struct PiFeedDecodeErrorPrivacyTests {
    @Test
    func emptyAcknowledgedBatchFailsBeforeDelivery() {
        let result = TerminalController.shared.v2IngestAcknowledgedFeedEvents([])
        guard case .err(let code, let message, _) = result else {
            Issue.record("empty acknowledged Feed batch did not fail")
            return
        }

        #expect(code == "invalid_params")
        #expect(message == "feed.push requires an `event` object")
    }

    @Test
    func malformedEventReturnsStableErrorWithoutDecoderDetails() throws {
        let request: [String: Any] = [
            "id": "pi-feed-decode-privacy",
            "method": "feed.push",
            "params": [
                "event": [
                    "session_id": ["private_marker": "must-not-leak"],
                    "hook_event_name": "PostToolUse",
                    "_source": "pi",
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let responseLine = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(responseLine.data(using: .utf8))
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let error = try #require(response["error"] as? [String: Any])

        #expect(error["code"] as? String == "invalid_params")
        #expect(error["message"] as? String == "feed.push event failed to decode")
        #expect(!responseLine.contains("must-not-leak"))
    }
}
