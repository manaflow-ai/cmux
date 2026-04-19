#if canImport(AppKit)
import AppKit
import Foundation
import RunestoneCore

/// Default theme used by Runestone on macOS when no other theme has been set.
public final class DefaultTheme: Theme {
    public let font: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    public let textColor: NSColor = .labelColor
    public let gutterBackgroundColor: NSColor = NSColor.windowBackgroundColor
    public let gutterHairlineColor: NSColor = NSColor.separatorColor
    public let lineNumberColor: NSColor = NSColor.secondaryLabelColor
    public let lineNumberFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    public let selectedLineBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.12)
    public let selectedLinesLineNumberColor: NSColor = NSColor.labelColor
    public let selectedLinesGutterBackgroundColor: NSColor = NSColor.windowBackgroundColor
    public let invisibleCharactersColor: NSColor = NSColor.tertiaryLabelColor
    public let pageGuideHairlineColor: NSColor = NSColor.separatorColor
    public let pageGuideBackgroundColor: NSColor = NSColor.controlBackgroundColor
    public let markedTextBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25)

    public init() {}

    public func textColor(for highlightName: String) -> NSColor? {
        if highlightName.hasPrefix("comment") {
            return NSColor.systemGreen
        } else if highlightName.hasPrefix("constant.builtin") || highlightName.hasPrefix("constant.character") {
            return NSColor.systemPink
        } else if highlightName.hasPrefix("constructor") || highlightName.hasPrefix("type") {
            return NSColor.systemOrange
        } else if highlightName.hasPrefix("function") {
            return NSColor.systemBlue
        } else if highlightName.hasPrefix("keyword") {
            return NSColor.systemPurple
        } else if highlightName.hasPrefix("number") {
            return NSColor.systemRed
        } else if highlightName.hasPrefix("property") {
            return NSColor.systemTeal
        } else if highlightName.hasPrefix("string") {
            return NSColor.systemMint
        } else if highlightName.hasPrefix("variable.builtin") {
            return NSColor.systemIndigo
        } else if highlightName.hasPrefix("operator") || highlightName.hasPrefix("punctuation") {
            return NSColor.secondaryLabelColor
        } else {
            return nil
        }
    }

    public func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("keyword") {
            return .bold
        } else {
            return []
        }
    }
}
#endif
