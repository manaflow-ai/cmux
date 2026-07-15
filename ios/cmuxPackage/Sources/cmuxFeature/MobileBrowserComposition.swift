import CmuxMobileBrowser
import Foundation

/// Owns process-wide browser persistence while vending scene-local live stores.
@MainActor
public final class MobileBrowserComposition {
    private let persistenceCoordinator: BrowserSurfacePersistenceCoordinator

    /// Creates the browser composition over an injectable persistence domain.
    /// - Parameter defaults: Defaults storage for cold-launch browser state, or
    ///   `nil` for an in-memory-only composition.
    public init(defaults: UserDefaults?) {
        persistenceCoordinator = BrowserSurfacePersistenceCoordinator(defaults: defaults)
    }

    /// Creates an independent live browser store for one scene.
    ///
    /// - Parameter defaultURL: The URL a new browser loads.
    /// - Returns: A scene-owned store sharing only durable persistence and
    ///   WebKit website data with other stores from this composition.
    public func makeSceneStore(
        defaultURL: URL? = URL(string: "https://duckduckgo.com/")
    ) -> BrowserSurfaceStore {
        BrowserSurfaceStore(
            defaultURL: defaultURL,
            persistenceCoordinator: persistenceCoordinator
        )
    }

    /// Waits for archive work submitted by any scene store.
    public func flushPersistence() async {
        await persistenceCoordinator.flush()
    }
}
