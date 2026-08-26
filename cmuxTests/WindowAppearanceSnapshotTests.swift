import XCTest
import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WindowAppearanceSnapshotTests: XCTestCase {
    func testUnifiedSurfaceBackdropsUseSingleWindowRootBackdrop() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: true)

        assertTerminalBackdrop(snapshot.policy(for: .windowRoot))
        assertClearBackdrop(snapshot.policy(for: .terminalCanvas))
        assertClearBackdrop(snapshot.policy(for: .bonsplitChrome))
        assertClearBackdrop(snapshot.policy(for: .titlebar))
        assertClearBackdrop(snapshot.policy(for: .browserSurface))
        assertClearBackdrop(snapshot.policy(for: .leftSidebar))
        assertClearBackdrop(snapshot.policy(for: .rightSidebar))
    }

    func testSeparateSurfaceBackdropsKeepRootBackdropAndSidebarMaterialsSeparate() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: false)

        assertTerminalBackdrop(snapshot.policy(for: .windowRoot))
        assertClearBackdrop(snapshot.policy(for: .terminalCanvas))
        assertClearBackdrop(snapshot.policy(for: .bonsplitChrome))
        assertClearBackdrop(snapshot.policy(for: .titlebar))
        assertClearBackdrop(snapshot.policy(for: .browserSurface))

        guard case let .sidebarMaterial(leftPolicy) = snapshot.policy(for: .leftSidebar) else {
            XCTFail("left sidebar should keep its own material policy")
            return
        }
        XCTAssertEqual(leftPolicy.material, .sidebar)
        XCTAssertEqual(leftPolicy.blendingMode, .withinWindow)

        guard case let .sidebarMaterial(rightPolicy) = snapshot.policy(for: .rightSidebar) else {
            XCTFail("right sidebar should keep its own material policy")
            return
        }
        XCTAssertEqual(rightPolicy.material, .sidebar)
        XCTAssertEqual(rightPolicy.blendingMode, .withinWindow)
    }

    func testMacOSGlassClearForcesTransparentHostingAndClearGlassStyle() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundOpacity: 1.0,
            backgroundBlur: .macosGlassClear
        )

        XCTAssertTrue(snapshot.shouldUseTransparentHosting(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ))
        XCTAssertTrue(snapshot.windowGlassSettings.shouldApply(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ))
        XCTAssertEqual(snapshot.windowGlassSettings.style, .clear)
        XCTAssertEqual(snapshot.windowGlassSettings.tintColor.hexString(includeAlpha: true), "#272822FF")
        assertClearBackdrop(snapshot.policy(for: .windowRoot))
        XCTAssertEqual(snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ).hostingPhase, .windowGlass)
    }

    func testTranslucentTerminalWithSidebarTintKeepsRootBackdropOwner() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundOpacity: 0.9,
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4
        )
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )

        XCTAssertEqual(plan.hostingPhase, .transparentRootBackdrop)
        XCTAssertTrue(plan.usesTransparentWindow)
        XCTAssertFalse(plan.usesWindowGlass)
        assertTerminalBackdrop(plan.rootPolicy, expectedOpacity: 0.9)

        guard case let .sidebarMaterial(sidebarPolicy) = snapshot.policy(for: .leftSidebar) else {
            XCTFail("left sidebar should keep its own tint material")
            return
        }
        XCTAssertEqual(sidebarPolicy.tintColor.hexString(includeAlpha: true), "#FF000066")
    }

    func testTranslucentTerminalUsesTransparentHostingWithOpaqueCompositedChromeColor() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundOpacity: 0.5
        )

        XCTAssertEqual(snapshot.compositedTerminalBackgroundColor.alphaComponent, 1, accuracy: 0.0001)

        let plan = snapshot.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )
        XCTAssertEqual(plan.hostingPhase, .transparentRootBackdrop)
        XCTAssertTrue(plan.usesTransparentWindow)
    }

    /// Verifies a mounted Dock does not cover the shared window backdrop.
    @MainActor
    func testDockChromeLeavesSharedWindowBackdropUnpainted() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundOpacity: 0.8
        )
        var config = GhosttyConfig()
        config.backgroundColor = snapshot.terminalBackgroundColor
        config.backgroundOpacity = Double(snapshot.terminalBackgroundOpacity)

        let appearance = DockSplitStore.makeAppearance(
            from: config,
            windowAppearance: snapshot
        )

        XCTAssertTrue(appearance.usesSharedBackdrop)
        XCTAssertEqual(
            appearance.chromeColors.backgroundHex,
            "#00000000",
            "Dock chrome must leave the shared window backdrop visible behind terminal surfaces"
        )
        XCTAssertEqual(appearance.chromeColors.paneBackgroundHex, "#00000000")
    }

    /// Verifies the controller's pre-mount appearance retains a concrete fallback.
    @MainActor
    func testDockChromeKeepsConcreteFallbackBeforeWindowBackdropMounts() {
        let config = GhosttyConfig()
        let appearance = DockSplitStore.makeAppearance(from: config)

        XCTAssertNotEqual(
            appearance.chromeColors.backgroundHex,
            "#00000000",
            "The pre-mount Dock configuration needs a concrete fallback"
        )
    }

    /// Verifies renderer-owned surfaces keep their concrete Dock chrome color.
    func testDockChromeKeepsConcreteColorWhenGhosttyOwnsTheSurface() {
        let color = NSColor(hex: "#112233")!
        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.8,
            sharesWindowBackdrop: true,
            renderingMode: .ghosttyRendererOwnedBackgroundImage,
            chromeHost: .dock
        )

        XCTAssertEqual(colors.backgroundHex, "#112233CC")
    }

    func testSidebarTintChangesDoNotDriveWindowBackdropPlanIdentity() {
        let red = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundOpacity: 0.9,
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4
        )
        let blue = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundOpacity: 0.9,
            sidebarTintHexDark: "#0000FF",
            sidebarTintOpacity: 0.8
        )

        XCTAssertEqual(
            red.backdropPlan(
                glassEffectAvailable: false,
                windowBackgroundPolicy: WindowBackgroundComposition.policy
            ).appKitMutationID,
            blue.backdropPlan(
                glassEffectAvailable: false,
                windowBackgroundPolicy: WindowBackgroundComposition.policy
            ).appKitMutationID
        )
    }

    func testChromeColorSchemeFollowsTerminalBackground() {
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#F8F8F2").chromeColorScheme,
            .light
        )
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820").chromeColorScheme,
            .dark
        )
    }

    func testChromeColorSchemeAccountsForTranslucentTerminalBackground() {
        let composited = WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: NSColor(hex: "#101820")!,
            opacity: 0.05,
            over: .white
        )

        XCTAssertEqual(cmuxReadableColorScheme(for: composited), .light)
    }

    func testSidebarContentColorSchemeUsesResolvedTerminalThemeForAllBackdrops() {
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme,
            .dark
        )
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: false, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme,
            .dark
        )
    }

    func testSidebarTintSelectionUsesResolvedTerminalThemeWhenSystemDisagrees() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundHex: "#F8F8F2",
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4,
            sidebarColorScheme: .dark
        )

        guard case let .sidebarMaterial(policy) = snapshot.policy(for: .rightSidebar) else {
            XCTFail("right sidebar should keep its own material policy")
            return
        }
        XCTAssertEqual(policy.tintColor.hexString(includeAlpha: true), "#00000066")
    }

    func testDockAndSidebarChromeShareResolvedTerminalThemeWhenSystemDisagrees() {
        let cases: [(backgroundHex: String, expected: ColorScheme)] = [
            ("#F8F8F2", .light),
            ("#101820", .dark),
        ]

        for testCase in cases {
            for systemResolvedSidebarScheme in [ColorScheme.light, .dark] {
                let snapshot = makeSnapshot(
                    unifySurfaceBackdrops: false,
                    backgroundHex: testCase.backgroundHex,
                    sidebarColorScheme: systemResolvedSidebarScheme
                )

                XCTAssertEqual(
                    snapshot.chromeColorScheme,
                    testCase.expected,
                    "Unexpected terminal theme resolution for \(testCase.backgroundHex)"
                )
                XCTAssertEqual(
                    snapshot.sidebarContentColorScheme,
                    testCase.expected,
                    "Dock/sidebar chrome diverged for terminal \(testCase.expected) and system \(systemResolvedSidebarScheme)"
                )
            }
        }
    }

    func testMatchedLeftAndRightSidebarBackdropsShareTerminalRootBackdrop() {
        let cases: [(backgroundHex: String, opacity: CGFloat)] = [
            ("#FFFFFF", 1),
            ("#000000", 1),
            ("#777777", 1),
            ("#000000", 0.05),
        ]

        for testCase in cases {
            let snapshot = makeSnapshot(
                unifySurfaceBackdrops: true,
                backgroundHex: testCase.backgroundHex,
                backgroundOpacity: testCase.opacity
            )

            assertTerminalBackdrop(
                snapshot.policy(for: .windowRoot),
                expectedHex: testCase.backgroundHex,
                expectedOpacity: testCase.opacity
            )
            assertClearBackdrop(snapshot.policy(for: .terminalCanvas))
            assertClearBackdrop(snapshot.policy(for: .bonsplitChrome))
            assertClearBackdrop(snapshot.policy(for: .titlebar))
            assertClearBackdrop(snapshot.policy(for: .browserSurface))
            assertClearBackdrop(snapshot.policy(for: .leftSidebar))
            assertClearBackdrop(snapshot.policy(for: .rightSidebar))
            XCTAssertEqual(snapshot.sidebarContentColorScheme, snapshot.chromeColorScheme)
        }
    }

    func testUnifiedSidebarBackdropsDoNotTintTransparentTerminalBackground() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundHex: "#000000",
            backgroundOpacity: 0.05
        )

        XCTAssertEqual(snapshot.compositedTerminalBackgroundColor.alphaComponent, 1, accuracy: 0.0001)
        assertClearBackdrop(snapshot.policy(for: .leftSidebar))
        assertClearBackdrop(snapshot.policy(for: .rightSidebar))
    }

    func testSeparateSidebarBackdropsKeepCustomTintBehavior() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundHex: "#000000",
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4
        )

        guard case let .sidebarMaterial(sidebarPolicy) = snapshot.policy(for: .leftSidebar) else {
            XCTFail("left sidebar should keep its own tint material")
            return
        }
        XCTAssertEqual(sidebarPolicy.tintColor.hexString(includeAlpha: true), "#FF000066")
    }

    func testOpaqueTerminalUsesOpaqueWindowFill() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: false, backgroundOpacity: 1.0)
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )

        XCTAssertEqual(plan.hostingPhase, .opaqueWindowFill)
        XCTAssertFalse(plan.usesTransparentWindow)
        XCTAssertEqual(plan.windowBackgroundColor.hexString(includeAlpha: true), "#272822FF")
    }

    func testDebugBackgroundGlassUsesWindowGlassPhase() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundOpacity: 1.0,
            sidebarBlendMode: SidebarBlendModeOption.behindWindow.rawValue,
            bgGlassEnabled: true
        )
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )

        XCTAssertEqual(plan.hostingPhase, .windowGlass)
        XCTAssertTrue(plan.usesTransparentWindow)
        XCTAssertTrue(plan.usesWindowGlass)
    }

    /// Verifies pane-local OSC colors paint on the host layer over a shared root backdrop.
    func testOSCOverrideUsesSurfaceHostFillWhenWindowRootBackdropIsShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 1.0,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        XCTAssertEqual(plan.owner, .surfaceHostLayer)
        XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#D2EEF9FF")
        XCTAssertTrue(plan.clearsSharedWindowBackdrop)
    }

    /// Verifies translucent OSC colors use one host-layer fill with configured opacity.
    func testTranslucentOSCOverrideUsesOneSurfaceHostFillWithConfiguredOpacity() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#E2D2F0") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        XCTAssertEqual(plan.owner, .surfaceHostLayer)
        XCTAssertEqual(plan.hostLayerColor.hexString(), "#E2D2F0")
        XCTAssertEqual(plan.hostLayerColor.alphaComponent, 0.42, accuracy: 0.0001)
        XCTAssertTrue(plan.clearsSharedWindowBackdrop)
    }

    /// Verifies default backgrounds keep the shared backdrop intact.
    func testSharedWindowBackdropDoesNotCutOutForDefaultBackgrounds() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: nil,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        XCTAssertEqual(plan.owner, .sharedWindowBackdrop)
        XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#00000000")
        XCTAssertFalse(plan.clearsSharedWindowBackdrop)
    }

    /// Verifies Bonsplit-owned pane backdrops stay authoritative when no cutout is available.
    func testOSCOverrideKeepsBonsplitPaneBackdropOwnerWhenNoCutoutIsAvailable() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: false,
            usesBonsplitPaneBackdrop: true
        )

        XCTAssertEqual(plan.owner, .bonsplitPaneBackdrop)
        XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#00000000")
        XCTAssertFalse(plan.clearsSharedWindowBackdrop)
    }

    /// Verifies non-shared window backdrops let OSC colors paint directly on the host layer.
    func testOSCOverrideUsesSurfaceHostFillWhenWindowBackdropIsNotShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#B5EAD7") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.73,
            sharesWindowBackdrop: false,
            usesBonsplitPaneBackdrop: false
        )

        XCTAssertEqual(plan.owner, .surfaceHostLayer)
        XCTAssertEqual(plan.hostLayerColor.hexString(), "#B5EAD7")
        XCTAssertEqual(plan.hostLayerColor.alphaComponent, 0.73, accuracy: 0.0001)
        XCTAssertFalse(plan.clearsSharedWindowBackdrop)
    }

    /// Verifies renderer-owned backgrounds keep cmux host layers clear.
    func testRendererOwnedOSCOverrideKeepsHostLayerClearWhenWindowRootBackdropIsShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .ghosttyRendererOwnedBackgroundImage,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 1.0,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        XCTAssertEqual(plan.owner, .ghosttyNativeRenderer)
        XCTAssertEqual(plan.hostLayerColor.hexString(includeAlpha: true), "#00000000")
        XCTAssertFalse(plan.clearsSharedWindowBackdrop)
    }

    /// A translucent terminal theme does not own the rendered pixels: the
    /// backdrop behind the surface tab strip and browser toolbar is the theme
    /// color composited over the ambient window base. The resolved chrome
    /// scheme must follow that rendered result, or icons keyed off it become
    /// white-on-white in a light window (issue #10477).
    func testTranslucentTerminalChromeSchemeFollowsRenderedBackdrop() {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#101820") ?? .black,
                backgroundOpacity: 0.3,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true,
                resolvedColorScheme: .dark
            )
        )

        let lightWindow = resolver.current(settings: makeUserSettings(colorScheme: .light))
        XCTAssertEqual(
            lightWindow.resolvedColorScheme,
            .light,
            "Translucent dark theme over a light window renders a light backdrop; chrome icons must resolve dark"
        )
        XCTAssertEqual(
            cmuxReadableColorScheme(for: lightWindow.resolvedChromeBackgroundColor),
            .light,
            "Chrome background must composite over the light window base the user actually sees"
        )

        let darkWindow = resolver.current(settings: makeUserSettings(colorScheme: .dark))
        XCTAssertEqual(
            darkWindow.resolvedColorScheme,
            .dark,
            "Translucent dark theme over a dark window keeps dark chrome"
        )
    }

    /// Opaque themes own their rendered pixels, so the terminal theme stays
    /// the light/dark authority even when the window appearance disagrees
    /// (issue #10146 contract).
    func testOpaqueTerminalChromeSchemeKeepsTerminalThemeAuthority() {
        for (backgroundHex, terminalScheme) in [("#101820", ColorScheme.dark), ("#F8F8F2", .light)] {
            for ambientScheme in [ColorScheme.light, .dark] {
                let resolver = WindowAppearanceResolver(
                    terminalAppearance: WindowTerminalAppearanceSnapshot(
                        backgroundColor: NSColor(hex: backgroundHex) ?? .black,
                        backgroundOpacity: 1.0,
                        backgroundBlur: .disabled,
                        usesHostLayerBackground: true,
                        resolvedColorScheme: terminalScheme
                    )
                )
                let snapshot = resolver.current(settings: makeUserSettings(colorScheme: ambientScheme))
                XCTAssertEqual(
                    snapshot.resolvedColorScheme,
                    terminalScheme,
                    "Opaque \(backgroundHex) theme must keep terminal authority under \(ambientScheme) ambient"
                )
            }
        }
    }

    /// Bonsplit derives fixed black/white tab-strip glyph colors from the hex
    /// the workspace hands it, so that hex must match the rendered backdrop:
    /// composited over the ambient base for translucent themes, the theme
    /// color itself for opaque ones (issue #10477).
    func testBonsplitChromeBackgroundColorMatchesRenderedBackdrop() {
        let translucentDarkOverLight = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 0.3,
            terminalColorScheme: .dark,
            ambientColorScheme: .light
        )
        XCTAssertEqual(
            cmuxReadableColorScheme(for: translucentDarkOverLight),
            .light,
            "Translucent dark theme in a light window must hand Bonsplit a light hex so tab glyphs resolve dark"
        )

        let translucentDarkOverDark = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 0.3,
            terminalColorScheme: .dark,
            ambientColorScheme: .dark
        )
        XCTAssertEqual(cmuxReadableColorScheme(for: translucentDarkOverDark), .dark)

        let opaqueDarkOverLight = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 1.0,
            terminalColorScheme: .dark,
            ambientColorScheme: .light
        )
        XCTAssertEqual(cmuxReadableColorScheme(for: opaqueDarkOverLight), .dark)
    }

    /// Callers that omit the ambient scheme (`currentFromUserDefaults`) must
    /// not have translucent chrome resolved against a guessed light window:
    /// the resolver fails closed to the terminal authority instead.
    func testOmittedAmbientSchemeFailsClosedToTerminalAuthority() {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#101820") ?? .black,
                backgroundOpacity: 0.3,
                backgroundBlur: .disabled,
                usesHostLayerBackground: true,
                resolvedColorScheme: .dark
            )
        )
        let snapshot = resolver.currentFromUserDefaults(
            defaults: UserDefaults(suiteName: "cmux.tests.omitted-ambient")!
        )

        XCTAssertEqual(
            snapshot.resolvedColorScheme,
            .dark,
            "Without an injected ambient scheme, translucent chrome must stay on the terminal authority, not a guessed light window"
        )
    }

    private func makeUserSettings(colorScheme: ColorScheme) -> WindowAppearanceUserSettingsSnapshot {
        WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: true,
            colorScheme: colorScheme,
            sidebarMaterial: SidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: SidebarBlendModeOption.withinWindow.rawValue,
            sidebarState: SidebarStateOption.followWindow.rawValue,
            sidebarTintHex: "#000000",
            sidebarTintHexLight: nil,
            sidebarTintHexDark: nil,
            sidebarTintOpacity: 0.18,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: false,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03
        )
    }

    private func makeSnapshot(
        unifySurfaceBackdrops: Bool,
        backgroundHex: String = "#272822",
        backgroundOpacity: CGFloat = 0.6,
        backgroundBlur: GhosttyBackgroundBlur = .disabled,
        sidebarBlendMode: String = SidebarBlendModeOption.withinWindow.rawValue,
        sidebarTintHexDark: String? = nil,
        sidebarTintOpacity: Double = 0.18,
        sidebarColorScheme: ColorScheme = .dark,
        bgGlassEnabled: Bool = false
    ) -> WindowAppearanceSnapshot {
        let backgroundColor = NSColor(hex: backgroundHex) ?? .black
        return WindowAppearanceSnapshot(
            terminalBackgroundColor: backgroundColor,
            terminalBackgroundOpacity: backgroundOpacity,
            terminalBackgroundBlur: backgroundBlur,
            terminalRenderingMode: .windowHostBackdrop,
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: SidebarMaterialOption.sidebar.rawValue,
                blendModeRawValue: sidebarBlendMode,
                stateRawValue: SidebarStateOption.followWindow.rawValue,
                tintHex: "#000000",
                tintHexLight: nil,
                tintHexDark: sidebarTintHexDark,
                tintOpacity: sidebarTintOpacity,
                cornerRadius: 0,
                blurOpacity: 1,
                colorScheme: sidebarColorScheme
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: sidebarBlendMode,
                isEnabled: bgGlassEnabled,
                tintHex: "#000000",
                tintOpacity: 0.03,
                terminalBackgroundBlur: backgroundBlur,
                terminalGlassTintColor: backgroundColor.withAlphaComponent(backgroundOpacity)
            )
        )
    }

    private func assertTerminalBackdrop(
        _ policy: WindowBackdropPolicy,
        expectedHex: String = "#272822",
        expectedOpacity: CGFloat = 0.6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .ghosttyTerminalBackdrop(color, opacity, renderingMode) = policy else {
            XCTFail("expected terminal backdrop", file: file, line: line)
            return
        }
        XCTAssertEqual(color.hexString(), expectedHex, file: file, line: line)
        XCTAssertEqual(opacity, expectedOpacity, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(renderingMode, .windowHostBackdrop, file: file, line: line)
    }

    private func assertClearBackdrop(
        _ policy: WindowBackdropPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .clear = policy else {
            XCTFail("expected clear backdrop", file: file, line: line)
            return
        }
    }
}
