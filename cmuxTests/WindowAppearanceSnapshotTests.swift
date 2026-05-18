import XCTest
import AppKit
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

    private func makeSnapshot(
        unifySurfaceBackdrops: Bool,
        backgroundOpacity: CGFloat = 0.6,
        backgroundBlur: GhosttyBackgroundBlur = .disabled,
        sidebarBlendMode: String = SidebarBlendModeOption.withinWindow.rawValue,
        sidebarTintHexDark: String? = nil,
        sidebarTintOpacity: Double = 0.18,
        bgGlassEnabled: Bool = false
    ) -> WindowAppearanceSnapshot {
        WindowAppearanceSnapshot(
            terminalBackgroundColor: NSColor(hex: "#272822") ?? .black,
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
                colorScheme: .dark
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: sidebarBlendMode,
                isEnabled: bgGlassEnabled,
                tintHex: "#000000",
                tintOpacity: 0.03,
                terminalBackgroundBlur: backgroundBlur,
                terminalGlassTintColor: (NSColor(hex: "#272822") ?? .black)
                    .withAlphaComponent(backgroundOpacity)
            )
        )
    }

    private func assertTerminalBackdrop(
        _ policy: WindowBackdropPolicy,
        expectedOpacity: CGFloat = 0.6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .ghosttyTerminalBackdrop(color, opacity, renderingMode) = policy else {
            XCTFail("expected terminal backdrop", file: file, line: line)
            return
        }
        XCTAssertEqual(color.hexString(), "#272822", file: file, line: line)
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
