//
//  DynamicNotchTransitionConfiguration.swift
//  DynamicNotchKit
//
//  Created by Sebastian on 2025-06-13.
//

import SwiftUI

/// Configuration for customizing transition animations of a ``DynamicNotch``.
///
/// Use this to override the default style-based animations and control
/// how the notch transitions between states.
///
/// ```swift
/// let notch = DynamicNotch(style: .auto) {
///     Text("Hello")
/// }
/// notch.transitionConfiguration = .init(
///     openingAnimation: .spring(duration: 0.3),
///     skipIntermediateHides: true
/// )
/// ```
public struct DynamicNotchTransitionConfiguration: Sendable {
    /// Animation used when the notch appears (hidden → expanded or hidden → compact).
    /// When `nil`, falls back to the style's default opening animation.
    public var openingAnimation: Animation?

    /// Animation used when the notch disappears (expanded → hidden or compact → hidden).
    /// When `nil`, falls back to the style's default closing animation.
    public var closingAnimation: Animation?

    /// Animation used when converting between compact and expanded states.
    /// When `nil`, falls back to the style's default conversion animation.
    public var conversionAnimation: Animation?

    /// When `true`, transitions between compact and expanded states skip the intermediate
    /// hide step, resulting in a faster, more direct animation.
    public var skipIntermediateHides: Bool

    /// Creates a new transition configuration.
    /// - Parameters:
    ///   - openingAnimation: Custom opening animation, or `nil` to use the style default.
    ///   - closingAnimation: Custom closing animation, or `nil` to use the style default.
    ///   - conversionAnimation: Custom conversion animation, or `nil` to use the style default.
    ///   - skipIntermediateHides: Whether to skip the hide step when converting between states. Defaults to `false`.
    public init(
        openingAnimation: Animation? = nil,
        closingAnimation: Animation? = nil,
        conversionAnimation: Animation? = nil,
        skipIntermediateHides: Bool = false
    ) {
        self.openingAnimation = openingAnimation
        self.closingAnimation = closingAnimation
        self.conversionAnimation = conversionAnimation
        self.skipIntermediateHides = skipIntermediateHides
    }
}
