#if os(iOS)
import CNDesign
import SwiftUI
import UIKit

/// Measured Mobile Safari (iOS 27, compact layout) metrics, colors and
/// springs from `ios-next/reference/safari.md`. Geometry is expressed
/// relative to the screen so the same numbers hold on every iPhone width;
/// the comments give the 402 x 874 pt reference values.
struct BrowserMetrics: Sendable {
    /// Toolbar side inset (34).
    let sideInset: CGFloat = 34
    /// Glass circle diameter and bar height (48).
    let control: CGFloat = 48
    /// Gap between circles and the capsule (8).
    let gap: CGFloat = 8
    /// Back/forward split: extra width of the back pill when forward history exists.
    let forwardExtra: CGFloat = 40
    /// URL label size, expanded (17 pt medium).
    let urlFont: CGFloat = 17
    /// Collapsed label scale (69 -> 51 pt wide, about 12.6 pt).
    let collapsedScale: CGFloat = 0.74
    /// Collapsed pill: text + 2 x 19 pt, 32 high, 14 pt above the screen bottom.
    let pillPadding: CGFloat = 19
    let pillHeight: CGFloat = 32
    let pillBottom: CGFloat = 14
    /// Progress line along the capsule bottom.
    let progressHeight: CGFloat = 2
    /// Downward finger travel that collapses the bar and upward travel that expands it.
    let collapseThreshold: CGFloat = 15
    let expandThreshold: CGFloat = 6
    /// Editing with a software keyboard: 8 pt insets and gap above the keyboard.
    let editInset: CGFloat = 8
    /// Display corner radius used for full-screen page cards (overview zoom, swipe).
    let screenRadius: CGFloat = 55
    // Tab overview.
    let cardWidthRatio: CGFloat = 177.0 / 402.0
    let cardAspect: CGFloat = 249.3 / 177.0
    let cardRadius: CGFloat = 18
    let gridInset: CGFloat = 16
    let titleRow: CGFloat = 23
    let rowGap: CGFloat = 16
    let cardClose: CGFloat = 22
    let overviewTopControl: CGFloat = 36
    // Page menu.
    let menuWidth: CGFloat = 250
    let menuRadius: CGFloat = 32
    let menuRow: CGFloat = 42
    let menuGroupGap: CGFloat = 21
    // Start page.
    let favoriteTile: CGFloat = 72
    let favoriteRadius: CGFloat = 16
}

/// Safari color tokens (section 10).
struct BrowserColors: Sendable {
    static func pair(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let a = trait.userInterfaceStyle == .dark ? darkAlpha : lightAlpha
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        })
    }

    let label = BrowserColors.pair(0x000000, 0xFFFFFF)
    let glyphDisabled = BrowserColors.pair(0xC5C5C7, 0x5B5B5D)
    let secondaryLabel = BrowserColors.pair(0x3C3C43, 0xEBEBF5, lightAlpha: 0.6, darkAlpha: 0.6)
    let startBackground = BrowserColors.pair(0xF2F2F7, 0x000000)
    let startCard = BrowserColors.pair(0xFFFFFF, 0x1C1C1E)
    let favoriteTile = BrowserColors.pair(0xCCCDD4, 0x3A3A3C)
    let overviewTop = BrowserColors.pair(0xECDFD3, 0x1A1918)
    let overviewBottom = BrowserColors.pair(0xD2D3DB, 0x0B0B0D)
    /// Card close circle: #F2F2F7 over a white card, white 8% over a dark
    /// one (#232325 measured on #111); the cross is mid gray.
    /// Dark values from a device screenshot (opaque #3E3E3F, cross #A7A7A9).
    let cardCloseFill = BrowserColors.pair(0xF2F2F7, 0x3E3E3F, lightAlpha: 0.94, darkAlpha: 1)
    let cardCloseGlyph = BrowserColors.pair(0x7E7E83, 0xA7A7A9)
    let separator = BrowserColors.pair(0x3C3C43, 0x545458, lightAlpha: 0.18, darkAlpha: 0.5)
    /// cmux-next has one hue (`highlight`); Safari's #0088FF progress line and
    /// Done button use it.
    var accent: Color { .cn(\.highlight) }
}

/// Springs fitted to the reference recordings (section 8).
struct BrowserMotion: Sendable {
    /// Collapse on scroll down. Spec fit 0.36/0.91; framediff on collapse.mp4 (track of the label) fits 0.39/0.84, and 0.39/0.86 reproduces it here.
    let collapse = Animation.spring(response: 0.39, dampingFraction: 0.86)
    /// Expand on scroll up (browser-springs-verify.md: 0.385 / 0.880).
    let expandScroll = Animation.spring(response: 0.385, dampingFraction: 0.88)
    /// Expand on tapping the pill (verified: 0.390 / 0.879).
    let expandTap = Animation.spring(response: 0.39, dampingFraction: 0.88)
    /// Side buttons (ink measured with real timestamps): gone by about
    /// 105–117 ms on collapse; on expand they start about 90 ms in and ease
    /// out (50 % at about 158 ms, full at about 330 ms).
    let sideOut = Animation.linear(duration: 0.10)
    let sideIn = Animation.easeOut(duration: 0.23).delay(0.09)
    /// Address field rides with the keyboard.
    let keyboard = Animation.spring(response: 0.35, dampingFraction: 1)
    /// Go: field back into the toolbar.
    let editEnd = Animation.spring(response: 0.30, dampingFraction: 1)
    /// Page menu glass morph.
    let menu = Animation.spring(response: 0.40, dampingFraction: 0.78)
    /// Card reflow after a close: Safari's own reflow curve replayed
    /// (`SafariCurve.reflow`; fitted springs stayed 1-2 frames off,
    /// tabs-parity-reaudit-3 D8). The tab zoom's curves are in TabZoom.swift.
    let reflow = Animation.safari(.reflow)
    /// Toolbar swipe snap.
    let swipe = Animation.spring(response: 0.40, dampingFraction: 0.9)

    /// Reduce Motion swaps every spatial animation for a short crossfade.
    @MainActor func resolve(_ animation: Animation) -> Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.18) : animation
    }
}

struct BrowserStyle: Sendable {
    let metrics = BrowserMetrics()
    let colors = BrowserColors()
    let motion = BrowserMotion()
    static let shared = BrowserStyle()
}
#endif
