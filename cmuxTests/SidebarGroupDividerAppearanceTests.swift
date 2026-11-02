import AppKit
import CmuxFoundation
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The band and guide color resolvers are pure functions shared by both
/// renderers: given a group color, a scheme, the contrast/brighten settings and
/// an optional concrete backdrop they must return the documented wash opacities
/// and, over a concrete backdrop, a separable result that is never opaque.
@Suite struct SidebarGroupDividerAppearanceTests {
    // Design mockup colors (see the Colors section of the spec).
    static let paletteBlue = "#1565C0"
    static let paletteGreen = "#196F3D"
    static let terminalBackdropDark = "#30354B"
    // Approximate light sidebar surface, matching the surface the existing
    // selection resolver uses for light appearance.
    static let sidebarSurfaceLight = NSColor(white: 0.93, alpha: 1)
    static let sidebarSurfaceDark = NSColor(hex: terminalBackdropDark)!

    static let secondaryTextFloor: CGFloat = 3.5

    private func approx(_ lhs: Double, _ rhs: Double, _ eps: Double = 1e-6) -> Bool {
        abs(lhs - rhs) <= eps
    }

    private func sameColor(_ lhs: NSColor, _ rhs: NSColor, _ eps: CGFloat = 0.004) -> Bool {
        guard let l = lhs.usingColorSpace(.sRGB), let r = rhs.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(l.redComponent - r.redComponent) <= eps
            && abs(l.greenComponent - r.greenComponent) <= eps
            && abs(l.blueComponent - r.blueComponent) <= eps
            && abs(l.alphaComponent - r.alphaComponent) <= eps
    }

    private func isGrayscale(_ color: NSColor, _ eps: CGFloat = 0.01) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return abs(c.redComponent - c.greenComponent) <= eps
            && abs(c.greenComponent - c.blueComponent) <= eps
    }

    private func srgbLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : CGFloat(pow(Double((v + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(c.redComponent)
            + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
    }

    // MARK: - Table opacities (no concrete backdrop, no check)

    @Test func coloredBandNilBackdropUsesTableOpacities() {
        #expect(approx(
            sidebarGroupBandStyle(
                groupColorHex: Self.paletteBlue,
                colorScheme: .dark,
                increaseContrast: false,
                brightenInDarkMode: true,
                over: nil
            ).opacity,
            0.24
        ))
        #expect(approx(
            sidebarGroupBandStyle(
                groupColorHex: Self.paletteBlue,
                colorScheme: .light,
                increaseContrast: false,
                brightenInDarkMode: true,
                over: nil
            ).opacity,
            0.16
        ))
    }

    @Test func neutralBandNilBackdropUsesTableOpacities() {
        let dark = sidebarGroupBandStyle(
            groupColorHex: nil,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        )
        #expect(approx(dark.opacity, 0.09))
        #expect(isGrayscale(dark.color!))

        let light = sidebarGroupBandStyle(
            groupColorHex: nil,
            colorScheme: .light,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        )
        #expect(approx(light.opacity, 0.07))
        #expect(isGrayscale(light.color!))
    }

    @Test func coloredGuideNilBackdropUsesTableOpacities() {
        #expect(approx(Double(sidebarGroupGuideColor(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        ).alphaComponent), 0.60, 1e-4))
        #expect(approx(Double(sidebarGroupGuideColor(
            groupColorHex: Self.paletteBlue,
            colorScheme: .light,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        ).alphaComponent), 0.55, 1e-4))
    }

    @Test func neutralGuideNilBackdropUsesTableOpacities() {
        #expect(approx(Double(sidebarGroupGuideColor(
            groupColorHex: nil,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        ).alphaComponent), 0.18, 1e-4))
        #expect(approx(Double(sidebarGroupGuideColor(
            groupColorHex: nil,
            colorScheme: .light,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        ).alphaComponent), 0.20, 1e-4))
    }

    // MARK: - Increase Contrast adds 0.10

    @Test func increaseContrastAddsTenPoints() {
        for scheme in [ColorScheme.dark, .light] {
            for hex in [Self.paletteBlue, nil] {
                let base = sidebarGroupBandStyle(
                    groupColorHex: hex,
                    colorScheme: scheme,
                    increaseContrast: false,
                    brightenInDarkMode: true,
                    over: nil
                ).opacity
                let bumped = sidebarGroupBandStyle(
                    groupColorHex: hex,
                    colorScheme: scheme,
                    increaseContrast: true,
                    brightenInDarkMode: true,
                    over: nil
                ).opacity
                #expect(approx(bumped - base, 0.10))
            }
        }
    }

    // MARK: - brightenInDarkMode mirrors displayNSColor

    @Test func brightenInDarkModeMatchesDisplayColor() {
        let on = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: nil
        ).color!
        let off = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: false,
            over: nil
        ).color!

        let expectedOn = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteBlue,
            colorScheme: .dark,
            brightenInDarkMode: true
        )!
        let expectedOff = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteBlue,
            colorScheme: .dark,
            brightenInDarkMode: false
        )!

        #expect(sameColor(on, expectedOn))
        #expect(sameColor(off, expectedOff))
        #expect(!sameColor(on, off))
    }

    // MARK: - Concrete backdrop: separation check, fallback, cap

    @Test func saturatedBackdropNearGroupColorFallsBackToNeutral() {
        // Backdrop equal to the resolved group color: the wash cannot separate
        // from it at any opacity, so the band drops to a neutral tint.
        let colored = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteBlue,
            colorScheme: .dark,
            brightenInDarkMode: true
        )!
        let backdropHex = colored.hexString()

        let style = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: backdropHex
        )
        #expect(isGrayscale(style.color!))
        #expect(!sameColor(style.color!, colored))

        // The fallback actually separates from the backdrop.
        let backdrop = NSColor(hex: backdropHex)!
        let composite = cmuxCompositedNSColor(
            style.color!.withAlphaComponent(CGFloat(style.opacity)),
            over: backdrop
        )
        #expect(abs(srgbLuminance(composite) - srgbLuminance(backdrop)) > 0.02)
    }

    @Test func neutralEqualsBackdropShiftsLuminanceInsteadOfGoingInvisible() {
        // A sidebar tint can make the backdrop equal the neutral label color.
        let labelColor = SidebarAppearanceColorResolver()
            .resolvedColor(.labelColor, for: .dark)
            .withAlphaComponent(1)
        let backdropHex = labelColor.hexString()

        let style = sidebarGroupBandStyle(
            groupColorHex: nil,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: backdropHex
        )
        let backdrop = NSColor(hex: backdropHex)!
        let composite = cmuxCompositedNSColor(
            style.color!.withAlphaComponent(CGFloat(style.opacity)),
            over: backdrop
        )
        // Not left invisible: the wash composites to a different luminance.
        #expect(abs(srgbLuminance(composite) - srgbLuminance(backdrop)) > 0.02)
        // Never opaque.
        #expect(style.opacity < 1)
    }

    @Test func opacityNeverExceedsTableValuePlusBump() {
        // Over any backdrop, including Increase Contrast and the fallback, the
        // band opacity stays within the table value + 0.10 hard cap.
        let coloredCapDark = 0.24 + 0.10
        let neutralCapDark = 0.09 + 0.10

        let nearColor = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteBlue,
            colorScheme: .dark,
            brightenInDarkMode: true
        )!
        // Colored request that falls back lands on a neutral opacity <= neutral cap.
        let fallback = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: true,
            brightenInDarkMode: true,
            over: nearColor.hexString()
        )
        #expect(fallback.opacity <= neutralCapDark + 1e-6)

        // Colored request that stays colored over a separable backdrop is capped.
        let colored = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: true,
            brightenInDarkMode: true,
            over: Self.terminalBackdropDark
        )
        #expect(colored.opacity <= coloredCapDark + 1e-6)
    }

    @Test func declaredSchemeOverMismatchedBackdropUsesDeclaredScheme() {
        // A declared dark scheme over a light backdrop still resolves the group
        // color through the dark (brightened) display color, not a scheme
        // derived from the backdrop's luminance.
        let style = sidebarGroupBandStyle(
            groupColorHex: Self.paletteBlue,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: "#DDDDDD"
        )
        let darkDisplay = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteBlue,
            colorScheme: .dark,
            brightenInDarkMode: true
        )!
        #expect(sameColor(style.color!, darkDisplay))
    }

    @Test func guideSharesBandResolution() {
        // The guide is the same resolution at the guide opacity table, so both
        // renderers paint identical colors; over a near-equal backdrop it falls
        // back to a separable neutral just like the band.
        let colored = WorkspaceTabColorSettings.displayNSColor(
            hex: Self.paletteGreen,
            colorScheme: .dark,
            brightenInDarkMode: true
        )!
        let guide = sidebarGroupGuideColor(
            groupColorHex: Self.paletteGreen,
            colorScheme: .dark,
            increaseContrast: false,
            brightenInDarkMode: true,
            over: colored.hexString()
        )
        #expect(isGrayscale(guide))
        #expect(guide.alphaComponent < 1)
    }

    // MARK: - Text over the band stays legible

    @Test func headerNameStaysReadableOverBand() {
        let resolver = SidebarAppearanceColorResolver()
        for scheme in [ColorScheme.dark, .light] {
            let surface = scheme == .dark ? Self.sidebarSurfaceDark : Self.sidebarSurfaceLight
            // The header name keeps its own paint: labelColor at 0.9.
            let nameForeground = resolver
                .resolvedColor(.labelColor, for: scheme)
                .withAlphaComponent(0.9)

            for increaseContrast in [false, true] {
                // Every palette color covers the most saturated one, plus the
                // neutral band (nil group color).
                let hexes = WorkspaceTabColorSettings.defaultPalette.map { $0.hex } + [nil]
                for hex in hexes {
                    let band = sidebarGroupBandStyle(
                        groupColorHex: hex,
                        colorScheme: scheme,
                        increaseContrast: increaseContrast,
                        brightenInDarkMode: true,
                        over: nil
                    )
                    let bandComposite = cmuxCompositedNSColor(
                        band.color!.withAlphaComponent(CGFloat(band.opacity)),
                        over: surface
                    )
                    let nameComposite = cmuxCompositedNSColor(nameForeground, over: bandComposite)
                    let ratio = cmuxContrastRatio(foreground: nameComposite, background: bandComposite)
                    #expect(
                        ratio >= Self.secondaryTextFloor,
                        "name over band \(hex ?? "neutral") scheme=\(scheme) ic=\(increaseContrast) ratio=\(ratio)"
                    )
                }
            }
        }
    }
}
