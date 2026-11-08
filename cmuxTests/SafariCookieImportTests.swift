import CmuxBrowser
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Safari cookie import from a `Cookies.binarycookies` file into cmux browser profiles.
final class SafariCookieImportTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafariCookieImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testImportWritesSecureHTTPOnlyCookieToTheSelectedProfileOnly() async throws {
        let cookieName = "cmux-safari-import-\(UUID().uuidString)"
        let sourceProfile = try writeSourceProfile(records: [
            Self.record(
                domain: ".example.com",
                name: cookieName,
                path: "/",
                value: "imported",
                expiry: Date().addingTimeInterval(3_600),
                flags: 0x1 | 0x4
            ),
        ])
        let destination = try XCTUnwrap(
            BrowserProfileStore.shared.createProfile(named: "Safari import target \(UUID().uuidString)")
        )
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: destination.id) }
        let otherProfile = try XCTUnwrap(
            BrowserProfileStore.shared.createProfile(named: "Safari import other \(UUID().uuidString)")
        )
        defer { _ = BrowserProfileStore.shared.deleteProfile(id: otherProfile.id) }

        let result = await BrowserDataImporter.importSafariCookies(
            sourceProfiles: [sourceProfile],
            destinationProfileID: destination.id,
            domainFilters: [],
            reader: SafariCookieStoreReader(homeDirectory: temporaryDirectory),
            parser: SafariBinaryCookiesParser(),
            now: Date()
        )

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.warnings, [])
        let destinationCookies = await BrowserProfileStore.shared
            .websiteDataStore(for: destination.id).httpCookieStore.allCookies()
        let imported = try XCTUnwrap(destinationCookies.first { $0.name == cookieName })
        XCTAssertEqual(imported.value, "imported")
        XCTAssertEqual(imported.domain, ".example.com")
        XCTAssertTrue(imported.isSecure)
        XCTAssertTrue(imported.isHTTPOnly)
        let otherCookies = await BrowserProfileStore.shared
            .websiteDataStore(for: otherProfile.id).httpCookieStore.allCookies()
        XCTAssertFalse(otherCookies.contains { $0.name == cookieName })
    }

    @MainActor
    func testStoreAboveTheDecodeLimitGetsItsOwnWarningNamingTheLimit() async throws {
        let sourceProfile = try writeSourceProfile(records: [
            Self.record(
                domain: ".example.com",
                name: "large",
                path: "/",
                value: String(repeating: "x", count: 256),
                expiry: Date().addingTimeInterval(3_600),
                flags: 0
            ),
        ])
        let decodeLimit = 128
        let destinationID = BrowserProfileStore.shared.builtInDefaultProfileID

        let result = await BrowserDataImporter.importSafariCookies(
            sourceProfiles: [sourceProfile],
            destinationProfileID: destinationID,
            domainFilters: [],
            reader: SafariCookieStoreReader(homeDirectory: temporaryDirectory),
            parser: SafariBinaryCookiesParser(maximumDecodedBytes: decodeLimit),
            now: Date()
        )

        XCTAssertEqual(result.importedCount, 0)
        let warning = try XCTUnwrap(result.warnings.first)
        XCTAssertEqual(result.warnings.count, 1)
        let formattedLimit = ByteCountFormatter.string(fromByteCount: Int64(decodeLimit), countStyle: .binary)
        XCTAssertTrue(warning.contains(formattedLimit), "warning \(warning.debugDescription) should name \(formattedLimit)")
        XCTAssertTrue(warning.contains("~/Profile/Cookies.binarycookies"), warning)
    }

    // MARK: - Fixture

    /// Writes a one-page store into a named Safari profile under the temporary home.
    private func writeSourceProfile(records: [[UInt8]]) throws -> InstalledBrowserProfile {
        let profileURL = temporaryDirectory.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try Self.store(records: records).write(to: profileURL.appendingPathComponent("Cookies.binarycookies"))
        return InstalledBrowserProfile(displayName: "Imported", rootURL: profileURL, isDefault: false)
    }

    /// A `Cookies.binarycookies` file holding one page of `records`.
    private static func store(records: [[UInt8]]) -> Data {
        var page: [UInt8] = [0x00, 0x00, 0x01, 0x00]
        page += littleEndian(UInt32(records.count))
        var offset = 8 + 4 * records.count + 4
        for record in records {
            page += littleEndian(UInt32(offset))
            offset += record.count
        }
        page += [0x00, 0x00, 0x00, 0x00]
        for record in records {
            page += record
        }
        var bytes: [UInt8] = Array("cook".utf8)
        bytes += bigEndian(1)
        bytes += bigEndian(UInt32(page.count))
        bytes += page
        return Data(bytes)
    }

    /// One cookie record: a 56-byte header, then null-terminated strings.
    private static func record(
        domain: String,
        name: String,
        path: String,
        value: String,
        expiry: Date,
        flags: UInt32
    ) -> [UInt8] {
        let strings = [domain, name, path, value].map { Array($0.utf8) + [0] }
        var stringOffsets: [UInt32] = []
        var cursor = 56
        for string in strings {
            stringOffsets.append(UInt32(cursor))
            cursor += string.count
        }
        var bytes: [UInt8] = []
        bytes += littleEndian(UInt32(cursor))
        bytes += littleEndian(UInt32(0))
        bytes += littleEndian(flags)
        bytes += littleEndian(UInt32(0))
        for stringOffset in stringOffsets {
            bytes += littleEndian(stringOffset)
        }
        bytes += littleEndian(UInt32(0))
        bytes += littleEndian(UInt32(0))
        bytes += littleEndian(expiry.timeIntervalSinceReferenceDate.bitPattern)
        bytes += littleEndian(Double(0).bitPattern)
        for string in strings {
            bytes += string
        }
        return bytes
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}
