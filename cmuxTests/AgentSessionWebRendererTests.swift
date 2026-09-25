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
    func testReactShellUsesCustomSchemeForModuleBundle() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let shellURL = AgentSessionWebRendererCoordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )

        #expect(shellURL.scheme == "cmux-agent-session")
        #expect(shellURL.host == "shell")
    }

    @Test
    @MainActor
    func testTerminalCommandQueuedBeforeCloseIsRejectedAfterClose() {
        let coordinator = AgentSessionWebRendererCoordinator()
        var invoked = false
        coordinator.onRunCommand = { _ in
            invoked = true
            return ["accepted": true]
        }

        coordinator.close()

        #expect(throws: AgentSessionBridgeError.self) {
            _ = try coordinator.runTerminalCommandRequest("pwd")
        }
        #expect(!invoked)
    }

    @Test
    func testTrustedShellURLAcceptsOnlyMatchingFileURL() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = AgentSessionWebRendererCoordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )
        let equivalent = resources
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("agent-session.html", isDirectory: false)
        let otherBundledFile = resources
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("diff-viewer.html", isDirectory: false)

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }
}
