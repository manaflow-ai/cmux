import Foundation

/// The app's settings store: the Settings screen writes and every module
/// reads app settings through `AppSettings.current`, so they always use the
/// same `UserDefaults` (the mock app swaps in its own suite; a module that
/// read `.standard` instead never saw the mock's toggles).
public final class AppSettings: @unchecked Sendable {
    /// "Bring tabs forward on Mac automatically" (Settings › Browser).
    public static let browserBringForwardKey = "cmuxNext.browser.bringForward"

    /// The store in use. Set once at launch, before any screen reads it.
    public nonisolated(unsafe) static var current = AppSettings(defaults: .standard)

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var browserBringForward: Bool {
        get { defaults.bool(forKey: Self.browserBringForwardKey) }
        set { defaults.set(newValue, forKey: Self.browserBringForwardKey) }
    }
}
