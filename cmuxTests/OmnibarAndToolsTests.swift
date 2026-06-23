import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class FinderServicePathResolverTests: XCTestCase {
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-finder-service-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/../cmux-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/project",
                "/tmp/cmux-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/cmux-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/cmux-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/cmux-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/cmux-services/b",
                "/tmp/cmux-services/a",
            ]
        )
    }

    func testOrderedUniqueDirectoriesSkipsBundleAndEmbeddedPathsWhenExcludingBundleRoot() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Tools/../cmux.app", isDirectory: true)
        let input: [URL] = [
            bundleURL,
            URL(fileURLWithPath: "/Applications/cmux.app/Contents/MacOS/cmux", isDirectory: false),
            URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/bin/cmux", isDirectory: false),
            URL(fileURLWithPath: "/Users/tester/Projects/cmux", isDirectory: true),
            URL(fileURLWithPath: "/Users/tester/Projects/cmux/README.md", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(
            from: input,
            excludingDescendantsOf: [bundleURL]
        )

        XCTAssertEqual(
            directories,
            [
                "/Users/tester/Projects/cmux",
            ]
        )
    }

    func testOrderedUniqueDirectoriesExclusionDoesNotFilterSiblingPaths() {
        let bundleURL = URL(fileURLWithPath: "/Applications/cmux.app", isDirectory: true)
        let input: [URL] = [
            URL(fileURLWithPath: "/Applications/cmux.app backup/project", isDirectory: true),
            URL(fileURLWithPath: "/Applications/cmux.app.beta/project/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(
            from: input,
            excludingDescendantsOf: [bundleURL]
        )

        XCTAssertEqual(
            directories,
            [
                "/Applications/cmux.app backup/project",
                "/Applications/cmux.app.beta/project",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesSymlinkAliasPaths() throws {
        try withTemporaryDirectory { root in
            let actualDirectory = root.appendingPathComponent("actual/project", isDirectory: true)
            let aliasDirectory = root.appendingPathComponent("alias-project", isDirectory: true)
            let actualFile = actualDirectory.appendingPathComponent("README.md", isDirectory: false)
            let aliasFile = aliasDirectory.appendingPathComponent("README.md", isDirectory: false)

            try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: actualFile.path, contents: Data())
            try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: actualDirectory)

            let directories = FinderServicePathResolver.orderedUniqueDirectories(
                from: [aliasDirectory, aliasFile]
            )

            XCTAssertEqual(directories, [aliasDirectory.standardizedFileURL.path])
            XCTAssertNotEqual(directories, [actualDirectory.standardizedFileURL.path])
        }
    }

    func testOrderedUniqueDirectoriesDedupesSymlinkAndRealPaths() throws {
        try withTemporaryDirectory { root in
            let actualDirectory = root.appendingPathComponent("actual/project", isDirectory: true)
            let aliasDirectory = root.appendingPathComponent("alias-project", isDirectory: true)

            try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: actualDirectory)

            let directories = FinderServicePathResolver.orderedUniqueDirectories(
                from: [aliasDirectory, actualDirectory]
            )

            XCTAssertEqual(directories, [aliasDirectory.standardizedFileURL.path])
        }
    }

    func testOrderedUniqueDirectoriesResolvesSymlinksOnlyForExcludedRootComparison() throws {
        try withTemporaryDirectory { root in
            let applicationsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
            let actualBundle = applicationsDirectory.appendingPathComponent("cmux.app", isDirectory: true)
            let actualBinary = actualBundle.appendingPathComponent("Contents/MacOS/cmux", isDirectory: false)
            let aliasApplications = root.appendingPathComponent("Launcher", isDirectory: true)
            let aliasWorkspace = aliasApplications.appendingPathComponent("workspace", isDirectory: true)

            try FileManager.default.createDirectory(at: actualBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: actualBinary.path, contents: Data())
            try FileManager.default.createDirectory(
                at: applicationsDirectory.appendingPathComponent("workspace", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: aliasApplications, withDestinationURL: applicationsDirectory)

            let directories = FinderServicePathResolver.orderedUniqueDirectories(
                from: [
                    aliasApplications.appendingPathComponent("cmux.app", isDirectory: true),
                    aliasApplications.appendingPathComponent("cmux.app/Contents/MacOS/cmux", isDirectory: false),
                    aliasWorkspace,
                ],
                excludingDescendantsOf: [actualBundle]
            )

            XCTAssertEqual(directories, [aliasWorkspace.standardizedFileURL.path])
        }
    }
}


final class VSCodeServeWebURLBuilderTests: XCTestCase {
    func testExtractWebUIURLParsesServeWebOutput() {
        let output = """
        *
        * Visual Studio Code Server
        *
        Web UI available at http://127.0.0.1:5555?tkn=test-token
        """

        let url = VSCodeServeWebURLBuilder.extractWebUIURL(from: output)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:5555?tkn=test-token")
    }

    func testOpenFolderURLAppendsFolderQueryWhilePreservingToken() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/Projects/cmux"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "tkn" })?.value, "test-token")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "folder" })?.value, "/Users/tester/Projects/cmux")
    }

    func testOpenFolderURLReplacesExistingFolderQuery() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token&folder=/tmp/old")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/New Folder"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.filter { $0.name == "folder" }.count,
            1
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "folder" })?.value,
            "/Users/tester/New Folder"
        )
    }
}


final class VSCodeCLILaunchConfigurationBuilderTests: XCTestCase {
    func testLaunchConfigurationPrefersCodeTunnelWrapperOverCachedCodeServer() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let codeTunnelPath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"
        let cachedCodeServerPath = "/Users/tester/.vscode/cli/serve-web/server-new/bin/code-server"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            baseEnvironment: [
                "ELECTRON_RUN_AS_NODE": "stale",
            ],
            isExecutableAtPath: { $0 == codeTunnelPath || $0 == cachedCodeServerPath },
            dataAtURL: { _ in
                XCTFail("Expected code-tunnel wrapper selection to skip cached serve-web discovery")
                return nil
            },
            contentsOfDirectoryAtURL: { _ in
                XCTFail("Expected code-tunnel wrapper selection to skip cached serve-web discovery")
                return []
            },
            contentModificationDateAtURL: { _ in nil }
        )

        XCTAssertEqual(configuration?.executableURL.path, codeTunnelPath)
        XCTAssertEqual(configuration?.argumentsPrefix, ["serve-web"])
        XCTAssertEqual(configuration?.environment["ELECTRON_RUN_AS_NODE"], "1")
        XCTAssertEqual(configuration?.usesCodeTunnelWrapper, true)
        XCTAssertEqual(configuration?.supportsUserDataDirectoryArgument, false)
    }

    func testLaunchConfigurationFallsBackToCachedCodeServerWhenCodeTunnelIsMissing() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let productURL = appURL.appendingPathComponent("Contents/Resources/app/product.json", isDirectory: false)
        let cacheURL = URL(fileURLWithPath: "/Users/tester/.vscode/cli/serve-web", isDirectory: true)
        let lruURL = cacheURL.appendingPathComponent("lru.json", isDirectory: false)
        let codeTunnelPath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"
        let expectedExecutablePath = "/Users/tester/.vscode/cli/serve-web/server-new/bin/code-server"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            baseEnvironment: [
                "ELECTRON_RUN_AS_NODE": "stale",
            ],
            isExecutableAtPath: { $0 != codeTunnelPath && $0 == expectedExecutablePath },
            dataAtURL: { url in
                if url == productURL {
                    return Data(#"{"dataFolderName": ".vscode"}"#.utf8)
                }
                if url == lruURL {
                    return Data(#"["missing","server-new"]"#.utf8)
                }
                return nil
            },
            contentsOfDirectoryAtURL: { _ in
                XCTFail("Expected lru.json to select the cached code-server binary")
                return []
            },
            contentModificationDateAtURL: { _ in nil }
        )

        XCTAssertEqual(configuration?.executableURL.path, expectedExecutablePath)
        XCTAssertEqual(configuration?.argumentsPrefix, [])
        XCTAssertNil(configuration?.environment["ELECTRON_RUN_AS_NODE"])
        XCTAssertEqual(configuration?.usesCodeTunnelWrapper, false)
        XCTAssertEqual(configuration?.supportsUserDataDirectoryArgument, true)
    }

    func testLaunchConfigurationUsesCodeTunnelBinaryWhenNoCacheExists() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let expectedExecutablePath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            baseEnvironment: [:],
            isExecutableAtPath: { $0 == expectedExecutablePath },
            dataAtURL: { _ in nil },
            contentsOfDirectoryAtURL: { _ in [] },
            contentModificationDateAtURL: { _ in nil }
        )

        XCTAssertEqual(configuration?.executableURL.path, expectedExecutablePath)
        XCTAssertEqual(configuration?.argumentsPrefix, ["serve-web"])
        XCTAssertEqual(configuration?.environment["ELECTRON_RUN_AS_NODE"], "1")
        XCTAssertEqual(configuration?.usesCodeTunnelWrapper, true)
        XCTAssertEqual(configuration?.supportsUserDataDirectoryArgument, false)
    }

    func testCodeTunnelProcessLaunchEnablesFileKeyringWithoutUnsupportedUserDataArgument() {
        let configuration = VSCodeCLILaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"),
            argumentsPrefix: ["serve-web"],
            environment: [:],
            usesCodeTunnelWrapper: true,
            supportsUserDataDirectoryArgument: false
        )
        let serverDataDirectoryURL = URL(fileURLWithPath: "/tmp/cmux-vscode/server-data", isDirectory: true)
        let launchOptions = VSCodeServeWebLaunchOptions(
            port: 64120,
            serverDataDirectoryURL: serverDataDirectoryURL,
            userDataDirectoryURL: serverDataDirectoryURL.appendingPathComponent("user-data", isDirectory: true),
            connectionTokenFileURL: serverDataDirectoryURL.appendingPathComponent(
                "connection-token",
                isDirectory: false
            ),
            allowsEphemeralPortFallback: true
        )

        let arguments = configuration.processArguments(for: launchOptions)
        let environment = configuration.processEnvironment(for: launchOptions)

        XCTAssertEqual(Array(arguments.prefix(2)), ["serve-web", "--accept-server-license-terms"])
        XCTAssertTrue(arguments.contains("--server-data-dir"))
        XCTAssertTrue(arguments.contains(serverDataDirectoryURL.path))
        XCTAssertTrue(arguments.contains("--connection-token-file"))
        XCTAssertFalse(arguments.contains("--user-data-dir"))
        XCTAssertFalse(arguments.contains(launchOptions.userDataDirectoryURL.path))
        XCTAssertEqual(environment["VSCODE_CLI_USE_FILE_KEYRING"], "1")
        XCTAssertEqual(
            environment["VSCODE_CLI_DATA_DIR"],
            serverDataDirectoryURL.appendingPathComponent("cli-data", isDirectory: true).path
        )
        XCTAssertNil(environment["VSCODE_CLI_DISABLE_KEYCHAIN_ENCRYPT"])
    }

    func testLaunchConfigurationMapsNodeEnvironmentVariables() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "NODE_OPTIONS": "--max-old-space-size=4096",
                "NODE_REPL_EXTERNAL_MODULE": "module-name"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_OPTIONS"], "--max-old-space-size=4096")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"], "module-name")
        XCTAssertNil(configuration?.environment["NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["NODE_REPL_EXTERNAL_MODULE"])
    }

    func testLaunchConfigurationClearsStaleVSCodeNodeVariablesWhenNodeVariablesAreAbsent() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "VSCODE_NODE_OPTIONS": "--stale",
                "VSCODE_NODE_REPL_EXTERNAL_MODULE": "stale-module"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(configuration?.environment["VSCODE_NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"])
    }
}

final class VSCodeServeWebLaunchOptionsTests: XCTestCase {
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-vscode-serve-web-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    private func withDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "cmux-vscode-serve-web-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    private func assertCmuxGeneratedToken(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let token = try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
        XCTAssertNotNil(
            token.range(of: #"^[0-9A-Fa-f]{32}$"#, options: .regularExpression),
            "Expected a 32-character hexadecimal token, got \(token)",
            file: file,
            line: line
        )
    }

    func testResolveCreatesStableDataDirectoryPortAndTokenFile() throws {
        try withTemporaryDirectory { appSupportURL in
            try withDefaults { defaults in
                let first = try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                    environment: [:],
                    defaults: defaults,
                    bundleIdentifier: "dev.cmux.test",
                    applicationSupportDirectoryURL: appSupportURL
                ))
                let firstTokenData = try Data(contentsOf: first.connectionTokenFileURL)

                let second = try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                    environment: [:],
                    defaults: defaults,
                    bundleIdentifier: "dev.cmux.test",
                    applicationSupportDirectoryURL: appSupportURL
                ))
                let secondTokenData = try Data(contentsOf: second.connectionTokenFileURL)

                try assertCmuxGeneratedToken(firstTokenData)
                XCTAssertEqual(first.port, second.port)
                XCTAssertTrue(first.allowsEphemeralPortFallback)
                XCTAssertEqual(first.ephemeralPortFallback()?.port, 0)
                XCTAssertEqual(defaults.integer(forKey: VSCodeServeWebLaunchOptions.portDefaultsKey), first.port)
                XCTAssertEqual(
                    first.serverDataDirectoryURL.path,
                    appSupportURL
                        .appendingPathComponent("dev.cmux.test", isDirectory: true)
                        .appendingPathComponent("vscode-serve-web", isDirectory: true)
                        .path
                )
                XCTAssertEqual(
                    first.userDataDirectoryURL.path,
                    first.serverDataDirectoryURL.appendingPathComponent("user-data", isDirectory: true).path
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: first.userDataDirectoryURL.path))
                XCTAssertEqual(first.connectionTokenFileURL, second.connectionTokenFileURL)
                XCTAssertEqual(first.connectionTokenFileURL.lastPathComponent, "connection-token")
                XCTAssertEqual(firstTokenData, secondTokenData)
                XCTAssertTrue(first.arguments.contains("--server-data-dir"))
                XCTAssertTrue(first.arguments.contains(first.serverDataDirectoryURL.path))
                XCTAssertTrue(first.arguments.contains("--user-data-dir"))
                XCTAssertTrue(first.arguments.contains(first.userDataDirectoryURL.path))
                XCTAssertTrue(first.arguments.contains("--connection-token-file"))
                XCTAssertTrue(first.arguments.contains(first.connectionTokenFileURL.path))
                XCTAssertTrue(first.arguments.contains("--port"))
                XCTAssertTrue(first.arguments.contains(String(first.port)))
                XCTAssertFalse(first.arguments(includeUserDataDirectory: false).contains("--user-data-dir"))
                XCTAssertFalse(first.arguments(includeUserDataDirectory: false).contains(first.userDataDirectoryURL.path))
            }
        }
    }

    func testResolveUsesEnvironmentOverrides() throws {
        try withTemporaryDirectory { rootURL in
            try withDefaults { defaults in
                defaults.set(5555, forKey: VSCodeServeWebLaunchOptions.portDefaultsKey)
                let dataDirectoryURL = rootURL.appendingPathComponent("custom data", isDirectory: true)

                let options = try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                    environment: [
                        VSCodeServeWebLaunchOptions.portEnvironmentKey: "8123",
                        VSCodeServeWebLaunchOptions.dataDirectoryEnvironmentKey: dataDirectoryURL.path,
                    ],
                    defaults: defaults,
                    bundleIdentifier: "dev.cmux.test",
                    applicationSupportDirectoryURL: rootURL
                ))

                XCTAssertEqual(options.port, 8123)
                XCTAssertFalse(options.allowsEphemeralPortFallback)
                XCTAssertNil(options.ephemeralPortFallback())
                XCTAssertEqual(options.serverDataDirectoryURL.path, dataDirectoryURL.path)
                XCTAssertEqual(
                    options.userDataDirectoryURL.path,
                    dataDirectoryURL.appendingPathComponent("user-data", isDirectory: true).path
                )
                XCTAssertEqual(options.connectionTokenFileURL.deletingLastPathComponent().path, dataDirectoryURL.path)
            }
        }
    }

    func testResolveReusesValidConnectionTokenFile() throws {
        try withTemporaryDirectory { rootURL in
            let dataDirectoryURL = rootURL.appendingPathComponent("valid-token", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
            let tokenFileURL = dataDirectoryURL.appendingPathComponent("connection-token", isDirectory: false)
            let existingToken = "0123456789abcdef0123456789ABCDEF"
            try Data(existingToken.utf8).write(to: tokenFileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)

            let options = try withDefaults { defaults in
                try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                    environment: [VSCodeServeWebLaunchOptions.dataDirectoryEnvironmentKey: dataDirectoryURL.path],
                    defaults: defaults,
                    applicationSupportDirectoryURL: rootURL
                ))
            }
            let tokenData = try Data(contentsOf: options.connectionTokenFileURL)

            XCTAssertEqual(options.connectionTokenFileURL, tokenFileURL)
            XCTAssertEqual(String(data: tokenData, encoding: .utf8), existingToken)
        }
    }

    func testResolveReplacesInvalidConnectionTokenFiles() throws {
        let invalidTokens = [
            "",
            "partial",
            String(repeating: "0", count: 31),
            String(repeating: "0", count: 33),
            String(repeating: "g", count: 32),
        ]

        try withTemporaryDirectory { rootURL in
            for (index, invalidToken) in invalidTokens.enumerated() {
                let dataDirectoryURL = rootURL.appendingPathComponent("invalid-token-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
                let tokenFileURL = dataDirectoryURL.appendingPathComponent("connection-token", isDirectory: false)
                try Data(invalidToken.utf8).write(to: tokenFileURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)

                let options = try withDefaults { defaults in
                    try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                        environment: [VSCodeServeWebLaunchOptions.dataDirectoryEnvironmentKey: dataDirectoryURL.path],
                        defaults: defaults,
                        applicationSupportDirectoryURL: rootURL
                    ))
                }
                let tokenData = try Data(contentsOf: options.connectionTokenFileURL)

                XCTAssertEqual(options.connectionTokenFileURL, tokenFileURL)
                try assertCmuxGeneratedToken(tokenData)
                XCTAssertNotEqual(String(data: tokenData, encoding: .utf8), invalidToken)
            }

            let dataDirectoryURL = rootURL.appendingPathComponent("group-readable-token", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
            let tokenFileURL = dataDirectoryURL.appendingPathComponent("connection-token", isDirectory: false)
            let groupReadableToken = String(repeating: "0", count: 32)
            try Data(groupReadableToken.utf8).write(to: tokenFileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenFileURL.path)

            let options = try withDefaults { defaults in
                try XCTUnwrap(VSCodeServeWebLaunchOptions.resolve(
                    environment: [VSCodeServeWebLaunchOptions.dataDirectoryEnvironmentKey: dataDirectoryURL.path],
                    defaults: defaults,
                    applicationSupportDirectoryURL: rootURL
                ))
            }
            let tokenData = try Data(contentsOf: options.connectionTokenFileURL)

            XCTAssertEqual(options.connectionTokenFileURL, tokenFileURL)
            try assertCmuxGeneratedToken(tokenData)
            XCTAssertNotEqual(String(data: tokenData, encoding: .utf8), groupReadableToken)
            let attributes = try FileManager.default.attributesOfItem(atPath: tokenFileURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        }
    }
}


final class ServeWebOutputCollectorTests: XCTestCase {
    func testWaitForURLReturnsFalseAfterProcessExitSignal() {
        let collector = ServeWebOutputCollector()

        // The process exited without ever emitting a Web UI URL. markProcessExited()
        // is the real completion signal that unblocks waitForURL; deliver it first so
        // the wait returns the instant the signal is observed instead of racing an
        // async dispatch and timing the latency. The outcome the prior elapsed-time
        // guard stood for is exactly this: the exit signal (not the timeout) is what
        // releases the wait, and with no URL collected the result is false. A generous
        // timeout remains as a deadline so a regression that fails to signal still
        // fails the test rather than hanging.
        collector.markProcessExited()

        XCTAssertFalse(collector.waitForURL(timeoutSeconds: 5))
        XCTAssertNil(collector.webUIURL)
    }

    func testWaitForURLReturnsTrueWhenURLIsCollected() {
        let collector = ServeWebOutputCollector()
        let urlLine = "Web UI available at http://127.0.0.1:7777?tkn=test-token\n"

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            collector.append(Data(urlLine.utf8))
        }

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:7777?tkn=test-token")
    }

    func testMarkProcessExitedParsesFinalURLWithoutTrailingNewline() {
        let collector = ServeWebOutputCollector()
        let finalChunk = "Web UI available at http://127.0.0.1:9001?tkn=final-token"

        collector.append(Data(finalChunk.utf8))
        collector.markProcessExited()

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 0.1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:9001?tkn=final-token")
    }
}


final class VSCodeServeWebControllerTests: XCTestCase {
    func testStopDuringInFlightLaunchDoesNotDropNextGenerationCompletion() {
        let firstLaunchStarted = expectation(description: "first launch started")
        let firstCompletionCalled = expectation(description: "first generation completion called")
        let secondCompletionCalled = expectation(description: "second generation completion called")

        let launchGate = DispatchSemaphore(value: 0)
        let launchCallLock = NSLock()
        var launchCallCount = 0

        let controller = VSCodeServeWebController { _, _ in
            launchCallLock.lock()
            launchCallCount += 1
            let callNumber = launchCallCount
            launchCallLock.unlock()

            if callNumber == 1 {
                firstLaunchStarted.fulfill()
                _ = launchGate.wait(timeout: .now() + 1)
            }
            return nil
        }

        let callbackLock = NSLock()
        var firstGenerationCallbacks: [URL?] = []
        var secondGenerationCallbacks: [URL?] = []
        let vscodeAppURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            firstGenerationCallbacks.append(url)
            callbackLock.unlock()
            firstCompletionCalled.fulfill()
        }

        wait(for: [firstLaunchStarted], timeout: 1)
        controller.stop()

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            secondGenerationCallbacks.append(url)
            callbackLock.unlock()
            secondCompletionCalled.fulfill()
        }

        launchGate.signal()
        wait(for: [firstCompletionCalled, secondCompletionCalled], timeout: 2)

        callbackLock.lock()
        let firstSnapshot = firstGenerationCallbacks
        let secondSnapshot = secondGenerationCallbacks
        callbackLock.unlock()

        launchCallLock.lock()
        let launchCalls = launchCallCount
        launchCallLock.unlock()

        XCTAssertEqual(firstSnapshot.count, 1)
        if firstSnapshot.count == 1 {
            XCTAssertNil(firstSnapshot[0])
        }
        XCTAssertEqual(secondSnapshot.count, 1)
        if secondSnapshot.count == 1 {
            XCTAssertNil(secondSnapshot[0])
        }
        XCTAssertEqual(launchCalls, 2)
    }

}

final class OmnibarStateMachineTests: XCTestCase {
    func testPointerFocusCanPreserveInitialClickSelection() throws {
        var state = OmnibarState()

        let effects = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: "https://example.com/", shouldSelectAll: false)
        )

        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(effects.shouldSelectAll)
    }

    func testExplicitRefocusRequestPreservesEditingBufferAndSelectsAll() throws {
        var state = OmnibarState()

        _ = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: "https://example.com/")
        )
        _ = omnibarReduce(state: &state, event: .bufferChanged("abcdef"))

        let effects = omnibarReduce(
            state: &state,
            event: .focusReasserted(
                shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                    selectionIntent: .selectAll
                )
            )
        )

        XCTAssertTrue(state.isFocused)
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.currentURLString, "https://example.com/")
        XCTAssertEqual(state.buffer, "abcdef")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusReassertionHonorsSelectionIntent() throws {
        XCTAssertTrue(
            browserOmnibarShouldSelectAllOnFocusReassertion(
                selectionIntent: .selectAll
            )
        )
        XCTAssertFalse(
            browserOmnibarShouldSelectAllOnFocusReassertion(
                selectionIntent: .preserveFieldEditorSelection
            )
        )
    }

    // State 1 (issue #5459): the single click that moves first responder into the
    // omnibar selects the whole URL so the next keystroke replaces it (Chrome parity).
    func testFocusGainingClickSelectsAll() throws {
        XCTAssertTrue(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: false,
                didDrag: false
            )
        )
    }

    // State 2 (issue #5268 must not regress): a click while the omnibar is already
    // first responder keeps the caret placed at the click point — no select-all.
    func testAlreadyFocusedClickPlacesCaret() throws {
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: false,
                isShiftClick: false,
                didDrag: false
            )
        )
    }

    // A Shift-click or a drag expresses an explicit range, so the focus-gaining
    // select-all defers to it even on the click that gains focus.
    func testFocusGainingClickDefersToExplicitSelection() throws {
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: true,
                didDrag: false
            )
        )
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: false,
                didDrag: true
            )
        )
    }

    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertFalse(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }

    func testSuggestionsUpdateKeepsSelectionAcrossNonEmptyListRefresh() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        // Simulate remote merge update for the same query while popup remains open.
        let merged: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
            .remoteSearchSuggestion("go fmt"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(merged))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected selection to remain stable while list stays open")
    }

    func testSuggestionsReopenResetsSelectionToFirstRow() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        XCTAssertEqual(state.selectedSuggestionIndex, 1)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 0, "Expected reopened popup to focus first row")
    }

    func testSuggestionsUpdatePrefersAutocompleteMatchWhenSelectionNotTracked() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "gm"),
            .history(url: "https://google.com/", title: "Google"),
            .history(url: "https://gmail.com/", title: "Gmail"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected autocomplete candidate to become selected without explicit index state.")
        XCTAssertEqual(state.selectedSuggestionID, rows[2].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[state.selectedSuggestionIndex]))
        XCTAssertEqual(state.suggestions[state.selectedSuggestionIndex].completion, "https://gmail.com/")
    }

    @MainActor
    func testCommandBackspaceClearsInlineCompletionTypedPrefix() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        try harness.dispatchBackspace(
            modifiers: [.command],
            fallbackCommand: #selector(NSResponder.deleteToBeginningOfLine(_:))
        )

        XCTAssertEqual(harness.state.buffer, "")
        XCTAssertNil(harness.inlineCompletion)
        XCTAssertTrue(harness.state.suggestions.isEmpty)
    }

    @MainActor
    func testOptionBackspaceDeletesWordBeforeInlineCompletion() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gmail account info",
            displayText: "gmail account information",
            suggestions: [
                .remoteSearchSuggestion("gmail account information"),
            ]
        )

        try harness.dispatchBackspace(
            modifiers: [.option],
            fallbackCommand: #selector(NSResponder.deleteWordBackward(_:))
        )

        XCTAssertEqual(harness.state.buffer, "gmail account ")
        XCTAssertNil(harness.inlineCompletion)
        XCTAssertTrue(harness.state.suggestions.isEmpty)
    }

    @MainActor
    func testPlainBackspaceStillDeletesSingleCharacterWithInlineCompletion() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        try harness.dispatchBackspace(modifiers: [], fallbackCommand: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(harness.state.buffer, "gm")
        XCTAssertEqual(harness.inlineCompletion?.typedText, "gm")
        XCTAssertEqual(harness.inlineCompletion?.displayText, "gmail.com")
    }
}

@MainActor
final class BrowserOmnibarNativeFieldRegistryWindowSelectionTests: XCTestCase {
    func testFieldLookupPrefersMatchingWindowAndNilWindowPrefersAttachedField() throws {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let visibleField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let offWindowField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        visibleField.panelId = panelId
        offWindowField.panelId = panelId
        contentView.addSubview(visibleField)
        window.contentView = contentView
        defer {
            registry.unregister(visibleField, panelId: panelId)
            registry.unregister(offWindowField, panelId: panelId)
            visibleField.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        registry.register(visibleField, panelId: panelId)
        registry.register(offWindowField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId, in: window) === visibleField)
        XCTAssertTrue(registry.field(for: panelId, in: nil) === visibleField)
        XCTAssertTrue(registry.field(for: panelId) === visibleField)

        registry.unregister(offWindowField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId) === visibleField)
    }

    func testWindowLookupDoesNotFallBackAcrossWindows() throws {
        let panelId = UUID()
        let registry = BrowserOmnibarNativeFieldRegistry()
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let requestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let sourceField = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        sourceField.panelId = panelId
        contentView.addSubview(sourceField)
        sourceWindow.contentView = contentView
        defer {
            registry.unregister(sourceField, panelId: panelId)
            sourceField.removeFromSuperview()
            sourceWindow.contentView = nil
            sourceWindow.orderOut(nil)
            requestedWindow.orderOut(nil)
        }

        registry.register(sourceField, panelId: panelId)

        XCTAssertTrue(registry.field(for: panelId, in: sourceWindow) === sourceField)
        XCTAssertNil(registry.field(for: panelId, in: requestedWindow))
    }

    func testInteractionOverlayPassesThroughUntilFieldIsRegisteredInWindow() throws {
        let panelId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 32),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        let field = OmnibarNativeTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let interactionView = BrowserOmnibarInteractionView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.panelId = panelId
        interactionView.panelId = panelId
        contentView.addSubview(field)
        contentView.addSubview(interactionView)
        window.contentView = contentView
        defer {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(field, panelId: panelId)
            field.removeFromSuperview()
            interactionView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertNil(
            interactionView.hitTest(NSPoint(x: 12, y: 12)),
            "The overlay must not swallow the first click before it has a forwarding target"
        )

        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)

        XCTAssertTrue(
            interactionView.hitTest(NSPoint(x: 12, y: 12)) === interactionView,
            "The overlay should capture events once it can forward to the same-window native field"
        )
    }
}

@MainActor
final class BrowserPortalOmnibarSuggestionsTests: XCTestCase {
    func testPortalSuggestionsOverlayPassesHitTestingOutsidePopupFrame() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        let item = OmnibarSuggestion.search(engineName: "Google", query: "news")
        let popupFrame = CGRect(
            x: 40,
            y: 12,
            width: 220,
            height: OmnibarSuggestionsView.popupHeight(for: [item])
        )

        slot.setOmnibarSuggestions(
            BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: UUID(),
                popupFrame: popupFrame,
                colorScheme: .dark,
                engineName: "Google",
                items: [item],
                selectedIndex: 0,
                isLoadingRemoteSuggestions: false,
                searchSuggestionsEnabled: true,
                onCommit: { _ in XCTFail("Unexpected commit") },
                onHighlight: { _ in XCTFail("Unexpected highlight") }
            )
        )
        slot.layoutSubtreeIfNeeded()

        let overlay = slot.subviews.first {
            String(describing: type(of: $0)).contains("OmnibarSuggestionsHostingView")
        }
        XCTAssertNotNil(overlay)
        guard let overlay else { return }

        XCTAssertNil(overlay.hitTest(NSPoint(x: 8, y: 8)))

        let insideTopLeftPoint = NSPoint(x: popupFrame.midX, y: popupFrame.midY)
        let insidePoint = overlay.isFlipped
            ? insideTopLeftPoint
            : NSPoint(x: insideTopLeftPoint.x, y: overlay.bounds.height - insideTopLeftPoint.y)
        XCTAssertNotNil(overlay.hitTest(insidePoint))
    }
}

@MainActor
private final class OmnibarInlineDeletionHarness {
    var state = OmnibarState()
    var inlineCompletion: OmnibarInlineCompletion?

    init(
        typedText: String,
        displayText: String,
        suggestions: [OmnibarSuggestion]
    ) {
        state.isFocused = true
        state.currentURLString = ""
        state.buffer = typedText
        state.suggestions = suggestions
        inlineCompletion = OmnibarInlineCompletion(
            typedText: typedText,
            displayText: displayText,
            acceptedText: displayText
        )
    }

    func dispatchBackspace(
        modifiers: NSEvent.ModifierFlags,
        fallbackCommand: Selector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let coordinator = makeCoordinator()
        let editor = NSTextView()
        editor.string = inlineCompletion?.displayText ?? state.buffer
        if let inlineCompletion {
            editor.setSelectedRange(inlineCompletion.suffixRange)
        }

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}",
                isARepeat: false,
                keyCode: 51
            ),
            file: file,
            line: line
        )

        let handledInKeyDown = coordinator.handleKeyEvent(event, editor: editor)
        if !handledInKeyDown {
            _ = coordinator.control(NSTextField(), textView: editor, doCommandBy: fallbackCommand)
        }
    }

    private func makeCoordinator() -> OmnibarTextFieldRepresentable.Coordinator {
        OmnibarTextFieldRepresentable.Coordinator(
            parent: OmnibarTextFieldRepresentable(
                panelId: UUID(),
                fontSize: 12,
                text: Binding(
                    get: { self.state.buffer },
                    set: { self.state.buffer = $0 }
                ),
                isFocused: Binding(
                    get: { self.state.isFocused },
                    set: { self.state.isFocused = $0 }
                ),
                selectAllRequestId: 0,
                inlineCompletion: inlineCompletion,
                placeholder: "",
                onTap: {},
                onSubmit: { _ in },
                onEscape: {},
                onFieldLostFocus: {},
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: { self.deleteSingleCharacterBeforeInlineCompletion() },
                onClearTypedPrefixWithInlineSelection: { self.clearTypedPrefix() },
                onDeleteWordBackwardWithInlineSelection: { self.deleteWordBeforeInlineCompletion() },
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { false }
            )
        )
    }

    private func deleteSingleCharacterBeforeInlineCompletion() {
        guard let inlineCompletion else { return }
        let updated = String(inlineCompletion.typedText.dropLast())
        replaceTypedPrefix(with: updated)
    }

    private func clearTypedPrefix() {
        replaceTypedPrefixAndDismissSuggestions(with: "")
    }

    private func deleteWordBeforeInlineCompletion() {
        guard let inlineCompletion else { return }
        let updated = omnibarPrefixAfterDeletingTrailingWord(from: inlineCompletion.typedText)
        replaceTypedPrefixAndDismissSuggestions(with: updated)
    }

    private func replaceTypedPrefix(with updated: String) {
        let effects = omnibarReduce(state: &state, event: .bufferChanged(updated))
        XCTAssertTrue(effects.shouldRefreshSuggestions)
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: state.buffer,
            suggestions: state.suggestions,
            isFocused: state.isFocused,
            selectionRange: NSRange(location: updated.utf16.count, length: 0),
            hasMarkedText: false
        )
    }

    private func replaceTypedPrefixAndDismissSuggestions(with updated: String) {
        _ = omnibarReduce(state: &state, event: .bufferChanged(updated))
        let effects = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertFalse(effects.shouldRefreshSuggestions)
        inlineCompletion = nil
    }

}


@MainActor
final class BrowserOmnibarFieldEditorResolutionTests: XCTestCase {
    func testPanelIdResolutionUsesLiveOmnibarFieldWhenFieldEditorResponderChainIsStale() {
        _ = NSApplication.shared

        let panelId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let staleWebView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 80), configuration: WKWebViewConfiguration())
        contentView.addSubview(staleWebView)

        let field = OmnibarNativeTextField(frame: NSRect(x: 8, y: 28, width: 300, height: 24))
        field.panelId = panelId
        contentView.addSubview(field)

        window.makeKeyAndOrderFront(nil)
        defer {
            field.removeFromSuperview()
            staleWebView.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        XCTAssertTrue(window.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            XCTFail("Expected omnibar field editor after focusing text field")
            return
        }

        let originalNextResponder = editor.nextResponder
        editor.nextResponder = staleWebView
        defer {
            editor.nextResponder = originalNextResponder
        }

        XCTAssertEqual(
            browserOmnibarPanelId(for: editor),
            panelId,
            "A live omnibar field editor must resolve to its owning omnibar field even when AppKit leaves a stale browser responder chain behind"
        )
    }
}


final class OmnibarRemoteSuggestionMergeTests: XCTestCase {
    func testMergeRemoteSuggestionsInsertsBelowSearchAndDedupes() {
        let now = Date()
        let entries: [BrowserHistoryStore.Entry] = [
            BrowserHistoryStore.Entry(
                id: UUID(),
                url: "https://go.dev/",
                title: "The Go Programming Language",
                lastVisited: now,
                visitCount: 10
            ),
        ]

        let merged = buildOmnibarSuggestions(
            query: "go",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["go tutorial", "go.dev", "go json"],
            resolvedURL: nil,
            limit: 8
        )

        let completions = merged.compactMap { $0.completion }
        XCTAssertGreaterThanOrEqual(completions.count, 5)
        XCTAssertEqual(completions[0], "https://go.dev/")
        XCTAssertEqual(completions[1], "go")

        let remoteCompletions = Array(completions.dropFirst(2))
        XCTAssertEqual(Set(remoteCompletions), Set(["go tutorial", "go.dev", "go json"]))
        XCTAssertEqual(remoteCompletions.count, 3)
    }

    func testStaleRemoteSuggestionsKeptForNearbyEdits() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "go t",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json", "golang tips"],
            limit: 8
        )

        XCTAssertEqual(stale, ["go tutorial", "go json", "golang tips"])
    }

    func testStaleRemoteSuggestionsTrimAndRespectLimit() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "gooo",
            previousRemoteQuery: "goo",
            previousRemoteSuggestions: [" go tutorial ", "", "go json", "   ", "go fmt"],
            limit: 2
        )

        XCTAssertEqual(stale, ["go tutorial", "go json"])
    }

    func testStaleRemoteSuggestionsDroppedForUnrelatedQuery() {
        let stale = staleOmnibarRemoteSuggestionsForDisplay(
            query: "python",
            previousRemoteQuery: "go",
            previousRemoteSuggestions: ["go tutorial", "go json"],
            limit: 8
        )

        XCTAssertTrue(stale.isEmpty)
    }
}


final class OmnibarSuggestionRankingTests: XCTestCase {
    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000_000)
    }

    func testSingleCharacterQueryPromotesAutocompletionMatchToFirstRow() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "n",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["search google for n", "news"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertNotEqual(results.map(\.completion).first, "n")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "n", suggestion: $0) } ?? false)
    }

    func testGmAutocompleteCandidateIsFirstOnExactQueryMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["gmail", "gmail.com", "google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        let inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: "gm",
            suggestions: results,
            isFocused: true,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )
        XCTAssertNotNil(inlineCompletion)
    }

    func testAutocompletionCandidateWinsOverRemoteAndSearchRowsForTwoLetterQuery() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://gmail.com/",
                    title: "Gmail",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com", "Google mail"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
    }

    func testSuggestionSelectionPrefersAutocompletionCandidateAfterSuggestionsUpdate() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["Search google for gm", "gmail", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        var state = OmnibarState()
        let _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: ""))
        let _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))
        let _ = omnibarReduce(state: &state, event: .suggestionsUpdated(results))

        XCTAssertEqual(state.selectedSuggestionIndex, 0)
        XCTAssertEqual(state.selectedSuggestionID, results[0].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[0]))
    }

    func testTwoCharQueryWithRemoteSuggestionsStillPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://news.ycombinator.com/",
                title: "News.YC",
                lastVisited: fixedNow,
                visitCount: 12,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://www.google.com/",
                title: "Google",
                lastVisited: fixedNow - 200,
                visitCount: 8,
                typedCount: 2,
                lastTypedAt: fixedNow - 200
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "ne",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [],
            remoteQueries: ["netflix", "new york times", "newegg"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // The autocompletable history entry (news.ycombinator.com) should be first despite remote results.
        XCTAssertEqual(results.first?.completion, "https://news.ycombinator.com/")
        XCTAssertTrue(results.first.map { omnibarSuggestionSupportsAutocompletion(query: "ne", suggestion: $0) } ?? false)

        // Remote suggestions should still appear in the results (two-char queries include them).
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions to be present for two-char query")
    }

    func testGmQueryWithRemoteSuggestionsAndOpenTabPromotesAutocompletionMatch() {
        let entries: [BrowserHistoryStore.Entry] = [
            .init(
                id: UUID(),
                url: "https://google.com/",
                title: "Google",
                lastVisited: fixedNow,
                visitCount: 4,
                typedCount: 1,
                lastTypedAt: fixedNow
            ),
            .init(
                id: UUID(),
                url: "https://gmail.com/",
                title: "Gmail",
                lastVisited: fixedNow,
                visitCount: 10,
                typedCount: 2,
                lastTypedAt: fixedNow
            ),
        ]

        let results = buildOmnibarSuggestions(
            query: "gm",
            engineName: "Google",
            historyEntries: entries,
            openTabMatches: [
                .init(
                    tabId: UUID(),
                    panelId: UUID(),
                    url: "https://google.com/maps",
                    title: "Google Maps",
                    isKnownOpenTab: true
                ),
            ],
            remoteQueries: ["gmail login", "gm stock price", "gmail.com"],
            resolvedURL: nil,
            limit: 8,
            now: fixedNow
        )

        // Gmail should be first (autocompletable + typed history).
        XCTAssertEqual(results.first?.completion, "https://gmail.com/")
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: results[0]))

        // Verify remote suggestions are present alongside history/tab matches.
        let remoteCompletions = results.filter {
            if case .remote = $0.kind { return true }
            return false
        }.map(\.completion)
        XCTAssertFalse(remoteCompletions.isEmpty, "Expected remote suggestions in results")
        let hasSearch = results.contains {
            if case .search = $0.kind { return true }
            return false
        }
        XCTAssertTrue(hasSearch, "Expected search row in results")
    }

    func testHistorySuggestionDisplaysTitleAndUrlOnSingleLine() {
        let row = OmnibarSuggestion.history(
            url: "https://www.example.com/path?q=1",
            title: "Example Domain"
        )
        XCTAssertEqual(row.listText, "Example Domain — example.com/path?q=1")
        XCTAssertFalse(row.listText.contains("\n"))
    }

    func testPublishedBufferTextUsesTypedPrefixWhenInlineSuffixIsSelected() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: inline.displayText,
            inlineCompletion: inline,
            selectionRange: inline.suffixRange,
            hasMarkedText: false
        )

        XCTAssertEqual(published, "l")
    }

    func testPublishedBufferTextKeepsUserTypedValueWhenDisplayDiffersFromInlineText() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let published = omnibarPublishedBufferTextForFieldChange(
            fieldValue: "la",
            inlineCompletion: inline,
            selectionRange: NSRange(location: 2, length: 0),
            hasMarkedText: false
        )

        XCTAssertEqual(published, "la")
    }

    func testInlineCompletionRenderIgnoresStaleTypedPrefixMismatch() {
        let staleInline = OmnibarInlineCompletion(
            typedText: "g",
            displayText: "github.com",
            acceptedText: "https://github.com/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: staleInline
        )

        XCTAssertNil(active)
    }

    func testInlineCompletionRenderKeepsMatchingTypedPrefix() {
        let inline = OmnibarInlineCompletion(
            typedText: "l",
            displayText: "localhost:3000",
            acceptedText: "https://localhost:3000/"
        )

        let active = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: "l",
            inlineCompletion: inline
        )

        XCTAssertEqual(active, inline)
    }

    func testInlineCompletionSkipsTitleMatchWhoseURLDoesNotStartWithTypedText() {
        // History entry: visited google.com/search?q=localhost:3000 with title
        // "localhost:3000 - Google Search". Typing "l" should NOT inline-complete
        // to "google.com/..." because that replaces the typed "l" with "g".
        let suggestions: [OmnibarSuggestion] = [
            .history(
                url: "https://www.google.com/search?q=localhost:3000",
                title: "localhost:3000 - Google Search"
            ),
        ]

        let result = omnibarInlineCompletionForDisplay(
            typedText: "l",
            suggestions: suggestions,
            isFocused: true,
            selectionRange: NSRange(location: 1, length: 0),
            hasMarkedText: false
        )

        XCTAssertNil(result, "Should not inline-complete when display text does not start with typed prefix")
    }
}
