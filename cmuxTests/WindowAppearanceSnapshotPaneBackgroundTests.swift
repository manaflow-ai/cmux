import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct WindowAppearanceSnapshotPaneBackgroundTests {
    /// Verifies pane-local OSC colors paint the surface without replacing the shared window root.
    @Test func surfaceOSCOverrideUsesHostFillAndKeepsSharedWindowRootDefault() throws {
        let snapshot = makeSnapshot(
            unifySurfaceBackdrops: true,
            backgroundHex: "#272822",
            backgroundOpacity: 1.0
        )
        let override = try #require(NSColor(hex: "#E6BE78"))
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: snapshot.terminalRenderingMode,
            surfaceBackgroundColor: override,
            defaultBackgroundColor: snapshot.terminalBackgroundColor,
            backgroundOpacity: Double(snapshot.terminalBackgroundOpacity),
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )
        let windowRoot = snapshot.windowRootBackdropResolution(
            surfaceBackgroundColor: override
        )

        #expect(fillPlan.owner == .surfaceHostLayer)
        #expect(fillPlan.hostLayerColor.hexString(includeAlpha: true) == "#E6BE78FF")
        #expect(fillPlan.clearsSharedWindowBackdrop)
        #expect(windowRoot.source == "defaultBackground(surfaceOverrideLocal)")
        #expect(windowRoot.overrideHex == "#E6BE78")
        #expect(windowRoot.snapshot.terminalBackgroundColor.hexString() == "#272822")
        #expect(
            windowRoot.snapshot.compositedTerminalBackgroundColor.hexString(includeAlpha: true) == "#272822FF"
        )
        #expect(
            windowRoot.snapshot.windowGlassSettings.terminalGlassTintColor?.hexString(includeAlpha: true) == "#272822FF"
        )
    }

    private func makeSnapshot(
        unifySurfaceBackdrops: Bool,
        backgroundHex: String,
        backgroundOpacity: CGFloat
    ) -> WindowAppearanceSnapshot {
        let backgroundColor = NSColor(hex: backgroundHex) ?? .black
        return WindowAppearanceSnapshot(
            terminalBackgroundColor: backgroundColor,
            terminalBackgroundOpacity: backgroundOpacity,
            terminalBackgroundBlur: .disabled,
            terminalRenderingMode: .windowHostBackdrop,
            unifySurfaceBackdrops: unifySurfaceBackdrops,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: SidebarMaterialOption.sidebar.rawValue,
                blendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                stateRawValue: SidebarStateOption.followWindow.rawValue,
                tintHex: "#000000",
                tintHexLight: nil,
                tintHexDark: nil,
                tintOpacity: 0.18,
                cornerRadius: 0,
                blurOpacity: 1,
                colorScheme: .dark
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: SidebarBlendModeOption.withinWindow.rawValue,
                isEnabled: false,
                tintHex: "#000000",
                tintOpacity: 0.03,
                terminalBackgroundBlur: .disabled,
                terminalGlassTintColor: backgroundColor.withAlphaComponent(backgroundOpacity)
            )
        )
    }
}
