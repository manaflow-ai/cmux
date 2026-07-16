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
        try forEachAppearance { appearance, background in
            for style in FileExplorerStyle.allCases {
                // Finder applies these colors as contrast-safe masks over AppKit's native icons;
                // screenshot verification covers the rendered result.
                for (kind, tint) in [
                    ("file", style.fileIconTint),
                    ("folder", style.folderIconTint),
                ] {
                    let foreground = try resolved(tint, in: appearance)
                    let ratio = contrastRatio(foreground: foreground, background: background)
                    #expect(
                        ratio >= minimumIconContrast,
                        "\(style.label) \(kind) icon contrast in \(appearance.name.rawValue) was \(ratio)"
                    )
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

            for (kind, color, repeatedColor) in [
                ("file", style.fileIconTint, style.fileIconTint),
                ("folder", style.folderIconTint, style.folderIconTint),
            ] {
                #expect(color === repeatedColor)
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
        let hoverOverlay = try resolved(style.hoverColor, in: appearance)
        return [
            ("plain", baseBackground),
            ("selected-focused", composited(focusedSelection, over: baseBackground)),
            ("selected-unfocused", composited(unfocusedSelection, over: baseBackground)),
            ("selected-worst-case", worstCaseSelection),
            ("hovered", composited(hoverOverlay, over: baseBackground)),
        ]
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
