import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import XCTest

final class WindowAppearanceRendererOwnershipTests: XCTestCase {
    func testRendererOwnedTerminalLeavesSharedWindowRootClear() {
        let snapshot = makeSnapshot(usesHostLayerBackground: false)

        guard case .clear = snapshot.policy(for: .windowRoot) else {
            XCTFail("renderer-owned terminal pixels should leave the shared root clear")
            return
        }
    }

    func testHostOwnedTerminalRetainsSharedWindowRootBackdrop() {
        let snapshot = makeSnapshot(usesHostLayerBackground: true)

        guard case let .ghosttyTerminalBackdrop(_, opacity, renderingMode) = snapshot.policy(for: .windowRoot) else {
            XCTFail("host-owned terminal pixels should retain the shared root backdrop")
            return
        }
        XCTAssertEqual(opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(renderingMode, .windowHostBackdrop)
    }

    private func makeSnapshot(usesHostLayerBackground: Bool) -> WindowAppearanceSnapshot {
        let resolver = WindowAppearanceResolver(
            terminalAppearance: WindowTerminalAppearanceSnapshot(
                backgroundColor: NSColor(hex: "#272822") ?? .black,
                backgroundOpacity: 0.5,
                backgroundBlur: .disabled,
                usesHostLayerBackground: usesHostLayerBackground
            )
        )
        return resolver.current(settings: WindowAppearanceUserSettingsSnapshot(
            unifySurfaceBackdrops: true,
            colorScheme: .dark,
            sidebarMaterial: WindowChromeSidebarMaterialOption.sidebar.rawValue,
            sidebarBlendMode: WindowChromeSidebarBlendModeOption.withinWindow.rawValue,
            sidebarState: WindowChromeSidebarStateOption.followWindow.rawValue,
            sidebarTintHex: WindowChromeSidebarTintDefaults().hex,
            sidebarTintHexLight: nil,
            sidebarTintHexDark: nil,
            sidebarTintOpacity: WindowChromeSidebarTintDefaults().opacity,
            sidebarCornerRadius: 0,
            sidebarBlurOpacity: 1,
            bgGlassEnabled: false,
            bgGlassTintHex: "#000000",
            bgGlassTintOpacity: 0.03
        ))
    }
}
