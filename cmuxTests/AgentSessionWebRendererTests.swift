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
    func testTrustedShellURLAcceptsOnlyAgentSessionAppURL() {
        let expected = CmuxAgentSessionURLSchemeHandler.shellURL
        let equivalent = URL(string: "cmux-agent-session://app/agent-session.html")
        let otherBundledFile = URL(string: "cmux-agent-session://app/diff-viewer.html")

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }

    @Test
    func testAgentSessionSchemeResolvesCompressedModuleAssets() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appAssets = resources
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
        try FileManager.default.createDirectory(at: appAssets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }

        let shell = appAssets.appendingPathComponent("agent-session.html")
        let compressedModule = appAssets.appendingPathComponent("main.mjs.deflate")
        try Data("<html></html>".utf8).write(to: shell)
        try Data([0x78, 0x9c]).write(to: compressedModule)

        let handler = CmuxAgentSessionURLSchemeHandler(resourceDirectoryURL: resources)
        let shellAsset = handler.asset(for: try #require(URL(string: "cmux-agent-session://app/agent-session.html")))
        let moduleAsset = handler.asset(for: try #require(URL(string: "cmux-agent-session://app/main.mjs")))

        expectEqual(shellAsset?.fileURL, shell)
        expectEqual(shellAsset?.mimeType, "text/html")
        expectFalse(shellAsset?.isDeflated ?? true)
        expectEqual(moduleAsset?.fileURL, compressedModule)
        expectEqual(moduleAsset?.mimeType, "text/javascript")
        expectTrue(moduleAsset?.isDeflated ?? false)
        expectNil(handler.asset(for: try #require(URL(string: "cmux-agent-session://other/main.mjs"))))
        expectNil(handler.asset(for: try #require(URL(string: "cmux-agent-session://app/../main.mjs"))))
    }
}
