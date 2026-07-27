//
//  DynamicNotchInfo+HelperViews.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-04-21.
//

import SwiftUI

extension DynamicNotchInfo {
    struct CompactLeadingView: View {
        @ObservedObject var dynamicNotch: DynamicNotchInfo
        @Namespace private var namespace

        init(dynamicNotch: DynamicNotchInfo) {
            self.dynamicNotch = dynamicNotch
        }

        public var body: some View {
            dynamicNotch.compactLeading
                .transition(.blur(intensity: 10).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
                .matchedGeometryEffect(
                    id: "info_icon",
                    in: dynamicNotch.internalDynamicNotch.namespace ?? namespace,
                    isSource: dynamicNotch.internalDynamicNotch.state == .compact && dynamicNotch.shouldSkipHideWhenConverting
                )
        }
    }

    struct CompactTrailingView: View {
        @ObservedObject var dynamicNotch: DynamicNotchInfo

        init(dynamicNotch: DynamicNotchInfo) {
            self.dynamicNotch = dynamicNotch
        }

        public var body: some View {
            dynamicNotch.compactTrailing
                .transition(.blur(intensity: 10).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
        }
    }

    struct InfoView: View {
        @Environment(\.notchStyle) private var notchStyle
        @ObservedObject var dynamicNotch: DynamicNotchInfo
        @Namespace private var namespace

        init(dynamicNotch: DynamicNotchInfo) {
            self.dynamicNotch = dynamicNotch
        }

        public var body: some View {
            HStack(spacing: 10) {
                if let icon = dynamicNotch.icon {
                    icon
                        .matchedGeometryEffect(
                            id: "info_icon",
                            in: dynamicNotch.internalDynamicNotch.namespace ?? namespace,
                            isSource: dynamicNotch.internalDynamicNotch.state == .expanded && dynamicNotch.shouldSkipHideWhenConverting
                        )
                }

                textView()

                Spacer(minLength: 0)
            }
            .frame(height: 40)
        }

        @ViewBuilder
        func textView() -> some View {
            VStack(alignment: .leading, spacing: dynamicNotch.description != nil ? nil : 0) {
                Text(dynamicNotch.title)
                    .font(.headline)
                    .foregroundStyle(dynamicNotch.textColor ?? (notchStyle.isNotch ? .white : .primary))

                if let description = dynamicNotch.description {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(dynamicNotch.textColor?.opacity(0.5) ?? (notchStyle.isNotch ? .white.opacity(0.5) : .secondary))
                }
            }
        }
    }
}
