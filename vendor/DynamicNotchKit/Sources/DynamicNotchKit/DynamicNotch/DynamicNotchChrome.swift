//
//  DynamicNotchChrome.swift
//  DynamicNotchKit
//
//  Local cmux extension for runtime-programmable shell appearance.
//

import SwiftUI

/// Runtime-programmable chrome surrounding Dynamic Notch content.
///
/// Every default preserves DynamicNotchKit's upstream appearance. Supplying
/// `nil` for a color or radius keeps the style-specific native value.
public struct DynamicNotchChrome {
    public var backgroundColor: Color?
    public var backgroundOpacity: Double
    public var borderColor: Color?
    public var borderWidth: CGFloat?
    public var shadowColor: Color?
    public var shadowOpacity: Double?
    public var shadowRadius: CGFloat?
    public var hoverShadowOpacity: Double?
    public var hoverShadowRadius: CGFloat?
    public var floatingOuterPadding: CGFloat
    public var floatingContentInsets: EdgeInsets
    public var notchContentInsets: EdgeInsets
    public var floatingCornerRadius: CGFloat?
    public var notchTopCornerRadius: CGFloat?
    public var notchBottomCornerRadius: CGFloat?
    public var syntheticNotchWidth: CGFloat

    public init(
        backgroundColor: Color? = nil,
        backgroundOpacity: Double = 1,
        borderColor: Color? = nil,
        borderWidth: CGFloat? = nil,
        shadowColor: Color? = nil,
        shadowOpacity: Double? = nil,
        shadowRadius: CGFloat? = nil,
        hoverShadowOpacity: Double? = nil,
        hoverShadowRadius: CGFloat? = nil,
        floatingOuterPadding: CGFloat = 20,
        floatingContentInsets: EdgeInsets = EdgeInsets(
            top: 15,
            leading: 15,
            bottom: 15,
            trailing: 15
        ),
        notchContentInsets: EdgeInsets = EdgeInsets(
            top: 0,
            leading: 15,
            bottom: 15,
            trailing: 15
        ),
        floatingCornerRadius: CGFloat? = nil,
        notchTopCornerRadius: CGFloat? = nil,
        notchBottomCornerRadius: CGFloat? = nil,
        syntheticNotchWidth: CGFloat = 164
    ) {
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.shadowColor = shadowColor
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.hoverShadowOpacity = hoverShadowOpacity
        self.hoverShadowRadius = hoverShadowRadius
        self.floatingOuterPadding = floatingOuterPadding
        self.floatingContentInsets = floatingContentInsets
        self.notchContentInsets = notchContentInsets
        self.floatingCornerRadius = floatingCornerRadius
        self.notchTopCornerRadius = notchTopCornerRadius
        self.notchBottomCornerRadius = notchBottomCornerRadius
        self.syntheticNotchWidth = syntheticNotchWidth
    }
}
