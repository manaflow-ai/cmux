//
//  BlurModifier.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-08-30.
//

import SwiftUI

struct BlurModifier: ViewModifier {
    let intensity: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: intensity)
    }
}

struct ScaleModifier: ViewModifier {
    let xScale: CGFloat
    var yScale: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: xScale, y: yScale, anchor: anchor)
    }
}

extension AnyTransition {
    static func blur(intensity: CGFloat) -> AnyTransition {
        .modifier(
            active: BlurModifier(intensity: intensity),
            identity: BlurModifier(intensity: 0)
        )
    }

    static func scale(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> AnyTransition {
        .modifier(
            active: ScaleModifier(xScale: x, yScale: y, anchor: anchor),
            identity: ScaleModifier(xScale: 1, yScale: 1, anchor: anchor)
        )
    }
}
