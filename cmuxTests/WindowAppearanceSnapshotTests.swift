import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WindowAppearanceSnapshotTests {
    @Test func unifiedSurfaceBackdropsUseSingleWindowRootBackdrop() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: true)

        assertTerminalBackdrop(snapshot.policy(for: .windowRoot))
        assertClearBackdrop(snapshot.policy(for: .terminalCanvas))
        assertClearBackdrop(snapshot.policy(for: .bonsplitChrome))
        assertClearBackdrop(snapshot.policy(for: .titlebar))
        assertClearBackdrop(snapshot.policy(for: .browserSurface))
        assertClearBackdrop(snapshot.policy(for: .leftSidebar))
        assertClearBackdrop(snapshot.policy(for: .rightSidebar))
    }

    @Test func separateSurfaceBackdropsKeepRootBackdropAndSidebarMaterialsSeparate() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: false)

        assertTerminalBackdrop(snapshot.policy(for: .windowRoot))
        assertClearBackdrop(snapshot.policy(for: .terminalCanvas))
        assertClearBackdrop(snapshot.policy(for: .bonsplitChrome))
        assertClearBackdrop(snapshot.policy(for: .titlebar))
        assertClearBackdrop(snapshot.policy(for: .browserSurface))

        guard case let .sidebarMaterial(leftPolicy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("left sidebar should keep its own material policy")
            return
        }
        #expect(leftPolicy.material == .sidebar)
        #expect(leftPolicy.blendingMode == .withinWindow)

        guard case let .sidebarMaterial(rightPolicy) = snapshot.policy(for: .rightSidebar) else {
            Issue.record("right sidebar should keep its own material policy")
            return
        }
        #expect(rightPolicy.material == .sidebar)
        #expect(rightPolicy.blendingMode == .withinWindow)
    }

    @Test func macOSGlassClearForcesTransparentHostingAndClearGlassStyle() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundOpacity: 1.0,
            backgroundBlur: .macosGlassClear
        )

        #expect(snapshot.shouldUseTransparentHosting(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ))
        #expect(snapshot.windowGlassSettings.shouldApply(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ))
        #expect(snapshot.windowGlassSettings.style == .clear)
        #expect(snapshot.windowGlassSettings.tintColor.hexString(includeAlpha: true) == "#272822FF")
        assertClearBackdrop(snapshot.policy(for: .windowRoot))
        #expect(snapshot.backdropPlan(
            glassEffectAvailable: true,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        ).hostingPhase == .windowGlass)
    }

    @Test func translucentTerminalWithSidebarTintKeepsRootBackdropOwner() {
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

        #expect(plan.hostingPhase == .transparentRootBackdrop)
        #expect(plan.usesTransparentWindow)
        #expect(!plan.usesWindowGlass)
        assertTerminalBackdrop(plan.rootPolicy, expectedOpacity: 0.9)

        guard case let .sidebarMaterial(sidebarPolicy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("left sidebar should keep its own tint material")
            return
        }
        #expect(sidebarPolicy.tintColor.hexString(includeAlpha: true) == "#FF000066")
    }

    @Test func translucentTerminalUsesTransparentHostingWithOpaqueCompositedChromeColor() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundOpacity: 0.5
        )

        #expect(abs(snapshot.compositedTerminalBackgroundColor.alphaComponent - 1) < 0.0001)

        let plan = snapshot.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )
        #expect(plan.hostingPhase == .transparentRootBackdrop)
        #expect(plan.usesTransparentWindow)
    }

    /// A mounted Dock must leave the shared window backdrop visible.
    @Test func dockChromeLeavesSharedWindowBackdropUnpainted() {
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

        #expect(appearance.usesSharedBackdrop)
        #expect(
            appearance.chromeColors.backgroundHex == "#00000000",
            "Dock chrome must leave the shared window backdrop visible behind terminal surfaces"
        )
        #expect(appearance.chromeColors.paneBackgroundHex == "#00000000")
    }

    /// The controller's pre-mount appearance retains a concrete fallback.
    @Test func dockChromeKeepsConcreteFallbackBeforeWindowBackdropMounts() {
        let config = GhosttyConfig()
        let appearance = DockSplitStore.makeAppearance(from: config)

        #expect(
            appearance.chromeColors.backgroundHex != "#00000000",
            "The pre-mount Dock configuration needs a concrete fallback"
        )
    }

    /// Renderer-owned surfaces keep their concrete Dock chrome color.
    @Test func dockChromeKeepsConcreteColorWhenGhosttyOwnsTheSurface() {
        let color = NSColor(hex: "#112233")!
        let colors = Workspace.bonsplitChromeColors(
            backgroundColor: color,
            backgroundOpacity: 0.8,
            sharesWindowBackdrop: true,
            renderingMode: .ghosttyRendererOwnedBackgroundImage,
            chromeHost: .dock
        )

        #expect(colors.backgroundHex == "#112233CC")
    }

    @Test func sidebarTintChangesDoNotDriveWindowBackdropPlanIdentity() {
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

        #expect(
            red.backdropPlan(
                glassEffectAvailable: false,
                windowBackgroundPolicy: WindowBackgroundComposition.policy
            ).appKitMutationID ==
            blue.backdropPlan(
                glassEffectAvailable: false,
                windowBackgroundPolicy: WindowBackgroundComposition.policy
            ).appKitMutationID
        )
    }

    @Test func chromeColorSchemeFollowsTerminalBackground() {
        #expect(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#F8F8F2").chromeColorScheme ==
                .light
        )
        #expect(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820").chromeColorScheme ==
                .dark
        )
    }

    @Test func chromeColorSchemeAccountsForTranslucentTerminalBackground() {
        let composited = WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: NSColor(hex: "#101820")!,
            opacity: 0.05,
            over: .white
        )

        #expect(cmuxReadableColorScheme(for: composited) == .light)
    }

    @Test func sidebarContentColorSchemeUsesResolvedTerminalThemeForAllBackdrops() {
        #expect(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme == .dark
        )
        #expect(
            makeSnapshot(unifySurfaceBackdrops: false, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme == .dark
        )
    }

    @Test func sidebarTintSelectionUsesResolvedTerminalThemeWhenSystemDisagrees() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundHex: "#F8F8F2",
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4,
            sidebarColorScheme: .dark
        )

        guard case let .sidebarMaterial(policy) = snapshot.policy(for: .rightSidebar) else {
            Issue.record("right sidebar should keep its own material policy")
            return
        }
        #expect(policy.tintColor.hexString(includeAlpha: true) == "#00000066")
    }

    @Test func dockAndSidebarChromeShareResolvedTerminalThemeWhenSystemDisagrees() {
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

                #expect(
                    snapshot.chromeColorScheme == testCase.expected,
                    "Unexpected terminal theme resolution for \(testCase.backgroundHex)"
                )
                #expect(
                    snapshot.sidebarContentColorScheme == testCase.expected,
                    "Dock/sidebar chrome diverged for terminal \(testCase.expected) and system \(systemResolvedSidebarScheme)"
                )
            }
        }
    }

    @Test func matchedLeftAndRightSidebarBackdropsShareTerminalRootBackdrop() {
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
            #expect(snapshot.sidebarContentColorScheme == snapshot.chromeColorScheme)
        }
    }

    @Test func unifiedSidebarBackdropsDoNotTintTransparentTerminalBackground() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundHex: "#000000",
            backgroundOpacity: 0.05
        )

        #expect(abs(snapshot.compositedTerminalBackgroundColor.alphaComponent - 1) < 0.0001)
        assertClearBackdrop(snapshot.policy(for: .leftSidebar))
        assertClearBackdrop(snapshot.policy(for: .rightSidebar))
    }

    @Test func separateSidebarBackdropsKeepCustomTintBehavior() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundHex: "#000000",
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4
        )

        guard case let .sidebarMaterial(sidebarPolicy) = snapshot.policy(for: .leftSidebar) else {
            Issue.record("left sidebar should keep its own tint material")
            return
        }
        #expect(sidebarPolicy.tintColor.hexString(includeAlpha: true) == "#FF000066")
    }

    @Test func opaqueTerminalUsesLayerBackedOpaqueRoot() {
        let snapshot = makeSnapshot(unifySurfaceBackdrops: false, backgroundOpacity: 1.0)
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: false,
            windowBackgroundPolicy: WindowBackgroundComposition.policy
        )

        #expect(plan.hostingPhase == .opaqueRootBackdrop)
        #expect(!plan.usesTransparentWindow)
        #expect(plan.windowBackgroundColor.hexString(includeAlpha: true) == "#00000000")
        assertTerminalBackdrop(plan.rootPolicy, expectedOpacity: 1)
    }

    @Test func debugBackgroundGlassUsesWindowGlassPhase() {
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

        #expect(plan.hostingPhase == .windowGlass)
        #expect(plan.usesTransparentWindow)
        #expect(plan.usesWindowGlass)
    }

    /// Verifies pane-local OSC colors paint on the host layer over a shared root backdrop.
    @Test func oscOverrideUsesSurfaceHostFillWhenWindowRootBackdropIsShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 1.0,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(plan.owner == .surfaceHostLayer)
        #expect(plan.hostLayerColor.hexString(includeAlpha: true) == "#D2EEF9FF")
        #expect(!plan.excludesSharedRootBackdrop)
    }

    /// Verifies translucent OSC colors use one host-layer fill with configured opacity.
    @Test func translucentOSCOverrideUsesOneSurfaceHostFillWithConfiguredOpacity() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#E2D2F0") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(plan.owner == .surfaceHostLayer)
        #expect(plan.hostLayerColor.hexString() == "#E2D2F0")
        #expect(abs(plan.hostLayerColor.alphaComponent - 0.42) < 0.0001)
        #expect(plan.excludesSharedRootBackdrop)
    }

    /// Verifies default backgrounds remain owned by the shared root backdrop.
    @Test func defaultBackgroundUsesSharedWindowBackdrop() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: nil,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(plan.owner == .sharedWindowBackdrop)
        #expect(plan.hostLayerColor.hexString(includeAlpha: true) == "#00000000")
        #expect(!plan.excludesSharedRootBackdrop)
    }

    /// Verifies Bonsplit-owned pane backdrops stay authoritative for OSC overrides.
    @Test func oscOverrideKeepsBonsplitPaneBackdropOwner() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.42,
            sharesWindowBackdrop: false,
            usesBonsplitPaneBackdrop: true
        )

        #expect(plan.owner == .bonsplitPaneBackdrop)
        #expect(plan.hostLayerColor.hexString(includeAlpha: true) == "#00000000")
        #expect(!plan.excludesSharedRootBackdrop)
    }

    /// Verifies non-shared window backdrops let OSC colors paint directly on the host layer.
    @Test func oscOverrideUsesSurfaceHostFillWhenWindowBackdropIsNotShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: NSColor(hex: "#B5EAD7") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 0.73,
            sharesWindowBackdrop: false,
            usesBonsplitPaneBackdrop: false
        )

        #expect(plan.owner == .surfaceHostLayer)
        #expect(plan.hostLayerColor.hexString() == "#B5EAD7")
        #expect(abs(plan.hostLayerColor.alphaComponent - 0.73) < 0.0001)
        #expect(!plan.excludesSharedRootBackdrop)
    }

    /// Verifies renderer-owned backgrounds keep cmux host layers clear.
    @Test func rendererOwnedOSCOverrideKeepsHostLayerClearWhenWindowRootBackdropIsShared() {
        let plan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .ghosttyRendererOwnedBackgroundImage,
            surfaceBackgroundColor: NSColor(hex: "#D2EEF9") ?? .white,
            defaultBackgroundColor: NSColor(hex: "#272822") ?? .black,
            backgroundOpacity: 1.0,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(plan.owner == .ghosttyNativeRenderer)
        #expect(plan.hostLayerColor.hexString(includeAlpha: true) == "#00000000")
        #expect(!plan.excludesSharedRootBackdrop)
    }

    /// A translucent terminal theme does not own the rendered pixels: the
    /// backdrop behind the surface tab strip and browser toolbar is the theme
    /// color composited over the ambient window base. The resolved chrome
    /// scheme must follow that rendered result, or icons keyed off it become
    /// white-on-white in a light window (issue #10477).
    @Test func translucentTerminalChromeSchemeFollowsRenderedBackdrop() {
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
        #expect(
            lightWindow.resolvedColorScheme == .light,
            "Translucent dark theme over a light window renders a light backdrop; chrome icons must resolve dark"
        )
        #expect(
            cmuxReadableColorScheme(for: lightWindow.resolvedChromeBackgroundColor) == .light,
            "Chrome background must composite over the light window base the user actually sees"
        )

        let darkWindow = resolver.current(settings: makeUserSettings(colorScheme: .dark))
        #expect(
            darkWindow.resolvedColorScheme == .dark,
            "Translucent dark theme over a dark window keeps dark chrome"
        )
    }

    /// Opaque themes own their rendered pixels, so the terminal theme stays
    /// the light/dark authority even when the window appearance disagrees
    /// (issue #10146 contract).
    @Test func opaqueTerminalChromeSchemeKeepsTerminalThemeAuthority() {
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
                #expect(
                    snapshot.resolvedColorScheme == terminalScheme,
                    "Opaque \(backgroundHex) theme must keep terminal authority under \(ambientScheme) ambient"
                )
            }
        }
    }

    /// Bonsplit derives fixed black/white tab-strip glyph colors from the hex
    /// the workspace hands it, so that hex must match the rendered backdrop:
    /// composited over the ambient base for translucent themes, the theme
    /// color itself for opaque ones (issue #10477).
    @Test func bonsplitChromeBackgroundColorMatchesRenderedBackdrop() {
        let translucentDarkOverLight = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 0.3,
            terminalColorScheme: .dark,
            ambientColorScheme: .light
        )
        #expect(
            cmuxReadableColorScheme(for: translucentDarkOverLight) == .light,
            "Translucent dark theme in a light window must hand Bonsplit a light hex so tab glyphs resolve dark"
        )

        let translucentDarkOverDark = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 0.3,
            terminalColorScheme: .dark,
            ambientColorScheme: .dark
        )
        #expect(cmuxReadableColorScheme(for: translucentDarkOverDark) == .dark)

        let opaqueDarkOverLight = Workspace.resolvedTerminalChromeBackgroundColor(
            backgroundColor: NSColor(hex: "#101820") ?? .black,
            backgroundOpacity: 1.0,
            terminalColorScheme: .dark,
            ambientColorScheme: .light
        )
        #expect(cmuxReadableColorScheme(for: opaqueDarkOverLight) == .dark)
    }

    /// Callers that omit the ambient scheme (`currentFromUserDefaults`) must
    /// not have translucent chrome resolved against a guessed light window:
    /// the resolver fails closed to the terminal authority instead.
    @Test func omittedAmbientSchemeFailsClosedToTerminalAuthority() {
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

        #expect(
            snapshot.resolvedColorScheme == .dark,
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
        expectedOpacity: CGFloat = 0.6
    ) {
        guard case let .ghosttyTerminalBackdrop(color, opacity, renderingMode) = policy else {
            Issue.record("expected terminal backdrop")
            return
        }
        #expect(color.hexString() == expectedHex)
        #expect(abs(opacity - expectedOpacity) < 0.0001)
        #expect(renderingMode == .windowHostBackdrop)
    }

    private func assertClearBackdrop(_ policy: WindowBackdropPolicy) {
        guard case .clear = policy else {
            Issue.record("expected clear backdrop")
            return
        }
    }
}
