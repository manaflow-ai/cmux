import CmuxMobilePairedMac
import Foundation
import OSLog
import SwiftUI

#if canImport(UIKit) && DEBUG
import CmuxMobileTerminal
#endif

private let mobileRootSceneLog = Logger(subsystem: "dev.cmux.ios", category: "mobile-root-scene")

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
    private let pairedMacStore: (any MobilePairedMacStoring)?

    /// Creates the root scene.
    /// - Parameter runtime: The mobile runtime that backs the shell store.
    public init(runtime: CMUXMobileRuntime) {
        self.runtime = runtime
        // TRANSITIONAL (iOS refactor): open the SQLite paired-mac store at the
        // composition root and inject it as `any MobilePairedMacStoring`,
        // replacing the deleted `MobileShellStorePairedMacStoreFactory`
        // singleton. Opening can fail in a read-only sandbox (tests/previews);
        // the store degrades to in-memory operation when `nil`.
        do {
            self.pairedMacStore = try MobilePairedMacStore()
        } catch {
            mobileRootSceneLog.error(
                "failed to open paired mac store: \(String(describing: error), privacy: .public)"
            )
            self.pairedMacStore = nil
        }
    }

    public var body: some View {
        #if canImport(UIKit) && DEBUG
        if ProcessInfo.processInfo.environment["CMUX_ZOOM_STRESS"] == "1" {
            MobileZoomStressView()
        } else {
            CMUXMobileAppView(store: makeStore())
        }
        #else
        CMUXMobileAppView(store: makeStore())
        #endif
    }

    private func makeStore() -> CMUXMobileShellStore {
        CMUXMobileShellStore(runtime: runtime, pairedMacStore: pairedMacStore)
    }
}
