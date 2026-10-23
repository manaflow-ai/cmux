import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct WorkspaceColorMenuTests {
    @Test
    func namedPaletteColorMarksTheMatchingMenuItem() {
        let menu = NSMenu()
        let palette = [
            WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
            WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        ]

        SidebarWorkspaceRowColorMenu(
            currentColorHex: "  #006b6b ",
            colorScheme: .light
        ).addPaletteItems(
            to: menu,
            palette: palette,
            apply: { _ in }
        )

        #expect(menu.items.map(\.state) == [.on, .off])
        #expect(menu.items.map(\.title) == ["Teal", "Blue"])
        #expect(menu.items.allSatisfy { $0.image != nil })
    }

    #if compiler(>=6.4)
    /// macOS 27 hides menu item images by default, which dropped the swatches.
    @Test
    func paletteSwatchesOptIntoVisibleImages() {
        guard #available(macOS 27.0, *) else { return }
        let menu = NSMenu()
        SidebarWorkspaceRowColorMenu(
            currentColorHex: nil,
            colorScheme: .light
        ).addPaletteItems(
            to: menu,
            palette: [WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B")],
            apply: { _ in }
        )

        #expect(menu.items.map(\.preferredImageVisibility) == [.visible])
    }
    #endif

    @Test
    func unmatchedCustomColorLeavesNamedPaletteItemsUnmarked() {
        let menu = NSMenu()
        let palette = [
            WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
            WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        ]

        SidebarWorkspaceRowColorMenu(
            currentColorHex: "#123456",
            colorScheme: .light
        ).addPaletteItems(
            to: menu,
            palette: palette,
            apply: { _ in }
        )

        #expect(menu.items.allSatisfy { $0.state == .off })
    }
}
