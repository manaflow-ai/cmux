import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class OpenCodeDatabaseSnapshotTests: XCTestCase {
    func testSnapshotUsesOpenCodeDBOverrideAndCopiesWALAndSHMSidecars() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-opencode-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceDB = root.appendingPathComponent("custom.sqlite")
        let walURL = URL(fileURLWithPath: sourceDB.path + "-wal")
        let shmURL = URL(fileURLWithPath: sourceDB.path + "-shm")
        try Data("database".utf8).write(to: sourceDB)
        try Data("write-ahead-log".utf8).write(to: walURL)
        try Data("shared-memory".utf8).write(to: shmURL)

        let snapshot = try XCTUnwrap(OpenCodeDatabaseSnapshot.make(
            prefix: "cmux-opencode-test",
            environment: ["HOME": root.path, "OPENCODE_DB": sourceDB.path]
        ))
        defer { snapshot.remove() }

        XCTAssertEqual(try Data(contentsOf: snapshot.databaseURL), Data("database".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: snapshot.databaseURL.path + "-wal")),
            Data("write-ahead-log".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: snapshot.databaseURL.path + "-shm")),
            Data("shared-memory".utf8)
        )
    }

    func testSnapshotReturnsNilWhenConfiguredDatabaseDoesNotExist() throws {
        let missingDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-missing-\(UUID().uuidString).sqlite")

        XCTAssertNil(try OpenCodeDatabaseSnapshot.make(
            prefix: "cmux-opencode-test",
            environment: ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "OPENCODE_DB": missingDB.path]
        ))
    }
}
