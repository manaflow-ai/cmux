import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SafariBinaryCookiesParserTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal valid Cookies.binarycookies Data with one page and one cookie.
    private func makeSingleCookieData(
        domain: String = "example.com",
        name: String = "session",
        path: String = "/",
        value: String = "abc123",
        flags: UInt32 = 0x00,
        expiryMacTime: Double = 0
    ) -> Data {
        // Strings (null-terminated)
        let domainBytes = domain.utf8 + [0]
        let nameBytes   = name.utf8   + [0]
        let pathBytes   = path.utf8   + [0]
        let valueBytes  = value.utf8  + [0]

        // Cookie record offsets (relative to cookie start, fixed header = 56 bytes)
        let domainOff = UInt32(56)
        let nameOff   = domainOff + UInt32(domainBytes.count)
        let pathOff   = nameOff   + UInt32(nameBytes.count)
        let valueOff  = pathOff   + UInt32(pathBytes.count)
        let cookieSize = Int(valueOff) + valueBytes.count

        var cookie = Data()
        cookie += leUInt32(UInt32(cookieSize))  // offset  0: size
        cookie += leUInt32(0)                    // offset  4: unknown
        cookie += leUInt32(flags)               // offset  8: flags
        cookie += leUInt32(0)                    // offset 12: unknown
        cookie += leUInt32(domainOff)           // offset 16: domain offset
        cookie += leUInt32(nameOff)             // offset 20: name offset
        cookie += leUInt32(pathOff)             // offset 24: path offset
        cookie += leUInt32(valueOff)            // offset 28: value offset
        cookie += leUInt64(0)                   // offset 32: unknown (8 bytes)
        cookie += leDouble(expiryMacTime)       // offset 40: expiry
        cookie += leDouble(0)                   // offset 48: creation
        // Strings
        cookie += Data(domainBytes)
        cookie += Data(nameBytes)
        cookie += Data(pathBytes)
        cookie += Data(valueBytes)

        // Page: 4-byte signature + 4-byte count + (4 * M)-byte offset array + 4-byte footer + cookies
        // For M=1: header is 16 bytes, so first cookie is at page offset 16.
        var page = Data()
        page += Data([0x00, 0x01, 0x00, 0x00])  // page signature (bytes 0-3)
        page += leUInt32(1)                       // 1 cookie (bytes 4-7)
        page += leUInt32(16)                      // cookie offset = 16 (bytes 8-11)
        page += leUInt32(0)                       // page footer (bytes 12-15)
        page += cookie                            // cookie data starts at byte 16

        let pageSize = UInt32(page.count)

        // File header
        var file = Data()
        file += Data([0x63, 0x6F, 0x6F, 0x6B])  // magic "cook"
        file += beUInt32(1)                        // 1 page
        file += beUInt32(pageSize)                 // page size
        file += page

        // Footer (8-byte checksum placeholder)
        file += Data(count: 8)
        return file
    }

    // MARK: - Tests

    func testParsesBasicCookieFields() throws {
        let data = makeSingleCookieData(domain: "example.com", name: "token", path: "/app", value: "xyz")
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].domain, "example.com")
        XCTAssertEqual(cookies[0].name, "token")
        XCTAssertEqual(cookies[0].path, "/app")
        XCTAssertEqual(cookies[0].value, "xyz")
    }

    func testSecureFlag() throws {
        let data = makeSingleCookieData(flags: 0x01)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertTrue(cookies[0].isSecure)
        XCTAssertFalse(cookies[0].isHttpOnly)
    }

    func testHttpOnlyFlag() throws {
        let data = makeSingleCookieData(flags: 0x04)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertFalse(cookies[0].isSecure)
        XCTAssertTrue(cookies[0].isHttpOnly)
    }

    func testBothFlags() throws {
        let data = makeSingleCookieData(flags: 0x05)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertTrue(cookies[0].isSecure)
        XCTAssertTrue(cookies[0].isHttpOnly)
    }

    func testNoFlags() throws {
        let data = makeSingleCookieData(flags: 0x00)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertFalse(cookies[0].isSecure)
        XCTAssertFalse(cookies[0].isHttpOnly)
    }

    func testExpiryConversionFromMacAbsoluteTime() throws {
        // Mac absolute time 1.0 = 2001-01-01 00:00:01 UTC = Unix 978307201
        let macTime: Double = 1.0
        let data = makeSingleCookieData(expiryMacTime: macTime)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        let expectedUnix: TimeInterval = 978_307_201
        XCTAssertEqual(cookies[0].expiresDate?.timeIntervalSince1970 ?? 0, expectedUnix, accuracy: 1.0)
    }

    func testZeroMacTimeMeansSessionCookie() throws {
        // Mac absolute time 0.0 means "session cookie" (no expiry) in the binary format
        let data = makeSingleCookieData(expiryMacTime: 0.0)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertNil(cookies[0].expiresDate, "0.0 mac time = session cookie = nil expiry")
    }

    func testExpiryConversionKnownDate() throws {
        // 2030-01-01 00:00:00 UTC = Unix 1893456000
        // Mac absolute = 1893456000 - 978307200 = 915148800
        let macTime: Double = 915_148_800
        let data = makeSingleCookieData(expiryMacTime: macTime)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].expiresDate?.timeIntervalSince1970 ?? 0, 1_893_456_000, accuracy: 1.0)
    }

    func testZeroExpiryYieldsNilDate() throws {
        // expiryMacTime <= 0 should produce nil expiresDate
        let data = makeSingleCookieData(expiryMacTime: -1)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertNil(cookies[0].expiresDate)
    }

    func testNonFiniteExpiryYieldsNilDate() throws {
        // A malformed file with a non-finite (infinity) expiry must not produce a Date.
        let data = makeSingleCookieData(expiryMacTime: .infinity)
        let cookies = try SafariBinaryCookiesParser.parse(data: data)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertNil(cookies[0].expiresDate)
    }

    func testParsesDataSliceWithNonZeroStartIndex() throws {
        // Callers may pass a Data slice (startIndex != 0); parsing must still work.
        let base = makeSingleCookieData(domain: "example.com", name: "token", value: "xyz")
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(base)
        let slice = padded[3...]
        XCTAssertNotEqual(slice.startIndex, 0)
        let cookies = try SafariBinaryCookiesParser.parse(data: slice)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].name, "token")
    }

    func testInvalidMagicThrows() {
        var data = makeSingleCookieData()
        data[0] = 0xFF
        XCTAssertThrowsError(try SafariBinaryCookiesParser.parse(data: data)) { error in
            XCTAssertTrue(error is SafariBinaryCookiesParser.ParseError)
        }
    }

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try SafariBinaryCookiesParser.parse(data: Data())) { error in
            XCTAssertTrue(error is SafariBinaryCookiesParser.ParseError)
        }
    }

    func testTruncatedDataThrows() {
        let data = Data([0x63, 0x6F, 0x6F, 0x6B, 0x00])  // magic + partial page count
        XCTAssertThrowsError(try SafariBinaryCookiesParser.parse(data: data))
    }

    func testEmptyPageYieldsNoCookies() throws {
        // Build a file with 0 pages
        var file = Data()
        file += Data([0x63, 0x6F, 0x6F, 0x6B])
        file += beUInt32(0)  // 0 pages
        file += Data(count: 8)
        let cookies = try SafariBinaryCookiesParser.parse(data: file)
        XCTAssertEqual(cookies.count, 0)
    }

    // MARK: - Import mapping (ParsedCookie -> HTTPCookie)

    func testImportPreservesHttpOnly() {
        let parsed = SafariBinaryCookiesParser.ParsedCookie(
            domain: "example.com", name: "sid", path: "/", value: "v",
            expiresDate: nil, isSecure: false, isHttpOnly: true
        )
        let cookie = BrowserDataImporter.makeSafariHTTPCookie(from: parsed)
        XCTAssertNotNil(cookie)
        XCTAssertTrue(cookie?.isHTTPOnly ?? false, "HttpOnly must survive import into HTTPCookie")
    }

    func testImportPreservesSecureAndValueAndPersistence() {
        let parsed = SafariBinaryCookiesParser.ParsedCookie(
            domain: "example.com", name: "sid", path: "/app", value: "abc=123",
            expiresDate: Date(timeIntervalSince1970: 1_893_456_000), isSecure: true, isHttpOnly: false
        )
        let cookie = BrowserDataImporter.makeSafariHTTPCookie(from: parsed)
        XCTAssertNotNil(cookie)
        XCTAssertTrue(cookie?.isSecure ?? false)
        XCTAssertFalse(cookie?.isHTTPOnly ?? true)
        XCTAssertEqual(cookie?.name, "sid")
        XCTAssertEqual(cookie?.value, "abc=123")
        XCTAssertEqual(cookie?.path, "/app")
        // Persistent cookie must stay persistent. The exact expiry is intentionally
        // not asserted: HTTPCookie clamps far-future dates to the platform's max
        // cookie lifetime (~400 days), which is time- and OS-version-dependent.
        XCTAssertNotNil(cookie?.expiresDate)
    }

    func testImportSessionCookieHasNoExpiry() {
        let parsed = SafariBinaryCookiesParser.ParsedCookie(
            domain: "example.com", name: "sid", path: "/", value: "v",
            expiresDate: nil, isSecure: false, isHttpOnly: false
        )
        XCTAssertNil(BrowserDataImporter.makeSafariHTTPCookie(from: parsed)?.expiresDate)
    }

    func testImportEmptyPathDefaultsToRoot() {
        let parsed = SafariBinaryCookiesParser.ParsedCookie(
            domain: "example.com", name: "sid", path: "", value: "v",
            expiresDate: nil, isSecure: false, isHttpOnly: false
        )
        XCTAssertEqual(BrowserDataImporter.makeSafariHTTPCookie(from: parsed)?.path, "/")
    }

    func testImportEmptyNameReturnsNil() {
        let parsed = SafariBinaryCookiesParser.ParsedCookie(
            domain: "example.com", name: "", path: "/", value: "v",
            expiresDate: nil, isSecure: false, isHttpOnly: false
        )
        XCTAssertNil(BrowserDataImporter.makeSafariHTTPCookie(from: parsed))
    }

    // MARK: - Byte helpers

    private func leUInt32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private func beUInt32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func leUInt64(_ v: UInt64) -> Data {
        var d = Data(count: 8)
        for i in 0 ..< 8 { d[i] = UInt8((v >> (i * 8)) & 0xFF) }
        return d
    }

    private func leDouble(_ v: Double) -> Data {
        leUInt64(v.bitPattern)
    }
}
