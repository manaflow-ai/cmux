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
