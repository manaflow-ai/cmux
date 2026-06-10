@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - CJK font mapping and fallback injection
extension GhosttyMouseFocusTests {
    func withTempConfig(
        _ contents: String,
        body: (String) -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("config")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        body(file.path)
    }

    // MARK: cjkFontMappings

    func testCJKFontMappingsReturnsHiraginoWithKanaForJapanese() {
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "en-US"])!
        let fonts = Set(mappings.map(\.1))
        let ranges = mappings.map(\.0)

        XCTAssertTrue(fonts.contains("Hiragino Sans"))
        XCTAssertTrue(ranges.contains("U+3040-U+309F"), "Should include Hiragana")
        XCTAssertTrue(ranges.contains("U+30A0-U+30FF"), "Should include Katakana")
        XCTAssertTrue(ranges.contains("U+4E00-U+9FFF"), "Should include CJK Ideographs")
        XCTAssertFalse(ranges.contains("U+AC00-U+D7AF"), "Should NOT include Hangul")
    }

    func testCJKFontMappingsReturnsNilForKoreanOnly() {
        // Korean is not auto-mapped — Ghostty's native CTFontCreateForString
        // fallback selects a better-matching font for Hangul.
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["ko-KR"]))
    }

    func testCJKFontMappingsReturnsPingFangForChinese() {
        let mappingsTW = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hant-TW"])!
        XCTAssertTrue(mappingsTW.contains { $0.1 == "PingFang TC" })

        let mappingsCN = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-Hans-CN"])!
        XCTAssertTrue(mappingsCN.contains { $0.1 == "PingFang SC" })

        let mappingsHK = GhosttyApp.cjkFontMappings(preferredLanguages: ["zh-HK"])!
        XCTAssertTrue(mappingsHK.contains { $0.1 == "PingFang TC" })
    }

    func testCJKFontMappingsReturnsNilForNonCJKLanguages() {
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: ["en-US", "fr-FR"]))
        XCTAssertNil(GhosttyApp.cjkFontMappings(preferredLanguages: []))
    }

    func testCJKFontMappingsMultiLanguageSkipsKorean() {
        // When both ja and ko are preferred, only Japanese mappings are generated.
        // Korean is left to Ghostty's native CTFontCreateForString fallback.
        let mappings = GhosttyApp.cjkFontMappings(preferredLanguages: ["ja-JP", "ko-KR"])!

        let hiraginoRanges = mappings.filter { $0.1 == "Hiragino Sans" }.map(\.0)

        XCTAssertTrue(hiraginoRanges.contains("U+3040-U+309F"), "Hiragana → Hiragino")
        XCTAssertTrue(hiraginoRanges.contains("U+4E00-U+9FFF"), "Shared CJK → first lang font")
        XCTAssertFalse(mappings.contains { $0.1 == "Apple SD Gothic Neo" }, "No Korean font mapping")
        XCTAssertFalse(hiraginoRanges.contains("U+AC00-U+D7AF"), "Hangul NOT in Hiragino")
    }

    func testResolvedInjectedCJKFontNamePinsRegularWeightForHiraginoSans() throws {
        guard let plain = GhosttyApp.discoveredCTFont(named: "Hiragino Sans"),
              let pinned = GhosttyApp.discoveredCTFont(
                  named: GhosttyApp.resolvedInjectedCJKFontName(named: "Hiragino Sans")
              ) else {
            throw XCTSkip("Hiragino Sans is unavailable on this runner")
        }

        let plainFullName = CTFontCopyFullName(plain) as String
        let pinnedFullName = CTFontCopyFullName(pinned) as String

        XCTAssertEqual(CTFontCopyFamilyName(pinned) as String, "Hiragino Sans")
        XCTAssertFalse(pinnedFullName.contains(" W0"))
        if plainFullName.contains(" W0") {
            XCTAssertNotEqual(
                CTFontCopyPostScriptName(plain) as String,
                CTFontCopyPostScriptName(pinned) as String
            )
        }
    }

    func testResolvedInjectedCJKFontNameLeavesPingFangSCStable() throws {
        guard GhosttyApp.discoveredCTFont(named: "PingFang SC") != nil else {
            throw XCTSkip("PingFang SC is unavailable on this runner")
        }

        XCTAssertEqual(
            GhosttyApp.resolvedInjectedCJKFontName(named: "PingFang SC"),
            "PingFang SC"
        )
    }

    // MARK: autoInjectedCJKFontMappings

    func testAutoInjectedCJKFontMappingsSkipsRangesCoveredByConfiguredPrimaryFont() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertNil(
                GhosttyApp.autoInjectedCJKFontMappings(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

    func testAutoInjectedCJKFontMappingsKeepsOnlyUncoveredRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Example CJK Mono\n") { path in
            let mappings = GhosttyApp.autoInjectedCJKFontMappings(
                preferredLanguages: ["ja-JP"],
                configPaths: [path],
                rangeCoverageProbe: { _, range in
                    coveredRanges.contains(range)
                }
            )!

            XCTAssertEqual(Set(mappings.map(\.0)), Set(["U+3040-U+309F", "U+30A0-U+30FF"]))
            XCTAssertEqual(Set(mappings.map(\.1)), Set(["Hiragino Sans"]))
        }
    }

    // MARK: userConfigContainsCJKCodepointMap

    func testUserConfigContainsCJKCodepointMapDetectsPresence() throws {
        try withTempConfig("font-family = Menlo\nfont-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseWhenAbsent() throws {
        try withTempConfig("font-family = Menlo\nfont-size = 14\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapIgnoresComments() throws {
        try withTempConfig("# font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n") { path in
            XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path]))
        }
    }

    func testUserConfigContainsCJKCodepointMapReturnsFalseForMissingFiles() {
        let path = NSTemporaryDirectory() + "cmux-nonexistent-\(UUID().uuidString)/config"
        XCTAssertFalse(
            GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
        )
    }

    func testUserConfigContainsCJKCodepointMapFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+3000-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = Menlo\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapFollowsRelativeIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = fonts.conf\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesOptionalInclude() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "config-file = ?\(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [main.path]))
    }

    func testUserConfigContainsCJKCodepointMapHandlesCyclicIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.conf")
        let fileB = dir.appendingPathComponent("b.conf")
        try "config-file = \(fileB.path)\n"
            .write(to: fileA, atomically: true, encoding: .utf8)
        try "config-file = \(fileA.path)\n"
            .write(to: fileB, atomically: true, encoding: .utf8)

        // Should not hang; should return false since neither file has font-codepoint-map
        XCTAssertFalse(GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [fileA.path]))
    }

    func testUserConfigContainsCJKCodepointMapRespectsReset() throws {
        try withTempConfig("""
        font-codepoint-map = U+4E00-U+9FFF=Hiragino Sans
        font-codepoint-map =
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigContainsCJKCodepointMap(configPaths: [path])
            )
        }
    }

    // MARK: userConfigHasExplicitFontFamilyFallbackChain

    func testUserConfigHasExplicitFontFamilyFallbackChainDetectsMultipleEntries() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertTrue(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainFollowsConfigFileIncludes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [main.path])
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsFontFamilyReset() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family =
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(configPaths: [path])
            )
        }
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainIgnoresDuplicateFamilies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\n"
            .write(to: legacy, atomically: true, encoding: .utf8)

        let preferred = dir.appendingPathComponent("config.ghostty")
        try "font-family = JetBrains Mono\n"
            .write(to: preferred, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [legacy.path, preferred.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainMatchesGhosttyIncludeLoadOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "font-family =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    func testUserConfigHasExplicitFontFamilyFallbackChainRespectsConfigFileReset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-cjk-font-family-config-file-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let included = dir.appendingPathComponent("fonts.conf")
        try "font-family = LXGW WenKai Mono TC\n"
            .write(to: included, atomically: true, encoding: .utf8)

        let main = dir.appendingPathComponent("config")
        try "font-family = JetBrains Mono\nconfig-file = \(included.path)\n"
            .write(to: main, atomically: true, encoding: .utf8)

        let reset = dir.appendingPathComponent("config.ghostty")
        try "config-file =\n"
            .write(to: reset, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.userConfigHasExplicitFontFamilyFallbackChain(
                configPaths: [main.path, reset.path]
            )
        )
    }

    // MARK: shouldInjectCJKFontFallback

    func testShouldInjectCJKFontFallbackSkipsExplicitMultiFontFallbackChain() throws {
        try withTempConfig("""
        font-family = JetBrains Mono
        font-family = LXGW WenKai Mono TC
        """) { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackAllowsSingleFontWithoutExplicitOverrides() throws {
        try withTempConfig("font-family = JetBrains Mono\n") { path in
            XCTAssertTrue(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path]
                )
            )
        }
    }

    func testShouldInjectCJKFontFallbackSkipsConfiguredFontThatAlreadyCoversMappedRanges() throws {
        let coveredRanges: Set<String> = [
            "U+3000-U+303F",
            "U+4E00-U+9FFF",
            "U+F900-U+FAFF",
            "U+FF00-U+FFEF",
            "U+3400-U+4DBF",
        ]

        try withTempConfig("font-family = Sarasa Mono K\n") { path in
            XCTAssertFalse(
                GhosttyApp.shouldInjectCJKFontFallback(
                    preferredLanguages: ["zh-Hans-CN"],
                    configPaths: [path],
                    rangeCoverageProbe: { fontFamily, range in
                        XCTAssertEqual(fontFamily, "Sarasa Mono K")
                        return coveredRanges.contains(range)
                    }
                )
            )
        }
    }

}
