import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXCLINodeOptionsShimWriterTests: XCTestCase {
    func testWriteShimIfChangedRewritesWhitespaceOnlyByteDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-node-options-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shimURL = directory.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        let canonicalScript = "module.exports = true\n"
        try (canonicalScript + "\n").write(to: shimURL, atomically: false, encoding: .utf8)

        try CMUXCLI(args: []).writeShimIfChanged(canonicalScript, to: shimURL, mode: 0o600)

        XCTAssertEqual(try String(contentsOf: shimURL, encoding: .utf8), canonicalScript)
        let mode = try FileManager.default.attributesOfItem(atPath: shimURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}
