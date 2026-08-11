// Behavior tests for FileSearchResultIcon, extension→symbol/tint mapping and the process-wide image cache.

import AppKit
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FileSearchResultIconTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FileSearchResultIcon._resetSymbolCacheForTests()
    }

    func testSymbolPicksExtensionMapping() {
        let icon = FileSearchResultIcon.symbol(forRelativePath: "src/Foo.swift")
        XCTAssertNotNil(icon)
        // SF Symbol-backed NSImage carries the requested name in `accessibilityDescription`
        // only when we set it, so we instead verify identity stability via the cache.
        let icon2 = FileSearchResultIcon.symbol(forRelativePath: "lib/Bar.swift")
        XCTAssertTrue(icon === icon2, "Same SF Symbol should resolve to the same cached NSImage instance")
    }

    func testSymbolFallsBackForUnknownExtension() {
        let icon = FileSearchResultIcon.symbol(forRelativePath: "data/blob.unknownext")
        XCTAssertNotNil(icon)
        // Identity check vs an unrelated unknown ext that shares the fallback.
        let icon2 = FileSearchResultIcon.symbol(forRelativePath: "report.weirdext")
        XCTAssertTrue(icon === icon2, "Unknown extensions should share the fallback symbol")
    }

    func testSymbolFallsBackForNoExtension() {
        let icon = FileSearchResultIcon.symbol(forRelativePath: "src/no_extension_here")
        XCTAssertNotNil(icon)
    }

    func testTintIsLanguageSpecific() {
        XCTAssertEqual(
            FileSearchResultIcon.symbolTint(forRelativePath: "src/Foo.swift"),
            .systemOrange
        )
        XCTAssertEqual(
            FileSearchResultIcon.symbolTint(forRelativePath: "src/Bar.ts"),
            .systemBlue
        )
    }

    func testTintFallsBackToSecondaryLabelForUnknown() {
        XCTAssertEqual(
            FileSearchResultIcon.symbolTint(forRelativePath: "data/blob.unknownext"),
            .secondaryLabelColor
        )
    }

    func testExactNameOutranksExtension() {
        // Dockerfile has no extension but has an exact-name mapping. README.md
        // has both a markdown extension AND an exact-name mapping.
        let dockerfile = FileSearchResultIcon.symbol(forRelativePath: "tools/Dockerfile")
        let readme = FileSearchResultIcon.symbol(forRelativePath: "README.md")
        XCTAssertNotNil(dockerfile)
        XCTAssertNotNil(readme)
        // Resolve a generic markdown file (no exact match) and confirm it
        // differs from README.md (which uses a different symbol).
        let plainMarkdown = FileSearchResultIcon.symbol(forRelativePath: "notes/random.md")
        XCTAssertFalse(readme === plainMarkdown, "README.md exact-name mapping should not collide with generic .md")
    }

    func testCombinedIconReturnsSameImageAsSymbol() {
        let lookup = FileSearchResultIcon.icon(forRelativePath: "src/Foo.swift")
        let symbol = FileSearchResultIcon.symbol(forRelativePath: "src/Foo.swift")
        XCTAssertTrue(lookup.image === symbol, "icon(forRelativePath:) must return the same cached NSImage")
        XCTAssertEqual(lookup.tint, FileSearchResultIcon.symbolTint(forRelativePath: "src/Foo.swift"))
    }

    func testCombinedIconHandlesExactName() {
        let lookup = FileSearchResultIcon.icon(forRelativePath: "tools/Dockerfile")
        let symbol = FileSearchResultIcon.symbol(forRelativePath: "tools/Dockerfile")
        XCTAssertTrue(lookup.image === symbol)
        XCTAssertEqual(lookup.tint, FileSearchResultIcon.symbolTint(forRelativePath: "tools/Dockerfile"))
    }

    func testSymbolIsTemplate() {
        let icon = FileSearchResultIcon.symbol(forRelativePath: "src/Foo.swift")
        XCTAssertTrue(icon.isTemplate, "Symbol images must be template-rendered so AppKit applies contentTintColor")
    }

    func testResetClearsCache() {
        let before = FileSearchResultIcon.symbol(forRelativePath: "src/Foo.swift")
        FileSearchResultIcon._resetSymbolCacheForTests()
        let after = FileSearchResultIcon.symbol(forRelativePath: "src/Foo.swift")
        XCTAssertFalse(before === after, "Reset should evict cached entries so a fresh lookup allocates a new image")
    }

    /// Perf guardrail, 5000 lookups of mixed paths must stay under a generous
    /// wall-clock budget. The grouped Find sidebar reconfigures up to a few
    /// hundred header cells on snapshot apply and every sticky scroll tick
    /// hits this path; a regression that drops the cache would show up as a
    /// 10–100× slowdown here.
    func testIconLookupIsCheap() {
        let samplePaths = [
            "src/Foo.swift",
            "lib/util.ts",
            "scripts/run.sh",
            "README.md",
            "Dockerfile",
            "data/blob.unknownext",
            "tools/Makefile",
            "config/settings.json",
            "media/clip.mp4",
            "src/no_extension_here",
        ]
        // Warm the cache first so we measure the steady-state hit path.
        for path in samplePaths {
            _ = FileSearchResultIcon.icon(forRelativePath: path)
        }
        measure {
            for _ in 0..<500 {
                for path in samplePaths {
                    _ = FileSearchResultIcon.icon(forRelativePath: path)
                }
            }
        }
    }
}
