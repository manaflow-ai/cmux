#if canImport(AppKit)
import AppKit
import Foundation
import RunestoneCore
import RunestonePlatform

/// Fonts and colors to be used by a macOS `TextView`.
public protocol Theme: RunestoneTheme, AnyObject {
    /// Color of text matching the capture sequence.
    func textColor(for highlightName: String) -> NSColor?
    /// Font of text matching the capture sequence.
    func font(for highlightName: String) -> NSFont?
    /// Traits of text matching the capture sequence.
    func fontTraits(for highlightName: String) -> FontTraits
    /// Shadow of text matching the capture sequence.
    func shadow(for highlightName: String) -> NSShadow?
}

public extension Theme {
    var gutterHairlineWidth: CGFloat {
        1
    }

    var pageGuideHairlineWidth: CGFloat {
        1
    }

    var markedTextBackgroundCornerRadius: CGFloat {
        0
    }

    func textColor(for highlightName: String) -> NSColor? {
        nil
    }

    func font(for highlightName: String) -> NSFont? {
        nil
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        []
    }

    func shadow(for highlightName: String) -> NSShadow? {
        nil
    }
}
#endif
