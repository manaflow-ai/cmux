import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the appearance-resolution hot path: SwiftUI view
/// updates call `GhosttyConfig.load()` (via `resolveGhosttyAppearanceConfig`)
/// on every invalidation, and must reuse the cached parse instead of re-reading
/// and re-parsing the config files from disk unless a config file actually
/// changed. See https://github.com/manaflow-ai/cmux/issues/5833.
final class GhosttyConfigSignatureCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GhosttyConfig.invalidateLoadCache()
    }

    override func tearDown() {
        GhosttyConfig.invalidateLoadCache()
        super.tearDown()
    }

    private func signature(size: Int64, modified: TimeInterval) -> GhosttyConfig.ConfigFileSignature {
        GhosttyConfig.ConfigFileSignature(
            entries: [.init(path: "/tmp/cmux-test-config", size: size, modified: modified)]
        )
    }

    func testRepeatedResolvesReuseCachedParseUntilSignatureChanges() {
        var parseCount = 0
        func loadWith(_ signature: GhosttyConfig.ConfigFileSignature) -> GhosttyConfig {
            GhosttyConfig.load(
                preferredColorScheme: .dark,
                useCache: true,
                fileSignature: { signature },
                loadFromDisk: { _ in
                    parseCount += 1
                    return GhosttyConfig()
                }
            )
        }

        let signatureA = signature(size: 100, modified: 10)
        _ = loadWith(signatureA)
        _ = loadWith(signatureA)
        _ = loadWith(signatureA)
        XCTAssertEqual(
            parseCount,
            1,
            "Repeated appearance resolutions with an unchanged config file must reuse the cached parse"
        )

        // A real config-file change (new size/mtime) must trigger exactly one
        // re-parse, even without an explicit invalidateLoadCache() call.
        let signatureB = signature(size: 200, modified: 20)
        _ = loadWith(signatureB)
        _ = loadWith(signatureB)
        XCTAssertEqual(
            parseCount,
            2,
            "A changed config-file signature must trigger exactly one re-parse and then re-cache"
        )
    }

    func testSignatureCacheIsKeyedPerColorScheme() {
        var parseCount = 0
        let sharedSignature = signature(size: 50, modified: 5)
        func load(_ scheme: GhosttyConfig.ColorSchemePreference) -> GhosttyConfig {
            GhosttyConfig.load(
                preferredColorScheme: scheme,
                useCache: true,
                fileSignature: { sharedSignature },
                loadFromDisk: { _ in
                    parseCount += 1
                    return GhosttyConfig()
                }
            )
        }

        _ = load(.dark)
        _ = load(.light)
        _ = load(.dark)
        _ = load(.light)
        XCTAssertEqual(
            parseCount,
            2,
            "Each color scheme caches independently; the same file should parse at most once per scheme"
        )
    }
}
