import AppKit
import CmuxAppKitSupportUI
import SwiftUI

extension WindowAppearanceSnapshot {
    static var rightSidebarPanelViewTestDefault: WindowAppearanceSnapshot {
        let tintDefaults = WindowChromeSidebarTintDefaults()
        return WindowAppearanceSnapshot(
            terminalBackgroundColor: .windowBackgroundColor,
            terminalBackgroundOpacity: 1.0,
            terminalBackgroundBlur: .disabled,
            terminalRenderingMode: .windowHostBackdrop,
            unifySurfaceBackdrops: true,
            sidebarSettings: SidebarBackdropSettingsSnapshot(
                materialRawValue: WindowChromeSidebarMaterialOption.sidebar.rawValue,
                blendModeRawValue: WindowChromeSidebarBlendModeOption.withinWindow.rawValue,
                stateRawValue: WindowChromeSidebarStateOption.followWindow.rawValue,
                tintHex: tintDefaults.hex,
                tintHexLight: nil,
                tintHexDark: nil,
                tintOpacity: tintDefaults.opacity,
                cornerRadius: 0,
                blurOpacity: 1,
                colorScheme: .light
            ),
            windowGlassSettings: WindowGlassSettingsSnapshot(
                sidebarBlendModeRawValue: WindowChromeSidebarBlendModeOption.withinWindow.rawValue,
                isEnabled: false,
                tintHex: "#000000",
                tintOpacity: 0,
                terminalBackgroundBlur: .disabled,
                terminalGlassTintColor: .windowBackgroundColor
            )
        )
    }
}
