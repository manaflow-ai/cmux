import XCTest

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
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
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
