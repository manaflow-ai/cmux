import CmuxMobileBrowser
import Foundation

/// Owns the process-wide browser store injected into every mobile scene.
@MainActor
public final class MobileBrowserComposition {
    /// The single browser state and persistence owner for all scenes.
    public let store: BrowserSurfaceStore

    /// Creates the browser composition over an injectable persistence domain.
    /// - Parameter defaults: Defaults storage for cold-launch browser state, or
    ///   `nil` for an in-memory-only composition.
    public init(defaults: UserDefaults?) {
        store = BrowserSurfaceStore(persistenceDefaults: defaults)
    }
}
