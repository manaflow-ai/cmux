import Foundation
@preconcurrency import AVFoundation
import CMUXMobileCore
import CmuxMobileAuth
import CmuxMobileTerminal
import Observation
import OSLog
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

enum TerminalPalette {
    static let background = Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0)
    static let foreground = Color(red: 0xf8 / 255.0, green: 0xf8 / 255.0, blue: 0xf2 / 255.0)
    static let dimForeground = Color(red: 0xc8 / 255.0, green: 0xc8 / 255.0, blue: 0xc0 / 255.0)
}

enum PlatformPalette {
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.white
        #endif
    }

    static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.gray
        #endif
    }

    static func gameOfLifeCell(colorScheme: ColorScheme) -> Color {
        #if os(iOS)
        Color(uiColor: colorScheme == .dark ? .systemGray4 : .systemGray2)
        #elseif os(macOS)
        Color(nsColor: colorScheme == .dark ? .systemGray : .secondaryLabelColor)
        #else
        Color.gray
        #endif
    }
}


enum MobileTerminalSafeAreaContext: Equatable, Sendable {
    case fullWidth
    case splitSidebarVisible
}

struct MobileTerminalSafeAreaExpansionEdges: Equatable, Sendable {
    var horizontal: Bool
    var bottom: Bool

    var hasEdges: Bool {
        horizontal || bottom
    }

    var edgeSet: Edge.Set {
        var edges: Edge.Set = []
        if horizontal {
            edges.formUnion(.horizontal)
        }
        if bottom {
            edges.formUnion(.bottom)
        }
        return edges
    }
}

enum MobileTerminalSafeAreaExpansionPolicy {
    static func edges(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        includesBottom: Bool = true
    ) -> MobileTerminalSafeAreaExpansionEdges {
        switch context {
        case .fullWidth:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: hasCompactVerticalSize,
                bottom: includesBottom
            )
        case .splitSidebarVisible:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: false,
                bottom: includesBottom
            )
        }
    }
}

struct MobileTerminalContentInsets: Equatable, Sendable {
    static let zero = MobileTerminalContentInsets(leading: 0, trailing: 0)

    var leading: CGFloat
    var trailing: CGFloat
}

enum MobileTerminalContentSafeAreaPolicy {
    private static let landscapeCameraInsetThreshold: CGFloat = 32
    private static let landscapeCameraInsetDeltaThreshold: CGFloat = 8

    static func horizontalInsets(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        safeAreaInsets: EdgeInsets,
        symmetricCameraEdge: MobileTerminalLandscapeCameraEdge = .trailing
    ) -> MobileTerminalContentInsets {
        guard context == .fullWidth, hasCompactVerticalSize else {
            return .zero
        }
        let leading = max(0, safeAreaInsets.leading)
        let trailing = max(0, safeAreaInsets.trailing)
        let largestInset = max(leading, trailing)
        guard largestInset >= landscapeCameraInsetThreshold else {
            return .zero
        }
        let insetDelta = abs(leading - trailing)
        if insetDelta >= landscapeCameraInsetDeltaThreshold {
            if leading > trailing {
                return MobileTerminalContentInsets(leading: insetDelta, trailing: 0)
            }
            return MobileTerminalContentInsets(leading: 0, trailing: insetDelta)
        }

        switch symmetricCameraEdge {
        case .leading:
            return MobileTerminalContentInsets(leading: largestInset, trailing: 0)
        case .trailing:
            return MobileTerminalContentInsets(leading: 0, trailing: largestInset)
        case .none:
            return .zero
        }
    }
}

enum MobileTerminalLandscapeCameraEdge: Equatable, Sendable {
    case leading
    case trailing
    case none
}

enum MobileTerminalWindowOrientation: Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case unknown
}

enum MobileTerminalLandscapeCameraEdgeResolver {
    static func edge(for orientation: MobileTerminalWindowOrientation) -> MobileTerminalLandscapeCameraEdge {
        switch orientation {
        case .landscapeLeft:
            return .trailing
        case .landscapeRight:
            return .leading
        case .portrait, .portraitUpsideDown, .unknown:
            return .trailing
        }
    }
}

#if os(iOS)
private struct MobileCompactLandscapeTerminalSafeAreaCompensation: ViewModifier {
    let context: MobileTerminalSafeAreaContext
    let includesBottom: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        let edges = MobileTerminalSafeAreaExpansionPolicy.edges(
            context: context,
            hasCompactVerticalSize: verticalSizeClass == .compact,
            includesBottom: includesBottom
        )
        if edges.hasEdges {
            content
                .ignoresSafeArea(.container, edges: edges.edgeSet)
        } else {
            content
        }
    }
}

extension View {
    func mobileTerminalSafeAreaExpansion(
        context: MobileTerminalSafeAreaContext,
        includesBottom: Bool = true
    ) -> some View {
        modifier(MobileCompactLandscapeTerminalSafeAreaCompensation(
            context: context,
            includesBottom: includesBottom
        ))
    }
}

@MainActor
private enum MobileTerminalDeviceSafeArea {
    static var landscapeCameraEdge: MobileTerminalLandscapeCameraEdge {
        MobileTerminalLandscapeCameraEdgeResolver.edge(for: windowOrientation)
    }

    static var bottomInset: CGFloat {
        if let keyWindow {
            return keyWindow.safeAreaInsets.bottom
        }
        return 0
    }

    static func horizontalInsets(fallback: EdgeInsets) -> EdgeInsets {
        if let keyWindow {
            let insets = keyWindow.safeAreaInsets
            return EdgeInsets(
                top: insets.top,
                leading: insets.left,
                bottom: insets.bottom,
                trailing: insets.right
            )
        }
        return fallback
    }

    private static var windowOrientation: MobileTerminalWindowOrientation {
        guard let windowScene = keyWindow?.windowScene else {
            return .unknown
        }
        switch windowScene.interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    private static var keyWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: \.isKeyWindow) {
                return window
            }
        }
        return nil
    }
}

#endif

extension View {
    @ViewBuilder
    func mobilePlainTextInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileEmailTextInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileOneTimeCodeInput() -> some View {
        #if os(iOS)
        self
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
        #else
        self
        #endif
    }

    @ViewBuilder
    func addDeviceInputBehavior(_ kind: AddDeviceInputKind) -> some View {
        #if os(iOS)
        switch kind {
        case .text:
            self
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        case .url:
            self
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .number:
            self
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mobileGlassButton() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.bordered)
            .controlSize(.large)
        #endif
    }

    @ViewBuilder
    func mobileGlassProminentButton() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        #else
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        #endif
    }

    @ViewBuilder
    func mobileGlassPill() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        #else
        self
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        #endif
    }
}
