import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct FileExplorerStyleContrastTests {
    private let minimumTextContrast: CGFloat = 4.5
    private let minimumIconContrast: CGFloat = 3
    private let statuses: [GitFileStatus] = [.modified, .added, .deleted, .renamed, .untracked]

    @Test func filenameColorsMeetContrastInEveryAppearanceAndRowState() throws {
        try forEachAppearance { appearance, baseBackground in
            for style in FileExplorerStyle.allCases {
                let backgrounds = try rowBackgrounds(
                    for: style,
                    appearance: appearance,
                    baseBackground: baseBackground
                )

                for status in statuses {
                    let foreground = try resolved(style.gitColor(for: status), in: appearance)
                    for (rowState, background) in backgrounds {
                        let ratio = contrastRatio(foreground: foreground, background: background)
                        #expect(
                            ratio >= minimumTextContrast,
                            "\(style.label) \(statusName(status)) text contrast in \(appearance.name.rawValue) \(rowState) row was \(ratio)"
                        )
                    }
                }

                let plainForeground = try resolved(.labelColor, in: appearance)
                for (rowState, background) in backgrounds {
                    let ratio = contrastRatio(foreground: plainForeground, background: background)
                    #expect(
                        ratio >= minimumTextContrast,
                        "\(style.label) plain text contrast in \(appearance.name.rawValue) \(rowState) row was \(ratio)"
                    )
                }
            }
        }
    }

    @Test func declaredIconTintsMeetContrastInEveryAppearance() throws {
        try forEachAppearance { appearance, baseBackground in
            for style in FileExplorerStyle.allCases {
                // Finder applies these colors as contrast-safe masks over AppKit's native icons;
                // screenshot verification covers the rendered result.
                let backgrounds = try rowBackgrounds(
                    for: style,
                    appearance: appearance,
                    baseBackground: baseBackground
                )
                for (kind, tint) in [
                    ("file", style.fileIconTint),
                    ("folder", style.folderIconTint),
                ] {
                    let foreground = try resolved(tint, in: appearance)
                    for (rowState, background) in backgrounds {
                        let ratio = contrastRatio(foreground: foreground, background: background)
                        #expect(
                            ratio >= minimumIconContrast,
                            "\(style.label) \(kind) icon contrast in \(appearance.name.rawValue) \(rowState) row was \(ratio)"
                        )
                    }
                }
            }
        }
    }

    @Test func paletteColorsAdaptWithoutAnotherLookupAndReuseProviders() throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))

        for style in FileExplorerStyle.allCases {
            for status in statuses {
                let color = style.gitColor(for: status)
                #expect(color === style.gitColor(for: status))

                let light = try resolved(color, in: lightAppearance)
                let dark = try resolved(color, in: darkAppearance)
                #expect(
                    !hasSameRGBA(light, dark),
                    "\(style.label) \(statusName(status)) did not adapt to appearance"
                )
            }

            let iconColors: [(String, NSColor, () -> NSColor)] = [
                ("file", style.fileIconTint, { style.fileIconTint }),
                ("folder", style.folderIconTint, { style.folderIconTint }),
            ]
            for (kind, color, repeatedLookup) in iconColors {
                #expect(color === repeatedLookup())
                let light = try resolved(color, in: lightAppearance)
                let dark = try resolved(color, in: darkAppearance)
                #expect(
                    !hasSameRGBA(light, dark),
                    "\(style.label) \(kind) icon tint did not adapt to appearance"
                )
            }
        }
    }

    @Test func plainFilesKeepSemanticLabelColor() throws {
        let cell = FileExplorerCellView(identifier: NSUserInterfaceItemIdentifier("contrast-test"))
        let node = FileExplorerNode(name: "plain.swift", path: "/plain.swift", isDirectory: false)

        cell.configure(with: node)

        let nameLabel = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(nameLabel.textColor?.isEqual(NSColor.labelColor) == true)
    }

    private func forEachAppearance(
        _ body: (NSAppearance, NSColor) throws -> Void
    ) throws {
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        try body(lightAppearance, .white)
        try body(darkAppearance, .black)
    }

    private func rowBackgrounds(
        for style: FileExplorerStyle,
        appearance: NSAppearance,
        baseBackground: NSColor
    ) throws -> [(String, NSColor)] {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focusedSelection = try resolved(
            NSColor.controlAccentColor.withAlphaComponent(0.20),
            in: appearance
        )
        let unfocusedSelection = try resolved(
            NSColor.labelColor.withAlphaComponent(0.08),
            in: appearance
        )

        // FileExplorerRowView draws the focused and unfocused overlays above. Keep the
        // black/white 20% case as the worst luminance bound for any 20% accent tint.
        let worstCaseSelection = composited(
            (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.20),
            over: baseBackground
        )
        let canonicalFocusedSelection = composited(focusedSelection, over: baseBackground)
        let canonicalUnfocusedSelection = composited(unfocusedSelection, over: baseBackground)
        let actual = actualRowBackgrounds(for: style, isDark: isDark)

        // Hover only drives child prefetching; the row renderer draws no hover fill. Hovered
        // rows therefore reuse the same normal or selected background instead of another overlay.
        return [
            ("canonical-plain", baseBackground),
            ("canonical-selected-focused", canonicalFocusedSelection),
            ("canonical-selected-unfocused", canonicalUnfocusedSelection),
            ("canonical-selected-worst-case", worstCaseSelection),
            ("canonical-hovered", baseBackground),
            ("canonical-selected-focused-hovered", canonicalFocusedSelection),
            ("canonical-selected-unfocused-hovered", canonicalUnfocusedSelection),
            ("actual-material-normal", actual.normal),
            ("actual-material-selected-focused", actual.selectedFocused),
            ("actual-material-selected-unfocused", actual.selectedUnfocused),
            ("actual-material-hovered", actual.normal),
            ("actual-material-selected-focused-hovered", actual.selectedFocused),
            ("actual-material-selected-unfocused-hovered", actual.selectedUnfocused),
        ]
    }

    private func actualRowBackgrounds(
        for style: FileExplorerStyle,
        isDark: Bool
    ) -> (normal: NSColor, selectedFocused: NSColor, selectedUnfocused: NSColor) {
        let components: (
            normal: (Int, Int, Int),
            selectedFocused: (Int, Int, Int),
            selectedUnfocused: (Int, Int, Int)
        )
        switch style {
        case .liquidGlass:
            components = isDark
                ? ((0x21, 0x23, 0x24), (0x1A, 0x34, 0x50), (0x32, 0x34, 0x35))
                : ((0xB8, 0xBB, 0xBC), (0x93, 0xAE, 0xC9), (0xAA, 0xAC, 0xAD))
        case .highDensity:
            components = isDark
                ? ((0x21, 0x23, 0x24), (0x1A, 0x34, 0x50), (0x32, 0x34, 0x35))
                : ((0xB8, 0xBB, 0xBC), (0x93, 0xAE, 0xC9), (0xAA, 0xAC, 0xAD))
        case .terminalStealth:
            components = isDark
                ? ((0x21, 0x23, 0x24), (0x1A, 0x34, 0x50), (0x32, 0x34, 0x35))
                : ((0xB8, 0xBB, 0xBC), (0x93, 0xAE, 0xC9), (0xAA, 0xAC, 0xAD))
        case .proStudio:
            components = isDark
                ? ((0x21, 0x23, 0x24), (0x1A, 0x34, 0x50), (0x32, 0x34, 0x35))
                : ((0xB8, 0xBB, 0xBC), (0x93, 0xAE, 0xC9), (0xAA, 0xAC, 0xAD))
        case .finder:
            components = isDark
                ? ((0x21, 0x23, 0x24), (0x1A, 0x34, 0x50), (0x32, 0x34, 0x35))
                : ((0xB8, 0xBB, 0xBC), (0x93, 0xAE, 0xC9), (0xAA, 0xAC, 0xAD))
        }

        return (
            normal: color(components: components.normal),
            selectedFocused: color(components: components.selectedFocused),
            selectedUnfocused: color(components: components.selectedUnfocused)
        )
    }

    private func color(components: (Int, Int, Int)) -> NSColor {
        NSColor(
            srgbRed: CGFloat(components.0) / 255,
            green: CGFloat(components.1) / 255,
            blue: CGFloat(components.2) / 255,
            alpha: 1
        )
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB)
        }
        return try #require(resolvedColor)
    }

    private func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
        let opaqueForeground = composited(foreground, over: background)
        let foregroundLuminance = relativeLuminance(opaqueForeground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    private func composited(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let foreground = foreground.usingColorSpace(.sRGB) ?? foreground
        let background = background.usingColorSpace(.sRGB) ?? background
        let alpha = foreground.alphaComponent
        return NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func hasSameRGBA(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhs = lhs.usingColorSpace(.sRGB) ?? lhs
        let rhs = rhs.usingColorSpace(.sRGB) ?? rhs
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }

    private func statusName(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        }
    }
}
