//
//  DynamicNotchInfo.swift
//  DynamicNotchKit
//
//  Created by Kai Azim on 2023-08-25.
//

import SwiftUI

// MARK: DynamicNotchInfo

/// A preset `DynamicNotch` suited for seamlessly presenting information.
///
/// This class is a wrapper around `DynamicNotch` that provides a simple way to present information to the user.
/// It is designed to be easy to use and provide a clean and simple way to present information.
///
/// On top of this, it provides refined animations when transitioning between the expanded and compact states using `matchedGeometryEffect` (note that this is not in all cases; refer to your initializer for more details).
///
/// ## Compared to DynamicNotch
///
/// Instead of providing your own SwiftUI content, `DynamicNotchInfo` provides a set of predefined views that are automatically used in the expanded and compact states.
/// This makes it easy to use and provides a consistent look and feel, as all predefined views are designed to both look and feel native.
/// Refer to ``Label`` for available options for preset views.
///
/// ## Usage
///
/// ```swift
/// Task {
///     let notch = DynamicNotchInfo(
///         icon: .init(systemName: "hand.wave"),
///         title: "Hello There!",
///         description: "This is a description.",
///         compactLeading: .init(systemName: "wave.3.left", color: .blue),
///         compactTrailing: .init(systemName: "wave.3.right", color: .blue)
///     )
///
///     await notch.expand()
///     try await Task.sleep(for: .seconds(2))
///     await notch.compact()
///     try await Task.sleep(for: .seconds(2))
///     await notch.hide()
/// }
/// ```
/// > Similar to `DynamicNotch`, there is a `hoverBehavior` property of type ``DynamicNotchHoverBehavior``, which is available to modify how the window behaves when the user hovers over it.
/// > This can be helpful if you wish to keep the notch open during hover events or add effects such as scaling or haptic feedback.
///
@MainActor
public final class DynamicNotchInfo: ObservableObject, DynamicNotchControllable {
    final class ViewState: ObservableObject {
        weak var owner: DynamicNotchInfo?
    }

    var internalDynamicNotch: DynamicNotch<InfoView, CompactLeadingView, CompactTrailingView>!
    let viewState = ViewState()

    @Published public var icon: DynamicNotchInfo.Label? {
        didSet { viewState.objectWillChange.send() }
    }
    @Published public var title: LocalizedStringKey {
        didSet { viewState.objectWillChange.send() }
    }
    @Published public var description: LocalizedStringKey? {
        didSet { viewState.objectWillChange.send() }
    }
    @Published public var textColor: Color? {
        didSet { viewState.objectWillChange.send() }
    }
    @Published public var compactLeading: DynamicNotchInfo.Label? {
        didSet {
            internalDynamicNotch.disableCompactLeading = compactLeading == nil
            viewState.objectWillChange.send()
        }
    }

    @Published public var compactTrailing: DynamicNotchInfo.Label? {
        didSet {
            internalDynamicNotch.disableCompactTrailing = compactTrailing == nil
            viewState.objectWillChange.send()
        }
    }

    @Published var shouldSkipHideWhenConverting: Bool = false {
        didSet { viewState.objectWillChange.send() }
    }

    /// Creates a new DynamicNotchInfo with a predefined content and style based on parameters.
    /// - Parameters:
    ///   - icon: the icon to display in the expanded state of the notch.
    ///   - title: the title to display in the expanded state of the notch.
    ///   - description: the description to display in the expanded state of the notch. If unspecified, no description will be displayed.
    ///   - compactLeading: the icon to display in the compact leading state of the notch. If unspecified, the expanded icon will be displayed.
    ///   - compactTrailing: the icon to display in the compact trailing state of the notch. If unspecified, no icon will be displayed.
    ///   - hoverBehavior: the hover behavior of the notch, which allows for different interactions such as haptic feedback, increased shadow etc.
    ///   - style: the popover's style. If unspecified, the style will be automatically set according to the screen (notch or floating).
    public init(
        icon: DynamicNotchInfo.Label?,
        title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        compactLeading: DynamicNotchInfo.Label? = nil,
        compactTrailing: DynamicNotchInfo.Label? = nil,
        hoverBehavior: DynamicNotchHoverBehavior = .all,
        style: DynamicNotchStyle = .auto
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.viewState.owner = self
        self.internalDynamicNotch = DynamicNotch(
            hoverBehavior: hoverBehavior,
            style: style
        ) {
            InfoView(state: self.viewState)
        } compactLeading: {
            CompactLeadingView(state: self.viewState)
        } compactTrailing: {
            CompactTrailingView(state: self.viewState)
        }
        if let compactLeading {
            self.compactLeading = compactLeading
        } else {
            self.compactLeading = icon
            self.shouldSkipHideWhenConverting = true
        }
        self.compactTrailing = compactTrailing
        self.internalDynamicNotch.disableCompactLeading = self.compactLeading == nil
        self.internalDynamicNotch.disableCompactTrailing = self.compactTrailing == nil
    }

    deinit {
        internalDynamicNotch = nil
    }

    public func expand(
        on screen: NSScreen = NSScreen.screens[0]
    ) async {
        await internalDynamicNotch._expand(
            on: screen,
            skipHide: shouldSkipHideWhenConverting
        )
    }

    public func compact(
        on screen: NSScreen = NSScreen.screens[0]
    ) async {
        await internalDynamicNotch._compact(
            on: screen,
            skipHide: shouldSkipHideWhenConverting
        )
    }

    public func hide() async {
        await internalDynamicNotch.hide()
    }
}
