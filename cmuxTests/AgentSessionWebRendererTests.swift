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
            rendererKind: .solid,
            resourceDirectoryURL: resources
        )
        let equivalent = resources
            .appendingPathComponent("agent-session-solid", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("agent-session-solid", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        let otherBundledFile = resources
            .appendingPathComponent("agent-session-solid", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("app.js", isDirectory: false)

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }

    @Test
    func testTrustedShellURLAcceptsOnlyMatchingAgentSessionSchemeURL() {
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = AgentSessionWebRendererCoordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )
        let equivalent = URL(string: "CMUX-AGENT-SESSION://SHELL/agent-session.html")
        let otherBundledFile = URL(string: "cmux-agent-session://shell/main.mjs")

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "file:///tmp/agent-session.html"), expected: expected))
    }

    @Test
    func testAgentSessionSchemeHandlerContainsAndTypesBundledResources() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-session-\(UUID().uuidString)", isDirectory: true)
        let chunksURL = rootURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        try Data("export {};".utf8).write(to: chunksURL.appendingPathComponent("main.mjs"))
        try Data("private".utf8).write(to: rootURL.deletingLastPathComponent().appendingPathComponent("outside.mjs"))

        let handler = AgentSessionWebRendererURLSchemeHandler(rootURL: rootURL, fileManager: fileManager)
        let resource = try handler.resourceURL(
            for: URL(string: "cmux-agent-session://shell/chunks/main.mjs")!
        )
        #expect(resource.url == chunksURL.appendingPathComponent("main.mjs").standardizedFileURL)
        #expect(resource.mimeType == "text/javascript")

        let compressedURL = chunksURL.appendingPathComponent("compressed.mjs")
        try DeflatedAssetTestSupport.writeText(
            "export const compressed = true;\n",
            to: compressedURL,
            addingDeflateExtension: true
        )
        let compressedResource = try handler.resourceData(
            for: URL(string: "cmux-agent-session://shell/chunks/compressed.mjs")!
        )
        #expect(String(data: compressedResource.data, encoding: .utf8) == "export const compressed = true;\n")
        #expect(compressedResource.contentType == "text/javascript; charset=utf-8")

        #expect(throws: URLError.self) {
            _ = try handler.resourceURL(for: URL(string: "cmux-agent-session://shell/../outside.mjs")!)
        }
        #expect(throws: URLError.self) {
            _ = try handler.resourceURL(for: URL(string: "cmux-agent-session://shell/chunks/main.txt")!)
        }
    }
}
