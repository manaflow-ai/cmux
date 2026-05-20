import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentSessionProviderTests: XCTestCase {
    func testProviderOrderIsStableForPickerAndTabs() {
        XCTAssertEqual(AgentSessionProvider.all.map(\.id), [.codex, .claude, .opencode, .pi])
        XCTAssertEqual(AgentSessionProvider.all.map(\.displayName), ["Codex", "Claude Code", "OpenCode", "Pi"])
    }

    func testCodexProviderUsesExistingAppServerTransport() {
        let provider = AgentSessionProvider.provider(.codex)

        XCTAssertEqual(provider.transport, .stdioJSONRPC)
        XCTAssertEqual(provider.unixSocketSupport, .notApplicable)
        XCTAssertEqual(provider.launchPlan.executableName, "codex")
        XCTAssertEqual(provider.launchPlan.arguments, ["app-server", "--listen", "stdio://"])
    }

    func testClaudeProviderMatchesDesktopStdioShape() {
        let provider = AgentSessionProvider.provider(.claude)

        XCTAssertEqual(provider.transport, .stdioJSONLines)
        XCTAssertEqual(provider.unixSocketSupport, .notApplicable)
        XCTAssertEqual(provider.launchPlan.executableName, "claude")
        XCTAssertEqual(
            provider.launchPlan.arguments,
            [
                "--output-format", "stream-json",
                "--input-format", "stream-json",
                "--permission-prompt-tool", "stdio",
                "--include-partial-messages",
            ]
        )
    }

    func testOpenCodeProviderUsesLoopbackServerInsteadOfUnixSocket() {
        let provider = AgentSessionProvider.provider(.opencode)

        XCTAssertEqual(provider.transport, .httpSSELoopback)
        XCTAssertEqual(provider.unixSocketSupport, .unsupported)
        XCTAssertEqual(provider.launchPlan.executableName, "opencode")
        XCTAssertEqual(
            provider.launchPlan.arguments,
            ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        )
    }

    func testPiProviderUsesRPCModeOverJSONLines() {
        let provider = AgentSessionProvider.provider(.pi)

        XCTAssertEqual(provider.transport, .stdioJSONLines)
        XCTAssertEqual(provider.unixSocketSupport, .notApplicable)
        XCTAssertEqual(provider.launchPlan.executableName, "pi")
        XCTAssertEqual(provider.launchPlan.arguments, ["--mode", "rpc"])
    }

    func testExecutableResolverReturnsUserOwnedExecutableAndPreservesArguments() throws {
        let fixture = try ProviderExecutableFixture()
        defer { fixture.remove() }

        for provider in AgentSessionProvider.all {
            try fixture.writeExecutable(named: provider.launchPlan.executableName)
        }

        let resolver = AgentExecutableResolver(baseEnvironment: fixture.environment)

        for provider in AgentSessionProvider.all {
            let resolved = try resolver.resolveLaunchPlan(for: provider)

            XCTAssertEqual(
                resolved.executablePath,
                fixture.binDirectory.appendingPathComponent(provider.launchPlan.executableName).path
            )
            XCTAssertEqual(resolved.arguments, provider.launchPlan.arguments)
        }
    }

    func testExecutableResolverThrowsStructuredMissingExecutableError() throws {
        let fixture = try ProviderExecutableFixture()
        defer { fixture.remove() }

        let missingName = "cmux-missing-provider-\(UUID().uuidString)"
        let provider = AgentSessionProvider(
            id: .claude,
            displayName: "Claude Code",
            transport: .stdioJSONLines,
            unixSocketSupport: .notApplicable,
            launchPlan: AgentSessionLaunchPlan(executableName: missingName, arguments: ["--json"])
        )

        XCTAssertThrowsError(try AgentExecutableResolver(baseEnvironment: fixture.environment).resolveLaunchPlan(for: provider)) { error in
            guard case let AgentExecutableResolverError.missingExecutable(
                providerID,
                providerName,
                executableName,
                searchPaths
            ) = error else {
                return XCTFail("Expected structured missing executable error, got \(error)")
            }

            XCTAssertEqual(providerID, .claude)
            XCTAssertEqual(providerName, "Claude Code")
            XCTAssertEqual(executableName, missingName)
            XCTAssertTrue(searchPaths.contains(fixture.binDirectory.path))
            XCTAssertTrue(error.localizedDescription.contains("Claude Code"))
            XCTAssertTrue(error.localizedDescription.contains(missingName))
        }
    }

    func testExecutableResolverDoesNotSearchOwnBundleResources() throws {
        let bundleResourceBin = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResourceBin, withIntermediateDirectories: true)
        let executableName = "cmux-resource-only-provider-\(UUID().uuidString)"
        let executableURL = bundleResourceBin.appendingPathComponent(executableName)
        defer { try? FileManager.default.removeItem(at: executableURL) }
        try ProviderExecutableFixture.writeExecutable(named: executableName, in: bundleResourceBin)

        let provider = AgentSessionProvider(
            id: .codex,
            displayName: "Codex",
            transport: .stdioJSONRPC,
            unixSocketSupport: .notApplicable,
            launchPlan: AgentSessionLaunchPlan(executableName: executableName, arguments: ["app-server"])
        )
        let environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": bundleResourceBin.path,
        ]

        XCTAssertThrowsError(try AgentExecutableResolver(baseEnvironment: environment).resolveLaunchPlan(for: provider)) { error in
            guard case let AgentExecutableResolverError.missingExecutable(_, _, _, searchPaths) = error else {
                return XCTFail("Expected structured missing executable error, got \(error)")
            }
            XCTAssertFalse(searchPaths.contains(bundleResourceBin.path))
        }
    }

    func testProviderEnvironmentPreservesOwnBundleResourceBinForBundledCmuxHooks() throws {
        let bundleResourceBin = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleResourceBin, withIntermediateDirectories: true)

        let environment = AgentExecutableResolver.providerEnvironment(
            baseEnvironment: [
                "HOME": FileManager.default.temporaryDirectory.path,
                "PATH": "/usr/bin:/bin",
            ]
        )
        let pathComponents = try XCTUnwrap(environment["PATH"]).split(separator: ":").map(String.init)
        XCTAssertTrue(pathComponents.contains(bundleResourceBin.path))
    }

    func testExecutableResolverAllowsUserProviderInsideOtherAppBundleResourceBin() throws {
        let fixture = try ProviderExecutableFixture()
        defer { fixture.remove() }

        let resourceBin = fixture.root
            .appendingPathComponent("OtherAgent.app/Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBin, withIntermediateDirectories: true)
        let executableName = "cmux-user-app-bundle-provider-\(UUID().uuidString)"
        try ProviderExecutableFixture.writeExecutable(named: executableName, in: resourceBin)

        var environment = fixture.environment
        environment["PATH"] = resourceBin.path
        let provider = AgentSessionProvider(
            id: .codex,
            displayName: "Codex",
            transport: .stdioJSONRPC,
            unixSocketSupport: .notApplicable,
            launchPlan: AgentSessionLaunchPlan(executableName: executableName, arguments: ["app-server"])
        )

        let resolved = try AgentExecutableResolver(baseEnvironment: environment).resolveLaunchPlan(for: provider)
        XCTAssertEqual(resolved.executablePath, resourceBin.appendingPathComponent(executableName).path)
    }

    @MainActor
    func testCodexPanelDefaultsToCodexProvider() {
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp"
        )

        XCTAssertEqual(panel.provider, .provider(.codex))
        XCTAssertEqual(panel.displayTitle, "Codex")
        XCTAssertEqual(panel.selectedModelDisplayName, "Codex")
    }

    @MainActor
    func testCodexPanelCanCarryNonCodexProviderDescriptor() {
        let panel = CodexAppServerPanel(
            workspaceId: UUID(),
            cwd: "/tmp",
            provider: .provider(.opencode)
        )

        XCTAssertEqual(panel.provider, .provider(.opencode))
        XCTAssertEqual(panel.displayTitle, "OpenCode")
        XCTAssertEqual(panel.selectedModelDisplayName, "OpenCode")
    }
}

private struct ProviderExecutableFixture {
    let root: URL
    let binDirectory: URL

    var environment: [String: String] {
        [
            "HOME": root.path,
            "PATH": binDirectory.path,
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-provider-executables-\(UUID().uuidString)", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    }

    func writeExecutable(named name: String) throws {
        try Self.writeExecutable(named: name, in: binDirectory)
    }

    static func writeExecutable(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
