#if canImport(UIKit)
public import UIKit

/// Screens for workspace surfaces, injected by the composition root so the
/// workspace UI (C5, and the Workspaces placeholder until then) opens a
/// surface without importing the module that renders it. A nil slot means
/// the surface kind has no screen yet.
@MainActor
public struct SurfaceScreenFactories {
    /// Lane C2: the browser screen for one Mac browser tab.
    public var browser: ((BrowserTabInfo, HostID) -> UIViewController)?

    public init(browser: ((BrowserTabInfo, HostID) -> UIViewController)? = nil) {
        self.browser = browser
    }
}
#endif
