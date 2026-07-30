//
//  DynamicNotchHoverBehavior.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-04-19.
//

import Foundation

/// Defines the behavior of the notch when hovered over.
///
/// Currently, there are limited behaviors available.
/// In ``DynamicNotch`` and ``DynamicNotchInfo``, ``all`` is used by default, and there is likely no configuration required on your end.
///
/// If there is more behaviors you wish to see, please open an issue on the GitHub repository!
///
public struct DynamicNotchHoverBehavior: OptionSet, Sendable {
    /// The underlying raw value of the option set.
    public let rawValue: Int

    /// Creates a new instance with the specified raw value.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// All behaviors combined.
    public static let all: DynamicNotchHoverBehavior = [.keepVisible, .hapticFeedback, .increaseShadow]

    /// Ensures that the notch is always visible during hover.
    public static let keepVisible: DynamicNotchHoverBehavior = .init(rawValue: 1 << 0)

    /// Triggers haptic feedback when hovered over.
    public static let hapticFeedback: DynamicNotchHoverBehavior = .init(rawValue: 1 << 1)

    /// Increases the shadow of the notch during hover.
    public static let increaseShadow: DynamicNotchHoverBehavior = .init(rawValue: 1 << 2)
}
