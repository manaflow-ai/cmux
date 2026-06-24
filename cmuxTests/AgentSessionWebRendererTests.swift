import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionWebRendererTests {
    @Test
    func testTrustedShellURLAcceptsOnlyMatchingFileURL() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = AgentSessionWebRendererCoordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )
        let equivalent = resources
            .appendingPathComponent("agent-session-react", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("agent-session-react", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        let otherBundledFile = resources
            .appendingPathComponent("agent-session-solid", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }

    @Test
    func testNativePointerCoordinatesUseWebClientSpace() {
        let point = AgentSessionWebView.clientCoordinatesForNativePointerDown(
            at: NSPoint(x: 358.5, y: 613)
        )

        expectEqual(point.x, 358.5)
        expectEqual(point.y, 613)
    }
}
