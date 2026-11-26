import CmuxWorkspaces
import Testing

@Suite
struct CompositorBlurWindowLifetimeTests {
    @Test("blur reset is harmless before a window has a server number", arguments: [-1, Int.min, 0])
    func resetBeforeWindowRealization(windowNumber: Int) {
        // Returning without a trap is the contract: NSWindow can report -1
        // while a terminal view is attaching to a deferred window.
        CompositorBlurController().resetBackgroundBlur(windowNumber: windowNumber)
    }
}
