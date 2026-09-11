import CmuxTerminal
import Testing

@Suite("Terminal PATH environment")
struct TerminalPathEnvironmentTests {
    @Test("Drops malformed PATH components when prepending a cmux shim")
    func dropsMalformedPathComponentsWhenPrependingShim() {
        let shimDirectory = "/var/folders/demo/cmux-cli-shims/ABC"
        let malformedComponent = "\u{FFFD}u[\u{FFFD}\u{0008}`\u{FFFD}-\u{FFFD}(\u{FFFD}"
        let path = "/usr/bin:\(malformedComponent):/bin"

        let result = TerminalSurface.pathByPrependingUniqueDirectory(
            shimDirectory,
            to: path
        )

        #expect(result == "\(shimDirectory):/usr/bin:/bin")
    }
}
