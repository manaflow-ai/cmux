import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import CoreImage
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct WindowAppearanceSnapshotPaneBackgroundTests {
    /// Verifies the first OSC 11 can activate a cutout configured before AppKit's first display pass.
    @Test @MainActor func firstOSCOverrideUsesPredisplaySharedBackdropCutout() throws {
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 180)
        let host = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: bounds))
        host.frame = bounds

        let cutoutBeforeDisplay = try #require(sharedBackdropCutout(in: host))
        #expect(cutoutBeforeDisplay.layerUsesCoreImageFilters)
        #expect(cutoutBeforeDisplay.compositingFilter != nil)
        #expect(cutoutBeforeDisplay.isHidden)

        let contentView = NSView(frame: bounds)
        contentView.addSubview(host)
        let window = NSWindow(
            contentRect: bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        host.setBackgroundColor(
            try #require(NSColor(hex: "#4D0000")),
            clearsSharedWindowBackdrop: true
        )

        let activeCutout = try #require(sharedBackdropCutout(in: host))
        #expect(activeCutout === cutoutBeforeDisplay)
        #expect(!activeCutout.isHidden)

        host.setBackgroundColor(.clear, clearsSharedWindowBackdrop: false)
        #expect(cutoutBeforeDisplay.isHidden)
        #expect(cutoutBeforeDisplay.superview === host)
    }

    /// Ghostty reports OSC 111 as the configured RGB, which must restore shared-backdrop ownership.
    @Test func configuredDefaultColorUsesSharedWindowBackdrop() throws {
        let defaultBackground = try #require(NSColor(hex: "#3A3A3E"))
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: .windowHostBackdrop,
            surfaceBackgroundColor: defaultBackground,
            defaultBackgroundColor: defaultBackground,
            backgroundOpacity: 0.60,
            sharesWindowBackdrop: true,
            usesBonsplitPaneBackdrop: false
        )

        #expect(fillPlan.owner == .sharedWindowBackdrop)
        #expect(fillPlan.hostLayerColor.alphaComponent == 0)
        #expect(!fillPlan.clearsSharedWindowBackdrop)
    }

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

    private func sharedBackdropCutout(in host: NSView) -> NSView? {
        host.subviews.first {
            ($0.compositingFilter as? CIFilter)?.name == "terminalSharedBackdropCutout"
        }
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
