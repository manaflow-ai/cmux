import SwiftUI

#if canImport(UIKit) && DEBUG
import CmuxMobileTerminal
import Foundation
#endif

/// Top-level mobile scene root.
///
/// Renders the live cmux mobile UI: a ``CMUXMobileAppView`` backed by a fresh
/// ``CMUXMobileShellStore``. In DEBUG builds, setting the environment variable
/// `CMUX_ZOOM_STRESS=1` instead mounts the terminal zoom-stress repro harness
/// (`MobileZoomStressView` from `CmuxMobileTerminal`) so the crash-on-fast-zoom
/// path can be exercised in isolation.
///
/// The composition root (`cmuxApp`) builds the ``CMUXMobileRuntime`` and hands
/// it here. Owning the root-vs-stress decision in the feature layer keeps the
/// app target's package dependencies limited to `cmuxFeature` and
/// `CMUXMobileCore`; the terminal package stays an implementation detail.
public struct CMUXMobileRootScene: View {
    private let runtime: CMUXMobileRuntime

    /// Creates the root scene.
    /// - Parameter runtime: The mobile runtime that backs the shell store.
    public init(runtime: CMUXMobileRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        #if canImport(UIKit) && DEBUG
        if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else {
            CMUXMobileAppView(store: CMUXMobileShellStore(runtime: runtime))
        }
        #else
        CMUXMobileAppView(store: CMUXMobileShellStore(runtime: runtime))
        #endif
    }
}
