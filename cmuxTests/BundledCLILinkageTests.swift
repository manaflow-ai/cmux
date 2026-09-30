import XCTest

enum BundledCLITestSupport {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func bundledCLIPath(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try bundledCLIURL(for: bundleClass, file: file, line: line).path
    }

    static func bundledCLIURL(
        for bundleClass: AnyClass,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: bundleClass)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedCLIURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)

        if fileManager.isExecutableFile(atPath: expectedCLIURL.path) {
            return expectedCLIURL
        }

        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux"),
                  fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item
        }

        let message = "Bundled cmux CLI not found at \(expectedCLIURL.path)"
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    /// Environment key that confines a Debug CLI's implicit socket discovery to its
    /// state directory, skipping the machine-wide `/tmp` marker files and legacy `/tmp`
    /// socket aliases a real cmux running as the same user publishes.
    static let isolatedSocketDiscoveryEnvironmentKey = "CMUX_TEST_ISOLATED_SOCKET_DISCOVERY"

    /// Environment for a spawned bundled CLI that cannot see the real user's cmux.
    ///
    /// Every home-derived location (`HOME`, `CFFIXED_USER_HOME`, the XDG base
    /// directories, `TMPDIR`) points inside `home`; inherited `CMUX*`
    /// variables (socket pins, surface/workspace ids, tags) are dropped; and implicit
    /// socket discovery is confined to `home`'s state directory. On a machine where
    /// the user (or a CI runner account) has a live cmux, the CLI would otherwise
    /// follow `/tmp/cmux-last-socket-path` to that app's socket.
    static func hermeticCLIEnvironment(
        home: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for key in Array(environment.keys)
        where key.hasPrefix("CMUX") || key.hasPrefix("XDG_") {
            environment.removeValue(forKey: key)
        }
        let fileManager = FileManager.default
        let tmpURL = home.appendingPathComponent("tmp", isDirectory: true)
        let runtimeURL = home.appendingPathComponent("run", isDirectory: true)
        try? fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config", isDirectory: true).path
        environment["XDG_DATA_HOME"] = home.appendingPathComponent(".local/share", isDirectory: true).path
        environment["XDG_STATE_HOME"] = home.appendingPathComponent(".local/state", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = home.appendingPathComponent(".cache", isDirectory: true).path
        environment["XDG_RUNTIME_DIR"] = runtimeURL.path
        environment["TMPDIR"] = tmpURL.path + "/"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment[isolatedSocketDiscoveryEnvironmentKey] = "1"
        return environment
    }
}

final class BundledCLILinkageTests: XCTestCase {
    deinit {}

    func testBundledCLIDoesNotDependOnPrivateRPathFrameworks() throws {
        let cliURL = try bundledCLIURL()
        let linkedLibraries = try linkedLibraries(for: cliURL)
        // Xcode links a target's automatic SwiftPM products as dynamic
        // <Name>_<hash>_PackageProduct.framework variants under the test action, so the
        // helper in a test-built app bundle picks those up even though a plain build links
        // the same products statically. Those names are toolchain-generated and do not
        // appear in a shipped bundle. A dependency that would abort dyld keeps its real
        // framework name (the v0.64.1 crash was @rpath/Sentry.framework, from the
        // Sentry-Dynamic product) and still fails this assert in every build style.
        let privateRPathFrameworks = linkedLibraries.filter {
            $0.hasPrefix("@rpath/")
                && $0.contains(".framework/")
                && !$0.contains("_PackageProduct.framework/")
        }

        XCTAssertEqual(
            privateRPathFrameworks,
            [],
            "The bundled cmux CLI is copied into Contents/Resources/bin as a standalone helper. Private @rpath framework dependencies abort in dyld before CLI code can run."
        )
    }

    private func bundledCLIURL() throws -> URL {
        try BundledCLITestSupport.bundledCLIURL(for: Self.self)
    }

    private func linkedLibraries(for executableURL: URL) throws -> [String] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", executableURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "otool failed: \(output)")

        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ")
                    .first
                    .map(String.init)
            }
    }
}
