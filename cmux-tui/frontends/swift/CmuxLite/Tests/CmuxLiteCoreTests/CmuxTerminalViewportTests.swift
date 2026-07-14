@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxTerminalViewportTests {
    @Test
    func ignoresIndentedPromptPaddingMarkerUntilPromptArrives() {
        #expect(!CmuxTerminalViewport(
            text: "                                                       %\n"
        ).hasPresentableInitialOutput)
        #expect(CmuxTerminalViewport(
            text: "                                                       %\nlawrence in ~ λ\n"
        ).hasPresentableInitialOutput)
    }

    @Test
    func acceptsOrdinaryPercentPromptAndText() {
        #expect(CmuxTerminalViewport(text: "%\n").hasPresentableInitialOutput)
        #expect(CmuxTerminalViewport(text: "progress 100%\n").hasPresentableInitialOutput)
        #expect(!CmuxTerminalViewport(text: "\n").hasPresentableInitialOutput)
    }
}
