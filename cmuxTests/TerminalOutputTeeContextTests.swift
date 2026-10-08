import Foundation
import CmuxTerminalCore
import Testing

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
        let output = Array("unrelated output\n".utf8)

        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            output.withUnsafeBufferPointer { buffer in
                context.consume(buffer)
            }
        }

        #expect(true)
    }
}
