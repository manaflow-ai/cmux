import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class LocalFileImageLoaderTests: XCTestCase {
    func testHttpIsRemote() {
        let url = URL(string: "http://example.com/foo.png")!
        XCTAssertEqual(LocalFileImageLoader.classify(url), .remote(url))
    }

    func testHttpsIsRemote() {
        let url = URL(string: "https://example.com/foo.png")!
        XCTAssertEqual(LocalFileImageLoader.classify(url), .remote(url))
    }

    func testFileURLIsLocal() {
        let url = URL(string: "file:///Users/u/foo.png")!
        let expected = URL(fileURLWithPath: "/Users/u/foo.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }

    func testFileURLFragmentIsDropped() {
        let url = URL(string: "file:///Users/u/foo.png#gh-dark-mode-only")!
        let expected = URL(fileURLWithPath: "/Users/u/foo.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }

    func testFileURLQueryIsDropped() {
        let url = URL(string: "file:///Users/u/foo.png?v=1")!
        let expected = URL(fileURLWithPath: "/Users/u/foo.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }

    func testFileURLPercentEncodedSpaceIsDecoded() {
        let url = URL(string: "file:///Users/u/has%20space.png")!
        let expected = URL(fileURLWithPath: "/Users/u/has space.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }

    func testFileURLPercentEncodedUnicodeIsDecoded() {
        let url = URL(string: "file:///Users/u/%E6%97%A5%E6%9C%AC%E8%AA%9E.png")!
        let expected = URL(fileURLWithPath: "/Users/u/日本語.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }

    func testMailtoIsUnsupported() {
        let url = URL(string: "mailto:foo@bar")!
        XCTAssertEqual(LocalFileImageLoader.classify(url), .unsupported)
    }

    func testDataURLIsUnsupported() {
        let url = URL(string: "data:image/png;base64,AAAA")!
        XCTAssertEqual(LocalFileImageLoader.classify(url), .unsupported)
    }

    func testRelativeURLAgainstFileBaseResolvesToAbsoluteLocal() {
        // swift-markdown-ui hands the provider the result of
        // `URL(string: "./images/plain.png", relativeTo: imageBaseURL)`.
        // The classifier must normalize that to an absolute file URL instead
        // of passing the relative path through to `URL(fileURLWithPath:)`,
        // which would join it against the shell's current working directory.
        let base = URL(fileURLWithPath: "/tmp/md-test/edge.md").deletingLastPathComponent()
        let relative = URL(string: "./images/plain.png", relativeTo: base)!
        let expected = URL(fileURLWithPath: "/tmp/md-test/images/plain.png")
        XCTAssertEqual(LocalFileImageLoader.classify(relative), .local(expected))
    }

    func testRelativeURLWithParentTraversalResolvesAgainstBase() {
        let base = URL(fileURLWithPath: "/tmp/md-test/edge.md").deletingLastPathComponent()
        let relative = URL(string: "../md-test/images/plain.png", relativeTo: base)!
        let expected = URL(fileURLWithPath: "/tmp/md-test/images/plain.png")
        XCTAssertEqual(LocalFileImageLoader.classify(relative), .local(expected))
    }

    func testBareRelativeURLResolvesAgainstBase() {
        let base = URL(fileURLWithPath: "/tmp/md-test/edge.md").deletingLastPathComponent()
        let relative = URL(string: "images/plain.png", relativeTo: base)!
        let expected = URL(fileURLWithPath: "/tmp/md-test/images/plain.png")
        XCTAssertEqual(LocalFileImageLoader.classify(relative), .local(expected))
    }

    func testSchemelessAbsolutePathIsLocal() {
        // Scheme-less absolute paths normally get normalized by the library
        // before they reach us, but verify the defensive branch in the
        // classifier.
        var components = URLComponents()
        components.path = "/Users/u/foo.png"
        let url = components.url!
        let expected = URL(fileURLWithPath: "/Users/u/foo.png")
        XCTAssertEqual(LocalFileImageLoader.classify(url), .local(expected))
    }
}

final class LocalFileImageCacheKeyTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("cmux-LocalFileImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testKeyReturnsNilForMissingFile() {
        let missing = tempDirectoryURL.appendingPathComponent("missing.png")
        XCTAssertNil(LocalFileImageCache.key(for: missing))
    }

    func testKeyChangesWhenFileModificationDateChanges() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("image.png")
        try Data([0x00]).write(to: fileURL)

        let firstKey = try XCTUnwrap(LocalFileImageCache.key(for: fileURL))

        // Bump mtime to a time that is definitely distinguishable from the
        // initial write so the composite key must change.
        let future = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes(
            [.modificationDate: future],
            ofItemAtPath: fileURL.path
        )

        let secondKey = try XCTUnwrap(LocalFileImageCache.key(for: fileURL))
        XCTAssertNotEqual(firstKey, secondKey)
    }

    func testKeyIsStableAcrossCallsWhenFileUnchanged() throws {
        let fileURL = tempDirectoryURL.appendingPathComponent("stable.png")
        try Data([0x00, 0x01]).write(to: fileURL)

        let first = try XCTUnwrap(LocalFileImageCache.key(for: fileURL))
        let second = try XCTUnwrap(LocalFileImageCache.key(for: fileURL))
        XCTAssertEqual(first, second)
    }
}
