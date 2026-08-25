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

        SidebarWorkspaceRowColorMenu.addPaletteItems(
            to: menu,
            palette: palette,
            currentColorHex: "  #006b6b ",
            colorScheme: .light,
            apply: { _ in }
        )

        #expect(menu.items.map(\.state) == [.on, .off])
        #expect(menu.items.map(\.title) == ["Teal", "Blue"])
        #expect(menu.items.allSatisfy { $0.image != nil })
    }

    @Test
    func unmatchedCustomColorLeavesNamedPaletteItemsUnmarked() {
        let menu = NSMenu()
        let palette = [
            WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
            WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
        ]

        SidebarWorkspaceRowColorMenu.addPaletteItems(
            to: menu,
            palette: palette,
            currentColorHex: "#123456",
            colorScheme: .light,
            apply: { _ in }
        )

        #expect(menu.items.allSatisfy { $0.state == .off })
    }
}
