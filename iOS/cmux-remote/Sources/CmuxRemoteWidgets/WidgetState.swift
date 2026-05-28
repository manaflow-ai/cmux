import Foundation
import WidgetKit
import CmuxKit

/// Widget-extension-facing thin wrapper around `CmuxWidgetStateStore` (which
/// lives in CmuxKit so the app target can write here without importing the
/// widget extension).
enum WidgetState {
    static func load() -> CmuxWidgetEntry? {
        CmuxWidgetStateStore.shared.load()
    }

    static func reloadAllTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
