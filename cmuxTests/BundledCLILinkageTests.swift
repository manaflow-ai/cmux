import XCTest

enum BundledCLITestSupport {
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
}

final class BundledCLILinkageTests: XCTestCase {
    deinit {}

    func testBundledCLIDoesNotDependOnPrivateRPathFrameworks() throws {
        let cliURL = try bundledCLIURL()
        let linkedLibraries = try linkedLibraries(for: cliURL)
        let privateRPathFrameworks = linkedLibraries.filter {
            $0.hasPrefix("@rpath/") && $0.contains(".framework/")
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

final class ArtifactCLIIntegrationTests: XCTestCase {
    func testArtifactCommandsPersistListResolveAndSearchWithoutSocket() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cli-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: projectRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: projectRoot) }
        let source = projectRoot.appendingPathComponent("source/launch-plan.md", isDirectory: false)
        try fileManager.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "release needle".write(to: source, atomically: true, encoding: .utf8)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)

        let added = try runCLI(
            cliPath,
            ["artifact", "add", source.path, "--project", projectRoot.path, "--json"]
        )
        XCTAssertEqual(added.status, 0, added.stderr)
        let addedPayload = try jsonObject(added.stdout)
        let storedPath = try XCTUnwrap(addedPayload["path"] as? String)
        let relativePath = try XCTUnwrap(addedPayload["relative_path"] as? String)
        XCTAssertTrue(fileManager.fileExists(atPath: storedPath))
        XCTAssertTrue(relativePath.hasSuffix("/launch-plan.md"))

        let listed = try runCLI(
            cliPath,
            ["artifact", "list", "--project", projectRoot.path, "--json"]
        )
        XCTAssertEqual(listed.status, 0, listed.stderr)
        let listedPayload = try jsonObject(listed.stdout)
        let artifacts = try XCTUnwrap(listedPayload["artifacts"] as? [[String: Any]])
        XCTAssertEqual(artifacts.compactMap { $0["relative_path"] as? String }, [relativePath])

        let resolved = try runCLI(
            cliPath,
            ["artifact", "path", relativePath, "--project", projectRoot.path]
        )
        XCTAssertEqual(resolved.status, 0, resolved.stderr)
        XCTAssertEqual(resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines), storedPath)

        let searched = try runCLI(
            cliPath,
            ["artifact", "search", "needle", "--project", projectRoot.path, "--json"]
        )
        XCTAssertEqual(searched.status, 0, searched.stderr)
        let searchedPayload = try jsonObject(searched.stdout)
        let results = try XCTUnwrap(searchedPayload["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["relative_path"] as? String }, [relativePath])
        XCTAssertEqual(results.first?["matched_content"] as? Bool, true)

        let missing = try runCLI(
            cliPath,
            ["artifact", "open", "missing.md", "--project", projectRoot.path]
        )
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.stderr.contains("Artifact not found"), missing.stderr)
    }

    private func runCLI(
        _ executablePath: String,
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "Expected JSON object, got: \(text)"
        )
    }
}
