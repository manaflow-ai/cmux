import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
public typealias RunestoneNativeColor = UIColor
public typealias RunestoneNativeFont = UIFont
public typealias RunestoneNativeEdgeInsets = UIEdgeInsets
#elseif canImport(AppKit)
import AppKit
public typealias RunestoneNativeColor = NSColor
public typealias RunestoneNativeFont = NSFont
public typealias RunestoneNativeEdgeInsets = NSEdgeInsets
#endif

/// Platform-neutral edge insets for portable editor layout contracts.
public struct RunestoneEdgeInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// Portable theme contract shared by Runestone UI adapters.
public protocol RunestoneTheme: AnyObject {
    var font: RunestoneNativeFont { get }
    var textColor: RunestoneNativeColor { get }
    var gutterBackgroundColor: RunestoneNativeColor { get }
    var gutterHairlineColor: RunestoneNativeColor { get }
    var gutterHairlineWidth: CGFloat { get }
    var lineNumberColor: RunestoneNativeColor { get }
    var lineNumberFont: RunestoneNativeFont { get }
    var selectedLineBackgroundColor: RunestoneNativeColor { get }
    var selectedLinesLineNumberColor: RunestoneNativeColor { get }
    var selectedLinesGutterBackgroundColor: RunestoneNativeColor { get }
    var invisibleCharactersColor: RunestoneNativeColor { get }
    var pageGuideHairlineColor: RunestoneNativeColor { get }
    var pageGuideHairlineWidth: CGFloat { get }
    var pageGuideBackgroundColor: RunestoneNativeColor { get }
    var markedTextBackgroundColor: RunestoneNativeColor { get }
    var markedTextBackgroundCornerRadius: CGFloat { get }
}
