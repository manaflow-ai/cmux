import Foundation
import CmuxTerminalCore
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal output tee context")
struct TerminalOutputTeeContextTests {
    @Test(.timeLimit(.minutes(1)))
    func concurrentOutputCallbacksDoNotRacePromptDetectionState() {
        let context = TerminalOutputTeeContext(
            workspaceID: UUID(),
            surfaceID: UUID(),
            agentDefinitions: [
                CmuxTaskManagerCodingAgentDefinition(
                    id: "test-agent",
                    displayName: "Test agent",
                    assetName: nil,
                    launchKinds: [],
                    directBasenames: [],
                    argumentNeedles: [],
                    promptTurnDetection: PromptLineTurnDetectionConfiguration(
                        prompt: ">>> "
                    )
                )
            ],
            scrollbackCheckpointFlags: TerminalScrollbackOutputFlags()
        )
        func consume(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { context.consume($0) }
        }

        consume(">>> ")
        consume("request\r\n")
        consume("output\r\n>>> ")

        #expect(context.forwardedSubmissionCount(for: "test-agent") == 1)

        let output = Array("unrelated output\n".utf8)

        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            output.withUnsafeBufferPointer { buffer in
                context.consume(buffer)
            }
        }

        #expect(context.forwardedSubmissionCount(for: "test-agent") == 1)
    }
}

private extension TerminalOutputTeeContext {
    func forwardedSubmissionCount(for agentID: String) -> UInt64? {
        detectorsLock.lock()
        defer { detectorsLock.unlock() }
        return detectors.first { $0.agentID == agentID }?.forwardedSubmissionCount
    }
}
