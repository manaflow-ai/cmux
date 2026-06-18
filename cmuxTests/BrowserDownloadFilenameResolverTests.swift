import Foundation
import Testing
import UniformTypeIdentifiers

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserDownloadFilenameResolverTests {
    private let resolver = BrowserDownloadFilenameResolver()

    @Test func downloadPolicyForcesChromeDownloadTypes() {
        #expect(resolver.shouldForceDownload(mimeType: "text/csv", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "text/csv; charset=utf-8", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/zip", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/x-zip-compressed", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/octet-stream", contentDisposition: nil))
        #expect(resolver.shouldForceDownload(mimeType: "application/gzip", contentDisposition: nil))
    }

    @Test func downloadPolicyKeepsInlineRenderableTypesInline() {
        #expect(!resolver.shouldForceDownload(mimeType: "text/html", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "image/png", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "application/pdf", contentDisposition: nil))
        #expect(!resolver.shouldForceDownload(mimeType: "application/json", contentDisposition: nil))
    }

    @Test func downloadPolicyHonorsAttachmentForAnyType() {
        #expect(resolver.shouldForceDownload(
            mimeType: "text/html",
            contentDisposition: "attachment; filename=index.html"
        ))
        #expect(resolver.shouldForceDownload(
            mimeType: "application/pdf",
            contentDisposition: "ATTACHMENT; filename=report.pdf"
        ))
    }

    @Test func rejectsNonSuccessHTTPStatusBeforeSavePanelNaming() throws {
        let url = try #require(URL(string: "https://example.test/logo.jpg"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
        ))

        #expect(resolver.httpStatusDecision(for: response) == .reject(statusCode: 403))
    }

    @Test func detectsPNGBytesForImageFilenameDerivation() throws {
        let imageType = try #require(resolver.imageType(forImageData: Self.onePixelPNG))

        #expect(imageType.conforms(to: .png))
    }

    @Test func imageBytesServedAsTextKeepImagePathExtension() throws {
        let url = try #require(URL(string: "https://example.test/logo.png"))
        let response = URLResponse(
            url: url,
            mimeType: "text/plain",
            expectedContentLength: Self.onePixelPNG.count,
            textEncodingName: nil
        )

        let filename = resolver.suggestedFilename(
            suggestedFilename: nil,
            response: response,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "logo.png")
    }

    @Test func imageBytesStripServerMIMEExtensionFromSuggestedFilename() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/logo"))
        let response = URLResponse(
            url: url,
            mimeType: "text/plain",
            expectedContentLength: Self.onePixelPNG.count,
            textEncodingName: nil
        )

        let filename = resolver.suggestedFilename(
            suggestedFilename: "logo.png.txt",
            response: response,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "logo.png")
    }

    @Test func imageBytesPreserveExplicitSuggestedFilenameBase() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/hash.png"))

        let filename = resolver.suggestedFilename(
            suggestedFilename: "avatar",
            response: nil,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "avatar.png")
    }

    @Test func imageBytesReplaceExplicitNonImageSuggestedExtension() throws {
        let url = try #require(URL(string: "https://cdn.example.test/assets/hash.png"))

        let filename = resolver.suggestedFilename(
            suggestedFilename: "avatar.txt",
            response: nil,
            sourceURL: url,
            imageType: .png
        )

        #expect(filename == "avatar.png")
    }

    @Test func downloadCookiesMatchRequestDomainAndPath() throws {
        let url = try #require(URL(string: "https://sub.example.test/reports/2026/export.csv"))
        let cookies = [
            try Self.cookie(name: "parent", domain: ".example.test", path: "/reports"),
            try Self.cookie(name: "host", domain: "sub.example.test", path: "/reports/2026"),
            try Self.cookie(name: "wrong-domain", domain: ".other.test", path: "/reports"),
            try Self.cookie(name: "wrong-path", domain: ".example.test", path: "/admin"),
        ]

        let names = Set(CmuxWebView.cookiesForDownloadRequest(cookies, url: url).map(\.name))

        #expect(names == ["parent", "host"])
    }

    @Test func downloadCookiesRejectSecureCookiesForHTTPAndExpiredCookies() throws {
        let url = try #require(URL(string: "http://example.test/report.csv"))
        let cookies = [
            try Self.cookie(name: "plain", domain: "example.test"),
            try Self.cookie(name: "secure", domain: "example.test", secure: true),
            try Self.cookie(name: "expired", domain: "example.test", expires: Date(timeIntervalSince1970: 0)),
            try Self.cookie(name: "future", domain: "example.test", expires: Date(timeIntervalSince1970: 4_102_444_800)),
        ]

        let names = Set(CmuxWebView.cookiesForDownloadRequest(cookies, url: url).map(\.name))

        #expect(names == ["plain", "future"])
    }

    private static func cookie(
        name: String,
        domain: String,
        path: String = "/",
        secure: Bool = false,
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "1",
            .domain: domain,
            .path: path,
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }
        return try #require(HTTPCookie(properties: properties))
    }

    private static let onePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x02,
        0x00, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x00, 0x00,
        0x06, 0x00, 0x05, 0x57, 0xBF, 0xAB, 0x7D, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
}
