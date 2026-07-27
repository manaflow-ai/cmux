//
//  EnvironmentValues+Extensions.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-03-26.
//

import SwiftUI

extension EnvironmentValues {
    @Entry var notchStyle: DynamicNotchStyle = .auto
    @Entry var notchSection: DynamicNotchSection = .expanded
}

enum DynamicNotchSection {
    case expanded
    case compactLeading
    case compactTrailing
}
