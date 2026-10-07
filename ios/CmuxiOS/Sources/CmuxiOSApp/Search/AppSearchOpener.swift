import CmuxiOSSearchCore

/// Opens search results through the root's routes (lane C15). Held by the
/// root; the search feature keeps it for the shell's lifetime.
@MainActor
final class AppSearchOpener: SearchOpening {
    weak var root: RootViewController?

    func open(_ destination: SearchDestination) {
        root?.openSearchDestination(destination)
    }
}
