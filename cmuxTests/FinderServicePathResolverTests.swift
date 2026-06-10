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


// MARK: - Finder Service Path Resolution
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


