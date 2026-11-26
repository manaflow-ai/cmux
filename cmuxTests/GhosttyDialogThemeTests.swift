import AppKit
import CmuxFoundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct GhosttyDialogThemeTests {
    private func hex(_ color: NSColor) -> String { color.hexString() }

    @Test("A dark Ghostty theme gives a dark dialog even when macOS is light")
    func darkThemeDrivesDialogColors() throws {
        let background = try #require(NSColor(hex: "#1D1F21"))
        let foreground = try #require(NSColor(hex: "#C5C8C6"))
        let theme = GhosttyDialogTheme.resolved(background: background, foreground: foreground)

        #expect(hex(theme.background) == "#1D1F21")
        #expect(hex(theme.foreground) == "#C5C8C6")
        #expect(theme.colorScheme == .dark)
    }

    @Test("A light Ghostty theme gives a light dialog")
    func lightThemeDrivesDialogColors() throws {
        let background = try #require(NSColor(hex: "#FDF6E3"))
        let foreground = try #require(NSColor(hex: "#657B83"))
        let theme = GhosttyDialogTheme.resolved(background: background, foreground: foreground)

        #expect(hex(theme.background) == "#FDF6E3")
        #expect(theme.colorScheme == .light)
    }

    @Test("A translucent terminal background still gives an opaque dialog")
    func translucentBackgroundIsOpaque() throws {
        let background = try #require(NSColor(hex: "#1D1F21")).withAlphaComponent(0.4)
        let theme = GhosttyDialogTheme.resolved(background: background, foreground: .white)

        #expect(theme.background.alphaComponent == 1)
        #expect(hex(theme.background) == "#1D1F21")
    }

    @Test("An unreadable foreground is replaced by a readable one")
    func unreadableForegroundIsAdjusted() throws {
        let background = try #require(NSColor(hex: "#101010"))
        let foreground = try #require(NSColor(hex: "#151515"))
        let theme = GhosttyDialogTheme.resolved(background: background, foreground: foreground)

        #expect(hex(theme.foreground) != "#151515")
        #expect(cmuxContrastRatio(foreground: theme.foreground, background: theme.background) >= 4.5)
    }
}
