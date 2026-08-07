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

    @Test func sidebarContentColorSchemeUsesTerminalOnlyForUnifiedBackdrops() {
        #expect(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme == .dark
        )
        #expect(
            makeSnapshot(unifySurfaceBackdrops: false, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme == .light
        )
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
