import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentExecutableResolverTests: XCTestCase {
    func testResolvesExecutableFromInjectedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        let plan = try resolver.resolve(.codex)
        XCTAssertEqual(plan.executableURL.path, executable.standardizedFileURL.path)
        XCTAssertEqual(plan.arguments, AgentSessionProviderID.codex.launchArguments)
        XCTAssertFalse(plan.executableURL.path.contains("/Contents/Resources/bin/"))
    }

    func testReturnsMissingForAbsentExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": root.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        XCTAssertThrowsError(try resolver.resolve(.opencode)) { error in
            guard case AgentExecutableResolverError.missing(let displayName, let executableName, _) = error else {
                return XCTFail("Expected missing executable error, got \(error)")
            }
            XCTAssertEqual(displayName, AgentSessionProviderID.opencode.displayName)
            XCTAssertEqual(executableName, "opencode")
        }
    }

    func testIgnoresBundleResourceBinEvenWhenExecutableExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let resourceBin = root
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceBin, withIntermediateDirectories: true)
        let bundledExecutable = resourceBin.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: bundledExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledExecutable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": resourceBin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Contents/Resources", isDirectory: true)
        )

        XCTAssertThrowsError(try resolver.resolve(.claude))
    }

    func testProviderLaunchPlansNeverUseEnvFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentExecutableResolverTests-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for provider in AgentSessionProviderID.allCases {
            let executable = bin.appendingPathComponent(provider.executableName)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let resolver = AgentExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            bundleResourceURL: root.appendingPathComponent("Resources", isDirectory: true)
        )

        for provider in AgentSessionProviderID.allCases {
            let plan = try resolver.resolve(provider)
            XCTAssertTrue(plan.executableURL.path.hasPrefix(bin.path))
            XCTAssertNotEqual(plan.executableURL.path, "/usr/bin/env")
            XCTAssertEqual(plan.arguments, provider.launchArguments)
        }
    }
}
