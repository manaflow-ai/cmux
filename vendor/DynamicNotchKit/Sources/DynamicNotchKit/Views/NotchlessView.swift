//
//  NotchlessView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2024-04-06.
//

import SwiftUI

struct NotchlessView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var windowHeight: CGFloat = 0

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var cornerRadius: CGFloat {
        if let cornerRadius = dynamicNotch.chrome.floatingCornerRadius {
            return cornerRadius
        }
        if case let .floating(cornerRadius) = dynamicNotch.style {
            return cornerRadius
        } else {
            return 20
        }
    }

    var body: some View {
        notchContent()
            .background {
                if let backgroundColor = dynamicNotch.chrome.backgroundColor {
                    backgroundColor.opacity(dynamicNotch.chrome.backgroundOpacity)
                } else {
                    VisualEffectView(material: .popover, blendingMode: .behindWindow)
                        .opacity(dynamicNotch.chrome.backgroundOpacity)
                }
            }
            .overlay {
                let borderWidth = dynamicNotch.chrome.borderWidth ?? 1
                if borderWidth > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            dynamicNotch.chrome.borderColor ?? Color(nsColor: .quaternaryLabelColor),
                            lineWidth: borderWidth
                        )
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .padding(dynamicNotch.chrome.floatingOuterPadding)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { newHeight in
                // This makes sure that the floating window FULLY slides off before disappearing
                windowHeight = newHeight
            }
            .offset(y: dynamicNotch.state == .expanded ? dynamicNotch.notchSize.height : -windowHeight)
            .onHover(perform: dynamicNotch.updateHoverState)
    }

    private func notchContent() -> some View {
        VStack(spacing: 0) {
            dynamicNotch.expandedContent
                .transition(.blur(intensity: 10).combined(with: .opacity))
                .padding(.top, dynamicNotch.chrome.floatingContentInsets.top)
                .padding(.bottom, dynamicNotch.chrome.floatingContentInsets.bottom)
                .padding(.leading, dynamicNotch.chrome.floatingContentInsets.leading)
                .padding(.trailing, dynamicNotch.chrome.floatingContentInsets.trailing)
        }
        .fixedSize()
    }
}
