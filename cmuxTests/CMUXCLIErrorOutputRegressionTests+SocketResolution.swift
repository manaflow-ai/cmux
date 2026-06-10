import CmuxSocketControl
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Bundled CLI socket resolution
extension CMUXCLIErrorOutputRegressionTests {
    func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Redirect the CLI's stable-socket resolution to the temp home so this
        // test is hermetic (CFFIXED_USER_HOME overrides homeDirectoryForCurrentUser).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    func testBundledCLIInTaggedDebugAppTreatsCaseVariantStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-case-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)
        let stableSocketPath = stableSocketURL.path
        let caseVariantStablePath = stableSocketURL
            .deletingLastPathComponent()
            .appendingPathComponent("CMUX.sock", isDirectory: false)
            .path

        let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = caseVariantStablePath
        // Resolve the stable path under the temp home so the case-variant env
        // socket is recognized as the implicit default hermetically.
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "PONG",
            result.stdout
        )
        XCTAssertEqual(stableResponder.receivedRequests, [])
    }

    func testBundledCLIInTaggedDebugAppDoesNotFallBackToStableEnvSocketWhenTaggedSocketIsMissing() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tagSlug = "cli-missing-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        try? FileManager.default.removeItem(atPath: taggedSocketPath)
        defer { try? FileManager.default.removeItem(atPath: taggedSocketPath) }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "OK STABLE")
        defer { stableResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"
        environment["CMUX_SOCKET_PATH"] = stableSocketURL.path
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains(taggedSocketPath), result.stdout)
        XCTAssertFalse(result.stdout.contains("OK STABLE"), result.stdout)
        XCTAssertEqual(stableResponder.receivedRequests, [])
    }

    func testBundledCLIInTaggedDebugAppTreatsUserScopedStableEnvSocketAsImplicitDefault() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmux-cli-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let stableSocketURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
        let stableSocketPath = stableSocketURL.path
        try FileManager.default.createDirectory(
            at: stableSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let aliases = [
            stableSocketPath,
            stableSocketURL
                .deletingLastPathComponent()
                .appendingPathComponent("CMUX-\(getuid()).sock", isDirectory: false)
                .path,
        ]

        if FileManager.default.fileExists(atPath: stableSocketPath) {
            throw XCTSkip("User-scoped stable cmux socket already exists at \(stableSocketPath)")
        }

        for alias in aliases {
            try autoreleasepool {
                let tagSlug = "cli-user-\(UUID().uuidString.lowercased())"
                let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
                let stableResponder = try UnixSocketResponder(path: stableSocketPath, response: "OK STABLE")
                defer { stableResponder.stop() }
                let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "PONG")
                defer { taggedResponder.stop() }

                let fakeCLIPath = try fakeTaggedBundledCLIPath(
                    sourceCLIPath: cliPath,
                    tagSlug: tagSlug
                )
                var environment = ProcessInfo.processInfo.environment
                for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
                    environment.removeValue(forKey: key)
                }
                environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
                environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
                environment["CMUX_SOCKET_PATH"] = alias
                environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

                let result = runProcess(
                    executablePath: fakeCLIPath,
                    arguments: ["ping"],
                    environment: environment,
                    timeout: 5
                )

                XCTAssertFalse(result.timedOut, result.stdout)
                XCTAssertEqual(result.status, 0, result.stdout)
                XCTAssertEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "PONG",
                    result.stdout
                )
                XCTAssertEqual(stableResponder.receivedRequests, [], alias)
            }
        }
    }

    func testBundledStableCLIPreservesLiveUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: userScopedStableSocketPath) {
            throw XCTSkip("User-scoped stable cmux socket already exists at \(userScopedStableSocketPath)")
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let userScopedResponder = try UnixSocketResponder(path: userScopedStableSocketPath, response: "OK USER")
        defer { userScopedResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK USER",
            result.stdout
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [])
        XCTAssertEqual(
            userScopedResponder.receivedRequests.count,
            1,
            userScopedResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            userScopedResponder.receivedRequests.contains { $0.contains("ping") },
            userScopedResponder.receivedRequests.joined(separator: "\n")
        )
    }

    func testBundledStableCLIFallsBackFromStaleUserScopedStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let userScopedStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux-\(getuid()).sock", isDirectory: false)
            .path
        if FileManager.default.fileExists(atPath: userScopedStableSocketPath) {
            throw XCTSkip("User-scoped stable cmux socket already exists at \(userScopedStableSocketPath)")
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = userScopedStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.stdout
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
    }

    func testBundledStableCLIFallsBackFromSymlinkedLegacyStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let legacyStableSocketPath = "/tmp/cmux.sock"
        let symlinkTargetSocketPath = "/tmp/cmux-symlink-target-\(UUID().uuidString).sock"
        if lstatPathExists(legacyStableSocketPath) {
            throw XCTSkip("Legacy stable cmux socket already exists at \(legacyStableSocketPath)")
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let targetResponder = try UnixSocketResponder(path: symlinkTargetSocketPath, response: "OK TARGET")
        defer { targetResponder.stop() }
        XCTAssertEqual(symlink(symlinkTargetSocketPath, legacyStableSocketPath), 0)
        defer { unlink(legacyStableSocketPath) }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = legacyStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK DEFAULT",
            result.stdout
        )
        XCTAssertEqual(
            defaultResponder.receivedRequests.count,
            1,
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            defaultResponder.receivedRequests.contains { $0.contains("ping") },
            defaultResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertEqual(targetResponder.receivedRequests, [])
    }

    func testBundledStableCLIPreservesLiveLegacyStableEnvSocket() throws {
        let cliPath = try bundledCLIPath()
        let fixedHomeURL = URL(fileURLWithPath: "/tmp/cmxh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixedHomeURL) }
        let socketDirectoryURL = fixedHomeURL
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
        try FileManager.default.createDirectory(
            at: socketDirectoryURL,
            withIntermediateDirectories: true
        )
        let defaultStableSocketPath = socketDirectoryURL
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
        let legacyStableSocketPath = "/tmp/cmux.sock"
        if FileManager.default.fileExists(atPath: legacyStableSocketPath) {
            throw XCTSkip("Legacy stable cmux socket already exists at \(legacyStableSocketPath)")
        }

        let fakeStableCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "stable-\(UUID().uuidString.lowercased())",
            bundleIdentifier: "com.cmuxterm.app",
            bundleName: "cmux"
        )
        let defaultResponder = try UnixSocketResponder(path: defaultStableSocketPath, response: "OK DEFAULT")
        defer { defaultResponder.stop() }
        let legacyResponder = try UnixSocketResponder(path: legacyStableSocketPath, response: "OK LEGACY")
        defer { legacyResponder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_SOCKET_PATH"] = legacyStableSocketPath
        environment["CFFIXED_USER_HOME"] = fixedHomeURL.path

        let result = runProcess(
            executablePath: fakeStableCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OK LEGACY",
            result.stdout
        )
        XCTAssertEqual(defaultResponder.receivedRequests, [])
        XCTAssertEqual(
            legacyResponder.receivedRequests.count,
            1,
            legacyResponder.receivedRequests.joined(separator: "\n")
        )
        XCTAssertTrue(
            legacyResponder.receivedRequests.contains { $0.contains("ping") },
            legacyResponder.receivedRequests.joined(separator: "\n")
        )
    }

    func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let stableSocketURL = try stableSocketURL(home: home)

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug,
            nestedIdentifierlessApp: true
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        // Redirect the CLI's stable-socket resolution to the temp home (hermetic).
        environment["CFFIXED_USER_HOME"] = home.path

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

}
