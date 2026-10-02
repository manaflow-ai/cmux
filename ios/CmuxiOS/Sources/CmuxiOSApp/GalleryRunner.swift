#if DEBUG
import CmuxHomeCore
import CmuxHomeUI
import UIKit

/// Captures the Home prototype gallery once per launch.
@MainActor
enum GalleryRunner {
    static func run(store: HomeStore, window: UIWindow) {
        Task { @MainActor in
            let urls = (try? await HomeGallery.capture(into: directory, store: store, window: window)) ?? []
            try? "\(urls.count)\n".write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery", isDirectory: true)
    }
}
#endif
