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
