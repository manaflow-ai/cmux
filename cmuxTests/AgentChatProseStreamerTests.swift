import CmuxAgentChat
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentChatProseStreamerTests: XCTestCase {
    private actor SleepGate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testStreamsWhenLegacyUserDefaultsFlagIsFalse() async throws {
        let legacyDefaultsKey = "CMUXAgentChatProseStreaming"
        let previousLegacyValue = UserDefaults.standard.object(forKey: legacyDefaultsKey)
        UserDefaults.standard.set(false, forKey: legacyDefaultsKey)
        defer {
            if let previousLegacyValue {
                UserDefaults.standard.set(previousLegacyValue, forKey: legacyDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            }
        }

        let surfaceID = UUID()
        let sessionID = "session-with-always-on-streaming"
        let expectedText = "The sky is blue."
        let screenRows = [
            "> Reply with one short sentence about blue.",
            "",
            expectedText,
            "",
            "Working (3s Esc to interrupt)",
            "> ",
        ]

        let emittedFrame = expectation(description: "streaming prose frame emitted")
        let sleepGate = SleepGate()
        var emittedFrames: [ChatSessionEventFrame] = []
        let streamer = AgentChatProseStreamer(
            emit: { frame in
                if emittedFrames.isEmpty {
                    emittedFrame.fulfill()
                }
                emittedFrames.append(frame)
            },
            snapshot: { requestedSurfaceID in
                requestedSurfaceID == surfaceID ? screenRows : nil
            },
            hasSubscribers: { true },
            now: { Date(timeIntervalSince1970: 1_711_111_111) },
            pollInterval: .seconds(60),
            sleep: { _ in await sleepGate.wait() }
        )

        streamer.turnStarted(sessionID: sessionID, surfaceID: surfaceID, agentKind: .codex)
        await fulfillment(of: [emittedFrame], timeout: 1.0)
        streamer.turnEnded(sessionID: sessionID)
        await sleepGate.resume()

        let frame = try XCTUnwrap(emittedFrames.first)
        XCTAssertEqual(frame.sessionID, sessionID)
        guard case .streamingProse(let message?) = frame.event else {
            return XCTFail("Expected a streaming prose preview frame")
        }
        XCTAssertEqual(message.id, "stream:\(sessionID)")
        XCTAssertEqual(message.role, .agent)
        guard case .prose(let prose) = message.kind else {
            return XCTFail("Expected prose preview content")
        }
        XCTAssertEqual(prose.text, expectedText)
    }
}
