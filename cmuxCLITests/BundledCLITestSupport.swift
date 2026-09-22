import Foundation
import XCTest

/// Resolves the `cmux` binary these tests spawn.
///
/// `cmuxTests` resolves it relative to the app host that loads it. `cmuxCLITests`
/// has no app host, so it resolves it from `CMUX_CLI_PATH` or relative to the
/// built products directory the bundle itself was copied into.
enum BundledCLITestSupport {
    /// Path to the bundled `cmux` CLI under test.
    ///
    /// Resolution order:
    ///   1. `CMUX_CLI_PATH` — CI and local runs point this at the binary they
    ///      built, which is what makes this bundle independent of an app host.
    ///   2. `<products>/cmux` — the `cmux-cli` target's own product, which sits
    ///      beside this .xctest bundle in `Build/Products/<config>`.
    ///   3. Any `*.app/Contents/Resources/bin/cmux` below the products
    ///      directory — the copy the app bundle ships.
    static func bundledCLIPath(
        for bundleClass: AnyClass = CLITestBundleAnchor.self,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try bundledCLIURL(for: bundleClass, file: file, line: line).path
    }

    static func bundledCLIURL(
        for bundleClass: AnyClass = CLITestBundleAnchor.self,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["CMUX_CLI_PATH"], !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: overrideURL.path) {
                return overrideURL
            }
            let message = "CMUX_CLI_PATH is set but not executable: \(override)"
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "cmux.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        let productsURL = Bundle(for: bundleClass).bundleURL.deletingLastPathComponent()

        let siblingCLI = productsURL.appendingPathComponent("cmux", isDirectory: false)
        if fileManager.isExecutableFile(atPath: siblingCLI.path) {
            return siblingCLI
        }

        let enumerator = fileManager.enumerator(
            at: productsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux"),
                  fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item
        }

        let message = """
        cmux CLI not found. Set CMUX_CLI_PATH, or build the cmux-cli product \
        into \(productsURL.path).
        """
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "cmux.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
