import CoreServices
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class UpdateQuarantineRepairTests: XCTestCase {
    func testRepairAddsLaunchServicesMetadataForMissingAgentBundleIdentifier() throws {
        let fileURL = try makeTemporaryFile(named: "cmux-nightly.dmg")
        try writeRawQuarantine("0383;69ba4249;;", to: fileURL)

        let beforeRawValue = try XCTUnwrap(UpdateQuarantineRepair.rawQuarantineAttribute(at: fileURL))
        XCTAssertEqual(beforeRawValue, "0383;69ba4249;;")

        let result = try UpdateQuarantineRepair.repairQuarantineIfNeeded(
            at: fileURL,
            agentBundleIdentifier: "com.cmuxterm.app.nightly",
            agentName: "cmux NIGHTLY",
            dataURL: URL(string: "https://example.com/cmux-nightly-macos.dmg")
        )

        XCTAssertEqual(result.outcome, .repaired)
        let afterRawValue = try XCTUnwrap(UpdateQuarantineRepair.rawQuarantineAttribute(at: fileURL))
        XCTAssertNotEqual(afterRawValue, beforeRawValue)
        XCTAssertFalse(UpdateQuarantineRepair.rawQuarantineNeedsLaunchServicesRepair(afterRawValue))

        let properties = try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(properties?[kLSQuarantineAgentBundleIdentifierKey as String] as? String, "com.cmuxterm.app.nightly")
        XCTAssertEqual(properties?[kLSQuarantineAgentNameKey as String] as? String, "cmux NIGHTLY")
        XCTAssertEqual(properties?[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    }

    func testRepairIsNoOpWhenLaunchServicesQuarantineRecordIsAlreadyValid() throws {
        let fileURL = try makeTemporaryFile(named: "cmux-nightly.dmg")
        try writeRawQuarantine("0383;69ba4249;;", to: fileURL)

        _ = try UpdateQuarantineRepair.repairQuarantineIfNeeded(
            at: fileURL,
            agentBundleIdentifier: "com.cmuxterm.app.nightly",
            agentName: "cmux NIGHTLY",
            dataURL: URL(string: "https://example.com/cmux-nightly-macos.dmg")
        )

        let repairedRawValue = try XCTUnwrap(UpdateQuarantineRepair.rawQuarantineAttribute(at: fileURL))
        let secondResult = try UpdateQuarantineRepair.repairQuarantineIfNeeded(
            at: fileURL,
            agentBundleIdentifier: "com.cmuxterm.app.nightly",
            agentName: "cmux NIGHTLY",
            dataURL: URL(string: "https://example.com/cmux-nightly-macos.dmg")
        )

        XCTAssertEqual(secondResult.outcome, .alreadyValid)
        XCTAssertEqual(secondResult.beforeRawValue, repairedRawValue)
        XCTAssertEqual(secondResult.afterRawValue, repairedRawValue)
    }

    func testLocateDownloadedArchivePrefersNewestMatchingVersionDirectory() throws {
        let cachesDirectory = try makeTemporaryDirectory(named: "SparkleCaches")
        let rootURL = UpdateQuarantineRepair.persistentDownloadsRootURL(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            cachesDirectory: cachesDirectory
        )

        let oldArchiveURL = rootURL
            .appendingPathComponent("token-old", isDirectory: true)
            .appendingPathComponent("cmux NIGHTLY 1234", isDirectory: true)
            .appendingPathComponent("old.dmg")
        let newArchiveURL = rootURL
            .appendingPathComponent("token-new", isDirectory: true)
            .appendingPathComponent("cmux NIGHTLY 1234", isDirectory: true)
            .appendingPathComponent("new.dmg")
        let otherArchiveURL = rootURL
            .appendingPathComponent("token-other", isDirectory: true)
            .appendingPathComponent("cmux NIGHTLY 9999", isDirectory: true)
            .appendingPathComponent("other.dmg")

        try createFile(at: oldArchiveURL)
        try createFile(at: newArchiveURL)
        try createFile(at: otherArchiveURL)

        try setModificationDate(Date(timeIntervalSince1970: 100), for: oldArchiveURL)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: newArchiveURL)
        try setModificationDate(Date(timeIntervalSince1970: 300), for: otherArchiveURL)

        let locatedArchiveURL = UpdateQuarantineRepair.locateDownloadedArchive(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            hostName: "cmux NIGHTLY",
            versionString: "1234",
            cachesDirectory: cachesDirectory
        )

        XCTAssertEqual(locatedArchiveURL, newArchiveURL)
    }

    func testLocateExtractedApplicationUsesNewestMatchingBundleName() throws {
        let cachesDirectory = try makeTemporaryDirectory(named: "SparkleInstallation")
        let rootURL = UpdateQuarantineRepair.installationRootURL(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            cachesDirectory: cachesDirectory
        )

        let oldAppURL = rootURL
            .appendingPathComponent("install-old", isDirectory: true)
            .appendingPathComponent("extract-old", isDirectory: true)
            .appendingPathComponent("cmux NIGHTLY.app", isDirectory: true)
        let newAppURL = rootURL
            .appendingPathComponent("install-new", isDirectory: true)
            .appendingPathComponent("extract-new", isDirectory: true)
            .appendingPathComponent("cmux NIGHTLY.app", isDirectory: true)
        let otherAppURL = rootURL
            .appendingPathComponent("install-other", isDirectory: true)
            .appendingPathComponent("extract-other", isDirectory: true)
            .appendingPathComponent("Different.app", isDirectory: true)

        try FileManager.default.createDirectory(at: oldAppURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newAppURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherAppURL, withIntermediateDirectories: true)

        try setModificationDate(Date(timeIntervalSince1970: 100), for: oldAppURL)
        try setModificationDate(Date(timeIntervalSince1970: 200), for: newAppURL)
        try setModificationDate(Date(timeIntervalSince1970: 300), for: otherAppURL)

        let locatedAppURL = UpdateQuarantineRepair.locateExtractedApplication(
            bundleIdentifier: "com.cmuxterm.app.nightly",
            bundleName: "cmux NIGHTLY.app",
            cachesDirectory: cachesDirectory
        )

        XCTAssertEqual(locatedAppURL, newAppURL)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateQuarantineRepairTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeTemporaryFile(named name: String) throws -> URL {
        let directoryURL = try makeTemporaryDirectory(named: "Files")
        let fileURL = directoryURL.appendingPathComponent(name)
        try createFile(at: fileURL)
        return fileURL
    }

    private func createFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
    }

    private func setModificationDate(_ modificationDate: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
    }

    private func writeRawQuarantine(_ value: String, to url: URL) throws {
        let bytes = Array(value.utf8)
        let status = url.path.withCString { pathPointer in
            "com.apple.quarantine".withCString { attributePointer in
                bytes.withUnsafeBytes { bufferPointer in
                    setxattr(pathPointer, attributePointer, bufferPointer.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        XCTAssertEqual(status, 0)
    }
}
