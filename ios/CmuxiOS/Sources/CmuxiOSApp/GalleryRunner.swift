#if DEBUG
import CmuxHomeCore
import UIKit

/// Captures the Home prototype gallery once per launch. Filled in when the
/// Home UI's `HomeGallery` lands; until then it writes nothing.
@MainActor
enum GalleryRunner {
    static func run(store: HomeStore, window: UIWindow) {}

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery", isDirectory: true)
    }
}
#endif
