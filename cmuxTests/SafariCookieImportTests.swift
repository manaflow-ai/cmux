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

    /// Creates an empty temporary home for each test.
    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafariCookieImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    /// Removes the temporary home.
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Only live, in-filter cookies reach the selected profile, with their attributes;
    /// duplicates keep the later expiry, and no other profile, including the
    /// default one, receives them.
    @MainActor
    func testImportWritesOnlyEligibleCookiesToTheSelectedProfile() async throws {
        let prefix = "cmux-safari-import-\(UUID().uuidString)"
        let now = Date()
        let future = now.addingTimeInterval(3_600)
        let past = now.addingTimeInterval(-3_600)
        let sourceProfile = try writeSourceProfile(records: [
            Self.record(domain: ".example.com", name: "\(prefix)-secure", path: "/", value: "secure", expiry: future, flags: 0x1 | 0x4),
            Self.record(domain: "login.example.com", name: "\(prefix)-session", path: "/account", value: "session", expiry: nil, flags: 0),
            Self.record(domain: ".other.net", name: "\(prefix)-excluded", path: "/", value: "excluded", expiry: future, flags: 0),
            Self.record(domain: ".example.com", name: "\(prefix)-expired", path: "/", value: "expired", expiry: past, flags: 0),
            Self.record(domain: ".other.net", name: "\(prefix)-excluded-expired", path: "/", value: "excluded", expiry: past, flags: 0),
            Self.record(domain: ".example.com", name: "\(prefix)-duplicate", path: "/", value: "later", expiry: future.addingTimeInterval(3_600), flags: 0),
            Self.record(domain: ".example.com", name: "\(prefix)-duplicate", path: "/", value: "earlier", expiry: future, flags: 0),
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
            domainFilters: ["example.com"],
            reader: SafariCookieStoreReader(homeDirectory: temporaryDirectory),
            parser: SafariBinaryCookiesParser(),
            now: now
        )

        // Expired cookies inside the filters count as skipped. Cookies outside
        // the filters were not asked for, so they are not counted, as in the
        // Firefox and Chromium importers. Duplicates collapse to one cookie
        // before the write and are not counted either.
        XCTAssertEqual(result.importedCount, 3)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.warnings, [])
        let destinationCookies = await BrowserProfileStore.shared
            .websiteDataStore(for: destination.id).httpCookieStore.allCookies()
            .filter { $0.name.hasPrefix(prefix) }
        XCTAssertEqual(
            Set(destinationCookies.map(\.name)),
            ["\(prefix)-secure", "\(prefix)-session", "\(prefix)-duplicate"]
        )
        XCTAssertEqual(destinationCookies.count, 3)
        let secure = try XCTUnwrap(destinationCookies.first { $0.name == "\(prefix)-secure" })
        XCTAssertEqual(secure.value, "secure")
        XCTAssertEqual(secure.domain, ".example.com")
        XCTAssertTrue(secure.isSecure)
        XCTAssertTrue(secure.isHTTPOnly)
        let session = try XCTUnwrap(destinationCookies.first { $0.name == "\(prefix)-session" })
        XCTAssertEqual(session.value, "session")
        XCTAssertEqual(session.domain, "login.example.com")
        XCTAssertEqual(session.path, "/account")
        XCTAssertTrue(session.isSessionOnly)
        XCTAssertFalse(session.isSecure)
        XCTAssertFalse(session.isHTTPOnly)
        let duplicate = try XCTUnwrap(destinationCookies.first { $0.name == "\(prefix)-duplicate" })
        XCTAssertEqual(duplicate.value, "later", "the later-expiring duplicate should win")
        let otherCookies = await BrowserProfileStore.shared
            .websiteDataStore(for: otherProfile.id).httpCookieStore.allCookies()
        XCTAssertFalse(otherCookies.contains { $0.name.hasPrefix(prefix) })
        let defaultProfileCookies = await BrowserProfileStore.shared
            .websiteDataStore(for: BrowserProfileStore.shared.builtInDefaultProfileID).httpCookieStore.allCookies()
        XCTAssertFalse(defaultProfileCookies.contains { $0.name.hasPrefix(prefix) })
    }

    /// A store above the parser's decode limit is reported with the limit, not as damaged.
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

    /// A store past the reader's limit is reported with the reader's limit, the threshold that refused it.
    @MainActor
    func testStoreAboveTheReadLimitGetsAWarningNamingTheReadLimit() async throws {
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
        let readLimit = 128
        let destinationID = BrowserProfileStore.shared.builtInDefaultProfileID

        let result = await BrowserDataImporter.importSafariCookies(
            sourceProfiles: [sourceProfile],
            destinationProfileID: destinationID,
            domainFilters: [],
            reader: SafariCookieStoreReader(homeDirectory: temporaryDirectory, maximumStoreBytes: readLimit),
            parser: SafariBinaryCookiesParser(),
            now: Date()
        )

        XCTAssertEqual(result.importedCount, 0)
        let warning = try XCTUnwrap(result.warnings.first)
        XCTAssertEqual(result.warnings.count, 1)
        let formattedLimit = ByteCountFormatter.string(fromByteCount: Int64(readLimit), countStyle: .binary)
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

    /// One cookie record: a 56-byte header, then null-terminated strings. A `nil`
    /// expiry is stored as `0`, Safari's session cookie.
    private static func record(
        domain: String,
        name: String,
        path: String,
        value: String,
        expiry: Date?,
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
        bytes += littleEndian((expiry?.timeIntervalSinceReferenceDate ?? 0).bitPattern)
        bytes += littleEndian(Double(0).bitPattern)
        for string in strings {
            bytes += string
        }
        return bytes
    }

    /// `value` as four big-endian bytes.
    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    /// `value` as little-endian bytes.
    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    /// `value` as little-endian bytes.
    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }
}
