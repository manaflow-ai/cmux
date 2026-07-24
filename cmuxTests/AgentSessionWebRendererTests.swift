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
    func testShellURLUsesAgentSessionAssetScheme() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = AgentSessionWebRendererCoordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )
        let script = URL(string: "./main.mjs", relativeTo: expected)?.absoluteURL

        expectEqual(expected.scheme, "cmux-agent-session")
        expectEqual(expected.host, "bundle")
        expectEqual(expected.path, "/markdown-viewer/webviews-app/agent-session.html")
        expectEqual(script?.scheme, "cmux-agent-session")
        expectEqual(script?.path, "/markdown-viewer/webviews-app/main.mjs")
    }

    @Test
    func testTrustedShellURLAcceptsOnlyMatchingAgentSessionURL() {
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
        let otherBundledFile = URL(string: "cmux-agent-session://bundle/markdown-viewer/webviews-app/main.mjs")

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }

    @Test
    func testAgentSessionAssetLookupFallsBackToDeflatedModules() throws {
        let root = try temporaryDirectory()
        let main = root
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("main.mjs", isDirectory: false)
        try FileManager.default.createDirectory(
            at: main.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try DeflatedAssetTestSupport.writeText("console.log('agent')", to: main, addingDeflateExtension: true)

        let requestURL = URL(string: "cmux-agent-session://bundle/markdown-viewer/webviews-app/main.mjs")
        let resolved = AgentSessionWebRendererCoordinator.agentSessionAssetFileURL(
            for: requestURL,
            resourceDirectoryURL: root
        )

        expectEqual(resolved, main.appendingPathExtension("deflate"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-agent-session-web-renderer-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
