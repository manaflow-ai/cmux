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


// MARK: - Appearance fallback and runtime color scheme synchronization
extension GhosttyConfigTests {
    func testUnparsedAppearanceFallbackIgnoresNativeLegacyBaselineWhenCurrentConfigExists() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-native-legacy-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        try "background = #112233\n"
            .write(to: ghosttyDir.appendingPathComponent("config", isDirectory: false), atomically: true, encoding: .utf8)
        try "background = black\n"
            .write(to: ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false), atomically: true, encoding: .utf8)

        XCTAssertTrue(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )
    }

    func testUnparsedAppearanceDirectiveIsTrackedSeparatelyFromParsedHexColor() {
        var config = GhosttyConfig()

        config.parse("background = black\nforeground = #ddeeff\n")

        XCTAssertTrue(config.hasBackgroundColorDirective)
        XCTAssertFalse(config.hasParsedBackgroundColor)
        XCTAssertTrue(config.hasForegroundColorDirective)
        XCTAssertTrue(config.hasParsedForegroundColor)
        XCTAssertEqual(config.foregroundColor.hexString(), "#DDEEFF")
    }

    func testUnparsedAppearanceFallbackKeepsNativeLegacyBaselineWhenCurrentConfigIsMissingOrEmpty() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-native-legacy-baseline-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let currentConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        try "background = #112233\n"
            .write(to: ghosttyDir.appendingPathComponent("config", isDirectory: false), atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )

        try "".write(to: currentConfig, atomically: true, encoding: .utf8)

        XCTAssertFalse(
            GhosttyApp.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
                appSupportDirectory: appSupport
            )
        )
    }

    func testDefaultBackgroundUpdateScopePrioritizesSurfaceOverAppAndUnscoped() {
        let cases: [(GhosttyDefaultBackgroundUpdateScope, GhosttyDefaultBackgroundUpdateScope, Bool)] = [
            (.unscoped, .app, true),
            (.app, .surface, true),
            (.surface, .surface, true),
            (.surface, .app, false),
            (.surface, .unscoped, false),
        ]
        for (currentScope, incomingScope, expected) in cases {
            XCTAssertEqual(
                GhosttyApp.shouldApplyDefaultBackgroundUpdate(
                    currentScope: currentScope,
                    incomingScope: incomingScope
                ),
                expected
            )
        }
    }

    func testAppearanceChangeReloadsWhenColorSchemeChanges() {
        XCTAssertTrue(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .dark, currentColorScheme: .light))
        XCTAssertTrue(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: nil, currentColorScheme: .dark))
    }

    func testAppearanceChangeSkipsReloadWhenColorSchemeUnchanged() {
        XCTAssertFalse(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .light, currentColorScheme: .light))
        XCTAssertFalse(GhosttyApp.shouldReloadConfigurationForAppearanceChange(previousColorScheme: .dark, currentColorScheme: .dark))
    }

    func testAppearanceSynchronizationPlanSkipsRuntimeUpdateWhenColorSchemeIsUnchanged() {
        let plan = GhosttyApp.appearanceSynchronizationPlan(
            previousColorScheme: .light,
            currentColorScheme: .light
        )

        switch plan {
        case .unchanged:
            XCTAssertFalse(plan.shouldReloadConfiguration)
        case .reload:
            XCTFail("Unchanged appearance should not produce a reload plan")
        }
    }

    func testAppearanceSynchronizationPlanUpdatesGhosttyRuntimeWhenReloading() {
        let cases: [
            (
                previous: GhosttyConfig.ColorSchemePreference?,
                current: GhosttyConfig.ColorSchemePreference,
                runtime: ghostty_color_scheme_e
            )
        ] = [
            (nil, .dark, GHOSTTY_COLOR_SCHEME_DARK),
            (.dark, .light, GHOSTTY_COLOR_SCHEME_LIGHT),
            (.light, .dark, GHOSTTY_COLOR_SCHEME_DARK),
        ]

        for testCase in cases {
            let plan = GhosttyApp.appearanceSynchronizationPlan(
                previousColorScheme: testCase.previous,
                currentColorScheme: testCase.current
            )

            switch plan {
            case .unchanged:
                XCTFail("Changed appearance should produce a reload plan")
            case let .reload(colorScheme, runtimeColorScheme):
                XCTAssertEqual(colorScheme, testCase.current)
                XCTAssertEqual(runtimeColorScheme, testCase.runtime)
                XCTAssertTrue(plan.shouldReloadConfiguration)
            }
        }
    }

    func testTerminalRuntimeColorSchemeFollowsResolvedThemeBackground() {
        XCTAssertEqual(
            GhosttyApp.terminalRuntimeColorSchemePreference(
                forBackgroundColor: NSColor(hex: "#F7F7F7")!
            ),
            .light
        )
        XCTAssertEqual(
            GhosttyApp.terminalRuntimeColorSchemePreference(
                forBackgroundColor: NSColor(hex: "#090300")!
            ),
            .dark
        )
    }

    func testRuntimeColorSchemeSynchronizationDecisionOnlySkipsReentrantCalls() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: nil,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: false
            ),
            .apply
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: GHOSTTY_COLOR_SCHEME_DARK,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: false
            ),
            .apply
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeSynchronizationDecision(
                applied: GHOSTTY_COLOR_SCHEME_LIGHT,
                requested: GHOSTTY_COLOR_SCHEME_DARK,
                isSynchronizing: true
            ),
            .skipReentrant
        )
    }

    func testRuntimeColorSchemeForCmuxSingleThemeReloadKeepsResolvedSchemeDuringConfigLoad() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Day"
            ),
            .light
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadPreviewSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "3024 Day"
            ),
            .light
        )
    }

    func testRuntimeColorSchemeForPairedThemeReloadUsesAppearanceDuringConfigLoad() {
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: GhosttySurfaceConfigurationRefresh.cmuxThemeReloadFinalSource,
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Night"
            ),
            .dark
        )
        XCTAssertEqual(
            GhosttyApp.runtimeColorSchemeForConfigLoad(
                source: "socket.reload_config",
                requestedColorScheme: .dark,
                effectiveTerminalColorScheme: .light,
                cmuxThemeValue: "light:3024 Day,dark:3024 Day"
            ),
            .dark
        )
    }

}
