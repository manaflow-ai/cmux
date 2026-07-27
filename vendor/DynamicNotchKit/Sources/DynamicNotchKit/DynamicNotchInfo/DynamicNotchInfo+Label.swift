//
//  DynamicNotchInfo+Label.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2025-04-18.
//

import SwiftUI

public extension DynamicNotchInfo {
    /// The label to display in a `DynamicNotchInfo`.
    ///
    /// You can use this to display an image, a system image, or a progress bar.
    /// If you require a custom view, you can use the ``init(content:)`` initializer, which is essentially a quick way to emulate the behavior of a ``DynamicNotch`` without needing to create all other components manually.
    ///
    struct Label: View {
        @Environment(\.notchStyle) private var notchStyle
        @Environment(\.notchSection) private var notchSection
        private let id: UUID = .init()
        private var iconStyle: Style

        enum Style: Equatable {
            case image(image: Image)
            case systemImage(systemName: String, color: Color?)
            case progress(progress: Binding<CGFloat>, color: Color?, overlay: AnyView?)
            case customView(contentID: UUID, view: AnyView)

            static func == (lhs: Label.Style, rhs: Label.Style) -> Bool {
                switch (lhs, rhs) {
                case let (.image(image1), .image(image2)):
                    image1 == image2
                case let (.systemImage(systemName1, color1), .systemImage(systemName2, color2)):
                    systemName1 == systemName2 && color1 == color2
                case let (.progress(progress1, color1, _), .progress(progress2, color2, _)):
                    progress1.wrappedValue == progress2.wrappedValue && color1 == color2
                case let (.customView(contentID1, _), .customView(contentID2, _)):
                    contentID1 == contentID2
                default:
                    false
                }
            }
        }

        /// An image to display in the `DynamicNotchInfo`.
        /// - Parameter image: the image to display.
        public init(image: Image) {
            self.iconStyle = .image(image: image)
        }

        /// A system image to display in the `DynamicNotchInfo`.
        /// - Parameters:
        ///   - systemName: the name of the system image to display.
        ///   - color: the color of the image. If not specified, the image will be colored according to the notch style.
        public init(systemName: String, color: Color? = nil) {
            self.iconStyle = .systemImage(systemName: systemName, color: color)
        }

        /// A progress bar to display in the `DynamicNotchInfo`. The progress should be a value between 0 and 1.
        /// - Parameters:
        ///  - progress: the progress to display.
        ///  - color: the color of the progress bar. If not specified, the progress bar will be colored according to the notch style.
        ///  - overlay: a view to display on top of the progress bar. If not specified, no overlay will be displayed.
        public init(progress: Binding<CGFloat>, color: Color? = nil, overlay: (() -> some View)? = { EmptyView() }) {
            self.iconStyle = .progress(
                progress: progress,
                color: color,
                overlay: overlay == nil ? nil : AnyView(overlay!())
            )
        }

        /// A view to display in the` DynamicNotchInfo`.
        /// - Parameter content: the view to display.
        public init(@ViewBuilder content: () -> some View) {
            self.iconStyle = .customView(contentID: .init(), view: AnyView(content()))
        }

        public var body: some View {
            Group {
                switch iconStyle {
                case let .image(image):
                    image
                        .resizable()
                        .padding(4)
                        .scaledToFit()
                case let .systemImage(systemName, color):
                    Image(systemName: systemName)
                        .resizable()
                        .foregroundStyle(color ?? (notchStyle.isNotch ? .white : .primary))
                        .padding(4)
                        .scaledToFit()
                case let .progress(progress, color, overlay):
                    ProgressRing(
                        to: progress,
                        color: color ?? (notchStyle.isNotch ? .white : .primary),
                        thickness: notchSection == .expanded ? 4 : 3
                    )
                    .overlay {
                        if let overlay {
                            overlay
                        }
                    }
                    .padding(2)
                case let .customView(_, view):
                    view
                }
            }
            .id(id)
        }

        struct ProgressRing: View {
            @Binding var target: CGFloat
            let color: Color
            let thickness: CGFloat

            @State private var isLoaded = false

            public init(
                to target: Binding<CGFloat>,
                color: Color = .white,
                thickness: CGFloat
            ) {
                self._target = target
                self.color = color
                self.thickness = thickness
            }

            public var body: some View {
                Circle()
                    .stroke(style: StrokeStyle(lineWidth: thickness))
                    .foregroundStyle(.tertiary)
                    .overlay {
                        Circle()
                            .trim(from: 0, to: isLoaded ? target : 0)
                            .stroke(
                                color.gradient,
                                style: StrokeStyle(
                                    lineWidth: thickness,
                                    lineCap: .round
                                )
                            )
                            .opacity(isLoaded ? 1 : 0)
                    }
                    .rotationEffect(.degrees(-90))
                    .padding(thickness / 2)
                    .task {
                        withAnimation(.timingCurve(0, 0.55, 0.45, 1, duration: 0.8).delay(0.1)) {
                            isLoaded = true
                        }
                    }
            }
        }
    }
}
