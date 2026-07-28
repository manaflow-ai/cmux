//
//  NotchView.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-24.
//

import SwiftUI

struct NotchView<Expanded, CompactLeading, CompactTrailing>: View where Expanded: View, CompactLeading: View, CompactTrailing: View {
    @ObservedObject private var dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>
    @State private var compactLeadingWidth: CGFloat = 0
    @State private var compactTrailingWidth: CGFloat = 0

    init(dynamicNotch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>) {
        self.dynamicNotch = dynamicNotch
    }

    private var expandedNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        let overrideTop = dynamicNotch.chrome.notchTopCornerRadius
        let overrideBottom = dynamicNotch.chrome.notchBottomCornerRadius
        if case let .notch(topCornerRadius, bottomCornerRadius) = dynamicNotch.style {
            return (
                top: overrideTop ?? topCornerRadius,
                bottom: overrideBottom ?? bottomCornerRadius
            )
        } else {
            return (top: overrideTop ?? 15, bottom: overrideBottom ?? 20)
        }
    }

    private var compactNotchCornerRadii: (top: CGFloat, bottom: CGFloat) {
        (top: 6, bottom: 14)
    }

    private var minWidth: CGFloat {
        dynamicNotch.notchSize.width + (topCornerRadius * 2)
    }

    private var topCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.top : compactNotchCornerRadii.top
    }

    private var bottomCornerRadius: CGFloat {
        dynamicNotch.state == .expanded ? expandedNotchCornerRadii.bottom : compactNotchCornerRadii.bottom
    }

    private var xOffset: CGFloat {
        if dynamicNotch.state != .compact {
            0
        } else {
            compactXOffset
        }
    }

    private var compactXOffset: CGFloat {
        guard !dynamicNotch.usesSyntheticNotch else { return 0 }
        return (compactTrailingWidth - compactLeadingWidth) / 2
    }

    var body: some View {
        notchContent()
            .background {
                Rectangle()
                    .foregroundStyle(dynamicNotch.chrome.backgroundColor ?? .black)
                    .opacity(dynamicNotch.chrome.backgroundOpacity)
                    .padding(-50) // The opening/closing animation can overshoot, so this makes sure that it's still black
            }
            .overlay {
                if let borderWidth = dynamicNotch.chrome.borderWidth, borderWidth > 0 {
                    NotchShape(
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius
                    )
                    .stroke(
                        dynamicNotch.chrome.borderColor ?? Color(nsColor: .quaternaryLabelColor),
                        lineWidth: borderWidth
                    )
                    .padding(.horizontal, 0.5)
                }
            }
            .mask {
                NotchShape(
                    topCornerRadius: topCornerRadius,
                    bottomCornerRadius: bottomCornerRadius
                )
                .padding(.horizontal, 0.5)
                .frame(
                    width: dynamicNotch.state != .hidden ? nil : minWidth,
                    height: dynamicNotch.state != .hidden ? nil : dynamicNotch.notchSize.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .offset(x: xOffset)
            .animation(.smooth, value: [compactLeadingWidth, compactTrailingWidth])
    }

    private func notchContent() -> some View {
        ZStack {
            compactContent()
                .fixedSize()
                .offset(x: dynamicNotch.state == .compact ? 0 : compactXOffset)
                .frame(
                    width: dynamicNotch.state == .compact ? nil : dynamicNotch.notchSize.width,
                    height: (dynamicNotch.state == .compact && dynamicNotch.isHovering) ? dynamicNotch.menubarHeight : dynamicNotch.notchSize.height
                )

            expandedContent()
                .fixedSize()
                .frame(
                    maxWidth: dynamicNotch.state == .expanded ? nil : 0,
                    maxHeight: dynamicNotch.state == .expanded ? nil : 0
                )
                .offset(x: dynamicNotch.state == .compact ? -compactXOffset : 0)
        }
        .padding(.horizontal, topCornerRadius)
        .fixedSize()
        .frame(minWidth: minWidth, minHeight: dynamicNotch.notchSize.height)
        .onHover(perform: dynamicNotch.updateHoverState)
    }

    func compactContent() -> some View {
        Group {
            if dynamicNotch.usesSyntheticNotch {
                ZStack {
                    Color.clear
                        .frame(width: dynamicNotch.notchSize.width)

                    HStack(spacing: 0) {
                        compactLeadingContent(addsHardwareNotchInsets: false)
                        Spacer(minLength: 0)
                        compactTrailingContent(addsHardwareNotchInsets: false)
                    }
                    .frame(width: dynamicNotch.notchSize.width)
                }
            } else {
                HStack(spacing: 0) {
                    compactLeadingContent(addsHardwareNotchInsets: true)

                    Spacer()
                        .frame(width: dynamicNotch.notchSize.width)

                    compactTrailingContent(addsHardwareNotchInsets: true)
                }
            }
        }
        .frame(height: dynamicNotch.notchSize.height)
        .onChange(of: dynamicNotch.disableCompactLeading) { _ in
            if dynamicNotch.disableCompactLeading {
                compactLeadingWidth = 0
            }
        }
        .onChange(of: dynamicNotch.disableCompactTrailing) { _ in
            if dynamicNotch.disableCompactTrailing {
                compactTrailingWidth = 0
            }
        }
    }

    @ViewBuilder
    private func compactLeadingContent(
        addsHardwareNotchInsets: Bool
    ) -> some View {
        if dynamicNotch.state == .compact,
           !dynamicNotch.disableCompactLeading {
            dynamicNotch.compactLeadingContent
                .environment(\.notchSection, .compactLeading)
                .safeAreaInset(edge: .leading, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(width: 8)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(height: 4)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(height: 8)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) {
                    compactLeadingWidth = $0
                }
                .transition(
                    .blur(intensity: 10)
                        .combined(with: .scale(x: 0, anchor: .trailing))
                        .combined(with: .opacity)
                )
        }
    }

    @ViewBuilder
    private func compactTrailingContent(
        addsHardwareNotchInsets: Bool
    ) -> some View {
        if dynamicNotch.state == .compact,
           !dynamicNotch.disableCompactTrailing {
            dynamicNotch.compactTrailingContent
                .environment(\.notchSection, .compactTrailing)
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(width: 8)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(height: 4)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if addsHardwareNotchInsets {
                        Color.clear.frame(height: 8)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) {
                    compactTrailingWidth = $0
                }
                .transition(
                    .blur(intensity: 10)
                        .combined(with: .scale(x: 0, anchor: .leading))
                        .combined(with: .opacity)
                )
        }
    }

    func expandedContent() -> some View {
        HStack(spacing: 0) {
            if dynamicNotch.state == .expanded {
                dynamicNotch.expandedContent
                    .transition(.blur(intensity: 10).combined(with: .scale(y: 0.6, anchor: .top)).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: dynamicNotch.notchSize.height) }
        .padding(.top, dynamicNotch.chrome.notchContentInsets.top)
        .padding(.bottom, dynamicNotch.chrome.notchContentInsets.bottom)
        .padding(.leading, dynamicNotch.chrome.notchContentInsets.leading)
        .padding(.trailing, dynamicNotch.chrome.notchContentInsets.trailing)
        .frame(minWidth: dynamicNotch.notchSize.width)
    }
}
