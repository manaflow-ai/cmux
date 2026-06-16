import XCTest
import AppKit
import CmuxFoundation
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

        XCTAssertTrue(snapshot.shouldUseTransparentHosting(glassEffectAvailable: true))
        XCTAssertTrue(snapshot.windowGlassSettings.shouldApply(glassEffectAvailable: true))
        XCTAssertEqual(snapshot.windowGlassSettings.style, .clear)
        XCTAssertEqual(snapshot.windowGlassSettings.tintColor.hexString(includeAlpha: true), "#272822FF")
        assertClearBackdrop(snapshot.policy(for: .windowRoot))
        XCTAssertEqual(snapshot.backdropPlan(glassEffectAvailable: true).hostingPhase, .windowGlass)
    }

    func testTranslucentTerminalWithSidebarTintKeepsRootBackdropOwner() {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: false,
            backgroundOpacity: 0.9,
            sidebarTintHexDark: "#FF0000",
            sidebarTintOpacity: 0.4
        )
        let plan = snapshot.backdropPlan(glassEffectAvailable: false)

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

        let plan = snapshot.backdropPlan(glassEffectAvailable: false)
        XCTAssertEqual(plan.hostingPhase, .transparentRootBackdrop)
        XCTAssertTrue(plan.usesTransparentWindow)
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
            red.backdropPlan(glassEffectAvailable: false).appKitMutationID,
            blue.backdropPlan(glassEffectAvailable: false).appKitMutationID
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

    func testSidebarContentColorSchemeUsesTerminalOnlyForUnifiedBackdrops() {
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: true, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme,
            .dark
        )
        XCTAssertEqual(
            makeSnapshot(unifySurfaceBackdrops: false, backgroundHex: "#101820", sidebarColorScheme: .light)
                .sidebarContentColorScheme,
            .light
        )
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
        let plan = snapshot.backdropPlan(glassEffectAvailable: false)

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
        let plan = snapshot.backdropPlan(glassEffectAvailable: true)

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
